{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  Messanger

  Small library for thread-safe intraprocess communication.

  ©František Milt 2018-10-22

  Version 1.2.3

  Notes:
    - do not create instance of class TMessangerEndpoint directly by calling
      its constructor, instead use method(s) TMessanger.CreateEndpoint
    - manage creation of all endpoints in one thread (a thread that is managing
      TMessanger instance) and then pass them to threads that needs them, do
      not create endpoints from other threads
    - on the other hand, free endpoints from threads that are using them, never
      free them from thread that is managing TMessanger instance
    - before freeing TMessanger instance, make sure all endpoints are freed from
      their respective threads, otherwise an exception will be raised when
      TMessanger instance is freed
    - use synchronous messages only when really necessary, bulk of the
      communication should be asynchronous
    - do not send synchronous messages from event handlers - it is possible as
      long as synchronous dispatch is not active (in that case, send function
      will fail), but discouraged

  Dependencies:
    AuxTypes    - github.com/ncs-sniper/Lib.AuxTypes
    AuxClasses  - github.com/ncs-sniper/Lib.AuxClasses
    MemVector   - github.com/ncs-sniper/Lib.MemVector
    WinSyncObjs - github.com/ncs-sniper/Lib.WinSyncObjs
    StrRect     - github.com/ncs-sniper/Lib.StrRect

===============================================================================}
unit Messanger;
{$message 'write how to use it'}
{$IFDEF FPC}
  {$MODE ObjFPC}
{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  AuxTypes, AuxClasses, MemVector, CrossSyncObjs;

{===============================================================================
    Library specific exceptions
===============================================================================}
type
  EMsgrException = class(Exception);

  EMsgrTimestampError   = class(EMsgrException);
  EMsgrIndexOutOfBounds = class(EMsgrException);
  EMsgrInvalidValue     = class(EMsgrException);
  EMsgrInvalidState     = class(EMsgrException);
  EMsgrNoResources      = class(EMsgrException);

{===============================================================================
    Common types and constants
===============================================================================}
type
  TMsgrEndpointID = UInt16;       PMsgrEndpointID = ^TMsgrEndpointID;
  TMsgrPriority   = Int32;        PMsgrPriority   = ^TMsgrPriority;
  TMsgrTimestamp  = Int64;        PMsgrTimestamp  = ^TMsgrTimestamp;
  TMsgrParam      = PtrInt;       PMsgrParam      = ^TMsgrParam;
  TMsgrSendParam  = Pointer;      PMsgrSendParam  = ^TMsgrSendParam;

type
{
  TMsgrMessage is used only internally, do not use it anywhere else.
}
  TMsgrMessage = packed record
    Sender:     TMsgrEndpointID;
    Recipient:  TMsgrEndpointID;
    Priority:   TMsgrPriority;
    Timestamp:  TMsgrTimestamp;
    Parameter1: TMsgrParam;
    Parameter2: TMsgrParam;
    Parameter3: TMsgrParam;
    Parameter4: TMsgrParam;
    SendParam:  TMsgrSendParam;  // used for synchronous communication
  end;
  PMsgrMessage = ^TMsgrMessage;

{
  TMsgrMessageIn is used in places where an incoming messages is passed for
  processing by the user.
}
  TMsgrMessageIn = record
    Sender:     TMsgrEndpointID;
    Parameter1: TMsgrParam;
    Parameter2: TMsgrParam;
    Parameter3: TMsgrParam;
    Parameter4: TMsgrParam;
  end;

{
  TMsgrMessageOut is used in sending of messages, where user passes can pass
  this structure in place of number of individual parameters.
}
  TMsgrMessageOut = record
    Recipient:  TMsgrEndpointID;
    Priority:   TMsgrPriority;
    Parameter1: TMsgrParam;
    Parameter2: TMsgrParam;
    Parameter3: TMsgrParam;
    Parameter4: TMsgrParam;    
  end;

const
{
  When selecting MSGR_ID_BROADCAST as a recipient, the message will be posted
  to all existing endpoints (including the sender).

    WARNING - this is only possible for posted messages, trying to broadcast
              synchronous message will always fail.
}
  MSGR_ID_BROADCAST = TMsgrEndpointID(High(TMsgrEndpointID)); // $FFFF

{
  Note that, when received messages are sorted for processing, the priority
  takes precedence over timestamp, meaning messages with higher priority are
  processed sooner than messages sent before them but with lower priority.
}
  MSGR_PRIORITY_MINIMAL       = TMsgrPriority(-100000);
  MSGR_PRIORITY_EXTREME_LOW   = TMsgrPriority(-10000);
  MSGR_PRIORITY_VERY_LOW      = TMsgrPriority(-1000);
  MSGR_PRIORITY_LOW           = TMsgrPriority(-100);
  MSGR_PRIORITY_BELOW_NORMAL  = TMsgrPriority(-10);
  MSGR_PRIORITY_NORMAL        = TMsgrPriority(0);
  MSGR_PRIORITY_ABOVE_NORMAL  = TMsgrPriority(10);
  MSGR_PRIORITY_HIGH          = TMsgrPriority(100);
  MSGR_PRIORITY_VERY_HIGH     = TMsgrPriority(1000);
  MSGR_PRIORITY_EXTREME_HIGH  = TMsgrPriority(10000);
  MSGR_PRIORITY_ABSOLUTE      = TMsgrPriority(100000);

  MSGR_PRIORITY_MIN = MSGR_PRIORITY_MINIMAL;
  MSGR_PRIORITY_MAX = MSGR_PRIORITY_ABSOLUTE;

  // infinite timeout
  INFINITE = UInt32(-1);

{===============================================================================
--------------------------------------------------------------------------------
                               TMsgrMessageVector
--------------------------------------------------------------------------------
===============================================================================}
{
  Class TMsgrMessageVector is only for internal purposes.
}
{===============================================================================
    TMsgrMessageVector - class declaration
===============================================================================}
type
  TMsgrMessageVector = class(TMemVector)
  protected
    Function GetItem(Index: Integer): TMsgrMessage; virtual;
    procedure SetItem(Index: Integer; Value: TMsgrMessage); virtual;
    Function ItemCompare(Item1,Item2: Pointer): Integer; override;
  public
    constructor Create; overload;
    constructor Create(Memory: Pointer; Count: Integer); overload;
    Function First: TMsgrMessage; reintroduce;
    Function Last: TMsgrMessage; reintroduce;
    Function IndexOf(Item: TMsgrMessage): Integer; reintroduce;
    Function Add(Item: TMsgrMessage): Integer; reintroduce;
    procedure Insert(Index: Integer; Item: TMsgrMessage); reintroduce;
    Function Remove(Item: TMsgrMessage): Integer; reintroduce;
    Function Extract(Item: TMsgrMessage): TMsgrMessage; reintroduce;
    property Items[Index: Integer]: TMsgrMessage read GetItem write SetItem; default;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                           TMsgrBufferedMessagesVector
--------------------------------------------------------------------------------
===============================================================================}
{
  Class TMsgrBufferedMessagesVector is only for internal purposes.
}
{===============================================================================
    TMsgrBufferedMessagesVector - class declaration
===============================================================================}
type
  TMsgrBufferedMessageVector = class(TMsgrMessageVector)
  protected
    Function ItemCompare(Item1,Item2: Pointer): Integer; override;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                               TMessangerEndpoint
