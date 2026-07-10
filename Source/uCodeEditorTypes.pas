unit uCodeEditorTypes;

{
  Shared token/lexer types for the Skia code editor and its highlighters.

  These live in their own unit so both the editor (uSkiaCodeEditor) and any
  highlighter (uSyntaxHighlighter) can reference them without a circular
  dependency -- the editor can then own a highlighter directly.
}

interface

uses
  System.UITypes;

type
  // A colored run within a single line: [start, start+length) share one style.
  TTokenRun = record
    StartCol: Integer;   // 0-based column, char index into the line string
    Length: Integer;
    Color: TAlphaColor;
    Bold: Boolean;
    Italic: Boolean;
  end;
  TTokenRunArray = TArray<TTokenRun>;

  // Continuation state carried across line boundaries (e.g. "inside a block
  // comment"). The tokenizer takes the incoming state and returns the outgoing
  // state; if a line's outgoing state changes, the next line must be re-lexed.
  // Value 0 (lsDefault) is "no continuation"; a tokenizer may use any other
  // integer values to encode its own multi-line contexts.
  TLexState = type Integer;

const
  lsDefault      = TLexState(0);
  lsBlockComment = TLexState(1);   // legacy convenience values
  lsString       = TLexState(2);

type
  // Tokenizer callback: caller supplies highlighting. Given a line's text and
  // the incoming lex state, fill Runs and return the outgoing lex state.
  // Keep this pure and per-line so re-tokenizing one edited line is cheap.
  TTokenizeLineProc = reference to function(const ALine: string;
    AStateIn: TLexState; out ARuns: TTokenRunArray): TLexState;

  // Find/replace options. Lives here so both the editor and the find bar can
  // reference it without a circular unit dependency.
  TFindOption = (foMatchCase, foWholeWord, foWrapAround);
  TFindOptions = set of TFindOption;

  // How a marker is drawn. Independent of what it spans: either kind can cover
  // a single token or a whole line.
  //   mkTint      - translucent rectangle behind the text (like a find hit)
  //   mkSquiggle  - wavy underline beneath the glyphs (like a compiler error)
  TMarkerKind = (mkTint, mkSquiggle);

  // ---- tooltip content ----
  // A tooltip is a list of lines; each line is a list of coloured runs. This
  // mirrors how a line of code is drawn (TTokenRun), so the same "measure and
  // draw run by run" logic applies. Colour = TAlphaColors.Null means "use the
  // tooltip's default text colour", so a plain run needs no colour at all.
  TTipRun = record
    Text: string;
    Color: TAlphaColor;
    Bold: Boolean;
  end;
  TTipLine = TArray<TTipRun>;
  TTipText = TArray<TTipLine>;

// Builders, so a host writes
//   Tip([ TipLine([TipRun('Error', TAlphaColors.Red, True), TipRun(' in rate')]),
//         TipLine([TipRun('  unexpected element name')]) ])
// rather than assembling dynamic arrays by hand.
function TipRun(const AText: string; AColor: TAlphaColor = TAlphaColors.Null;
  ABold: Boolean = False): TTipRun;
function TipLine(const ARuns: array of TTipRun): TTipLine;
function Tip(const ALines: array of TTipLine): TTipText;
// Plain string -> one default-coloured run per #10-separated line.
function TipFromText(const AText: string): TTipText;

type
  // A host-owned annotation on a span of one line: an error, warning, or any
  // other "look here". Purely visual and completely independent of the caret
  // and selection, so setting markers never moves the user's cursor.
  // Line/StartCol are 0-based INTERNALLY; the editor's public AddMarker /
  // MarkLine take 1-based values and convert, matching GoToLine / CaretLine.
  TEditorMarker = record
    Line: Integer;
    StartCol: Integer;
    Length: Integer;      // in chars; 0 => to end of line
    Kind: TMarkerKind;
    Color: TAlphaColor;
    Message: string;      // plain text; also what MarkerMessageAt returns
    Tip: TTipText;        // rich tooltip; empty => built from Message
  end;

implementation

uses
  System.SysUtils;

function TipRun(const AText: string; AColor: TAlphaColor;
  ABold: Boolean): TTipRun;
begin
  Result.Text := AText;
  Result.Color := AColor;
  Result.Bold := ABold;
end;

function TipLine(const ARuns: array of TTipRun): TTipLine;
var
  I: Integer;
begin
  SetLength(Result, System.Length(ARuns));
  for I := 0 to High(ARuns) do
    Result[I] := ARuns[I];
end;

function Tip(const ALines: array of TTipLine): TTipText;
var
  I: Integer;
begin
  SetLength(Result, System.Length(ALines));
  for I := 0 to High(ALines) do
    Result[I] := ALines[I];
end;

function TipFromText(const AText: string): TTipText;
var
  Parts: TArray<string>;
  I: Integer;
begin
  if AText = '' then
    Exit(nil);
  Parts := AText.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  SetLength(Result, System.Length(Parts));
  for I := 0 to High(Parts) do
    Result[I] := TipLine([TipRun(Parts[I])]);
end;

end.
