{$MODE objfpc}

uses
  SysUtils,
  Objects,
  skMHL,
  skOpen,
  skCommon;

const
  SortBase   : Boolean   = False;
  DedupBase  : Boolean   = False;
  AppendMode : Boolean   = False;
  DefTZUTC   : String[5] = '0000';

type
  TIndexRecCollection = object(TSortedCollection)
    function Compare(Key1, Key2: Pointer): Longint; virtual;
    procedure FreeItem(Item: Pointer); virtual;
    procedure SortReplyChains; virtual;
    procedure DedupByKey; virtual;
  end;

  PIndexRec = ^TIndexRec;
  TIndexRec = record
    Index, MsgNum: Longint;
    WrittenTimeUTC: Int64;
    FromAddress: TAddress;
    ToAddress: TAddress;
    MSGID: PString;
    REPLY: PString;
    HasTZUTC: Boolean;
    FromName: PString;
    ToName: PString;
    Subject: PString;
  end;

  TIndexRecArray = array of PIndexRec;
  TLongintArray = array of Longint;
  TInt64Array = array of Int64;
  TBoolArray = array of Boolean;

var
  SourceBase, DestBase: PMessageBase;
  SourceTextStream, DestTextStream: PMessageBaseStream;
  MsgDT: TMessageBaseDateTime;
  SourceBaseID, DestBaseID, SourceBasePath, DestBasePath, SourceFormat, DestFormat, S: String;
  SourceTMBF, DestTMBF: TMessageBaseFormat;
  IndexRec: PIndexRec;
  IndexRecCollection: TIndexRecCollection;
  DefTZUTCI, I, Err: Longint;

function NewPString(const S: String): PString;
begin
  GetMem(Result, Length(S) + 1);
  Result^ := S;
end;

procedure DisposePString(var PS: PString);
begin
  FreeMem(PS, Length(PS^) + 1);
  PS := nil;
end;

function TIndexRecCollection.Compare(Key1, Key2: Pointer): Longint;
begin
  if not SortBase then
    Compare := -1
  else
  if PIndexRec(Key1)^.WrittenTimeUTC < PIndexRec(Key2)^.WrittenTimeUTC then
    Compare := -1
  else
  if PIndexRec(Key1)^.WrittenTimeUTC > PIndexRec(Key2)^.WrittenTimeUTC then
    Compare := 1
  else
    Compare := 0;
end;

procedure TIndexRecCollection.FreeItem(Item: Pointer);
begin
  with TIndexRec(Item^) do
  begin
    DisposePString(FromName);
    DisposePString(ToName);
    DisposePString(Subject);
    DisposePString(MSGID);
    if SortBase then
      DisposePString(REPLY);
  end;
  Dispose(PIndexRec(Item));
end;

{ orders messages by MSGID, equal MSGIDs keep their original order }
function CompareMSGID(var Recs: TIndexRecArray; A, B: Longint): Longint;
begin
  if Recs[A]^.MSGID^ < Recs[B]^.MSGID^ then
    Result := -1
  else
  if Recs[A]^.MSGID^ > Recs[B]^.MSGID^ then
    Result := 1
  else
    Result := A - B;
end;

procedure SortByMSGID(var Recs: TIndexRecArray; var Idx: TLongintArray; L, R: Longint);
var
  I, J, P, T: Longint;
begin
  repeat
    I := L;
    J := R;
    P := Idx[(L + R) div 2];
    repeat
      while CompareMSGID(Recs, Idx[I], P) < 0 do
        Inc(I);
      while CompareMSGID(Recs, Idx[J], P) > 0 do
        Dec(J);
      if I <= J then
      begin
        T := Idx[I];
        Idx[I] := Idx[J];
        Idx[J] := T;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    if L < J then
      SortByMSGID(Recs, Idx, L, J);
    L := I;
  until L >= R;
end;

{ orders messages by sort key, equal keys keep their original order }
function CompareSortKey(var Key: TInt64Array; A, B: Longint): Longint;
begin
  if Key[A] < Key[B] then
    Result := -1
  else
  if Key[A] > Key[B] then
    Result := 1
  else
    Result := A - B;
end;

