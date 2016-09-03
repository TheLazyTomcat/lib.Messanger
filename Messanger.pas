{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  Messanger

  Small library for thread-safe intraprocess communication.

  ©František Milt 2016-09-03

  Version 1.1.1

  Notes:
    - do not create instance of class TMessangerEndpoint directly by calling
      its constructor, instead use method TMessanger.CreateEndpoint
    - manage creation of all endpoints in one thread (a thread that is managing
      TMessanger instance) and then pass them to threads that needs them, do
      not create endpoints from other threads
    - on the other hand, free endpoints from threads that are using them, never
      free them from thread that is managing TMessanger instance
    - before freeing TMessanger instance, make sure all endpoints are freed from
      their respective threads

===============================================================================}
unit Messanger;

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

interface

uses
  Windows, SysUtils, Classes, SyncObjs, AuxTypes, MemVector;

const
  EndpointsCapacity = 1024; // must be less than 65535

type
  TMsgrWaitResult = (mwrNewMessage,mwrTimeout,mwrError);

  TMsgrEndpointID = UInt16;       PMsgrEndpointID = ^TMsgrEndpointID;
  TMsgrPriority   = Int32;        PMsgrPriority   = ^TMsgrPriority;
  TMsgrTimeStamp  = Int64;        PMsgrTimeStamp  = ^TMsgrTimeStamp;
  TMsgrParam      = PtrInt;       PMsgrParam      = ^TMsgrParam;

  TMsgrMessage = packed record
    Sender:     TMsgrEndpointID;
    Target:     TMsgrEndpointID;
    Priority:   TMsgrPriority;
    TimeStamp:  TMsgrTimeStamp;
    Parameter1: TMsgrParam;
    Parameter2: TMsgrParam;
    Parameter3: TMsgrParam;
    Parameter4: TMsgrParam;
  end;
  PMsgrMessage = ^TMsgrMessage;

const
  MSGR_ID_BROADCAST = TMsgrEndpointID(High(TMsgrEndpointID));

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

{==============================================================================}
{------------------------------------------------------------------------------}
{                              TMsgrMessageVector                              }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMsgrMessageVector - declaration                                           }
{==============================================================================}

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

{==============================================================================}
{------------------------------------------------------------------------------}
{                          TMsgrBufferedMessagesVector                         }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMsgrBufferedMessagesVector - declaration                                  }
{==============================================================================}

  TMsgrBufferedMessagesVector = class(TMsgrMessageVector)
  protected
    Function ItemCompare(Item1,Item2: Pointer): Integer; override;
  end;

{==============================================================================}
{------------------------------------------------------------------------------}
{                              TMessangerEndpoint                              }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMessangerEndpoint - declaration                                           }
{==============================================================================}

  TMessanger = class; // forward declaration

  TMessageTraversingEvent = procedure(Sender: TObject; Msg: TMsgrMessage; var RemoveMessage,ContinueTraversing: Boolean) of object;

  TMessangerEndpoint = class(TOBject)
  private
    fEndpointID:          TMsgrEndpointID;
    fMessanger:           TMessanger;
    fAutoBuffSend:        Boolean;
    fSynchronizer:        TCriticalSection;
    fMessageWaiter:       TEvent;
    fReceivedMessages:    TMsgrMessageVector;
    fFetchedMessages:     TMsgrMessageVector;
    fBufferedMessages:    TMsgrBufferedMessagesVector;
    fOnMessageTraversing: TMessageTraversingEvent;
    fOnDestroying:        TNotifyEvent;
  protected
    procedure AddMessages(Messages: PMsgrMessage; Count: Integer); virtual;
  public
    constructor Create(EndpointID: TMsgrEndpointID; Messanger: TMessanger);
    destructor Destroy; override;
    Function WaitForNewMessage(TimeOut: DWORD): TMsgrWaitResult; virtual;
    procedure FetchMessages; virtual;
    Function SendMessage(TargetID: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL): Boolean; overload; virtual;
    Function SendMessage(const Msg: TMsgrMessage): Boolean; overload; virtual;
    procedure BufferMessage(TargetID: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL); overload; virtual;
    procedure BufferMessage(const Msg: TMsgrMessage); overload; virtual;
    procedure SendBufferedMessages; virtual;
    Function TraverseMessages: Boolean; virtual;
  published
    property EndpointID: TMsgrEndpointID read fEndpointID;
    property AutoBuffSend: Boolean read fAutoBuffSend write fAutoBuffSend;
    property Messages: TMsgrMessageVector read fFetchedMessages;
    property OnMessageTraversing: TMessageTraversingEvent read fOnMessageTraversing write fOnMessageTraversing;
    property OnDestroying: TNotifyEvent read fOnDestroying write fOnDestroying;
  end;

