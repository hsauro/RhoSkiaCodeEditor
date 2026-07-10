unit uSyntaxHighlighter;

{
  TSimpleHighlighter -- a configurable, ready-made tokenizer so a developer does
  not have to hand-write a TTokenizeLineProc scanner.

  Configure it with a comment style (or a language preset), a keyword list, and
  four colors, then hand its Tokenize method to the editor. It recognizes:
    - line comments   (prefix to end of line, e.g. slash-slash, hash, dash-dash)
    - block comments  (open/close pairs, e.g. brace pairs) -- multi-line
    - strings         (single-line, delimited by any of the given chars)
    - numbers         (decimal, 0x-hex, and dollar-hex)
    - keywords        (case-sensitive or not)
  Anything else is left in the editor's default text color.

  Multi-line block comments encode their continuation in TLexState: state N+1
  means "inside block-comment rule N"; 0 (lsDefault) means no continuation.
}

interface

uses
  System.SysUtils, System.Classes, System.UITypes,
  System.Generics.Collections,
  uCodeEditorTypes;

type
  TSimpleHighlighter = class
  private
    type
      TBlockComment = record
        Open: string;
        Close: string;
      end;
  private
    FKeywords: TDictionary<string, Boolean>;
    FLineComments: TList<string>;
    FBlockComments: TList<TBlockComment>;
    FStringDelims: string;
    FCaseSensitive: Boolean;
    FKeywordColor: TAlphaColor;
    FStringColor: TAlphaColor;
    FCommentColor: TAlphaColor;
    FNumberColor: TAlphaColor;
    FOnChange: TNotifyEvent;
    procedure Changed;
    function NormalizeWord(const AWord: string): string;
    function IsKeyword(const AWord: string): Boolean;
    procedure SetCaseSensitive(const Value: Boolean);
    procedure SetKeywordColor(const Value: TAlphaColor);
    procedure SetStringColor(const Value: TAlphaColor);
    procedure SetCommentColor(const Value: TAlphaColor);
    procedure SetNumberColor(const Value: TAlphaColor);
  public
    constructor Create;
    destructor Destroy; override;

    { keywords }
    procedure ClearKeywords;
    procedure AddKeyword(const AWord: string);
    procedure AddKeywords(const AWords: array of string);

    { comment / string rules }
    procedure ClearRules;
    procedure AddLineComment(const APrefix: string);
    procedure AddBlockComment(const AOpen, AClose: string);
    procedure AddStringDelimiter(const ADelim: Char);

    { language presets (each replaces the current comment/string rules) }
    procedure UsePascal;    // // line; { } and (* *) blocks; '...' strings; case-insensitive
    procedure UseCLike;     // // line; /* */ block; "..." strings; case-sensitive
    procedure UseAntimony;  // // and # line; /* */ block; "..." strings; case-sensitive

    { the tokenizer -- pass this to TSkiaCodeEditor.SetTokenizer }
    function Tokenize(const ALine: string; AStateIn: TLexState;
      out ARuns: TTokenRunArray): TLexState;

    property CaseSensitive: Boolean read FCaseSensitive write SetCaseSensitive;
    property KeywordColor: TAlphaColor read FKeywordColor write SetKeywordColor;
    property StringColor: TAlphaColor read FStringColor write SetStringColor;
    property CommentColor: TAlphaColor read FCommentColor write SetCommentColor;
    property NumberColor: TAlphaColor read FNumberColor write SetNumberColor;
    // Fired whenever configuration changes; the editor wires this to a re-lex.
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

implementation

{ TSimpleHighlighter }

constructor TSimpleHighlighter.Create;
begin
  inherited Create;
  FKeywords := TDictionary<string, Boolean>.Create;
  FLineComments := TList<string>.Create;
  FBlockComments := TList<TBlockComment>.Create;
  FStringDelims := '';
  FCaseSensitive := True;
  // Sensible defaults (VS-ish): keywords blue, strings maroon, comments green,
  // numbers teal.
  FKeywordColor := TAlphaColor($FF0000FF);
  FStringColor  := TAlphaColor($FFA31515);
  FCommentColor := TAlphaColor($FF008000);
  FNumberColor  := TAlphaColor($FF098658);
end;

destructor TSimpleHighlighter.Destroy;
begin
  FKeywords.Free;
  FLineComments.Free;
  FBlockComments.Free;
  inherited;
end;

procedure TSimpleHighlighter.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TSimpleHighlighter.NormalizeWord(const AWord: string): string;
begin
  if FCaseSensitive then
    Result := AWord
  else
    Result := AWord.ToLower;
end;

function TSimpleHighlighter.IsKeyword(const AWord: string): Boolean;
begin
  Result := FKeywords.ContainsKey(NormalizeWord(AWord));