--------------------------------------------------------------------------------
===============================================================================}
type
{
  Dispatch flags are serving two purposes - on enter to the handler, they can
  contain flags the handler can use to discern details about the currently
  processed message and also about the state of the messanger endpoint.
  Also, the handler can include or exclude some flags from the set - some flags
  are checked after the handle returns, and their presence or absence is used
  to control further dispatching or workings of the endpoint.

  Individual flags can be in, out, or in-out in nature.

    In flags are included before the handler is called, so it can probe them.
    Removing or adding them has no effect as they are ignored after the handler
    returns.

    Out flags are never included before the call, but handler can include them
    to control further processing.

    In-out flags can be both included before the call and also excluded or
    included to the set by the handler.


  mdfSentMessage (in)         - informs the handler that the current message
                                was sent synchronously (ie. using Send* method,
                                not Post* methods) and sender is waiting for
                                its processing

  mdfUndeliveredMessage (in)  - currently processed message is an undelivered
                                buffered message

  mdfSendBlocked (in)         - any sending or posting is blocked and will fail

  mdfStopDispatching (out)    - when added by the handler, orders the dispatcher
                                to stop dispatching further messages after the
                                current one

  mdfAutoCycle (in-out)       - when included on enter, informs the handler
                                that the endpoint is running the autocycle, by
                                removing this flag, handler can break the
                                autocycle, note that adding this flag when it
                                is not present will NOT activate the autocycle
}
  TMsgrDispatchFlag = (mdfSentMessage,mdfUndeliveredMessage,mdfSendBlocked,
                       mdfStopDispatching,mdfAutoCycle);

  TMsgrDispatchFlags = set of TMsgrDispatchFlag;

  TMsgrWaitResult = (mwrMessage,mwrTimeout,mwrError);

  TMsgrMessageInEvent    = procedure(Sender: TObject; Msg: TMsgrMessageIn; var Flags: TMsgrDispatchFlags) of object;
  TMsgrMessageInCallback = procedure(Sender: TObject; Msg: TMsgrMessageIn; var Flags: TMsgrDispatchFlags);

  TMsgrMessageOutEvent    = procedure(Sender: TObject; Msg: TMsgrMessageOut; var Flags: TMsgrDispatchFlags) of object;
  TMsgrMessageOutCallback = procedure(Sender: TObject; Msg: TMsgrMessageOut; var Flags: TMsgrDispatchFlags);

