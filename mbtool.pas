{$MODE objfpc}

uses
  Objects,
  skMHL,
  skOpen,
  skCommon;

const
  SortBase  : Boolean   = false;
  DedupBase : Boolean   = false;
  DefTZUTC  : String[5] = '0000';

type
  TIndexRecCollection = object(TSortedCollection)
    function Compare(Key1, Key2: Pointer): Longint; virtual;
    procedure Insert(Item: Pointer); virtual;
    procedure FreeItem(Item: Pointer); virtual;
  end;

  PIndexRec = ^TIndexRec;
  TIndexRec = record
    Index, MsgNum: Longint;
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
  SourceTextStream, DestTextStream: PMessageBaseStream;
  MsgDT: TMessageBaseDateTime;
  SourceBaseID, DestBaseID, SourceBasePath, DestBasePath, SourceFormat, DestFormat, S: String;
  SourceTMBF, DestTMBF: TMessageBaseFormat;
  IndexRec: PIndexRec;
  IndexRecCollection: TIndexRecCollection;
  DefTZUTCI, I, Err: Longint;
  T: Int64;

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
  if SortBase then
  begin
    I := MessageBaseDateTimeCompare(Rec1.WrittenDateUTC, Rec2.WrittenDateUTC);
    if I <> 0 then
    begin
      Compare := I;
      exit;
    end;
  end;
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
    WriteLn('Usage: ');
    WriteLn('  ', ParamStr(0), ' -src <SourceBase> -dst <DestBase> [-deftz <DefTZUTC>] [-sort] [-dedup]');
    WriteLn;
    WriteLn('Examples:');
    WriteLn('  ', ParamStr(0), ' -src Jc:\fido\msgbase\jam\ruftndev -dst Sc:\fido\msgbase\squish\ruftndev -dedup');
    WriteLn('  ', ParamStr(0), ' -src Jc:\fido\msgbase\jam\r50sysop -dst Sc:\fido\msgbase\squish\r50sysop -deftz 0300 -sort');
    WriteLn('  ', ParamStr(0), ' -src Jc:\fido\msgbase\jam\enetsys -dst Sc:\fido\msgbase\squish\enetsys -deftz -0500 -sort -dedup');
    WriteLn('  ', ParamStr(0), ' -src Mc:\fido\msgbase\msg\netmail -dst Sc:\fido\msgbase\squish\netmail -sort');
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
      SortBase := true
    else
    if ParamStr(I) = '-dedup' then
      DedupBase := true
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
  IndexRecCollection.Duplicates := not DedupBase;

  SourceBase^.SetBaseType(btNetmail);

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
        SourceBase^.GetWrittenDateTime(WrittenDateUTC);
        if SortBase then
        begin
          I := DefTZUTCI;
          if SourceBase^.GetKludge(#1'TZUTC', S) then
          begin
            S := ExtractWord(2, S, [' ']);
            Val(S, I, Err);
            if Err <> 0 then
            begin
              WriteLn('[WARN] Incorrect TZUTC in message #', Index, ': "', S, '", using default (', DefTZUTC, ')');
              I := DefTZUTCI;
            end;
          end;
          MessageBaseDateTimeToUnixDateTime(WrittenDateUTC, T);
          T := T - ((I div 100) * 3600) - ((I mod 100) * 60);
          UnixDateTimeToMessageBaseDateTime(T, WrittenDateUTC);
        end;
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
      CloseMessageBase(DestBase);
      CloseMessageBase(SourceBase);
      Halt(1);
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
      DestBase^.SetFromAndToAddress(IndexRec^.FromAddress, IndexRec^.ToAddress, false)
    else
    if not IsCleanAddress(IndexRec^.FromAddress) then
      DestBase^.SetFromAddress(IndexRec^.FromAddress, false)
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
    if Length(IndexRec^.MSGID^) > 0 then
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
