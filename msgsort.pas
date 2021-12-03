program msgsort;

uses
  VPUtils,
  Objects,
  skMHL,
  skOpen,
  skCommon;

const
  DefTZUTC : String[5] = '0000';

type
  TIndexRecCollection = object(TSortedCollection)
    function Compare(Key1, Key2: Pointer): Longint; virtual;
    procedure Insert(Item: Pointer); virtual;
    procedure FreeItem(Item: Pointer); virtual;
  end;

  PIndexRec = ^TIndexRec;
  TIndexRec = packed record
    Index: Longint;
    WrittenDateUTC: TMessageBaseDateTime;
    FromAddress: TAddress;
    ToAddress: TAddress;
    MSGID: PString;
    FromName: PString;
    ToName: PString;
    Subject: PString;
  end;

var
  SourceBase, DestBase: PMessageBase;
  MsgDT: TMessageBaseDateTime;
  SourceBaseID, DestBaseID, SourceBasePath, DestBasePath, SourceFormat, DestFormat, S: String;
  IndexRec: PIndexRec;
  IndexRecCollection: TIndexRecCollection;
  DefTZUTCI, I, T: Longint;
  Line: PChar;

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
var
  I: Integer;
  Rec1, Rec2: TIndexRec;
begin
  Rec1 := PIndexRec(Key1)^;
  Rec2 := PIndexRec(Key2)^;
  I := MessageBaseDateTimeCompare(Rec1.WrittenDateUTC, Rec2.WrittenDateUTC);
  if I <> 0 then Compare := I else
  if Rec1.MSGID^ <> Rec2.MSGID^ then Compare := -1 else
  if Rec1.FromName^ <> Rec2.FromName^ then Compare := -1 else
  if Rec1.ToName^ <> Rec2.ToName^ then Compare := -1 else
  if Rec1.Subject^ <> Rec2.Subject^ then Compare := -1 else
  if AddressCompare(Rec1.FromAddress, Rec2.FromAddress) <> 0 then Compare := -1 else
  if AddressCompare(Rec1.ToAddress, Rec2.ToAddress) <> 0 then Compare := -1 else
    Compare := 0;
end;

procedure TIndexRecCollection.Insert(Item: Pointer);
var
  OldCount: Longint;
begin
  OldCount := Count;
  inherited Insert(Item);
  if OldCount = Count then
    FreeItem(Item);
end;

procedure TIndexRecCollection.FreeItem(Item: Pointer);
begin
  with TIndexRec(Item^) do
  begin
    DisposePString(FromName);
    DisposePString(ToName);
    DisposePString(Subject);
    DisposePString(MSGID);
  end;
  Dispose(PIndexRec(Item));
end;

procedure DecodeMessageBaseID(const S: String; var Format, Path: String);
var
  TMBF: TMessageBaseFormat;
begin
  SplitID(S, TMBF, Path);
  case TMBF of
    mbfJam: Format := 'jam';
    mbfMSG: Format := 'msg';
    mbfSquish: Format := 'squish';
    mbfUnknown: Format := 'unknown';
  end;
  if TMBF = mbfUnknown then
  begin
    WriteLn('Invalid message base specification: ', S);
    Halt(1);
  end;
end;