{==============================================================================}
{------------------------------------------------------------------------------}
{                                  TMessanger                                  }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMessanger - declaration                                                   }
{==============================================================================}

  TMsgrEndopints = array[0..Pred(EndpointsCapacity)] of TMessangerEndpoint;

  TMessanger = class(TObject)
  private
    fEndpoints:     TMsgrEndopints;
    fSynchronizer:  TMultiReadExclusiveWriteSynchronizer;
    Function GetEndpointCapacity: Integer;
    Function GetEndpointCount: Integer;
    Function GetEndpoint(Index: Integer): TMessangerEndpoint;
  protected
    procedure RemoveEndpoint(EndpointID: TMsgrEndpointID); virtual;
    Function SendMessage(Msg: TMsgrMessage): Boolean; virtual;
    procedure SendBufferedMessages(Messages: TMsgrMessageVector); virtual;
  public
    constructor Create;
    destructor Destroy; override;
    Function IDIsFree(EndpointID: TMsgrEndpointID): Boolean; virtual;
    Function CreateEndpoint: TMessangerEndpoint; overload; virtual;
    Function CreateEndpoint(EndpointID: TMsgrEndpointID): TMessangerEndpoint; overload; virtual;
    property Endpoints[Index: Integer]: TMessangerEndpoint read GetEndpoint;
  published
    property EndpointCapacity: Integer read GetEndpointCapacity;
    property EndpointCount: Integer read GetEndpointCount;
  end;

{==============================================================================}
{   Auxiliary functions - declaration                                          }
{==============================================================================}

Function GetTimeStamp: TMsgrTimeStamp;
Function BuildMessage(Sender, Target: TMsgrEndpointID; Priority: TMsgrPriority; TimeStamp: TMsgrTimeStamp; P1,P2,P3,P4: TMsgrParam): TMsgrMessage;

implementation

{==============================================================================}
{   Auxiliary functions - implementation                                       }
{==============================================================================}

Function GetTimeStamp: TMsgrTimeStamp;
begin
Result := 0;
If not QueryPerformanceCounter(Result) then
  raise Exception.CreateFmt('GetTimeStamp: Cannot obtain time stamp (0x%.8x).',[GetLastError]);
end;

//------------------------------------------------------------------------------

Function BuildMessage(Sender, Target: TMsgrEndpointID; Priority: TMsgrPriority; TimeStamp: TMsgrTimeStamp; P1,P2,P3,P4: TMsgrParam): TMsgrMessage;
begin
Result.Sender := Sender;
Result.Target := Target;
Result.Priority := Priority;
Result.TimeStamp := TimeStamp;
Result.Parameter1 := P1;
Result.Parameter2 := P2;
Result.Parameter3 := P3;
Result.Parameter4 := P4;
end;


{==============================================================================}
{------------------------------------------------------------------------------}
{                              TMsgrMessageVector                              }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMsgrMessageVector - implementation                                        }
{==============================================================================}

{------------------------------------------------------------------------------}
{   TMsgrMessageVector - protected methods                                     }
{------------------------------------------------------------------------------}

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
Result := TMsgrMessage(Item2^).Priority - TMsgrMessage(Item1^).Priority;
If TMsgrMessage(Item2^).TimeStamp < TMsgrMessage(Item1^).TimeStamp then
  Inc(Result)