{===============================================================================
    TMessangerEndpoint - class declaration
===============================================================================}
type
  TMessangerEndpoint = class(TCustomObject)
  protected
    fMessanger:               TObject;              // should be TMessanger class
    fEndpointID:              TMsgrEndpointID;
    fAutoBuffSend:            Boolean;
    fSendLevelMax:            Integer;
    // runtime variables
    fSendLevel:               Integer;
    fAutoCycle:               Boolean;
    fSendBlocked:             Boolean;
    fReactFlags:              UInt32;
    // synchronizers
    fIncomingSynchronizer:    TCriticalSectionRTL;  // protects vector of incoming messages
    fReactEvent:              TEvent;
    // message storage vectors
    fIncomingSentMessages:    TMsgrMessageVector;
    fIncomingPostedMessages:  TMsgrMessageVector;
    fReceivedSentMessages:    TMsgrMessageVector;
    fReceivedPostedMessages:  TMsgrMessageVector;
    fBufferedMessages:        TMsgrBufferedMessageVector;
    fUndeliveredMessages:     TMsgrMessageVector;   // stores undelivered buffered messages
    // events
    fOnMessageEvent:          TMsgrMessageInEvent;
    fOnMessageCallback:       TMsgrMessageInCallback;
    fOnUndeliveredEvent:      TMsgrMessageOutEvent;
    fOnUndeliveredCallback:   TMsgrMessageOutCallback;
    fOnDestroyingEvent:       TNotifyEvent;
    fOnDestroyingCallback:    TNotifyCallback;
    // getters, setters
    Function GetMessageCount: Integer;
    Function GetMessage(Index: Integer): TMsgrMessage;
    // methods called from other (sender) threads
    procedure ReceiveSentMessages(Messages: PMsgrMessage; Count: Integer); virtual;
    procedure ReceivePostedMessages(Messages: PMsgrMessage; Count: Integer); virtual;
    // message dispatching
    procedure SentMessagesDispatch; virtual;
    procedure PostedMessagesDispatch; virtual;
    procedure UndeliveredDispatch; virtual;
    // events firing
    procedure DoMessage(Msg: TMsgrMessageIn; var Flags: TMsgrDispatchFlags); virtual;
    procedure DoUndelivered(Msg: TMsgrMessageOut; var Flags: TMsgrDispatchFlags); virtual;
    procedure DoDestroying; virtual;
    // init/final
    procedure Initialize(EndpointID: TMsgrEndpointID; Messanger: TObject); virtual;
    procedure Finalize; virtual;
    // utility
    Function MsgOutToMsg(Msg: TMsgrMessageOut; SendParamPtr: PMsgrSendParam): TMsgrMessage; virtual;
    Function MsgToMsgIn(Msg: TMsgrMessage): TMsgrMessageIn; virtual;
    Function MsgToMsgOut(Msg: TMsgrMessage): TMsgrMessageOut; virtual;
  public
  {
    Do not call the constructor, use TMessanger instance to create a new
    endpoint object.
  }
    constructor Create(EndpointID: TMsgrEndpointID; Messanger: TObject);
    destructor Destroy; override;
    // message sending methods
  {
    SendMessage will send the passed message and then waits - it will not
    return until the message has been processed by the recipient.

    It will return true only when the message was received AND processed by the
    recipient. So, in case the message was delivered, but not processed (eg.
    because the recipient was destroyed), it will return false.

    The endpoint can receive and dispatch other sent messages (not posted ones).
    This means that, while you are still waiting for the SendMessage to return,
    the endpoint can and will call message handler.
    It is to prevent a deadlock when the recipient responds by sending another
    synchronous message back to the sender within its message dispatch.    

    It is allowed to send another synchronous message from a message handler,
    but as this creates a complex recursion, it is limited - see SendLevel and
    SendLevelMaximum properties.

    It is not allowed to use MSGR_ID_BROADCAST as a recipient - synchronous
    messages cannot be broadcasted.

    If AutomaticBufferedSend is set to true and message sending is not blocked
    (see property SendBlocked), then all buffered messages are posted before
    the actual sending is performed.
  }
    Function SendMessage(Recipient: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL): Boolean; overload; virtual;
    Function SendMessage(Msg: TMsgrMessageOut): Boolean; overload; virtual;
  {
    PostMessage adds the passed message to the recipient's incoming messages
    and immediately exits.

    Use MSGR_ID_BROADCAST as a recipient to post the message to all existing
    endpoints (sender also receives a copy).

    If AutomaticBufferedSend is set to true and message sending is not blocked
    (see property SendBlocked), then all buffered messages are posted before
    the actual posting is performed.    
  }
    Function PostMessage(Recipient: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL): Boolean; overload; virtual;
    Function PostMessage(Msg: TMsgrMessageOut): Boolean; overload; virtual;
  {
    BufferMessage merely adds the passed message to internal storage, preparing
    it for future posting.

    This is here to optimize rapid posting of large number of messages - they
    can be buffered and then posted all at once, significantly reducing the
    operation overhead.

    MSGR_ID_BROADCAST can be used as s recipient to post the message to all
    existing endpoints (including the sender).
  }
    procedure BufferMessage(Recipient: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL); overload; virtual;
    procedure BufferMessage(Msg: TMsgrMessageOut); overload; virtual;
  {
    PostBufferedMessages posts all buffered messages at once to their respective
    recipients.

    If some of the messages cannot be delivered, they are passed at the end of
    the processing to the OnUndelivered* event/callback.
    If both OnUndeliveredCallback and OnUndeliveredEvent (equivalent to
    OnUndelivered) then only the event is called. If none is assigned, then
    the messages are dropped an deleted.

    Note that while in OnUndelivered* handler, all message sending and posting
    is blocked (property SendBlocked is true).
  }
    procedure PostBufferedMessages; virtual;
    // operation methods
  {
    WaitForMessage waits until a new message is received, timeout elapses (you
    can use INFINITE constant for infinite wait) or an error occurs.
    Whichever happened is indicated by the result.
  }
    Function WaitForMessage(Timeout: UInt32): TMsgrWaitResult; virtual;
  {
    FetchMessages copies incoming messages (those deposited to a shared location
    by other endpoints) into local storage (received messages), where they can
    be accessed without the overhead of thread synchronization and locking.
  }
    procedure FetchMessages; virtual;
  {
    When any of OnMessage(Event) or OnMessageCallback is assigned, it will
    traverse all received messages, passing each of them to the handler for
    processing (this process is called dispatching).

    All sent messages are dispatched first, the posted right after them. They
    are dispatched in order of ther priority (from higher to lower) and time of
    sending/posting (from olders to newest). Note that priority takes precedence
    over the time.

    If both OnMessageEvent (which is equivalent to OnMessage) and
    OnMessageCallback are assigned, then only the OnMessageEvent is called.

    When no event or callback is assigned, it only clears all received messages.
  }
    procedure DispatchMessages; virtual;
  {
    ClearMessages deletes all received messags without dispatching them.

    Note that senders waiting for sent messages to be processed will be
    released be the messages will NOT be marked as processed, meaning the
    respective SendMessage methods will return false.
  }
    procedure ClearMessages; virtual;
  {
    Calling Cycle is equivalent to the following sequence:

      If WaitForMessage(Timeout) = mwrMessage then
        begin
          FetchMessages;
          DispatchMessages;
        end;
  }
    procedure Cycle(Timeout: UInt32); virtual;
  {

    If autocycle is already running when calling this method, it will do
    nothing and immediately returns.
  }
    procedure AutoCycle(Timeout: UInt32); virtual;
    procedure BreakAutoCycle; virtual;
    // properties
    property EndpointID: TMsgrEndpointID read fEndpointID;
    property AutomaticBufferedSend: Boolean read fAutoBuffSend write fAutoBuffSend;
    property SendLevelMaximum: Integer read fSendLevelMax write fSendLevelMax;
    property SendLevel: Integer read fSendLevel;
    property InAutoCycle: Boolean read fAutoCycle;
    property SendBlocked: Boolean read fSendBlocked;
    property MessageCount: Integer read GetMessageCount;
    property Messages[Index: Integer]: TMsgrMessage read GetMessage;
    property OnMessageCallback: TMsgrMessageInCallback read fOnMessageCallback write fOnMessageCallback;
    property OnMessageEvent: TMsgrMessageInEvent read fOnMessageEvent write fOnMessageEvent;
    property OnMessage: TMsgrMessageInEvent read fOnMessageEvent write fOnMessageEvent;
    property OnUndeliveredCallback: TMsgrMessageOutCallback read fOnUndeliveredCallback write fOnUndeliveredCallback;
    property OnUndeliveredEvent: TMsgrMessageOutEvent read fOnUndeliveredEvent write fOnUndeliveredEvent;
    property OnUndelivered: TMsgrMessageOutEvent read fOnUndeliveredEvent write fOnUndeliveredEvent;
  end;