begin
  if ParamCount < 2 then
  begin
    WriteLn('Usage: ');
    WriteLn('  ', ParamStr(0), ' <SourceBase> <DestBase> [DefTZUTC]');
    WriteLn;
    WriteLn('Examples:');
    WriteLn('  ', ParamStr(0), ' Jc:\fido\msgbase\jam\ruftndev Sc:\fido\msgbase\squish\ruftndev');
    WriteLn('  ', ParamStr(0), ' Jc:\fido\msgbase\jam\r5sysop Sc:\fido\msgbase\squish\r50sysop 0300');
    WriteLn('  ', ParamStr(0), ' Jc:\fido\msgbase\jam\enetsys Sc:\fido\msgbase\squish\enetsys -0500');
    WriteLn('  ', ParamStr(0), ' Mc:\fido\netmail Sc:\fido\msgbase\squish\netmail');
    Halt(1);
  end;

  SourceBaseID := ParamStr(1);
  DestBaseID := ParamStr(2);
  if ParamCount > 2 then
    DefTZUTC := ParamStr(3);

  Val(DefTZUTC, DefTZUTCI, I);
  if I <> 0 then
  begin
    WriteLn('[CRIT] Incorrect TZUTC specified: ', DefTZUTC);
    Halt(1);
  end;

  DecodeMessageBaseID(SourceBaseID, SourceFormat, SourceBasePath);
  DecodeMessageBaseID(DestBaseID, DestFormat, DestBasePath);

  if ExistMessageBase(DestBaseID) then
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
  IndexRecCollection.Duplicates := false;

  GetMem(Line, MaxLineSize);

  SourceBase^.SetBaseType(btNetmail);
  SourceBase^.Seek(0);
  while SourceBase^.SeekFound do
  begin
    if SourceBase^.OpenMessageHeader then
    begin
      New(IndexRec);
      with IndexRec^ do
      begin
        Index := SourceBase^.Current;
        FromName := NewPString(SourceBase^.GetFrom);
        ToName := NewPString(SourceBase^.GetTo);
        Subject := NewPString(SourceBase^.GetSubject);
        SourceBase^.GetFromAddress(ToAddress);
        SourceBase^.GetToAddress(ToAddress);
        SourceBase^.GetWrittenDateTime(WrittenDateUTC);
        if SourceBase^.GetKludge(#1'TZUTC', S) then
          S := ExtractWord(2, S, [' '])
        else
          S := DefTZUTC;
        Val(S, I, T);
        if T <> 0 then
        begin
          WriteLn('[WARN] Incorrect TZUTC in message #', Index, ': "', S, '", using default (', DefTZUTC, ')');
          I := DefTZUTCI;
        end;
        MessageBaseDateTimeToUnixDateTime(WrittenDateUTC, T);
        T := T - ((I div 100) * 3600) - ((I mod 100) * 60);
        UnixDateTimeToMessageBaseDateTime(T, WrittenDateUTC);
        if SourceBase^.GetKludge(#1'MSGID', S) then
          S := Copy(S, 9, 255)
        else
          S := '';
        MSGID := NewPString(S);
      end;
      IndexRecCollection.Insert(IndexRec);
      SourceBase^.CloseMessage;
    end else
    begin
      WriteLn('[CRIT] Failed to open message: ', ExplainStatus(SourceBase^.GetStatus));
      WriteLn('[CRIT] Aborted!');
      break;
    end;
    SourceBase^.SeekNext;
  end;

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
    SourceBase^.Seek(IndexRec^.Index);
    if SourceBase^.Current <> IndexRec^.Index then
    begin
      WriteLn('[CRIT] Failed to seek to message #', IndexRec^.Index, ' - aborting!');
      break;
    end;
    if not SourceBase^.OpenMessage then
    begin
      WriteLn('[CRIT] Failed to open message #', IndexRec^.Index, ': ', ExplainStatus(SourceBase^.GetStatus));
      WriteLn('[CRIT] Aborted!');
      break;
    end;
    if not DestBase^.CreateNewMessage then
    begin
      WriteLn('[CRIT] Failed to create message:', IndexRec^.Index, ': ', ExplainStatus(DestBase^.GetStatus));
      WriteLn('[CRIT] Aborted!');
      break;
    end;
    DestBase^.SetKludge(#1'MSGID:', #1'MSGID: ' + IndexRec^.MSGID^);
    if not IsCleanAddress(IndexRec^.ToAddress) then
      DestBase^.SetToAddress(IndexRec^.ToAddress);
    DestBase^.SetFromAddress(IndexRec^.ToAddress, false);
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
    DestBase^.SetAttribute(maScanned, SourceBase^.GetAttribute(maScanned) or SourceBase^.GetAttribute(maSent));
    SourceBase^.GetWrittenDateTime(MsgDT);
    DestBase^.SetWrittenDateTime(MsgDT);
    SourceBase^.GetArrivedDateTime(MsgDT);
    DestBase^.SetArrivedDateTime(MsgDT);
    DestBase^.SetRead(SourceBase^.GetRead);
    SourceBase^.SetTextPos(0);
    DestBase^.SetTextPos(0);
    DestBase^.TruncateText;
    while not SourceBase^.EndOfMessage do
    begin
      SourceBase^.GetStringPChar(Line, MaxLineSize);
      DestBase^.PutStringPChar(Line);
    end;
    if SourceBase^.GetTextSize <> DestBase^.GetTextSize then
      WriteLn('[WARN] Message #', IndexRec^.Index, ' -> #', DestBase^.Current, ' text size changed!');
    DestBase^.WriteMessage;
    DestBase^.CloseMessage;
    SourceBase^.CloseMessage;
  end;
  CloseMessageBase(DestBase);
  CloseMessageBase(SourceBase);
  IndexRecCollection.Done;
  FreeMem(Line, MaxLineSize);
end.