else
  Dec(Result);
end;

{------------------------------------------------------------------------------}
{   TMsgrMessageVector - public methods                                        }
{------------------------------------------------------------------------------}

constructor TMsgrMessageVector.Create;
begin
inherited Create(SizeOf(TMsgrMessage));
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
begin
Result := TMsgrMessage(inherited Extract(@Item)^);
end;


{==============================================================================}
{------------------------------------------------------------------------------}
{                          TMsgrBufferedMessagesVector                         }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMsgrBufferedMessagesVector - implementation                               }
{==============================================================================}

{------------------------------------------------------------------------------}
{   TMsgrBufferedMessagesVector - protected methods                            }
{------------------------------------------------------------------------------}

Function TMsgrBufferedMessagesVector.ItemCompare(Item1,Item2: Pointer): Integer;
begin
Result := TMsgrMessage(Item2^).Target - TMsgrMessage(Item1^).Target;
end;

{==============================================================================}
{------------------------------------------------------------------------------}
{                              TMessangerEndpoint                              }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMessangerEndpoint - implementation                                        }
{==============================================================================}

{------------------------------------------------------------------------------}
{   TMessangerEndpoint - protected methods                                     }
{------------------------------------------------------------------------------}

procedure TMessangerEndpoint.AddMessages(Messages: PMsgrMessage; Count: Integer);
begin
fSynchronizer.Enter;
try
  fReceivedMessages.Append(Messages,Count);
  fMessageWaiter.SetEvent;
finally
  fSynchronizer.Leave;
end;
end;

{------------------------------------------------------------------------------}
{   TMessangerEndpoint - public methods                                        }
{------------------------------------------------------------------------------}

constructor TMessangerEndpoint.Create(EndpointID: TMsgrEndpointID; Messanger: TMessanger);
begin
inherited Create;
fEndpointID := EndpointID;
fMessanger := Messanger;
fAutoBuffSend := False;
fSynchronizer := TCriticalSection.Create;
fMessageWaiter := TEvent.Create(nil,True,False,'');
fReceivedMessages := TMsgrMessageVector.Create;
fFetchedMessages := TMsgrMessageVector.Create;
fBufferedMessages := TMsgrBufferedMessagesVector.Create;
end;

//------------------------------------------------------------------------------

destructor TMessangerEndpoint.Destroy;
begin
fMessanger.RemoveEndpoint(fEndpointID);
If Assigned(fOnDestroying) then
  fOnDestroying(Self);
fBufferedMessages.Free;
fFetchedMessages.Free;
fReceivedMessages.Free;
fMessageWaiter.Free;
fSynchronizer.Free;
inherited;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.WaitForNewMessage(TimeOut: DWORD): TMsgrWaitResult;
begin
case fMessageWaiter.WaitFor(TimeOut) of
  wrTimeOut:  Result := mwrTimeout;
  wrSignaled: Result := mwrNewMessage;
else
  Result := mwrError;
end;
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.FetchMessages;
begin
fSynchronizer.Enter;
try
  fFetchedMessages.Append(fReceivedMessages);
  fReceivedMessages.Clear;
  fMessageWaiter.ResetEvent;
finally
  fSynchronizer.Leave;
end;
If fFetchedMessages.Count > 0 then
  fFetchedMessages.Sort;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.SendMessage(TargetID: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL): Boolean;
begin
If fAutoBuffSend then
  SendBufferedMessages;
Result := fMessanger.SendMessage(BuildMessage(fEndpointID,TargetID,Priority,GetTimeStamp,P1,P2,P3,P4));
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

Function TMessangerEndpoint.SendMessage(const Msg: TMsgrMessage): Boolean;
begin
If fAutoBuffSend then
  SendBufferedMessages;
