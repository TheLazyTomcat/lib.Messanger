{-------------------------------------------------------------------------------

  This Source Code Form is subject to the terms of the Mozilla Public
  License, v. 2.0. If a copy of the MPL was not distributed with this
  file, You can obtain one at http://mozilla.org/MPL/2.0/.

-------------------------------------------------------------------------------}
{===============================================================================

  Messanger

  Small library for thread-safe intraprocess communication.

  ©František Milt 2016-03-07

  Version 1.0.1

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
  Windows, SysUtils, SyncObjs, AuxTypes, MemVector;

type
  TMsgrWaitResult = (mwrNewMessage,mwrTimeout,mwrError);

  TMsgrParam = PtrInt;
  PMsgrParam = ^TMsgrParam;

  TMsgrEndpointID = UInt16;

  TMsgrMessage = packed record
    Sender:     TMsgrEndpointID;
    Target:     TMsgrEndpointID;
    Priority:   Int32;
    TimeStamp:  Int64;
    Parameter1: TMsgrParam;
    Parameter2: TMsgrParam;
    Parameter3: TMsgrParam;
    Parameter4: TMsgrParam;
  end;
  PMsgrMessage = ^TMsgrMessage;

const
  MSGR_BROADCAST = $FFFF;

  MSGR_MAXENDPOINTS = $FFFE;

  MSGR_PRIORITY_MINIMAL       = -100000;
  MSGR_PRIORITY_EXTREME_LOW   = -10000;
  MSGR_PRIORITY_VERY_LOW      = -1000;
  MSGR_PRIORITY_LOW           = -100;
  MSGR_PRIORITY_BELOW_NORMAL  = -10;
  MSGR_PRIORITY_NORMAL        = 0;
  MSGR_PRIORITY_ABOVE_NORMAL  = 10;
  MSGR_PRIORITY_HIGH          = 100;
  MSGR_PRIORITY_VERY_HIGH     = 1000;
  MSGR_PRIORITY_EXTREME_HIGH  = 10000;
  MSGR_PRIORITY_ABSOLUTE      = 100000;

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
{                              TMessangerEndpoint                              }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMessangerEndpoint - declaration                                           }
{==============================================================================}

  TMessanger = class; // forward declaration

  TMessangerEndpoint = class(TOBject)
  private
    fEndpointID:        TMsgrEndpointID;
    fMessanger:         TMessanger;
    fAutoBuffSend:      Boolean;
    fSynchronizer:      TCriticalSection;
    fMessageWaiter:     TEvent;
    fReceivedMessages:  TMsgrMessageVector;
    fFetchedMessages:   TMsgrMessageVector;
    fBufferedMessages:  TMsgrMessageVector;
  protected
    procedure AddMessages(Messages: PMsgrMessage; Count: Integer); virtual;
  public
    constructor Create(EndpointID: TMsgrEndpointID; Messanger: TMessanger);
    destructor Destroy; override;
    Function WaitForNewMessage(TimeOut: DWORD): TMsgrWaitResult; virtual;
    procedure FetchMessages; virtual;
    Function SendMessage(TargetID: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: Integer = MSGR_PRIORITY_NORMAL): Boolean; virtual;
    procedure BufferMessage(TargetID: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: Integer = MSGR_PRIORITY_NORMAL); virtual;
    procedure SendBufferedMessages; virtual;
  published
    property EndpointID: TMsgrEndpointID read fEndpointID;
    property AutoBuffSend: Boolean read fAutoBuffSend write fAutoBuffSend;
    property Messages: TMsgrMessageVector read fFetchedMessages;
  end;

{==============================================================================}
{------------------------------------------------------------------------------}
{                                  TMessanger                                  }
{------------------------------------------------------------------------------}
{==============================================================================}

{==============================================================================}
{   TMessanger - declaration                                                   }
{==============================================================================}

  TMessanger = class(TObject)
  private
    fEndpoints:     array of TMessangerEndpoint;
    fSynchronizer:  TMultiReadExclusiveWriteSynchronizer;
    Function GetEndpointCapacity: Integer;
    Function GetEndpointCount: Integer;
    Function GetEndpoint(Index: Integer): TMessangerEndpoint;
  protected
    procedure RemoveEndpoint(EndpointID: TMsgrEndpointID); virtual;
    Function SendMessage(Message: TMsgrMessage): Boolean; virtual;
    procedure SendBufferedMessages(Messages: TMsgrMessageVector); virtual;
    procedure AddSlots(UpTo: Integer = -1); virtual;
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


implementation

uses
  Math;

{==============================================================================}
{   Auxiliary functions                                                        }
{==============================================================================}

Function GetTimeStamp: Int64;
begin
Result := 0;
If not QueryPerformanceCounter(Result) then
  raise Exception.CreateFmt('GetTimeStamp: Cannot obtain time stamp (0x%.8x).',[GetLastError]);
end;

//------------------------------------------------------------------------------

Function BuildMessage(Sender, Target: TMsgrEndpointID; Priority: Int32; TimeStamp: Int64;
                      Parameter1, Parameter2, Parameter3, Parameter4: TMsgrParam): TMsgrMessage;
begin
Result.Sender := Sender;
Result.Target := Target;
Result.Priority := Priority;
Result.TimeStamp := TimeStamp;
Result.Parameter1 := Parameter1;
Result.Parameter2 := Parameter2;
Result.Parameter3 := Parameter3;
Result.Parameter4 := Parameter4;
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
fBufferedMessages := TMsgrMessageVector.Create;
end;