end;

procedure TSimpleHighlighter.ClearKeywords;
begin
  FKeywords.Clear;
  Changed;
end;

procedure TSimpleHighlighter.AddKeyword(const AWord: string);
begin
  if AWord <> '' then
    FKeywords.AddOrSetValue(NormalizeWord(AWord), True);
  Changed;
end;

procedure TSimpleHighlighter.AddKeywords(const AWords: array of string);
var
  W: string;
begin
  for W in AWords do
    if W <> '' then
      FKeywords.AddOrSetValue(NormalizeWord(W), True);
  Changed;
end;

procedure TSimpleHighlighter.ClearRules;
begin
  FLineComments.Clear;
  FBlockComments.Clear;
  FStringDelims := '';
  Changed;
end;

procedure TSimpleHighlighter.AddLineComment(const APrefix: string);
begin
  if APrefix <> '' then
    FLineComments.Add(APrefix);
  Changed;
end;

procedure TSimpleHighlighter.AddBlockComment(const AOpen, AClose: string);
var
  BC: TBlockComment;
begin
  if (AOpen <> '') and (AClose <> '') then
  begin
    BC.Open := AOpen;
    BC.Close := AClose;
    FBlockComments.Add(BC);
  end;
  Changed;
end;

procedure TSimpleHighlighter.AddStringDelimiter(const ADelim: Char);
begin
  if Pos(ADelim, FStringDelims) = 0 then
    FStringDelims := FStringDelims + ADelim;
  Changed;
end;