procedure SortBySortKey(var Key: TInt64Array; var Idx: TLongintArray; L, R: Longint);
var
  I, J, P, T: Longint;
begin
  repeat
    I := L;
    J := R;
    P := Idx[(L + R) div 2];
    repeat
      while CompareSortKey(Key, Idx[I], P) < 0 do
        Inc(I);
      while CompareSortKey(Key, Idx[J], P) > 0 do
        Dec(J);
      if I <= J then
      begin
        T := Idx[I];
        Idx[I] := Idx[J];
        Idx[J] := T;
        Inc(I);
        Dec(J);
      end;
    until I > J;
    if L < J then
      SortBySortKey(Key, Idx, L, J);
    L := I;
  until L >= R;
end;

{ Reorders messages so that every reply follows the message it replies to.

  Ordering constraints are applied to a sort key instead of moving messages
  around, so every step is a single pass and the result cannot depend on the
  order in which violations happen to be found. The key is the written date in
  Unix seconds, the same value the collection is already sorted by, therefore
  a base without violations keeps its order untouched.

  Messages having a TZUTC kludge carry a reliable date and are kept in place
  as long as the order can be repaired by moving messages without TZUTC.
  Messages are moved against their reliable date only as a last resort, when
  their own reply chain leaves no other option. }

procedure TIndexRecCollection.SortReplyChains;
var
  Recs: TIndexRecArray;
  Key: TInt64Array;
  Idx, Parent, Order, ChildHead, NextChild, Stack, State: TLongintArray;
  Pulled: TBoolArray;
  N, I, J, K, L, R, M, C, P, SP: Longint;
