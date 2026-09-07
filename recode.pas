{$MODE objfpc}

uses
  SysUtils,
  skMHL,
  skOpen,
  skCommon;

const
  MaxMsgSize = 524288;

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

    if DontAsk then
    begin
      WriteLn('Yes (All)');
      Exit(0);
    end;

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

procedure DisplayMessage;
begin
  WriteLn;
  WriteLn('Msg : ', B^.Current);
  WriteLn('From: ', B^.GetFrom);
  WriteLn('To  : ', B^.GetTo);
  WriteLn('Subj: ', B^.GetSubject);
  WriteLn;
  B^.SetTextPos(0);
  while not B^.EndOfMessage do
  begin
    B^.GetString(S);
    WriteLn(S);
  end;
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

  DisplayMessage;

  I := YNQ('Above is a preview of the decoded message. Write it to the message base?');
  if I = 0 then
  begin
    B^.WriteMessage;
    if FromCharset <> SearchCharset then
      DisplayCharset := FromCharSet + ' (' + SearchCharset + ')'
    else
      DisplayCharset := FromCharset;
    WriteLn('Converted message #', B^.Current, ' from ', DisplayCharset, ' to ', ToCharset);
  end else
    WriteLn('Ok, message #', B^.Current, ' is left unchanged');

  Result := (I = 2);
end;

begin
  skCommon.MaxMessageSize := MaxMsgSize;

  if ParamCount < 3 then
  begin
    WriteLn('Usage: ', ParamStr(0), ' <basespec> <from_charset> <to_carset> [search_charset|msg_number]');
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
