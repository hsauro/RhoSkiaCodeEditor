unit uSyntaxHighlighter;

(*
  NOTE: this header is a paren-star comment, not a brace comment, because the
  metadata examples below contain literal braces -- which would close a brace
  comment early.

  TSimpleHighlighter -- a configurable, ready-made tokenizer so a developer does
  not have to hand-write a TTokenizeLineProc scanner.

  Configure it with a comment style (or a language preset), a keyword list, and
  four colors, then hand its Tokenize method to the editor. It recognizes:
    - line comments   (prefix to end of line, e.g. slash-slash, hash, dash-dash)
    - block comments  (open/close pairs, e.g. brace pairs) -- multi-line
    - strings         (single-line, delimited by any of the given chars)
    - numbers         (decimal, 0x-hex, and dollar-hex)
    - keywords        (case-sensitive or not)
    - metadata comments -- a comment whose first non-space character is '@'
      (see below)
  Anything else is left in the editor's default text color.

  Multi-line block comments encode their continuation in TLexState: the low 16
  bits hold N+1, meaning "inside block-comment rule N"; 0 (lsDefault) means no
  continuation. The high bits carry the metadata-comment flags below.

  METADATA COMMENTS
  Some languages carry structured annotations inside ordinary comments, because
  the language proper has no syntax for them -- e.g. Antimony scripts with
  simulation/plot directives:

      /*
      // baseline time course          <- prose: ordinary CommentColor
      @simulate wt: {                  <- '@simulate' MetadataTagColor,
        timeend: 50,                      the rest through the matching '}'
      }                                   MetadataColor
      */

  A comment whose first non-space character is '@' is a *metadata comment*.
  Inside one the tokenizer alternates between two modes:
    - between commands -- ordinary CommentColor, so hand-written prose and
      nested '//' notes inside the block still read as comments;
    - inside a command -- opened by a '@word' tag (MetadataTagColor) and running
      through the matching '}' of its value (MetadataColor). An optional name
      may follow the tag ('@simulate wt:'); it takes the body colour.

  The command body is deliberately NOT sub-parsed -- no inner grammar, so a
  '#1f77b4' colour literal, a nested brace or a '[...]' list costs nothing and
  cannot be mis-lexed. The one exception is quoted strings, which ARE skipped
  while counting braces, so a '}' inside "..." cannot end a command early.

  Recognition is per comment, not per line:
    - block comment -- decided at the opener. If the opener is followed only by
      whitespace to end of line (the common '/*' on its own line), the decision
      is deferred to the first line with content, via the lsMetaPending flag.
      Once decided, the whole comment keeps that status however many lines long.
    - line comment  -- single line only. '// @plot: { y: [S1] }' highlights, but
      a run of '//' lines does NOT continue a command across lines; use a block
      comment for multi-line metadata. (Continuing across '//' lines would make
      every leading line comment after an '@' one metadata until the next line
      of code -- too eager.)

  Set MetadataColor and MetadataTagColor to CommentColor to switch the feature
  off visually.
*)

interface

uses
  System.SysUtils, System.Classes,
  System.UIConsts,
  System.UITypes,
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
    FMetadataColor: TAlphaColor;      // body of an @command inside a comment
    FMetadataTagColor: TAlphaColor;   // the '@word' tag itself
    FOnChange: TNotifyEvent;
    FLanguage: TSyntaxLanguage;
    FLangKeywords: TArray<string>;   // built-in keywords for FLanguage (not streamed)
    FKeywordList: TStringList;       // the published Keywords: user's EXTRA words
    procedure Changed;
    function NormalizeWord(const AWord: string): string;
    function IsKeyword(const AWord: string): Boolean;
    procedure RebuildKeywordSet;     // FKeywords := built-in language set + extras
    procedure KeywordListChanged(Sender: TObject);
    procedure ApplyDefaultColors(ALang: TSyntaxLanguage);
    procedure ApplyLanguage;
    procedure SetLanguage(const Value: TSyntaxLanguage);
    function GetKeywords: TStrings;
    procedure SetKeywords(const Value: TStrings);
    procedure SetCaseSensitive(const Value: Boolean);
    procedure SetKeywordColor(const Value: TAlphaColor);
    procedure SetStringColor(const Value: TAlphaColor);
    procedure SetCommentColor(const Value: TAlphaColor);
    procedure SetNumberColor(const Value: TAlphaColor);
    procedure SetMetadataColor(const Value: TAlphaColor);
    procedure SetMetadataTagColor(const Value: TAlphaColor);
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

    { language presets: each replaces the comment/string rules and applies that
      language's default syntax colours (ApplyDefaultColors). They do NOT touch
      keywords (back-compat -- set those separately, or use the Language property
      which additionally loads the built-in keyword list). Set colours AFTER a
      preset to override its defaults. }
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
    // Metadata comments (see the unit header). Set both to CommentColor to make
    // '@command' comments look like any other comment.
    property MetadataColor: TAlphaColor read FMetadataColor write SetMetadataColor;
    property MetadataTagColor: TAlphaColor read FMetadataTagColor
      write SetMetadataTagColor;
  end;