{===============================================================================
--------------------------------------------------------------------------------
                                   TMessanger
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TMessanger - class declaration
===============================================================================}
type
  TMessanger = class(TCustomObject)
  protected
    fEndpoints:     array of TMessangerEndpoint;
    fSynchronizer:  TMultiReadExclusiveWriteSynchronizerRTL;
    // getters, setters
    Function GetEndpointCapacity: Integer;
    Function GetEndpointCount: Integer;
    Function GetEndpoint(Index: Integer): TMessangerEndpoint;
    // methods called from endpoint
    procedure RemoveEndpoint(EndpointID: TMsgrEndpointID); virtual;
    Function SendMessage(Msg: TMsgrMessage): Boolean; virtual;
    Function PostMessage(Msg: TMsgrMessage): Boolean; virtual;
    procedure PostBufferedMessages(Messages,Undelivered: TMsgrMessageVector); virtual;
    // init, final
    procedure Initialize(EndpointCapacity: TMsgrEndpointID); virtual;
    procedure Finalize; virtual;
  public
    constructor Create(EndpointCapacity: TMsgrEndpointID = 128);
    destructor Destroy; override;
    Function IDAvailable(EndpointID: TMsgrEndpointID): Boolean; virtual;
    Function CreateEndpoint: TMessangerEndpoint; overload; virtual;
    Function CreateEndpoint(EndpointID: TMsgrEndpointID): TMessangerEndpoint; overload; virtual;
    // properties
    property Endpoints[Index: Integer]: TMessangerEndpoint read GetEndpoint;
    property EndpointCapacity: Integer read GetEndpointCapacity;
    property EndpointCount: Integer read GetEndpointCount;
  end;

{===============================================================================
    Public auxiliary functions - declaration
===============================================================================}

Function BuildMessage(Recipient: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL): TMsgrMessageOut;

implementation

uses
  Windows,
  InterlockedOps;

{===============================================================================
    Internal auxiliary functions
===============================================================================}

Function GetTimestamp: TMsgrTimestamp;
begin
Result := 0;
If QueryPerformanceCounter(Result) then
  Result := Result and $7FFFFFFFFFFFFFFF  // mask out sign bit
else
  raise EMsgrTimestampError.CreateFmt('GetTimestamp: Cannot obtain time stamp (%d).',[GetLastError]);
end;

{===============================================================================
    Public auxiliary functions - implementation
===============================================================================}

Function BuildMessage(Recipient: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL): TMsgrMessageOut;
begin
Result.Recipient := Recipient;
Result.Priority := Priority;
Result.Parameter1 := P1;
Result.Parameter2 := P2;
Result.Parameter3 := P3;
Result.Parameter4 := P4;
end;


{===============================================================================
--------------------------------------------------------------------------------
                               TMsgrMessageVector
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TMsgrMessageVector - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TMsgrMessageVector - protected methods
-------------------------------------------------------------------------------}

Function TMsgrMessageVector.GetItem(Index: Integer): TMsgrMessage;
begin
Result := TMsgrMessage(GetItemPtr(Index)^);
end;

//------------------------------------------------------------------------------

procedure TMsgrMessageVector.SetItem(Index: Integer; Value: TMsgrMessage);
begin
SetItemPtr(Index,@Value);
end;

//------------------------------------------------------------------------------

Function TMsgrMessageVector.ItemCompare(Item1,Item2: Pointer): Integer;
begin
{
  Because messages are traversed from high index to low, the sorting is done in
  reversed order.
}
Result := 0;
If Assigned(TMsgrMessage(Item1^).SendParam) xor Assigned(TMsgrMessage(Item2^).SendParam) then
  begin
    If Assigned(TMsgrMessage(Item1^).SendParam) then
      Result := +1    // first is assigned, second is not => change order
    else
      Result := -1;   // first in not assigned, second is => keep order
  end
else
  begin
  {
    Both are assigned or not assigned, decide upon other parameters - first
    take priority (must go up), then Timestamp (down).
  }
    If TMsgrMessage(Item1^).Priority > TMsgrMessage(Item2^).Priority then
      Result := +1
    else If TMsgrMessage(Item1^).Priority < TMsgrMessage(Item2^).Priority then
      Result := -1
    else
      begin
        If TMsgrMessage(Item1^).Timestamp < TMsgrMessage(Item2^).Timestamp then
          Result := +1
        else If TMsgrMessage(Item1^).Timestamp > TMsgrMessage(Item2^).Timestamp then
          Result := -1;
      end; 
  end;
end;

{-------------------------------------------------------------------------------
    TMsgrMessageVector - public methods
-------------------------------------------------------------------------------}

constructor TMsgrMessageVector.Create;
begin
inherited Create(SizeOf(TMsgrMessage));
ShrinkMode := smKeepCap;
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

constructor TMsgrMessageVector.Create(Memory: Pointer; Count: Integer);
begin
inherited Create(Memory,Count,SizeOf(TMsgrMessage));
end;

//------------------------------------------------------------------------------

Function TMsgrMessageVector.First: TMsgrMessage;
begin
Result := TMsgrMessage(inherited First^);
end;

//------------------------------------------------------------------------------

Function TMsgrMessageVector.Last: TMsgrMessage;
begin
Result := TMsgrMessage(inherited Last^);
end;

//------------------------------------------------------------------------------

Function TMsgrMessageVector.IndexOf(Item: TMsgrMessage): Integer;
begin
Result := inherited IndexOf(@Item);
end;

//------------------------------------------------------------------------------

Function TMsgrMessageVector.Add(Item: TMsgrMessage): Integer;
begin
Result := inherited Add(@Item);
end;

//------------------------------------------------------------------------------

procedure TMsgrMessageVector.Insert(Index: Integer; Item: TMsgrMessage);
begin
inherited Insert(Index,@Item);
end;

//------------------------------------------------------------------------------

Function TMsgrMessageVector.Remove(Item: TMsgrMessage): Integer;
begin
Result := inherited Remove(@Item);
end;

//------------------------------------------------------------------------------

Function TMsgrMessageVector.Extract(Item: TMsgrMessage): TMsgrMessage;
var
  TempPtr:  Pointer;
begin
TempPtr := inherited Extract(@Item);
If Assigned(TempPtr) then
  Result := TMsgrMessage(TempPtr^)
else
  FillChar(Result,SizeOf(Result),0);
end;


