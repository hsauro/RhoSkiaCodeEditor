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
  uCodeEditorTypes,
  uLanguageKeywords;

type
  // Design-time language selector. Each maps to the like-named Use* preset and
  // (for the Language property) auto-loads that language's built-in keyword
  // list. slNone = no comment/string rules and no built-in keywords.
  TSyntaxLanguage = (slNone, slPascal, slCLike, slAntimony, slPython);

  // TPersistent (not TObject) so the editor can publish it as an expandable
  // node in the Object Inspector and stream its published config into the .fmx.
  TSimpleHighlighter = class(TPersistent)
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
    FLanguage: TSyntaxLanguage;
    FLangKeywords: TArray<string>;   // built-in keywords for FLanguage (not streamed)
    FKeywordList: TStringList;       // the published Keywords: user's EXTRA words
    procedure Changed;
    function NormalizeWord(const AWord: string): string;
    function IsKeyword(const AWord: string): Boolean;
    procedure RebuildKeywordSet;     // FKeywords := built-in language set + extras
    procedure KeywordListChanged(Sender: TObject);
    procedure ApplyLanguage;
    procedure SetLanguage(const Value: TSyntaxLanguage);
    function GetKeywords: TStrings;
    procedure SetKeywords(const Value: TStrings);
    procedure SetCaseSensitive(const Value: Boolean);
    procedure SetKeywordColor(const Value: TAlphaColor);
    procedure SetStringColor(const Value: TAlphaColor);
    procedure SetCommentColor(const Value: TAlphaColor);
    procedure SetNumberColor(const Value: TAlphaColor);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Assign(Source: TPersistent); override;

    { keywords -- these operate on the EXTRA (published) keyword list; the
      language's built-in keywords are added on top automatically. }
    procedure ClearKeywords;
    procedure AddKeyword(const AWord: string);
    procedure AddKeywords(const AWords: array of string);

    { comment / string rules }
    procedure ClearRules;
    procedure AddLineComment(const APrefix: string);
    procedure AddBlockComment(const AOpen, AClose: string);
    procedure AddStringDelimiter(const ADelim: Char);
    // The first configured line-comment prefix, or '' if none. The editor uses
    // this to drive its comment-toggle command when no prefix is set explicitly.
    function LineComment: string;

    { language presets (each replaces the current comment/string rules). These
      set RULES ONLY -- they do not touch keywords (back-compat). The published
      Language property is the richer, OI-facing selector that also loads the
      matching built-in keyword list. }
    procedure UsePascal;    // // line; { } and (* *) blocks; '...' strings; case-insensitive
    procedure UseCLike;     // // line; /* */ block; "..." strings; case-sensitive
    procedure UseAntimony;  // // and # line; /* */ block; "..." strings; case-sensitive
    procedure UsePython;    // # line; ''' and """ triple-quote blocks; '...' "..." strings; case-sensitive

    { the tokenizer -- pass this to TSkiaCodeEditor.SetTokenizer }
    function Tokenize(const ALine: string; AStateIn: TLexState;
      out ARuns: TTokenRunArray): TLexState;

    // Fired whenever configuration changes; the editor wires this to a re-lex.
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  published
    // Language preset: sets comment/string rules AND loads that language's
    // built-in keyword list. Keywords below are added on top. slNone clears both.
    property Language: TSyntaxLanguage read FLanguage write SetLanguage
      default slNone;
    // Extra keywords beyond the language's built-in list (one per line in the
    // OI editor). Merged with the built-in set; case per CaseSensitive.
    property Keywords: TStrings read GetKeywords write SetKeywords;
    property CaseSensitive: Boolean read FCaseSensitive write SetCaseSensitive
      default True;
    property KeywordColor: TAlphaColor read FKeywordColor write SetKeywordColor;
    property StringColor: TAlphaColor read FStringColor write SetStringColor;
    property CommentColor: TAlphaColor read FCommentColor write SetCommentColor;
    property NumberColor: TAlphaColor read FNumberColor write SetNumberColor;
  end;

implementation

{ TSimpleHighlighter }

constructor TSimpleHighlighter.Create;
begin
  inherited Create;
  FKeywords := TDictionary<string, Boolean>.Create;
  FLineComments := TList<string>.Create;
  FBlockComments := TList<TBlockComment>.Create;
  FKeywordList := TStringList.Create;
  FKeywordList.OnChange := KeywordListChanged;
  FStringDelims := '';
  FCaseSensitive := True;
  FLanguage := slNone;
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
  FKeywordList.Free;
  inherited;
end;

procedure TSimpleHighlighter.Assign(Source: TPersistent);
var
  H: TSimpleHighlighter;
begin
  if Source is TSimpleHighlighter then
  begin
    H := TSimpleHighlighter(Source);
    FCaseSensitive := H.FCaseSensitive;
    FKeywordColor  := H.FKeywordColor;
    FStringColor   := H.FStringColor;
    FCommentColor  := H.FCommentColor;
    FNumberColor   := H.FNumberColor;
    Language := H.FLanguage;                 // reapplies rules + built-in keywords
    FKeywordList.Assign(H.FKeywordList);     // fires KeywordListChanged -> rebuild
    Changed;
  end
  else
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

procedure TSimpleHighlighter.RebuildKeywordSet;
var
  W: string;
begin
  // The lookup set is the language's built-in keywords plus the user's extras,
  // both normalized to the current casing rule.
  FKeywords.Clear;
  for W in FLangKeywords do
    if W <> '' then
      FKeywords.AddOrSetValue(NormalizeWord(W), True);
  for W in FKeywordList do
    if W <> '' then
      FKeywords.AddOrSetValue(NormalizeWord(W), True);
end;

procedure TSimpleHighlighter.KeywordListChanged(Sender: TObject);
begin
  // The published Keywords list (user extras) changed -- fold it back in.
  RebuildKeywordSet;
  Changed;
end;

procedure TSimpleHighlighter.ClearKeywords;
begin
  FKeywordList.Clear;   // clears extras; KeywordListChanged rebuilds + notifies
end;

procedure TSimpleHighlighter.AddKeyword(const AWord: string);
begin
  if AWord <> '' then
    FKeywordList.Add(AWord);   // OnChange rebuilds + notifies
end;

procedure TSimpleHighlighter.AddKeywords(const AWords: array of string);
var
  W: string;
begin
  FKeywordList.BeginUpdate;   // batch: one rebuild + one notify at EndUpdate
  try
    for W in AWords do
      if W <> '' then
        FKeywordList.Add(W);
  finally
    FKeywordList.EndUpdate;
  end;
end;

function TSimpleHighlighter.GetKeywords: TStrings;
begin
  Result := FKeywordList;
end;

procedure TSimpleHighlighter.SetKeywords(const Value: TStrings);
begin
  FKeywordList.Assign(Value);   // fires KeywordListChanged
end;

procedure TSimpleHighlighter.ApplyLanguage;
begin
  // Rules from the matching preset; built-in keyword list from uLanguageKeywords.
  case FLanguage of
    slNone:     begin ClearRules; FLangKeywords := nil; end;
    slPascal:   begin UsePascal;   FLangKeywords := PascalKeywords; end;
    slCLike:    begin UseCLike;    FLangKeywords := CKeywords; end;
    slAntimony: begin UseAntimony; FLangKeywords := AntimonyKeywords; end;
    slPython:   begin UsePython;   FLangKeywords := PythonKeywords; end;
  end;
  RebuildKeywordSet;
end;

procedure TSimpleHighlighter.SetLanguage(const Value: TSyntaxLanguage);
begin
  FLanguage := Value;
  ApplyLanguage;   // the Use* presets and RebuildKeywordSet already fire Changed
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

function TSimpleHighlighter.LineComment: string;
begin
  if FLineComments.Count > 0 then
    Result := FLineComments[0]
  else
    Result := '';
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

procedure TSimpleHighlighter.UsePython;
begin
  // Python: '#' line comments; single-line '...' and "..." strings. Triple-quoted
  // strings (''' and """) are multi-line and cover docstrings; the engine has no
  // multi-line *string* rule, only multi-line block *comments*, so we model them
  // as block comments -- they render in CommentColor, a common and acceptable
  // simplification (docstrings read comment-like anyway). #39#39#39 is ''' -- the
  // triple-quote rules must be added *before* the ' / " string delimiters take
  // effect, but Tokenize already tests block comments before strings, so a lone
  // ' or " still opens an ordinary string.
  ClearRules;
  AddLineComment('#');
  AddBlockComment(#39#39#39, #39#39#39);   // ''' ... '''
  AddBlockComment('"""', '"""');
  AddStringDelimiter('''');
  AddStringDelimiter('"');
  CaseSensitive := True;
end;

procedure TSimpleHighlighter.SetCaseSensitive(const Value: Boolean);
begin
  if FCaseSensitive = Value then
    Exit;
  FCaseSensitive := Value;
  // Re-key both built-in and extra keywords under the new casing rule.
  RebuildKeywordSet;
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