implementation

const
  // Baseline (VS-ish light) syntax colours -- the shared default every language
  // starts from. Per-language overrides live in ApplyDefaultColors.
  DefKeywordColor = TAlphaColor($FF0000FF);   // blue
  DefStringColor  = TAlphaColor($FFA31515);   // maroon
  DefCommentColor = TAlphaColor($FF008000);   // green
  DefNumberColor  = TAlphaColor($FF098658);   // teal
  DefMetadataColor    = TAlphaColor(claOrange);   // slate grey -- @command body
  DefMetadataTagColor = TAlphaColor(claRed);   // mustard    -- the @word tag

  // TLexState layout. The low 16 bits keep the original "block-comment rule
  // N+1" encoding; the high bits describe a metadata comment in progress, so an
  // ordinary block comment still yields exactly the states it always did.
  lsBlockMask      = TLexState($0000FFFF);   // block-comment rule index + 1
  lsMetaBlock      = TLexState($00010000);   // this block IS a metadata comment
  lsMetaPending    = TLexState($00020000);   // ...undecided (opener line empty)
  lsMetaAwait      = TLexState($00040000);   // tag seen, waiting for its '{'
  lsMetaDepthShift = 20;                     // brace depth inside a command
  lsMetaDepthMask  = TLexState($0FF00000);
  MaxMetaDepth     = 255;

type
  // Result of probing a comment's leading content for the '@' that marks it as
  // metadata. mpEmpty = nothing but whitespace on this line, so defer.
  TMetaProbe = (mpEmpty, mpYes, mpNo);

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
  ApplyDefaultColors(slNone);   // seed the baseline syntax palette
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
    FMetadataColor    := H.FMetadataColor;
    FMetadataTagColor := H.FMetadataTagColor;
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