procedure TSimpleHighlighter.UsePascal;
begin
  ClearRules;
  AddLineComment('//');
  AddBlockComment('{', '}');
  AddBlockComment('(*', '*)');
  AddStringDelimiter('''');
  CaseSensitive := False;   // Pascal keywords are case-insensitive
end;

procedure TSimpleHighlighter.UseCLike;
begin
  ClearRules;
  AddLineComment('//');
  AddBlockComment('/*', '*/');
  AddStringDelimiter('"');
  CaseSensitive := True;
end;

procedure TSimpleHighlighter.UseAntimony;
begin
  // Antimony (SBML-compatible) accepts both Python-style '#' and C++/Pascal-style
  // '//' line comments, plus C-style '/* ... */' block comments.
  ClearRules;
  AddLineComment('//');
  AddLineComment('#');
  AddBlockComment('/*', '*/');
  AddStringDelimiter('"');
  CaseSensitive := True;
end;

procedure TSimpleHighlighter.SetCaseSensitive(const Value: Boolean);
var
  Old: TDictionary<string, Boolean>;
  Pair: TPair<string, Boolean>;
begin
  if FCaseSensitive = Value then
    Exit;
  FCaseSensitive := Value;
  // Re-key the existing keywords under the new casing rule.
  Old := FKeywords;
  try
    FKeywords := TDictionary<string, Boolean>.Create;
    for Pair in Old do
      FKeywords.AddOrSetValue(NormalizeWord(Pair.Key), True);
  finally
    Old.Free;
  end;
  Changed;
end;

procedure TSimpleHighlighter.SetKeywordColor(const Value: TAlphaColor);
begin
  if FKeywordColor <> Value then
  begin
    FKeywordColor := Value;
    Changed;
  end;
end;

procedure TSimpleHighlighter.SetStringColor(const Value: TAlphaColor);
begin
  if FStringColor <> Value then
  begin
    FStringColor := Value;
    Changed;
  end;
end;

procedure TSimpleHighlighter.SetCommentColor(const Value: TAlphaColor);
begin
  if FCommentColor <> Value then
  begin
    FCommentColor := Value;
    Changed;
  end;
end;

procedure TSimpleHighlighter.SetNumberColor(const Value: TAlphaColor);
begin
  if FNumberColor <> Value then
  begin
    FNumberColor := Value;
    Changed;
  end;
end;

function TSimpleHighlighter.Tokenize(const ALine: string; AStateIn: TLexState;
  out ARuns: TTokenRunArray): TLexState;
var
  Runs: TList<TTokenRun>;
  I, N, StartPos, Ci, ClosePos, State: Integer;
  Matched: Boolean;
  BC: TBlockComment;
  Delim: Char;

  procedure Emit(AStartCol0, ALen: Integer; AColor: TAlphaColor);
  var
    R: TTokenRun;
  begin
    if ALen <= 0 then
      Exit;
    R.StartCol := AStartCol0;
    R.Length := ALen;
    R.Color := AColor;
    R.Bold := False;
    R.Italic := False;
    Runs.Add(R);
  end;

  function MatchAt(const ASub: string; APos: Integer): Boolean;
  var
    K: Integer;
  begin
    if (ASub = '') or (APos + ASub.Length - 1 > N) then
      Exit(False);
    for K := 1 to ASub.Length do
      if ALine[APos + K - 1] <> ASub[K] then
        Exit(False);
    Result := True;
  end;

  // First position of ASub at or after AFrom (1-based), or 0.
  function FindFrom(const ASub: string; AFrom: Integer): Integer;
  var
    P: Integer;
  begin
    for P := AFrom to N - ASub.Length + 1 do
      if MatchAt(ASub, P) then
        Exit(P);
    Result := 0;
  end;

begin
  Runs := TList<TTokenRun>.Create;
  try
    N := ALine.Length;
    State := AStateIn;
    I := 1;

    // Continue an open block comment carried over from the previous line.
    if State > 0 then
    begin
      BC := FBlockComments[State - 1];
      ClosePos := FindFrom(BC.Close, 1);
      if ClosePos > 0 then
      begin
        Emit(0, ClosePos + BC.Close.Length - 1, FCommentColor);
        I := ClosePos + BC.Close.Length;
        State := 0;
      end
      else
      begin
        Emit(0, N, FCommentColor);
        ARuns := Runs.ToArray;
        Exit(TLexState(State));   // whole line still inside the comment
      end;
    end;

    while I <= N do
    begin
      Matched := False;

      // line comment -> rest of line
      for Ci := 0 to FLineComments.Count - 1 do
        if MatchAt(FLineComments[Ci], I) then
        begin
          Emit(I - 1, N - I + 1, FCommentColor);
          I := N + 1;
          Matched := True;
          Break;
        end;
      if Matched then
        Continue;

      // block comment (possibly spilling to following lines)
      for Ci := 0 to FBlockComments.Count - 1 do
        if MatchAt(FBlockComments[Ci].Open, I) then
        begin
          BC := FBlockComments[Ci];
          StartPos := I;
          ClosePos := FindFrom(BC.Close, I + BC.Open.Length);
          if ClosePos > 0 then
          begin
            Emit(StartPos - 1, ClosePos + BC.Close.Length - StartPos, FCommentColor);
            I := ClosePos + BC.Close.Length;
          end
          else
          begin
            Emit(StartPos - 1, N - StartPos + 1, FCommentColor);
            State := Ci + 1;
            I := N + 1;
          end;
          Matched := True;
          Break;
        end;
      if Matched then
        Continue;

      // string (single line)
      if (FStringDelims <> '') and (Pos(ALine[I], FStringDelims) > 0) then
      begin
        Delim := ALine[I];
        StartPos := I;
        Inc(I);
        while (I <= N) and (ALine[I] <> Delim) do
          Inc(I);
        if I <= N then
          Inc(I);            // include the closing delimiter
        Emit(StartPos - 1, I - StartPos, FStringColor);
        Continue;
      end;

      // number: $-hex, 0x-hex, or decimal with optional fraction
      if (ALine[I] = '$') and (I < N) and
         CharInSet(ALine[I + 1], ['0'..'9', 'a'..'f', 'A'..'F']) then
      begin
        StartPos := I;
        Inc(I);
        while (I <= N) and CharInSet(ALine[I], ['0'..'9', 'a'..'f', 'A'..'F']) do
          Inc(I);
        Emit(StartPos - 1, I - StartPos, FNumberColor);
        Continue;
      end;
      if CharInSet(ALine[I], ['0'..'9']) then
      begin
        StartPos := I;
        if (ALine[I] = '0') and (I < N) and CharInSet(ALine[I + 1], ['x', 'X']) then
        begin
          Inc(I, 2);
          while (I <= N) and CharInSet(ALine[I], ['0'..'9', 'a'..'f', 'A'..'F']) do
            Inc(I);
        end
        else
        begin
          while (I <= N) and CharInSet(ALine[I], ['0'..'9']) do
            Inc(I);
          if (I < N) and (ALine[I] = '.') and CharInSet(ALine[I + 1], ['0'..'9']) then
          begin
            Inc(I);
            while (I <= N) and CharInSet(ALine[I], ['0'..'9']) do
              Inc(I);
          end;
        end;
        Emit(StartPos - 1, I - StartPos, FNumberColor);
        Continue;
      end;

      // identifier / keyword
      if CharInSet(ALine[I], ['A'..'Z', 'a'..'z', '_']) then
      begin
        StartPos := I;
        while (I <= N) and CharInSet(ALine[I], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
          Inc(I);
        if IsKeyword(Copy(ALine, StartPos, I - StartPos)) then
          Emit(StartPos - 1, I - StartPos, FKeywordColor);
        Continue;
      end;

      Inc(I);
    end;

    ARuns := Runs.ToArray;
    Result := TLexState(State);
  finally
    Runs.Free;
  end;
end;

end.