begin
  N := Count;
  if N < 2 then
    Exit;

  SetLength(Recs, N);
  SetLength(Key, N);
  for I := 0 to N - 1 do
  begin
    Recs[I] := At(I);
    Key[I] := Recs[I]^.WrittenTimeUTC;
  end;

  { index messages by MSGID to look parents up without scanning the base }
  SetLength(Idx, N);
  for I := 0 to N - 1 do
    Idx[I] := I;
  SortByMSGID(Recs, Idx, 0, N - 1);

  SetLength(Parent, N);
  for I := 0 to N - 1 do
  begin
    Parent[I] := -1;
    if Recs[I]^.REPLY^ = '' then
      Continue;

    { locate the first message carrying the referenced MSGID }
    L := 0;
    R := N - 1;
    M := -1;
    while L <= R do
    begin
      K := (L + R) div 2;
      if Recs[Idx[K]]^.MSGID^ < Recs[I]^.REPLY^ then
        L := K + 1
      else
      begin
        if Recs[Idx[K]]^.MSGID^ = Recs[I]^.REPLY^ then
          M := K;
        R := K - 1;
      end;
    end;
    if M = -1 then
      Continue;

    { with duplicated MSGIDs prefer the nearest preceding message, it needs no
      move at all, and fall back to the first following one }
    P := -1;
    K := M;
    while (K < N) and (Recs[Idx[K]]^.MSGID^ = Recs[I]^.REPLY^) do
    begin
      C := Idx[K];
      if C < I then
        P := C
      else
      if C > I then
      begin
        if P = -1 then
          P := C;
        Break;
      end;
      Inc(K);
    end;
    Parent[I] := P;
  end;

  { drop references closing a loop, such messages have no valid order }
  SetLength(State, N);
  SetLength(Stack, N);
  for I := 0 to N - 1 do
    State[I] := 0;
  for I := 0 to N - 1 do
  begin
    if State[I] <> 0 then
      Continue;
    SP := 0;
    J := I;
    while (J <> -1) and (State[J] = 0) do
    begin
      State[J] := 1;
      Stack[SP] := J;
      Inc(SP);
      J := Parent[J];
    end;
    if (J <> -1) and (State[J] = 1) then
    begin
      WriteLn('[WARN] Reply loop detected at message #', Recs[Stack[SP - 1]]^.MsgNum,
              ', ignoring its REPLY reference');
      Parent[Stack[SP - 1]] := -1;
    end;
    while SP > 0 do
    begin
      Dec(SP);
      State[Stack[SP]] := 2;
    end;
  end;

  { references now form a forest, collect children of every message }
  SetLength(ChildHead, N);
  SetLength(NextChild, N);
  for I := 0 to N - 1 do
  begin
    ChildHead[I] := -1;
    NextChild[I] := -1;
  end;
  for I := N - 1 downto 0 do
    if Parent[I] <> -1 then
    begin
      NextChild[I] := ChildHead[Parent[I]];
      ChildHead[Parent[I]] := I;
    end;

  { walk the forest from roots to leaves, every message is visited after the
    message it replies to }
  SetLength(Order, N);
  K := 0;
  SP := 0;
  for I := N - 1 downto 0 do
    if Parent[I] = -1 then
    begin
      Stack[SP] := I;
      Inc(SP);
    end;
  while SP > 0 do
  begin
    Dec(SP);
    J := Stack[SP];
    State[J] := 3;
    Order[K] := J;
    Inc(K);
    C := ChildHead[J];
    while C <> -1 do
    begin
      Stack[SP] := C;
      Inc(SP);
      C := NextChild[C];
    end;
  end;

  { messages left out of the traversal would mean a loop survived, drop their
    references and keep them where they are rather than lose them }
  if K < N then
    for I := 0 to N - 1 do
      if State[I] <> 3 then
      begin
        Parent[I] := -1;
        Order[K] := I;
        Inc(K);
      end;

  { leaves to roots: a message without TZUTC standing behind its own reply got
    its date guessed wrong, so pull it in front of that reply. Pulled messages
    anchor their parents in turn, which drags a whole chain of messages with
    guessed dates in front of a reply having a reliable one }
  SetLength(Pulled, N);
  for I := 0 to N - 1 do
    Pulled[I] := False;
  for K := N - 1 downto 0 do
  begin
    I := Order[K];
    P := Parent[I];
    if (P = -1) or Recs[P]^.HasTZUTC then
      Continue;
    if not (Recs[I]^.HasTZUTC or Pulled[I]) then
      Continue;
    if (Key[P] > Key[I]) or ((Key[P] = Key[I]) and (P > I)) then
    begin
      Key[P] := Key[I] - 1;
      Pulled[P] := True;
    end;
  end;

  { roots to leaves: whatever is still out of order can only be fixed by moving
    the reply itself behind its parent, even when its date is a reliable one }
  for K := 0 to N - 1 do
  begin
    I := Order[K];
    P := Parent[I];
    if P = -1 then
      Continue;
    if (Key[I] > Key[P]) or ((Key[I] = Key[P]) and (I > P)) then
      Continue;
    if Recs[I]^.HasTZUTC then
      WriteLn('[WARN] Message #', Recs[I]^.MsgNum, ' has TZUTC but precedes message #',
              Recs[P]^.MsgNum, ' it replies to, moving it anyway');
    Key[I] := Key[P] + 1;
  end;

  for I := 0 to N - 1 do
    Idx[I] := I;
  SortBySortKey(Key, Idx, 0, N - 1);
  for I := 0 to N - 1 do
    AtPut(I, Recs[Idx[I]]);
end;

procedure TIndexRecCollection.DedupByKey;
var
  I, J: Longint;
  R1, R2: PIndexRec;
begin
  I := 0;
  while I < Count - 1 do
  begin
    R1 := At(I);
    J := I + 1;
    while J < Count do
    begin
      R2 := At(J);
      if (R1^.MSGID^ = R2^.MSGID^) and
         (R1^.FromName^ = R2^.FromName^) and
         (R1^.ToName^ = R2^.ToName^) and
         (R1^.Subject^ = R2^.Subject^) and
         (AddressCompare(R1^.FromAddress, R2^.FromAddress) = 0) and
         (AddressCompare(R1^.ToAddress, R2^.ToAddress) = 0) and
         (R1^.WrittenTimeUTC = R2^.WrittenTimeUTC)
      then
        AtFree(J)
      else
        Inc(J);
    end;
    Inc(I);
  end;
end;