{===============================================================================
--------------------------------------------------------------------------------
                           TMsgrBufferedMessagesVector
--------------------------------------------------------------------------------
===============================================================================}
{===============================================================================
    TMsgrBufferedMessageVector - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TMsgrBufferedMessageVector - protected methods
-------------------------------------------------------------------------------}

Function TMsgrBufferedMessageVector.ItemCompare(Item1,Item2: Pointer): Integer;
begin
{
  TMsgrBufferedMessageVector is sorted only by recipients, so there is no need
  for other comparisons.
}
Result := Integer(TMsgrMessage(Item2^).Recipient) - Integer(TMsgrMessage(Item1^).Recipient);
end;


{===============================================================================
--------------------------------------------------------------------------------
                               TMessangerEndpoint
--------------------------------------------------------------------------------
===============================================================================}
const
  MSGR_REACT_FLAG_MESSAGE = $00000001;

  MSGR_REACT_FLAGBIT_MESSAGE = 0;

  MSGR_SEND_FLAG_RELEASED  = $00000001;
  MSGR_SEND_FLAG_PROCESSED = $00000002;

  MSGR_SEND_FLAGBIT_RELEASED  = 0;
  MSGR_SEND_FLAGBIT_PROCESSED = 1;

  MSGR_SEND_LEVEL_MAX = 128;

type
  TMsgrSendRecord = record
    Flags:  UInt32;
    Event:  TEvent; // react event (this field should be a pointer)
  end;
  PMsgrSendRecord = ^TMsgrSendRecord;

{===============================================================================
    TMessangerEndpoint - class implementation
===============================================================================}
{-------------------------------------------------------------------------------
    TMessangerEndpoint - protected methods
-------------------------------------------------------------------------------}

Function TMessangerEndpoint.GetMessageCount: Integer;
begin
Result := fReceivedSentMessages.Count + fReceivedPostedMessages.Count;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.GetMessage(Index: Integer): TMsgrMessage;
begin
If (Index >= 0) and (Index < (fReceivedSentMessages.Count + fReceivedPostedMessages.Count)) then
  begin
    If Index > fReceivedSentMessages.HighIndex then
      Result := fReceivedPostedMessages[Index - fReceivedSentMessages.Count]
    else
      Result := fReceivedSentMessages[Index];
  end
else raise EMsgrIndexOutOfBounds.CreateFmt('TMessangerEndpoint.GetMessage: Index (%d) out of bounds.',[Index]);
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.ReceiveSentMessages(Messages: PMsgrMessage; Count: Integer);
begin
If Count > 0 then
  begin
    fIncomingSynchronizer.Lock;
    try
      fIncomingSentMessages.Append(Messages,Count);
      InterlockedBitTestAndSet(fReactFlags,MSGR_REACT_FLAGBIT_MESSAGE);
      fReactEvent.Unlock;
    finally
      fIncomingSynchronizer.Unlock;
    end;
  end;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.ReceivePostedMessages(Messages: PMsgrMessage; Count: Integer);
begin
If Count > 0 then
  begin
    fIncomingSynchronizer.Lock;
    try
      fIncomingPostedMessages.Append(Messages,Count);
      InterlockedBitTestAndSet(fReactFlags,MSGR_REACT_FLAGBIT_MESSAGE);
      fReactEvent.Unlock;
    finally
      fIncomingSynchronizer.Unlock;
    end;
  end;
end;


//------------------------------------------------------------------------------

procedure TMessangerEndpoint.SentMessagesDispatch;
var
  TempMsg:  TMsgrMessage;
  Flags:    TMsgrDispatchFlags;
  i:        Integer;
begin
If Assigned(fOnMessageEvent) or Assigned(fOnMessageCallback) then
  begin
    while fReceivedSentMessages.Count > 0 do
      begin
        // create local copy of the processed message
        TempMsg := fReceivedSentMessages[fReceivedSentMessages.HighIndex];
        // prepare flags
        Flags := [mdfSentMessage];
        If fAutoCycle then
          Include(Flags,mdfAutoCycle);
        If fSendBlocked then
          Include(Flags,mdfSendBlocked);
      {
        Delete the message now - another dispatch can occur inside of DoMessage
        call, which can change the fReceivedSentMessages list under our hands!
      }
        fReceivedSentMessages.Delete(fReceivedSentMessages.HighIndex);
        // call event
        DoMessage(MsgToMsgIn(TempMsg),Flags);
        // release sender
        InterlockedOr(PMsgrSendRecord(TempMsg.SendParam)^.Flags,MSGR_SEND_FLAG_RELEASED or MSGR_SEND_FLAG_PROCESSED);
        PMsgrSendRecord(TempMsg.SendParam)^.Event.Unlock;
        // process output flags
        fAutoCycle := fAutoCycle and (mdfAutoCycle in Flags);
        If mdfStopDispatching in Flags then
          Break{For i};
      end;
  end
else
  begin
    // no handler assigned, release waiting senders and remove all messages
    For i := fReceivedSentMessages.HighIndex downto fReceivedSentMessages.LowIndex do
      begin
        InterlockedBitTestAndSet(PMsgrSendRecord(fReceivedSentMessages[i].SendParam)^.Flags,MSGR_SEND_FLAGBIT_RELEASED);
        PMsgrSendRecord(fReceivedSentMessages[i].SendParam)^.Event.Unlock;
      end;
    fReceivedSentMessages.Clear;
  end;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.PostedMessagesDispatch;
var
  TempMsg:  TMsgrMessage;
  Flags:    TMsgrDispatchFlags;
begin
If Assigned(fOnMessageEvent) or Assigned(fOnMessageCallback) then
  begin
    while fReceivedPostedMessages.Count > 0 do
      begin
        TempMsg := fReceivedPostedMessages[fReceivedPostedMessages.HighIndex];
        Flags := [];
        If fAutoCycle then
          Include(Flags,mdfAutoCycle);
        If fSendBlocked then
          Include(Flags,mdfSendBlocked);          
        fReceivedPostedMessages.Delete(fReceivedPostedMessages.HighIndex);
        DoMessage(MsgToMsgIn(TempMsg),Flags);
        fAutoCycle := fAutoCycle and (mdfAutoCycle in Flags);
        If mdfStopDispatching in Flags then
          Break{For i};
      end;
  end