Result := fMessanger.SendMessage(Msg);
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.BufferMessage(TargetID: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: TMsgrPriority = MSGR_PRIORITY_NORMAL);
begin
fBufferedMessages.Add(BuildMessage(fEndpointID,TargetID,Priority,GetTimeStamp,P1,P2,P3,P4));
end;

//   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---   ---

procedure TMessangerEndpoint.BufferMessage(const Msg: TMsgrMessage);
begin
fBufferedMessages.Add(Msg);
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.SendBufferedMessages;
begin
If fBufferedMessages.Count > 0 then
  begin
    fBufferedMessages.Sort;
    fMessanger.SendBufferedMessages(fBufferedMessages);
    fBufferedMessages.Clear;
  end;
end;

//------------------------------------------------------------------------------

Function TMessangerEndpoint.TraverseMessages: Boolean;
var
  i:                  Integer;
  RemoveMessage:      Boolean;
  ContinueTraversing: Boolean;
begin
Result := True;
If Assigned(fOnMessageTraversing) then
  For i := fFetchedMessages.HighIndex downto fFetchedMessages.LowIndex do
    begin
      RemoveMessage := True;
      ContinueTraversing := True;
      fOnMessageTraversing(Self,fFetchedMessages[i],RemoveMessage,ContinueTraversing);
      If RemoveMessage then
        fFetchedMessages.Delete(i);
      If not ContinueTraversing then
        begin
          Result := False;
          Break{i};
        end;
    end
else Result := False;
end;

{==============================================================================}
{------------------------------------------------------------------------------}
{                                  TMessanger                                  }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMessanger - implementation                                                }
{==============================================================================}

{------------------------------------------------------------------------------}
{   TMessanger - private methods                                               }
{------------------------------------------------------------------------------}

Function TMessanger.GetEndpointCapacity: Integer;
begin
Result := Length(fEndpoints);
end;

//------------------------------------------------------------------------------

Function TMessanger.GetEndpointCount: Integer;
var
  i:  Integer;
begin
fSynchronizer.BeginRead;
try
  Result := 0;
  For i := Low(fEndpoints) to High(fEndpoints) do
    If Assigned(fEndpoints[i]) then Inc(Result);
finally
  fSynchronizer.EndRead;
end;
end;

//------------------------------------------------------------------------------

Function TMessanger.GetEndpoint(Index: Integer): TMessangerEndpoint;
begin
Result := nil;
fSynchronizer.BeginRead;
try
  If (Index >= Low(fEndpoints)) and (Index <= High(fEndpoints)) then
    Result := fEndpoints[Index]
  else
    raise Exception.CreateFmt('TMessanger.GetEndpoint: Index (%d) out of bounds.',[Index]);
finally
  fSynchronizer.EndRead;
end;
end;

{------------------------------------------------------------------------------}
{   TMessanger - protected methods                                             }
{------------------------------------------------------------------------------}

procedure TMessanger.RemoveEndpoint(EndpointID: TMsgrEndpointID);
begin
fSynchronizer.BeginWrite;
try
  If EndpointID <= High(fEndpoints) then
    fEndpoints[EndpointID] := nil
  else
    raise Exception.CreateFmt('TMessanger.RemoveEndpoint: EndpointID (%d) out of bounds.',[EndpointID]);
finally
  fSynchronizer.EndWrite;
end;
end;

//------------------------------------------------------------------------------

Function TMessanger.SendMessage(Msg: TMsgrMessage): Boolean;
var
  i:  Integer;
begin
Result := False;
fSynchronizer.BeginRead;
try
  If Msg.Target = MSGR_ID_BROADCAST then
    begin
      For i := Low(fEndpoints) to High(fEndpoints) do
        If Assigned(fEndpoints[i]) then
          fEndpoints[i].AddMessages(@Msg,1);
      Result := True;
    end
  else
    begin
      If Msg.Target <= High(fEndpoints) then
        If Assigned(fEndpoints[Msg.Target]) then
          begin
            fEndpoints[Msg.Target].AddMessages(@Msg,1);
            Result := True;
          end
    end;
finally
  fSynchronizer.EndRead;
