{$MODE objfpc}

uses
  SysUtils,
  StrUtils,
  skMHL,
  skOpen,
  skCommon;

const
  MaxMsgSize = 524288;
  ScreenWidth = 79;
  PreviewLines = 40;

  Quit: Boolean = False;
  DontAsk: Boolean = False;

var
  B: PMessageBase;
  S: String;
  TargetMsgNum: Longint;
  Buf: array[0..MaxMsgSize] of Char;
  FromCharset, ToCharset, SearchCharset: AnsiString;
  FromCP, ToCP: TSystemCodePage;
  Converted: RawByteString;

procedure ValidateCP(CP: TSystemCodePage; const Charset: AnsiString);
begin
  if CP <> $FFFF then Exit;

  WriteLn('Incorrect charset specified on the command line: ', Charset);
  Halt(1);
end;

function CHRSLevel(CodePage: TSystemCodePage): Byte;
begin
  if CodePage >= 65000 then Exit(4);

  if CodePage = 20127  then Exit(1);

  Result := 2;
end;

function YNQ(const Prompt: String): Byte;
var
  S: String;
begin
  repeat
    Write(Prompt, ' [Yes/All/No/Quit]: ');

    ReadLn(S);
    S := UpperCase(S);

    case S of
      'Y', 'YES'  : Exit(0);
      'A', 'ALL'  : begin
                      DontAsk := True;
                      Exit(0);
                    end;
      'N', 'NO'   : Exit(1);
      'Q', 'QUIT' : Exit(2);
    end;
  until False;
end;

function ConvertEncoding(const S: RawByteString; FromCP, ToCP: TSystemCodePage): RawByteString;
begin
  Result := S;
  SetCodePage(Result, FromCP, False);
  SetCodePage(Result, ToCP, True);
end;

function FormatWrittenDate: String;
var
  DT: TMessageBaseDateTime;
begin
  B^.GetWrittenDateTime(DT);
  Result := Format('%.2d %s %.2d %.2d:%.2d:%.2d',
    [DT.Day, MonthNumberToMonthString(DT.Month), DT.Year mod 100, DT.Hour, DT.Min, DT.Sec]);
end;

{ prints the message header in a frame followed by the message text,
  cutting lines from the middle of the text if it does not fit the screen }
procedure DisplayMessage;
const
  FrameLines = 6;
var
  Lines: array of String;
  FromAddress, ToAddress: TAddress;
  Date: String;
  N, I, Avail, Head, Tail: Longint;