else fReceivedPostedMessages.Clear;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.UndeliveredDispatch;
var
  i:      Integer;
  Flags:  TMsgrDispatchFlags;
begin
fSendBlocked := True;
try
  If Assigned(fOnUndeliveredEvent) or Assigned(fOnUndeliveredCallback) then
    begin
      fUndeliveredMessages.Sort;
      For i := fUndeliveredMessages.HighIndex downto fUndeliveredMessages.LowIndex do
        begin
          // prepare flags
          Flags := [mdfUndeliveredMessage,mdfSendBlocked];
          If fAutoCycle then
            Include(Flags,mdfAutoCycle);
          // call event
          DoUndelivered(MsgToMsgOut(fUndeliveredMessages[i]),Flags);
          // process output flags
          fAutoCycle := fAutoCycle and (mdfAutoCycle in Flags);
          If mdfStopDispatching in Flags then
            Break{For i};
        end;
    end;
  fUndeliveredMessages.Clear;
finally
  fSendBlocked := False;
end;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.DoMessage(Msg: TMsgrMessageIn; var Flags: TMsgrDispatchFlags);
begin
If Assigned(fOnMessageEvent) then
  fOnMessageEvent(Self,Msg,Flags)
else If Assigned(fOnMessageCallback) then
  fOnMessageCallback(Self,Msg,Flags);
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.DoUndelivered(Msg: TMsgrMessageOut; var Flags: TMsgrDispatchFlags);
begin
If Assigned(fOnUndeliveredEvent) then
  fOnUndeliveredEvent(Self,Msg,Flags)
else If Assigned(fOnUndeliveredCallback) then
  fOnUndeliveredCallback(Self,Msg,Flags);
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.DoDestroying;
begin
If Assigned(fOnDestroyingEvent) then
  fOnDestroyingEvent(Self)
else If Assigned(fOnDestroyingCallback) then
  fOnDestroyingCallback(Self);
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.Initialize(EndpointID: TMsgrEndpointID; Messanger: TObject);
begin
fMessanger := Messanger;
fEndpointID := EndpointID;
fAutoBuffSend := True;
fSendLevelMax := MSGR_SEND_LEVEL_MAX;
// runtime variables
fSendLevel := 0;
fAutoCycle := False;
fSendBlocked := False;
fReactFlags := 0;
// synchronizers
fIncomingSynchronizer := TCriticalSectionRTL.Create;
fReactEvent := TEvent.Create(False,False);
// message storage vectors
fIncomingSentMessages := TMsgrMessageVector.Create;
fIncomingPostedMessages := TMsgrMessageVector.Create;
fReceivedSentMessages := TMsgrMessageVector.Create;
fReceivedPostedMessages := TMsgrMessageVector.Create;
fBufferedMessages := TMsgrBufferedMessageVector.Create;
fUndeliveredMessages := TMsgrMessageVector.Create;
// events
fOnMessageEvent := nil;
fOnMessageCallback := nil;
fOnUndeliveredEvent := nil;
fOnUndeliveredCallback := nil;
fOnDestroyingEvent := nil;
fOnDestroyingCallback := nil;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.Finalize;
begin
// prevent sending of new messages
fSendBlocked := True;
// remove self from messanger (prevents receiving of new messages)
TMessanger(fMessanger).RemoveEndpoint(fEndpointID);
// fetch messages and give user a chance to process them
FetchMessages;
DispatchMessages; // clears the messages if handler is not assigned
// dispatch buffered messages as undelivered
fUndeliveredMessages.Assign(fBufferedMessages);
fBufferedMessages.Clear;
UndeliveredDispatch;
// call destoring event
DoDestroying;
// free vectors
fUndeliveredMessages.Free;
fBufferedMessages.Free;
fReceivedPostedMessages.Free;
fReceivedSentMessages.Free;
fIncomingPostedMessages.Free;
fIncomingSentMessages.Free;
// free synchronizers
fReactEvent.Free;
fIncomingSynchronizer.Free;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.MsgOutToMsg(Msg: TMsgrMessageOut; SendParamPtr: PMsgrSendParam): TMsgrMessage;
begin
Result.Sender := fEndpointID;
Result.Recipient := Msg.Recipient;
Result.Priority := Msg.Priority;
Result.Timestamp := GetTimestamp;
Result.Parameter1 := Msg.Parameter1;
Result.Parameter2 := Msg.Parameter2;
Result.Parameter3 := Msg.Parameter3;
Result.Parameter4 := Msg.Parameter4;
Result.SendParam := SendParamPtr;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.MsgToMsgIn(Msg: TMsgrMessage): TMsgrMessageIn;
begin
Result.Sender := Msg.Sender;
Result.Parameter1 := Msg.Parameter1;
Result.Parameter2 := Msg.Parameter2;
Result.Parameter3 := Msg.Parameter3;
Result.Parameter4 := Msg.Parameter4;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.MsgToMsgOut(Msg: TMsgrMessage): TMsgrMessageOut;
begin
Result.Recipient := Msg.Recipient;
Result.Priority := Msg.Priority;
Result.Parameter1 := Msg.Parameter1;
Result.Parameter2 := Msg.Parameter2;
Result.Parameter3 := Msg.Parameter3;
Result.Parameter4 := Msg.Parameter4;
end;

{-------------------------------------------------------------------------------
    TMessangerEndpoint - public methods
-------------------------------------------------------------------------------}

constructor TMessangerEndpoint.Create(EndpointID: TMsgrEndpointID; Messanger: TObject);
begin
inherited Create;
Initialize(EndpointID,Messanger);
end;

//------------------------------------------------------------------------------

destructor TMessangerEndpoint.Destroy;
begin
Finalize;
inherited;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.SendMessage(Recipient: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL): Boolean;
begin
Result := SendMessage(BuildMessage(Recipient,P1,P2,P3,P4,Priority));
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.SendMessage(Msg: TMsgrMessageOut): Boolean;
var
  SendRecord: TMsgrSendRecord;
  ExitWait:   Boolean;
  TempFlags:  UInt32;