//------------------------------------------------------------------------------

destructor TMessangerEndpoint.Destroy;
begin
fMessanger.RemoveEndpoint(fEndpointID);
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

Function TMessangerEndpoint.SendMessage(TargetID: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: Integer = MSGR_PRIORITY_NORMAL): Boolean;
begin
If fAutoBuffSend then
  SendBufferedMessages;
Result := fMessanger.SendMessage(BuildMessage(fEndpointID,TargetID,Priority,GetTimeStamp,P1,P2,P3,P4));
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.BufferMessage(TargetID: TMsgrEndpointID; P1,P2,P3,P4: TMsgrParam; Priority: Integer = MSGR_PRIORITY_NORMAL);
begin
If fBufferedMessages.Count > 0 then
  If fBufferedMessages[fBufferedMessages.LowIndex].Target <> TargetID then
    SendBufferedMessages;
fBufferedMessages.Add(BuildMessage(fEndpointID,TargetID,Priority,GetTimeStamp,P1,P2,P3,P4));
end;

//------------------------------------------------------------------------------

procedure TMessangerEndpoint.SendBufferedMessages;
begin
If fBufferedMessages.Count > 0 then
  begin
    fMessanger.SendBufferedMessages(fBufferedMessages);
    fBufferedMessages.Clear;
  end;
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
fSynchronizer.BeginRead;
try
  Result := Length(fEndpoints);
finally
  fSynchronizer.EndRead;
end;
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

Function TMessanger.SendMessage(Message: TMsgrMessage): Boolean;
var
  i:  Integer;
begin
Result := False;
fSynchronizer.BeginRead;
try
  If Message.Target = MSGR_BROADCAST then
    begin
      For i := Low(fEndpoints) to High(fEndpoints) do
        If Assigned(fEndpoints[i]) then
          fEndpoints[i].AddMessages(@Message,1);
      Result := True;
    end
  else
    begin
      If Message.Target <= High(fEndpoints) then
        If Assigned(fEndpoints[Message.Target]) then
          begin
            fEndpoints[Message.Target].AddMessages(@Message,1);
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
  i:  Integer;
begin
fSynchronizer.BeginRead;
try
  If Messages.Count > 0 then
    If Messages[Messages.LowIndex].Target = MSGR_BROADCAST then
      begin
        For i := Low(fEndpoints) to High(fEndpoints) do
          If Assigned(fEndpoints[i]) then
            fEndpoints[i].AddMessages(Messages.Memory,Messages.Count);
      end
    else
      begin
        If Messages[Messages.LowIndex].Target <= High(fEndpoints) then
          If Assigned(fEndpoints[Messages[Messages.LowIndex].Target]) then
            fEndpoints[Messages[Messages.LowIndex].Target].AddMessages(Messages.Memory,Messages.Count);
      end;
finally
  fSynchronizer.EndRead;
end;
end;

//------------------------------------------------------------------------------

procedure TMessanger.AddSlots(UpTo: Integer = -1);
begin
fSynchronizer.BeginWrite;
try
  If UpTo < 0 then
    begin
      If Length(fEndpoints) < MSGR_MAXENDPOINTS then
        SetLength(fEndpoints,Length(fEndpoints) + Min(16,MSGR_MAXENDPOINTS - Length(fEndpoints)))
      else
        raise Exception.Create('TMessanger.AddSlots: No additional endpoint slot available.');
    end
  else
    begin
      If UpTo <= MSGR_MAXENDPOINTS then
        begin
          If High(fEndpoints) < UpTo then
            SetLength(fEndpoints,UpTo);
        end
      else raise Exception.CreateFmt('TMessanger.AddSlots: Required endpoint slot (%d) is out of bounds.',[UpTo]);
    end;
finally
  fSynchronizer.EndWrite;
end;
end;

{------------------------------------------------------------------------------}
{   TMessanger - public methods                                                }
{------------------------------------------------------------------------------}

constructor TMessanger.Create;
begin
inherited Create;
SetLength(fEndpoints,0);
fSynchronizer := TMultiReadExclusiveWriteSynchronizer.Create;
end;

//------------------------------------------------------------------------------

destructor TMessanger.Destroy;
var
  i:  Integer;
begin
For i := Low(fEndpoints) to High(fEndpoints) do
  FreeAndNil(fEndpoints[i]);
SetLength(fEndpoints,0);
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
fSynchronizer.BeginWrite;
try
  Idx := -1;
  For i := Low(fEndpoints) to High(fEndpoints) do
    If not Assigned(fEndpoints[i]) then
      begin
        Idx := i;
        Break {For i};
      end;
  If Idx < 0 then
    begin
      Idx := Length(fEndpoints);
      AddSlots;
    end;
  Result := TMessangerEndpoint.Create(Idx,Self);
  fEndpoints[Idx] := Result;
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
  AddSlots(EndpointID);
  If not Assigned(fEndpoints[EndpointID]) then
    begin
      Result := TMessangerEndpoint.Create(EndpointID,Self);
      fEndpoints[EndpointID] := Result;
    end
  else raise Exception.CreateFmt('TMessanger.CreateEndpoint: Requested endpoint ID (%d) is already taken.',[EndpointID]);
finally
  fSynchronizer.EndWrite;
end;
end;

end.