procedure TSimpleHighlighter.ApplyDefaultColors(ALang: TSyntaxLanguage);
begin
  // Each language's default syntax palette. Every language currently starts from
  // the same VS-ish light baseline; to give one its own look, override its
  // colours in the matching branch below (e.g. slAntimony). These are applied
  // whenever a language is selected (Use* preset or the Language property);
  // OI-set colours, explicit code assignments, and ApplyTheme still override
  // them afterwards. Set directly (no Changed) -- the caller already notifies.
  FKeywordColor := DefKeywordColor;
  FStringColor  := DefStringColor;
  FCommentColor := DefCommentColor;
  FNumberColor  := DefNumberColor;
  FMetadataColor    := DefMetadataColor;
  FMetadataTagColor := DefMetadataTagColor;
  case ALang of
    slPascal:   ;   // override Pascal's colours here
    slCLike:    ;   // override C-like colours here
    slAntimony: begin
                  FCommentColor := claLightGreen;
                  FKeywordColor := claCornflowerblue;
                  FNumberColor := claCoral;
                  FStringColor := $FFA31515; end;
    slPython:   ;   // override Python's colours here
  else
    ;               // slNone: baseline only
  end;
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
  ApplyDefaultColors(slPascal);
  AddLineComment('//');
  AddBlockComment('{', '}');
  AddBlockComment('(*', '*)');
  AddStringDelimiter('''');
  CaseSensitive := False;   // Pascal keywords are case-insensitive
end;

procedure TSimpleHighlighter.UseCLike;
begin
  ClearRules;
  ApplyDefaultColors(slCLike);
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
  ApplyDefaultColors(slAntimony);
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
  ApplyDefaultColors(slPython);
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

procedure TSimpleHighlighter.SetMetadataColor(const Value: TAlphaColor);
begin
  if FMetadataColor <> Value then
  begin
    FMetadataColor := Value;
    Changed;
  end;
end;

procedure TSimpleHighlighter.SetMetadataTagColor(const Value: TAlphaColor);
begin
  if FMetadataTagColor <> Value then
  begin
    FMetadataTagColor := Value;
    Changed;
  end;
end;

function TSimpleHighlighter.Tokenize(const ALine: string; AStateIn: TLexState;
  out ARuns: TTokenRunArray): TLexState;
var
  Runs: TList<TTokenRun>;
  I, N, StartPos, Ci, ClosePos, ContentEnd, SpanEnd: Integer;
  Block, MetaDepth: Integer;
  InMeta, MetaPending, MetaAwait: Boolean;
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

  // Does this comment's content (positions AFrom..ATo) mark it as a metadata
  // comment? Whitespace-only => mpEmpty, i.e. ask again on the next line.
  function ProbeMeta(AFrom, ATo: Integer): TMetaProbe;
  var
    P: Integer;
  begin
    if ATo > N then
      ATo := N;
    P := AFrom;
    while (P <= ATo) and CharInSet(ALine[P], [' ', #9]) do
      Inc(P);
    if P > ATo then
      Exit(mpEmpty);
    if ALine[P] = '@' then
      Exit(mpYes);
    Result := mpNo;
  end;

  // Paint AFrom..ATo as the interior of a metadata comment, advancing the
  // command sub-state (MetaAwait / MetaDepth) as it goes. Between commands the
  // text keeps CommentColor -- that is what lets a '//' note or plain prose
  // inside the block still read as an ordinary comment.
  procedure EmitMetaSpan(AFrom, ATo: Integer);
  var
    P, Seg, E: Integer;
    Q: Char;

    procedure Flush(AEnd: Integer; AColor: TAlphaColor);
    begin
      if AEnd >= Seg then
        Emit(Seg - 1, AEnd - Seg + 1, AColor);
      Seg := AEnd + 1;
    end;

    function BodyColor: TAlphaColor;
    begin
      if MetaAwait or (MetaDepth > 0) then
        Result := FMetadataColor    // inside a command
      else
        Result := FCommentColor;    // between commands
    end;

  begin
    if ATo > N then
      ATo := N;
    P := AFrom;
    Seg := AFrom;
    while P <= ATo do
    begin
      // A '@word' tag opens a command -- but only between commands, so an '@'
      // appearing inside a value stays body-coloured.
      if (not MetaAwait) and (MetaDepth = 0) and (ALine[P] = '@') and (P < ATo)
         and CharInSet(ALine[P + 1], ['A'..'Z', 'a'..'z', '_']) then
      begin
        Flush(P - 1, FCommentColor);       // prose before the tag
        E := P + 1;
        while (E <= ATo) and
              CharInSet(ALine[E], ['A'..'Z', 'a'..'z', '0'..'9', '_']) do
          Inc(E);
        Emit(P - 1, E - P, FMetadataTagColor);
        Seg := E;
        MetaAwait := True;                 // command runs to its matching '}'
        P := E;
        Continue;
      end;

      // The tag's optional name ('@simulate wt:') sits here, in body colour,
      // until the '{' that actually opens the value.
      if MetaAwait and (ALine[P] = '{') then
      begin
        MetaAwait := False;
        MetaDepth := 1;
        Inc(P);
        Continue;
      end;

      if MetaDepth > 0 then
      begin
        case ALine[P] of
          '{':
            if MetaDepth < MaxMetaDepth then
              Inc(MetaDepth);
          '}':
            begin
              Dec(MetaDepth);
              if MetaDepth = 0 then
                Flush(P, FMetadataColor);  // '}' closes the command
            end;
          '"', '''':
            begin
              // Skip a quoted value, so a '}' inside "..." cannot close the
              // command early. This is the ONLY inner grammar we honour.
              Q := ALine[P];
              Inc(P);
              while (P <= ATo) and (ALine[P] <> Q) do
                Inc(P);
            end;
        end;
      end;
      Inc(P);
    end;
    Flush(ATo, BodyColor);
  end;

  // Pack the block-comment rule and the metadata sub-state back into TLexState.
  function ComposeState: TLexState;
  begin
    if Block = 0 then
      Exit(lsDefault);                     // not in a block => no metadata state
    Result := TLexState(Block) and lsBlockMask;
    if InMeta then
      Result := Result or lsMetaBlock;
    if MetaPending then
      Result := Result or lsMetaPending;
    if MetaAwait then
      Result := Result or lsMetaAwait;
    Result := Result or
      ((TLexState(MetaDepth) shl lsMetaDepthShift) and lsMetaDepthMask);
  end;

  // Reset everything that only means something inside a block comment.
  procedure LeaveBlock;
  begin
    Block := 0;
    InMeta := False;
    MetaPending := False;
    MetaAwait := False;
    MetaDepth := 0;
  end;

begin
  Runs := TList<TTokenRun>.Create;
  try
    N := ALine.Length;
    I := 1;

    Block       := AStateIn and lsBlockMask;
    InMeta      := (AStateIn and lsMetaBlock) <> 0;
    MetaPending := (AStateIn and lsMetaPending) <> 0;
    MetaAwait   := (AStateIn and lsMetaAwait) <> 0;
    MetaDepth   := (AStateIn and lsMetaDepthMask) shr lsMetaDepthShift;

    // Continue an open block comment carried over from the previous line.
    if Block > 0 then
    begin
      BC := FBlockComments[Block - 1];
      ClosePos := FindFrom(BC.Close, 1);
      if ClosePos > 0 then
        ContentEnd := ClosePos - 1
      else
        ContentEnd := N;

      // '/*' alone on its opening line left the decision to the first line that
      // actually has content -- this may be it.
      if MetaPending then
        case ProbeMeta(1, ContentEnd) of
          mpYes: begin InMeta := True;  MetaPending := False; end;
          mpNo:  begin InMeta := False; MetaPending := False; end;
          mpEmpty: ;   // still nothing to go on; ask again next line
        end;

      if InMeta then
      begin
        EmitMetaSpan(1, ContentEnd);
        if ClosePos > 0 then
          Emit(ClosePos - 1, BC.Close.Length, FCommentColor);
      end
      else
      begin
        if ClosePos > 0 then
          SpanEnd := ClosePos + BC.Close.Length - 1
        else
          SpanEnd := N;
        Emit(0, SpanEnd, FCommentColor);
      end;

      if ClosePos > 0 then
      begin
        I := ClosePos + BC.Close.Length;
        LeaveBlock;
      end
      else
      begin
        ARuns := Runs.ToArray;
        Exit(ComposeState);   // whole line still inside the comment
      end;
    end;

    while I <= N do
    begin
      Matched := False;

      // line comment -> rest of line
      for Ci := 0 to FLineComments.Count - 1 do
        if MatchAt(FLineComments[Ci], I) then
        begin
          StartPos := I + FLineComments[Ci].Length;
          if ProbeMeta(StartPos, N) = mpYes then
          begin
            // Metadata in a line comment is single-line: the command state is
            // built up and dropped within this line, never carried forward.
            MetaAwait := False;
            MetaDepth := 0;
            Emit(I - 1, FLineComments[Ci].Length, FCommentColor);
            EmitMetaSpan(StartPos, N);
            MetaAwait := False;
            MetaDepth := 0;
          end
          else
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
          StartPos := I + BC.Open.Length;
          ClosePos := FindFrom(BC.Close, StartPos);
          if ClosePos > 0 then
            ContentEnd := ClosePos - 1
          else
            ContentEnd := N;

          MetaAwait := False;
          MetaDepth := 0;
          case ProbeMeta(StartPos, ContentEnd) of
            mpYes: begin InMeta := True;  MetaPending := False; end;
            mpNo:  begin InMeta := False; MetaPending := False; end;
            // Opener followed by nothing but whitespace ('/*' on its own line):
            // defer to the next line, unless the comment closes right here.
            mpEmpty: begin InMeta := False; MetaPending := ClosePos = 0; end;
          end;

          if InMeta then
          begin
            Emit(I - 1, BC.Open.Length, FCommentColor);
            EmitMetaSpan(StartPos, ContentEnd);
            if ClosePos > 0 then
              Emit(ClosePos - 1, BC.Close.Length, FCommentColor);
          end
          else
          begin
            if ClosePos > 0 then
              SpanEnd := ClosePos + BC.Close.Length - 1
            else
              SpanEnd := N;
            Emit(I - 1, SpanEnd - I + 1, FCommentColor);
          end;

          if ClosePos > 0 then
          begin
            I := ClosePos + BC.Close.Length;
            LeaveBlock;
          end
          else
          begin
            Block := Ci + 1;
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
    Result := ComposeState;
  finally
    Runs.Free;
  end;
end;

end.