begin
Result := False;
If not fSendBlocked then
  begin
    If fAutoBuffSend then
      PostBufferedMessages;
    If (fSendLevel < fSendLevelMax) and (Msg.Recipient <> MSGR_ID_BROADCAST) then
      begin
        Inc(fSendLevel);
        try
          SendRecord.Flags := 0;
          SendRecord.Event := fReactEvent;
          If TMessanger(fMessanger).SendMessage(MsgOutToMsg(Msg,@SendRecord)) then
            repeat
              If not InterlockedBitTest(SendRecord.Flags,MSGR_SEND_FLAGBIT_RELEASED) then
                fReactEvent.Wait(INFINITE);
              If InterlockedBitTestAndReset(fReactFlags,MSGR_REACT_FLAGBIT_MESSAGE) then
                begin
                  // some messages were received, dispatch the sent ones
                  FetchMessages;
                  SentMessagesDispatch;
                end;
              // look if the message was processed
              TempFlags := InterlockedLoad(SendRecord.Flags);
              ExitWait := (TempFlags and MSGR_SEND_FLAG_RELEASED) <> 0;
              Result := ExitWait and ((TempFlags and MSGR_SEND_FLAG_PROCESSED) <> 0);
            until ExitWait;
        finally
          Dec(fSendLevel);
        end;
      end;
  end;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.PostMessage(Recipient: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL): Boolean;
begin
Result := PostMessage(BuildMessage(Recipient,P1,P2,P3,P4,Priority));
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

Function TMessangerEndpoint.PostMessage(Msg: TMsgrMessageOut): Boolean;
begin
If not fSendBlocked then
  begin
    If fAutoBuffSend then
      PostBufferedMessages;
    Result := TMessanger(fMessanger).PostMessage(MsgOutToMsg(Msg,nil));
  end
else Result := False;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.BufferMessage(Recipient: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL);
begin
BufferMessage(BuildMessage(Recipient,P1,P2,P3,P4,Priority));
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

procedure TMessangerEndpoint.BufferMessage(Msg: TMsgrMessageOut);
begin
fBufferedMessages.Add(MsgOutToMsg(Msg,nil));
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.PostBufferedMessages;
begin
If not fSendBlocked then
  begin
    If fBufferedMessages.Count > 0 then
      begin
        fBufferedMessages.Sort;
        TMessanger(fMessanger).PostBufferedMessages(fBufferedMessages,fUndeliveredMessages);
        fBufferedMessages.Clear;
      end;
    UndeliveredDispatch;
  end;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.WaitForMessage(Timeout: UInt32): TMsgrWaitResult;
var
  ExitWait: Boolean;
begin
repeat
  ExitWait := True;
  Result := mwrMessage;
  case fReactEvent.Wait(Timeout) of
    wrTimeout:  Result := mwrTimeout;
    wrSignaled: If not InterlockedBitTestAndReset(fReactFlags,MSGR_REACT_FLAGBIT_MESSAGE) then
                  ExitWait := False;
  else
    Result := mwrError;
  end;
until ExitWait;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.FetchMessages;
begin
fIncomingSynchronizer.Lock;
try
  fReceivedSentMessages.Append(fIncomingSentMessages);
  fReceivedPostedMessages.Append(fIncomingPostedMessages);
  fIncomingSentMessages.Clear;
  fIncomingPostedMessages.Clear;
finally
  fIncomingSynchronizer.Unlock;
end;
fReceivedSentMessages.Sort;
fReceivedPostedMessages.Sort;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.DispatchMessages;
begin
SentMessagesDispatch;
PostedMessagesDispatch;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.ClearMessages;
var
  i:  Integer;
begin
// release waiting senders
For i := fReceivedSentMessages.HighIndex downto fReceivedSentMessages.LowIndex do
  begin
    InterlockedBitTestAndSet(PMsgrSendRecord(fReceivedSentMessages[i].SendParam)^.Flags,MSGR_SEND_FLAGBIT_RELEASED);
    PMsgrSendRecord(fReceivedSentMessages[i].SendParam)^.Event.Unlock;
  end;
fReceivedSentMessages.Clear;
fReceivedPostedMessages.Clear;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.Cycle(Timeout: UInt32);
begin
If WaitForMessage(Timeout) = mwrMessage then
  begin
    FetchMessages;
    DispatchMessages;
  end;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.AutoCycle(Timeout: UInt32);
begin
If not fAutoCycle then
  begin
    fAutoCycle := True;
    while fAutoCycle do
      Cycle(Timeout);
  end;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.BreakAutoCycle;
begin
fAutoCycle := False;
end;


{==============================================================================}
{------------------------------------------------------------------------------}
{                                  TMessanger                                  }
{------------------------------------------------------------------------------}
{==============================================================================}
{===============================================================================
    TMessanger - class implementation
===============================================================================}
{------------------------------------------------------------------------------
    TMessanger - protected methods
-------------------------------------------------------------------------------}

Function TMessanger.GetEndpointCapacity: Integer;
begin
Result := Length(fEndpoints);
end;

//------------------------------------------------------------------------------

Function TMessanger.GetEndpointCount: Integer;
var
  i:  Integer;
begin
fSynchronizer.ReadLock;
try
  Result := 0;
  For i := Low(fEndpoints) to High(fEndpoints) do
    If Assigned(fEndpoints[i]) then Inc(Result);
finally
  fSynchronizer.ReadUnlock;
end;
end;

//------------------------------------------------------------------------------

Function TMessanger.GetEndpoint(Index: Integer): TMessangerEndpoint;
begin
Result := nil;
fSynchronizer.ReadLock;
try
  If (Index >= Low(fEndpoints)) and (Index <= High(fEndpoints)) then
    Result := fEndpoints[Index]
  else
    raise EMsgrIndexOutOfBounds.CreateFmt('TMessanger.GetEndpoint: Index (%d) out of bounds.',[Index]);
finally
  fSynchronizer.ReadUnlock;
end;
end;

//------------------------------------------------------------------------------

procedure TMessanger.RemoveEndpoint(EndpointID: TMsgrEndpointID);
begin
fSynchronizer.WriteLock;
try
  If EndpointID <= High(fEndpoints) then
    fEndpoints[EndpointID] := nil
  else
    raise EMsgrIndexOutOfBounds.CreateFmt('TMessanger.RemoveEndpoint: EndpointID (%d) out of bounds.',[EndpointID]);
finally
  fSynchronizer.WriteUnlock;
end;
end;