procedure DecodeMessageBaseID(const S: String; var TMBF: TMessageBaseFormat; var Format, Path: String);
begin
  SplitID(S, TMBF, Path);
  case TMBF of
    mbfJam: Format := 'JAM';
    mbfMSG: Format := 'MSG';
    mbfSquish: Format := 'Squish';
    mbfUnknown: Format := 'Unknown';
  end;
  if TMBF = mbfUnknown then
  begin
    WriteLn('[ERR] Invalid message base specification: ', S);
    Halt(1);
  end;
end;

begin
  if ParamCount < 4 then
  begin
    WriteLn('Fido message base conversion and processing tool');
    WriteLn;
    WriteLn('Usage:');
    WriteLn('  ', ParamStr(0), ' [options] -src <source> -dst <destination>');
    WriteLn;
    WriteLn('Options:');
    WriteLn('  -src <spec>      Source message base specification');
    WriteLn('  -dst <spec>      Destination message base specification');
    WriteLn('  -deftz <offset>  Default UTC offset for messages without TZUTC kludge (e.g., 0300 or -0500)');
    WriteLn('  -sort            Sort messages by date and reply chains');
    WriteLn('  -dedup           Remove duplicate messages');
    WriteLn('  -append          Append messagges to existing message base');
    WriteLn;
    WriteLn('Base Specification format:');
    WriteLn('  <Letter><Path>');
    WriteLn('  Where Letter is:');
    WriteLn('    J - JAM');
    WriteLn('    S - Squish');
    WriteLn('    F, M, * - MSG / Opus');
    WriteLn;
    WriteLn('Examples:');
    WriteLn('  ', ParamStr(0), ' -src Jc:\fido\msgbase\jam\ruftndev -dst Sc:\fido\msgbase\squish\ruftndev -dedup');
    WriteLn('  ', ParamStr(0), ' -src Jc:\fido\msgbase\jam\r50sysop -dst Sc:\fido\msgbase\squish\r50sysop -deftz 0300 -sort');
    WriteLn('  ', ParamStr(0), ' -src Jc:\fido\msgbase\jam\enetsys -dst Sc:\fido\msgbase\squish\enetsys -deftz -0500 -sort -dedup');
    WriteLn('  ', ParamStr(0), ' -src Mc:\fido\msgbase\msg\netmail -dst Jc:\fido\msgbase\jam\netmail -sort');
    Halt(1);
  end;

  I := 1;
  while I <= ParamCount do
  begin
    if ParamStr(I) = '-src' then
    begin
      Inc(I);
      SourceBaseID := ParamStr(I);
    end else
    if ParamStr(I) = '-dst' then
    begin
      Inc(I);
      DestBaseID := ParamStr(I);
    end else
    if ParamStr(I) = '-deftz' then
    begin
      Inc(I);
      DefTZUTC := ParamStr(I);
    end else
    if ParamStr(I) = '-sort' then
      SortBase := True
    else
    if ParamStr(I) = '-dedup' then
      DedupBase := True
    else
    if ParamStr(I) = '-append' then
      AppendMode := True
    else
      WriteLn('[WARN] Unknown command line parameter: ', ParamStr(I));
    Inc(I);
  end;

  Val(DefTZUTC, DefTZUTCI, Err);
  if Err <> 0 then
  begin
    WriteLn('[ERR] Incorrect TZUTC specified: ', DefTZUTC);
    Halt(1);
  end;

  DecodeMessageBaseID(SourceBaseID, SourceTMBF, SourceFormat, SourceBasePath);
  DecodeMessageBaseID(DestBaseID, DestTMBF, DestFormat, DestBasePath);

  skCommon.MaxLineSize := 16384;
  skCommon.MaxMessageSize := 524288;

  if not AppendMode and ExistMessageBase(DestBaseID) then
  begin
    WriteLn('[CRIT] Destination base ', DestBasePath, ' (', DestFormat, ') already exists!');
    Halt(1);
  end;

  if not OpenMessageBase(SourceBase, SourceBaseID) then
  begin
    WriteLn('[CRIT] Failed to open source message base ', SourceBasePath, ': ', ExplainStatus(OpenStatus));
    Halt(1);
  end;

  if not OpenOrCreateMessageBase(DestBase, DestBaseID) then
  begin
    CloseMessageBase(SourceBase);
    WriteLn('[CRIT] Failed to create destination message base ', DestBasePath, ': ', ExplainStatus(OpenStatus));
    Halt(1);
  end;

  WriteLn('[INFO] Converting message base ', SourceBasePath, ' (', SourceFormat, ') to ', DestBasePath, ' (', DestFormat, ')');

  IndexRecCollection.Init(SourceBase^.GetCount, 5);
  IndexRecCollection.Duplicates := True;

  SourceBase^.SetBaseType(btNetmail);

  WriteLn('[INFO] Reading source message base...');

  SourceBase^.Seek(0);
  while SourceBase^.SeekFound do
  begin
    if SourceBase^.OpenMessage then
    begin
      New(IndexRec);
      with IndexRec^ do
      begin
        Index := SourceBase^.GetLocation;
        MsgNum := SourceBase^.Current;
        FromName := NewPString(SourceBase^.GetFrom);
        ToName := NewPString(SourceBase^.GetTo);
        Subject := NewPString(SourceBase^.GetSubject);
        SourceBase^.GetFromAndToAddress(FromAddress, ToAddress);
        SourceBase^.GetWrittenDateTime(MsgDT);
        MessageBaseDateTimeToUnixDateTime(MsgDT, WrittenTimeUTC);

        if SourceBase^.GetKludge(#1'MSGID:', S) then
          S := Copy(S, 9, 255)
        else
          S := '';
        MSGID := NewPString(S);

        if SortBase then
        begin
          I := DefTZUTCI;
          HasTZUTC := False;
          if SourceBase^.GetKludge(#1'TZUTC:', S) then
          begin
            S := Trim(Copy(S, 8, 255));
            Val(S, I, Err);
            if Err <> 0 then
            begin
              WriteLn('[WARN] Incorrect TZUTC in message #', Index, ': "', S, '", using default (', DefTZUTC, ')');
              I := DefTZUTCI;
            end else
              HasTZUTC := True;
          end;
          WrittenTimeUTC := WrittenTimeUTC - ((I div 100) * 3600) - ((I mod 100) * 60);

          if SourceBase^.GetKludge(#1'REPLY:', S) then
            S := Trim(Copy(S, 8, 255))
          else
            S := '';
          REPLY := NewPString(S);
        end;
      end;
      IndexRecCollection.Insert(IndexRec);
      SourceBase^.CloseMessage;
    end else
    begin
      WriteLn('[CRIT] Failed to open message: ', ExplainStatus(SourceBase^.GetStatus));
      WriteLn('[CRIT] Aborted!');
      CloseMessageBase(DestBase);
      CloseMessageBase(SourceBase);
      Halt(1);
    end;
    SourceBase^.SeekNext;
  end;

  if DedupBase then
  begin
    WriteLn('[INFO] Deduplicating...');
    IndexRecCollection.DedupByKey;
  end;

  if SortBase then
  begin
    WriteLn('[INFO] Sorting replies...');
    IndexRecCollection.SortReplyChains;
  end;

  WriteLn('[INFO] Writing dest message base...');

  for I := 0 to IndexRecCollection.Count - 1 do
  begin
    IndexRec := IndexRecCollection.At(I);

    if IsCleanAddress(IndexRec^.ToAddress) then
    begin
      SourceBase^.SetBaseType(btEchomail);
      DestBase^.SetBaseType(btEchomail);
    end else
    begin
      SourceBase^.SetBaseType(btNetmail);
      DestBase^.SetBaseType(btNetmail);
    end;

    SourceBase^.SetLocation(IndexRec^.Index);
    if not SourceBase^.SeekFound or (SourceBase^.Current <> IndexRec^.MsgNum) then
    begin
      WriteLn('[CRIT] Failed to seek to message #', IndexRec^.MsgNum, ' - aborting!');
      break;
    end;

    if not SourceBase^.OpenMessage then
    begin
      WriteLn('[CRIT] Failed to open message #', IndexRec^.MsgNum, ': ', ExplainStatus(SourceBase^.GetStatus));
      WriteLn('[CRIT] Aborted!');
      break;
    end;

    if not DestBase^.CreateNewMessage then
    begin
      WriteLn('[CRIT] Failed to create message: ', ExplainStatus(DestBase^.GetStatus));
      WriteLn('[CRIT] Aborted!');
      break;
    end;

    { copy message text first because other manipulations may set additional kludges }
    SourceTextStream := SourceBase^.GetMessageTextStream;
    DestTextStream := DestBase^.GetMessageTextStream;
    SourceTextStream^.Seek(0);
    DestTextStream^.Seek(0);
    DestTextStream^.CopyFrom(SourceTextStream^, SourceTextStream^.GetSize);
    DestTextStream^.Truncate;

    if SourceBase^.GetTextSize <> DestBase^.GetTextSize then
      WriteLn('[WARN] Message #', IndexRec^.MsgNum, ' -> #', DestBase^.Current, ' text size changed!');

    { copy message headers }
    if not (IsCleanAddress(IndexRec^.FromAddress) or IsCleanAddress(IndexRec^.ToAddress)) then
      DestBase^.SetFromAndToAddress(IndexRec^.FromAddress, IndexRec^.ToAddress, False)
    else
    if not IsCleanAddress(IndexRec^.FromAddress) then
      DestBase^.SetFromAddress(IndexRec^.FromAddress, False)
    else
    if not IsCleanAddress(IndexRec^.ToAddress) then
      DestBase^.SetToAddress(IndexRec^.ToAddress);
    DestBase^.SetTo(IndexRec^.ToName^);
    DestBase^.SetFrom(IndexRec^.FromName^);
    DestBase^.SetSubject(IndexRec^.Subject^);
    DestBase^.SetAttribute(maPrivate, SourceBase^.GetAttribute(maPrivate));
    DestBase^.SetAttribute(maCrash, SourceBase^.GetAttribute(maCrash));
    DestBase^.SetAttribute(maReceived, SourceBase^.GetAttribute(maReceived));
    DestBase^.SetAttribute(maSent, SourceBase^.GetAttribute(maSent));
    DestBase^.SetAttribute(maAttach, SourceBase^.GetAttribute(maAttach));
    DestBase^.SetAttribute(maTransit, SourceBase^.GetAttribute(maTransit));
    DestBase^.SetAttribute(maOrphan, SourceBase^.GetAttribute(maOrphan));
    DestBase^.SetAttribute(maKill, SourceBase^.GetAttribute(maKill));
    DestBase^.SetAttribute(maLocal, SourceBase^.GetAttribute(maLocal));
    DestBase^.SetAttribute(maHold, SourceBase^.GetAttribute(maHold));
    DestBase^.SetAttribute(maFRq, SourceBase^.GetAttribute(maFRq));
    DestBase^.SetAttribute(maRRq, SourceBase^.GetAttribute(maRRq));
    DestBase^.SetAttribute(maRRc, SourceBase^.GetAttribute(maRRc));
    DestBase^.SetAttribute(maARq, SourceBase^.GetAttribute(maARq));
    DestBase^.SetAttribute(maURq, SourceBase^.GetAttribute(maURq));
    DestBase^.SetAttribute(maScanned, SourceBase^.GetAttribute(maScanned) or (SourceBase^.GetAttribute(maLocal) and SourceBase^.GetAttribute(maSent)));
    SourceBase^.GetWrittenDateTime(MsgDT);
    DestBase^.SetWrittenDateTime(MsgDT);
    SourceBase^.GetArrivedDateTime(MsgDT);
    DestBase^.SetArrivedDateTime(MsgDT);
    DestBase^.SetRead(SourceBase^.GetRead);

    { overwrite generated MSGID kludge with the original one }
    { or delete it if original message didn't have it }
    if IndexRec^.MSGID^ <> '' then
      DestBase^.SetKludge(#1'MSGID:', #1'MSGID: ' + IndexRec^.MSGID^)
    else
      DestBase^.DeleteKludge(#1'MSGID:');

    DestBase^.WriteMessage;
    DestBase^.CloseMessage;

    SourceBase^.CloseMessage;
  end;
  CloseMessageBase(DestBase);
  CloseMessageBase(SourceBase);

  IndexRecCollection.Done;
end.