begin
  B^.GetFromAndToAddress(FromAddress, ToAddress);
  Date := FormatWrittenDate;

  N := 0;
  SetLength(Lines, 64);
  B^.SetTextPos(0);
  while not B^.EndOfMessage do
  begin
    B^.GetString(S);
    if (S <> '') and (S[1] = #1) then Continue;
    if N = Length(Lines) then
      SetLength(Lines, N * 2);
    Lines[N] := S;
    Inc(N);
  end;
  while (N > 0) and (Trim(Lines[N - 1]) = '') do
    Dec(N);

  WriteLn;
  WriteLn(AddCharR('=', '=[ ' + IntToStr(B^.Current) + ' of ' + IntToStr(B^.GetCount) + ' ]',
    ScreenWidth - Length(Date) - 5), '[ ', Date, ' ]=');
  WriteLn(Format(' From : %-35.35s %.35s', [B^.GetFrom, AddressToStrEx(FromAddress)]));
  if IsCleanAddress(ToAddress) then
    WriteLn(Format(' To   : %.71s', [B^.GetTo]))
  else
    WriteLn(Format(' To   : %-35.35s %.35s', [B^.GetTo, AddressToStrEx(ToAddress)]));
  WriteLn(Format(' Subj : %.71s', [B^.GetSubject]));
  WriteLn(StringOfChar('=', ScreenWidth));

  Avail := PreviewLines - FrameLines;
  if N <= Avail then
  begin
    for I := 0 to N - 1 do
      WriteLn(Lines[I]);
  end else
  begin
    Head := (Avail - 1) div 2;
    Tail := Avail - 1 - Head;
    for I := 0 to Head - 1 do
      WriteLn(Lines[I]);
    WriteLn('[ ', N - Head - Tail, ' lines skipped ]');
    for I := N - Tail to N - 1 do
      WriteLn(Lines[I]);
  end;
  WriteLn(StringOfChar('=', ScreenWidth));
  WriteLn;
end;

function ConvertMessageEncoding: Boolean;
var
  I: Byte;
  DisplayCharset: AnsiString;
begin
  B^.SetKludge(#1'CHRS:', #1'CHRS: ' + ToCharset + ' ' + IntToStr(CHRSLevel(ToCP)));

  B^.SetFrom(ConvertEncoding(B^.GetFrom, FromCP, ToCP));
  B^.SetTo(ConvertEncoding(B^.GetTo, FromCP, ToCP));
  B^.SetSubject(ConvertEncoding(B^.GetSubject, FromCP, ToCP));

  B^.SetTextPos(0);
  B^.ReadText(Buf, B^.GetTextSize);
  Buf[B^.GetTextSize] := #0;
  Converted := ConvertEncoding(PChar(@Buf), FromCP, ToCP);

  B^.SetTextPos(0);
  B^.TruncateText;
  B^.WriteText(PChar(Converted)^, StrLen(PChar(Converted)));

  if DontAsk then
    I := 0
  else
  begin
    DisplayMessage;
    I := YNQ('Above is a preview of the decoded message. Write it to the message base?');
  end;

  if I = 0 then
  begin
    if B^.WriteMessage then
    begin
      if FromCharset <> SearchCharset then
        DisplayCharset := FromCharSet + ' (' + SearchCharset + ')'
      else
        DisplayCharset := FromCharset;
      WriteLn('Converted message #', B^.Current, ' from ', DisplayCharset, ' to ', ToCharset);
    end else
    begin
      WriteLn('Failed to write message #', B^.Current, ' to message base - aborting.');
      I := 2;
    end;
  end else
    WriteLn('Ok, message #', B^.Current, ' is left unchanged');

  Result := (I = 2);
end;

begin
  skCommon.MaxMessageSize := MaxMsgSize;

  if ParamCount < 3 then
  begin
    WriteLn('Fido message base character set recoding tool');
    WriteLn;
    WriteLn('Usage:');
    WriteLn('  ', ParamStr(0), ' <basespec> <from_charset> <to_charset> [search_charset | msg_number]');
    WriteLn;
    WriteLn('Parameters:');
    WriteLn('  <basespec>       Message base specification');
    WriteLn('  <from_charset>   Source character set');
    WriteLn('  <to_charset>     Destination character set');
    WriteLn('  [search_charset] Optional character set to match in CHRS kludge');
    WriteLn('  [msg_number]     Optional specific message number to recode');
    WriteLn;
    WriteLn('Base Specification format:');
    WriteLn('  <Letter><Path>');
    WriteLn('  Where Letter is:');
    WriteLn('    J - JAM');
    WriteLn('    S - Squish');
    WriteLn('    F, M, * - MSG / Opus');
    WriteLn;
    WriteLn('Note:');
    WriteLn('  This tool operates interactively with manual confirmation. A preview');
    WriteLn('  of the decoded message is shown on screen before writing to base.');
    WriteLn('  It is recommended to recode to your console character set (e.g., CP866)');
    WriteLn('  so the preview is readable, or do so at your own risk.');
    WriteLn;
    WriteLn('Examples:');
    WriteLn('  ', ParamStr(0), ' Jc:\fido\msgbase\jam\ruftndev UTF-8 CP866');
    WriteLn('  ', ParamStr(0), ' Sc:\fido\msgbase\squish\fn_sysop UTF-8 CP850');
    WriteLn('  ', ParamStr(0), ' Mc:\fido\msgbase\msg\netmail KOI8-R CP866 KOI');
    WriteLn('    (recode messages with incorrect CHRS kludge: KOI instead of KOI8-R)');
    WriteLn('  ', ParamStr(0), ' Jc:\fido\msgbase\jam\su_chainik CP866 CP866 ASCII');
    WriteLn('    (just replace incorrect CHRS kludge: ASCII -> CP866)');
    WriteLn('  ', ParamStr(0), ' Sc:\fido\msgbase\squish\ru_linux KOI8-R CP866 666');
    WriteLn('    (recode message #666 even if it has no CHRS kludge)');
    Halt(1);
  end;

  FromCharset := UpperCase(ParamStr(2));
  ToCharset := UpperCase(ParamStr(3));

  FromCP := CodePageNameToCodePage(FromCharset);
  ToCP := CodePageNameToCodePage(ToCharset);

  ValidateCP(FromCP, FromCharset);
  ValidateCP(ToCP, ToCharset);

  if (ParamCount >= 4) and not TryStrToInt(ParamStr(4), TargetMsgNum) then
  begin
    TargetMsgNum := 0;
    SearchCharset := UpperCase(ParamStr(4));
  end else
    SearchCharset := FromCharset;

  if not OpenMessageBase(B, ParamStr(1)) then
  begin
    WriteLn('Message base open failed: ', ExplainStatus(OpenStatus));
    Halt(1);
  end;

  B^.Seek(TargetMsgNum);
  while B^.SeekFound do
  begin
    if (TargetMsgNum <> 0) and (B^.Current <> TargetMsgNum) then
    begin
      WriteLn('Failed to seek to message #', TargetMsgNum);
      Break;
    end;

    if B^.OpenMessage then
    begin
      if (TargetMsgNum <> 0) or (B^.GetKludge(#1'CHRS:', S) and (Pos(SearchCharset, UpperCase(S)) > 0)) then
        Quit := ConvertMessageEncoding;
      B^.CloseMessage;
    end else
      WriteLn('Failed to open message #', B^.Current);

    if Quit or (TargetMsgNum <> 0) then Break;

    B^.SeekNext;
  end;
  CloseMessageBase(B);
end.