end;
end;

//------------------------------------------------------------------------------

procedure TMessanger.SendBufferedMessages(Messages: TMsgrMessageVector);
var
  i:        Integer;
  StartIdx: Integer;
  Count:    Integer;

  procedure DoSending;
  var
    ii: Integer;
  begin
    If Messages[StartIdx].Target = MSGR_ID_BROADCAST then
      begin
        For ii := Low(fEndpoints) to High(fEndpoints) do
          If Assigned(fEndpoints[ii]) then
            fEndpoints[ii].AddMessages(Messages.Pointers[StartIdx],Count);
      end
    else
      begin
        If Messages[StartIdx].Target <= High(fEndpoints) then
          If Assigned(fEndpoints[Messages[StartIdx].Target]) then
            fEndpoints[Messages[StartIdx].Target].AddMessages(Messages.Pointers[StartIdx],Count);
      end;
  end;

begin
If Messages.Count > 0 then
  begin
    fSynchronizer.BeginRead;
    try
      StartIdx := Messages.LowIndex;
      while StartIdx <= Messages.HighIndex do
        begin
          Count := 1;
          For i := Succ(StartIdx) to Messages.HighIndex do
            If Messages[StartIdx].Target = Messages[i].Target then
              Inc(Count)
            else
              Break{i};
          DoSending;
          StartIdx := StartIdx + Count;    
        end;
    finally
      fSynchronizer.EndRead;
    end;
  end;
end;

{------------------------------------------------------------------------------}
{   TMessanger - public methods                                                }
{------------------------------------------------------------------------------}

constructor TMessanger.Create;
begin
inherited Create;
fSynchronizer := TMultiReadExclusiveWriteSynchronizer.Create;
end;

//------------------------------------------------------------------------------

destructor TMessanger.Destroy;
var
  i:  Integer;
begin
For i := Low(fEndpoints) to High(fEndpoints) do
  FreeAndNil(fEndpoints[i]);
fSynchronizer.Free;
inherited;
end;

//------------------------------------------------------------------------------

Function TMessanger.IDIsFree(EndpointID: TMsgrEndpointID): Boolean;
begin
fSynchronizer.BeginRead;
try
  If EndpointID <= High(fEndpoints) then
    Result := not Assigned(fEndpoints[EndpointID])
  else
    Result := False;
finally
  fSynchronizer.EndRead;
end;
end;

//------------------------------------------------------------------------------

Function TMessanger.CreateEndpoint: TMessangerEndpoint;
var
  i,Idx:  Integer;
begin
Result := nil;
fSynchronizer.BeginWrite;
try
  Idx := -1;
  For i := Low(fEndpoints) to High(fEndpoints) do
    If not Assigned(fEndpoints[i]) then
      begin
        Idx := i;
        Break {For i};
      end;
  If Idx >= 0 then
    begin
      Result := TMessangerEndpoint.Create(TMsgrEndpointID(Idx),Self);
      fEndpoints[Idx] := Result;
    end
  else raise Exception.Create('TMessanger.CreateEndpoint: No endpoint slot available.');
finally
  fSynchronizer.EndWrite;
end;
end;

//------------------------------------------------------------------------------

Function TMessanger.CreateEndpoint(EndpointID: TMsgrEndpointID): TMessangerEndpoint;
begin
Result := nil;
fSynchronizer.BeginWrite;
try
  If EndpointID <= High(fEndpoints) then
    begin
      If not Assigned(fEndpoints[EndpointID]) then
        begin
          Result := TMessangerEndpoint.Create(EndpointID,Self);
          fEndpoints[EndpointID] := Result;
        end
      else raise Exception.CreateFmt('TMessanger.CreateEndpoint: Requested endpoint ID (%d) is already taken.',[EndpointID]);
    end
  else raise Exception.CreateFmt('TMessanger.CreateEndpoint: Requested endpoint ID (%d) is not allocated.',[EndpointID]);
finally
  fSynchronizer.EndWrite;
end;
end;

end.