//------------------------------------------------------------------------------

Function TMessanger.SendMessage(Msg: TMsgrMessage): Boolean;
begin
Result := False;
fSynchronizer.ReadLock;
try
  If Msg.Recipient <= High(fEndpoints) then
    If Assigned(fEndpoints[Msg.Recipient]) then
      begin
        fEndpoints[Msg.Recipient].ReceiveSentMessages(@Msg,1);
        Result := True;
      end;
finally
  fSynchronizer.ReadUnlock;
end;
end;

//------------------------------------------------------------------------------

Function TMessanger.PostMessage(Msg: TMsgrMessage): Boolean;
var
  i:  Integer;
begin
Result := False;
fSynchronizer.ReadLock;
try
  If Msg.Recipient = MSGR_ID_BROADCAST then
    begin
      For i := Low(fEndpoints) to High(fEndpoints) do
        If Assigned(fEndpoints[i]) then
          begin
            fEndpoints[i].ReceivePostedMessages(@Msg,1);
            Result := True;
          end;
    end
  else
    begin
      If Msg.Recipient <= High(fEndpoints) then
        If Assigned(fEndpoints[Msg.Recipient]) then
          begin
            fEndpoints[Msg.Recipient].ReceivePostedMessages(@Msg,1);
            Result := True;
          end;
    end;
finally
  fSynchronizer.ReadUnlock;
end;
end;

//------------------------------------------------------------------------------

procedure TMessanger.PostBufferedMessages(Messages,Undelivered: TMsgrMessageVector);

  Function SendMessages(Start,Count: Integer): Boolean;
  var
    i:  Integer;
  begin
    Result := False;
    If Messages[Start].Recipient = MSGR_ID_BROADCAST then
      begin
        For i := Low(fEndpoints) to High(fEndpoints) do
          If Assigned(fEndpoints[i]) then
            begin
              fEndpoints[i].ReceivePostedMessages(Messages.Pointers[Start],Count);
              Result := True;
            end;
      end
    else
      begin
        If Messages[Start].Recipient <= High(fEndpoints) then
          If Assigned(fEndpoints[Messages[Start].Recipient]) then
            begin
              fEndpoints[Messages[Start].Recipient].ReceivePostedMessages(Messages.Pointers[Start],Count);
              Result := True;
            end;
      end;
  end;

var
  Start:  Integer;
  Count:  Integer;
  i:      Integer;  
begin
If Messages.Count > 0 then
  begin
    fSynchronizer.ReadLock;
    try
      // the messages are sorted by recipient id
      Start := Messages.LowIndex;
      while Start <= Messages.HighIndex do
        begin
          Count := 1;
          For i := Succ(Start) to Messages.HighIndex do
            If Messages[i].Recipient = Messages[Start].Recipient then
              Inc(Count)
            else
              Break{For i};
          If not SendMessages(Start,Count) then
            Undelivered.Assign(Messages.Pointers[Start],Count);
          Start := Start + Count;
        end;
    finally
      fSynchronizer.ReadUnlock;
    end;
  end;
end;

//------------------------------------------------------------------------------

procedure TMessanger.Initialize(EndpointCapacity: TMsgrEndpointID);
begin
// High(TMsgrEndpointID) = $FFFF(65535) is reserved for broadcast
If EndpointCapacity < High(TMsgrEndpointID) then
  SetLength(fEndpoints,EndpointCapacity)
else
  raise EMsgrInvalidValue.CreateFmt('TMessanger.Initialize: Required capacity (%d) is too high.',[EndpointCapacity]);
fSynchronizer := TMultiReadExclusiveWriteSynchronizerRTL.Create;
end;

//------------------------------------------------------------------------------

procedure TMessanger.Finalize;
begin
If EndpointCount > 0 then
  raise EMsgrInvalidState.Create('TMessanger.Finalize: Not all endpoints were freed.');
fSynchronizer.Free;
end;

{-------------------------------------------------------------------------------
    TMessanger - public methods
-------------------------------------------------------------------------------}

constructor TMessanger.Create(EndpointCapacity: TMsgrEndpointID = 128);
begin
inherited Create;
Initialize(EndpointCapacity);
end;

//------------------------------------------------------------------------------

destructor TMessanger.Destroy;
begin
Finalize;
inherited;
end;

//------------------------------------------------------------------------------

Function TMessanger.IDAvailable(EndpointID: TMsgrEndpointID): Boolean;
begin
fSynchronizer.ReadLock;
try
  If EndpointID <= High(fEndpoints) then
    Result := not Assigned(fEndpoints[EndpointID])
  else
    Result := False;
finally
  fSynchronizer.ReadUnlock;
end;
end;

//------------------------------------------------------------------------------

Function TMessanger.CreateEndpoint: TMessangerEndpoint;
var
  i,Idx:  Integer;
begin
Result := nil;
fSynchronizer.WriteLock;
try
  Idx := -1;
  For i := Low(fEndpoints) to High(fEndpoints) do
    If not Assigned(fEndpoints[i]) then
      begin
        Idx := i;
        Break{For i};
      end;
  If Idx >= 0 then
    begin
      Result := TMessangerEndpoint.Create(TMsgrEndpointID(Idx),Self);
      fEndpoints[Idx] := Result;
    end
  else raise EMsgrNoResources.Create('TMessanger.CreateEndpoint: No endpoint slot available.');
finally
  fSynchronizer.WriteUnlock;
end;
end;

//------------------------------------------------------------------------------

Function TMessanger.CreateEndpoint(EndpointID: TMsgrEndpointID): TMessangerEndpoint;
begin
Result := nil;
fSynchronizer.WriteLock;
try
  If EndpointID <= High(fEndpoints) then
    begin
      If not Assigned(fEndpoints[EndpointID]) then
        begin
          Result := TMessangerEndpoint.Create(EndpointID,Self);
          fEndpoints[EndpointID] := Result;
        end
      else raise EMsgrInvalidValue.CreateFmt('TMessanger.CreateEndpoint: Requested endpoint ID (%d) is already taken.',[EndpointID]);
    end
  else raise EMsgrNoResources.CreateFmt('TMessanger.CreateEndpoint: Requested endpoint ID (%d) is not allocated.',[EndpointID]);
finally
  fSynchronizer.WriteUnlock;
end;
end;

end.
