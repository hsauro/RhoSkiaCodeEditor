unit uSkiaCodeEditor;

{
  TSkiaCodeEditor - an owner-drawn, Skia-backed code editor control for FMX.

  Design goals:
    - No native presenter in the loop. Every glyph is measured and drawn with
      Skia, so Windows and macOS share one identical paint path. This is the
      whole point: it eliminates the native-vs-styled presenter divergence that
      makes TMemo-derived styled memos unfixable cross-platform.
    - Viewport-clipped painting: only visible lines are laid out and drawn.
    - Per-line token cache for syntax highlighting; re-tokenize only edited
      lines (plus multi-line continuation state).
    - You own caret / selection / hit-testing directly against Skia metrics,
      so there is no FMX-point vs native-pixel size mismatch.

  Status: FUNCTIONAL. Rendering, editing, scrolling (owned scrollbars), selection
  (+ double-click word, drag), clipboard, undo/redo, lazy syntax highlighting
  with downstream invalidation, find/replace (+ built-in bar), IME scaffolding,
  live font/colour theming, and navigation are all implemented. See CLAUDE.md
  for the per-feature map and the two open caveats (macOS IME untested on real
  hardware; CJK needs a font fallback).
}

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Rtti,
  System.Generics.Collections, System.Math, System.StrUtils,
  FMX.Types, FMX.Controls, FMX.Graphics, FMX.Layouts, FMX.StdCtrls, FMX.Platform,
  FMX.Text, FMX.Forms, System.Skia, FMX.Skia,
  uCodeEditorTypes, uSyntaxHighlighter, uFindBar;

type
  // Token/lexer types (TTokenRun, TLexState, TTokenizeLineProc, ls* consts)
  // live in uCodeEditorTypes and are re-exported here for callers.
  TTokenRun = uCodeEditorTypes.TTokenRun;
  TTokenRunArray = uCodeEditorTypes.TTokenRunArray;
  TLexState = uCodeEditorTypes.TLexState;
  TTokenizeLineProc = uCodeEditorTypes.TTokenizeLineProc;

  // One logical line: its text plus cached tokens, lex state, and wrap layout.
  //
  // Wrapping: WrapStarts holds the 0-based column at which each *visual row* of
  // this line begins; WrapStarts[0] is always 0, so Length(WrapStarts) is the
  // row count and is >= 1. With WordWrap off every line has exactly one row, so
  // the row machinery collapses to the old "1 line = 1 row" geometry rather
  // than needing a separate code path. FirstRow is this line's absolute row
  // index in the document (a running sum maintained by UpdateContentSize).
  TEditorLine = class
  public
    Text: string;
    Tokens: TTokenRunArray;
    TokensValid: Boolean;   // False => must re-tokenize before paint
    StateIn: TLexState;     // lex state entering this line
    StateOut: TLexState;    // lex state leaving this line
    WrapStarts: TArray<Integer>;  // start col of each visual row; [0] = 0
    WrapValid: Boolean;     // False => must re-wrap before layout
    FirstRow: Integer;      // absolute visual row of this line's row 0
    constructor Create(const AText: string);
  end;

  TCaretPos = record
    Line: Integer;   // 0-based
    Col: Integer;    // 0-based char column
  end;

  // Find/replace options (defined in uCodeEditorTypes; re-exported here).
  TFindOption = uCodeEditorTypes.TFindOption;
  TFindOptions = uCodeEditorTypes.TFindOptions;

  // Host-owned annotations (errors/warnings). Re-exported for callers.
  TMarkerKind = uCodeEditorTypes.TMarkerKind;
  TEditorMarker = uCodeEditorTypes.TEditorMarker;
  TTipRun = uCodeEditorTypes.TTipRun;
  TTipLine = uCodeEditorTypes.TTipLine;
  TTipText = uCodeEditorTypes.TTipText;

const
  // A type alias re-exports the type but NOT its enum values, so name them too:
  // a host can then use markers with only uSkiaCodeEditor in its uses clause.
  mkTint     = uCodeEditorTypes.mkTint;
  mkSquiggle = uCodeEditorTypes.mkSquiggle;

  // Default monospaced face per platform. Consolas does not exist on macOS, and
  // TSkTypeface.MakeFromName does NOT fail on a missing family -- it silently
  // returns a default (proportional) typeface. Menlo ships on every Mac; SF Mono
  // is not reliably available to non-terminal apps.
  DefaultFontFamily =
    {$IF DEFINED(MACOS)}   'Menlo'
    {$ELSEIF DEFINED(MSWINDOWS)} 'Consolas'
    {$ELSE}                'DejaVu Sans Mono'
    {$ENDIF};

// Tooltip builders, re-exported for the same reason (a uses-clause convenience).
// Deliberately NOT inline: an inline function whose body lives in another unit
// makes every host emit H2443 unless it also uses uCodeEditorTypes, which is
// exactly the uses-clause burden this re-export exists to remove.
function TipRun(const AText: string; AColor: TAlphaColor = TAlphaColors.Null;
  ABold: Boolean = False): TTipRun;
function TipLine(const ARuns: array of TTipRun): TTipLine;
function Tip(const ALines: array of TTipLine): TTipText;

type

  // One undoable edit, modelled as a range replacement: the span starting at
  // RangeStart that held OldText now holds NewText. This inverts trivially, so
  // one record type covers insert, delete, and replace. Caret positions are for
  // restoring the cursor on undo/redo. Both texts use #10 line separators.
  TEditAction = record
    RangeStart: TCaretPos;
    OldText: string;
    NewText: string;
    CaretBefore: TCaretPos;
    CaretAfter: TCaretPos;
  end;

  // ITextInput lets the platform (macOS Cocoa, Windows IMM) route IME
  // composition to this control. Committed text still arrives through KeyDown;
  // this interface adds the in-progress "marked" string and candidate-window
  // placement. Layout/measurement stay 100% Skia -- only text *input* touches
  // native services, as the design allows.
  TSkiaCodeEditor = class(TControl, ITextInput)
  private
    FLines: TObjectList<TEditorLine>;
    FContent: TControl;            // Skia paint surface, client-aligned = viewport
    FVScroll: TScrollBar;          // vertical scrollbar (we own scrolling)
    FHScroll: TScrollBar;          // horizontal scrollbar
    FScrollX: Single;              // scroll offset (content coords) shown at left/top
    FScrollY: Single;
    FContentW: Single;             // total content extent (all lines)
    FContentH: Single;
    FGutterWidth: Single;          // 0 when the gutter is hidden
    FGutterVisible: Boolean;
    FLineHeight: Single;
    FCharWidth: Single;            // advance for monospace fast-path (0 => measure)
    FDigitWidth: Single;           // advance of '0'; layout metric, always valid
    FFontSize: Single;
    FFontFamily: string;
    FMonospace: Boolean;
    FWordWrap: Boolean;
    FTotalRows: Integer;           // sum of every line's visual row count
    FWrapWidth: Single;            // text width the current wrap was computed for
    FCaretAtRowEnd: Boolean;       // caret affinity at a wrap boundary (see below)
    FDesiredX: Single;             // goal column (as content x) for Up/Down runs
    FHasDesiredX: Boolean;         // False => next vertical move seeds FDesiredX
    FCaret: TCaretPos;
    FSelAnchor: TCaretPos;          // selection is the range [FSelAnchor .. FCaret]
    FMouseSelecting: Boolean;       // true while a drag-select is in progress
    FUndo: TList<TEditAction>;      // undo stack (top = last edit)
    FRedo: TList<TEditAction>;      // redo stack (top = last undone edit)
    FCoalesceTyping: Boolean;       // fold the next typed char into the last record
    FTextService: TTextService;     // native IME mediator (nil if unavailable)
    FIMEActive: Boolean;            // a composition is in progress
    FMarkedText: string;            // the in-progress (uncommitted) composition
    FCaretTimer: TTimer;
    FCaretVisible: Boolean;        // blink phase; only shown while focused
    FTokenizeLine: TTokenizeLineProc;
    FHighlighter: TSimpleHighlighter;   // owned; created lazily by Highlighter
    FBuiltInFindUI: Boolean;            // Ctrl+F shows the built-in bar vs event
    FFindBar: TFindBar;                 // owned; created lazily on first Ctrl+F
    FSkTypeface: ISkTypeface;
    FSkFont: ISkFont;
    FSkFontBold: ISkFont;          // for bold tooltip runs; same size/family
    FMaxLineWidth: Single;         // widest laid-out line, for content sizing

    // colors
    FTextColor: TAlphaColor;
    FBackColor: TAlphaColor;
    FGutterBackColor: TAlphaColor;
    FGutterTextColor: TAlphaColor;
    FCaretColor: TAlphaColor;
    FSelectionColor: TAlphaColor;
    FFindMatchColor: TAlphaColor;   // highlight for the current find match
    FFindHighlightColor: TAlphaColor;  // tint for every OTHER visible match
    FSelIsMatch: Boolean;           // current selection came from find

    // highlight-all: the live search term, painted behind every visible match.
    FHighlightTerm: string;         // '' => nothing highlighted
    FHighlightOptions: TFindOptions;
    FHighlightAll: Boolean;

    // host-owned markers (errors/warnings); never touch caret or selection
    FMarkers: TList<TEditorMarker>;
    FMarkersClearOnEdit: Boolean;

    // marker tooltip: own-drawn (Skia) so it is identical on Win/mac and can be
    // multi-line with per-run colour. A native hint service could do neither.
    FHoverTimer: TTimer;
    FHoverMarker: Integer;      // marker index under the pointer, -1 = none
    FHoverPt: TPointF;          // pointer, viewport coords
    FTipVisible: Boolean;
    FTooltipColor: TAlphaColor;
    FTooltipTextColor: TAlphaColor;
    FTooltipBorderColor: TAlphaColor;

    FModified: Boolean;                // text edited since load / last reset

    // events
    FOnCaretChange: TNotifyEvent;      // caret moved or text changed
    FOnChange: TNotifyEvent;           // text mutated (NOT caret moves / load)
    FOnRequestGotoLine: TNotifyEvent;  // user pressed Ctrl/Cmd+G
    FOnRequestFind: TNotifyEvent;      // user pressed Ctrl/Cmd+F

    procedure RebuildFontMetrics;
    function IsFixedPitch: Boolean;
    procedure UpdateContentSize;
    procedure UpdateScrollBars;
    procedure SetScrollPos(AX, AY: Single);
    procedure ScrollBarChange(Sender: TObject);
    procedure RedrawContent;
    function LineWidth(AIndex: Integer): Single;
    function GetCaretLine: Integer;
    function GetCaretColumn: Integer;
    function VisibleRowRange(out AFirst, ALast: Integer): Boolean;

    // word wrap. Rows are the universal vertical coordinate: with wrap off each
    // line yields exactly one row, so all geometry below has a single code path.
    function TextAreaWidth: Single;
    function RowBreak(const AText: string; AStart: Integer; AAvail: Single): Integer;
    procedure WrapLine(AIndex: Integer);
    procedure EnsureWrap(AIndex: Integer);
    procedure InvalidateWrap;
    function RowsInLine(AIndex: Integer): Integer;
    procedure RowColBounds(ALine, ARowInLine: Integer; out AStart, AEnd: Integer);
    function RowOfCol(ALine, ACol: Integer; APreferEnd: Boolean = False): Integer;
    function RowToLine(ARow: Integer): Integer;
    function CaretRowInLine: Integer;
    function CaretRow: Integer;
    function CaretContentX: Single;
    procedure ResetCaretTarget;
    procedure SetWordWrap(const Value: Boolean);
    procedure EnsureTokens(AIndex: Integer);
    function LexLine(AIndex: Integer; AStateIn: TLexState): TLexState;
    procedure RetokenizeAfterEdit(AStart, AEnd: Integer);
    procedure HighlighterChanged(Sender: TObject);

    // paint helpers, all Skia so Win/mac are identical
    procedure PaintContent(const ACanvas: ISkCanvas; const ADest: TRectF);
    procedure PaintFindMatches(const ACanvas: ISkCanvas;
      AFirstRow, ALastRow: Integer);
    procedure PaintMarkers(const ACanvas: ISkCanvas;
      AFirstRow, ALastRow: Integer; AKind: TMarkerKind);
    procedure PaintSquiggle(const ACanvas: ISkCanvas; const APaint: ISkPaint;
      AX1, AX2, ABaseY: Single);
    procedure MarkerSpan(const AMarker: TEditorMarker;
      out AStart, AEnd: Integer);
    function WordSpanAt(ALine, ACol: Integer;
      out AStartCol, ALen: Integer): Boolean;
    function MarkerRowRect(const AMarker: TEditorMarker; ARowInLine: Integer;
      out ARect: TRectF): Boolean;
    function MarkerAtPoint(const APt: TPointF): Integer;
    function MarkerTip(const AMarker: TEditorMarker): TTipText;
    function TipFontFor(ABold: Boolean): ISkFont;
    procedure PaintTooltip(const ACanvas: ISkCanvas);
    procedure HoverTimer(Sender: TObject);
    procedure HideTooltip;
    procedure ContentMouseLeave(Sender: TObject);
    procedure SetTooltipColor(const Value: TAlphaColor);
    procedure SetTooltipTextColor(const Value: TAlphaColor);
    procedure SetTooltipBorderColor(const Value: TAlphaColor);
    procedure PaintGutter(const ACanvas: ISkCanvas; AFirstRow, ALastRow: Integer);
    procedure PaintRow(const ACanvas: ISkCanvas; ALineIdx, ARowInLine: Integer;
      AY: Single);
    procedure PaintSelection(const ACanvas: ISkCanvas; AFirstRow, ALastRow: Integer);
    procedure PaintMarkedText(const ACanvas: ISkCanvas);
    procedure PaintCaret(const ACanvas: ISkCanvas);

    // IME / composition (macOS + Windows). ITextInput is what the platform
    // queries on the focused control to drive composition.
    function FormHandle: TWindowHandle;
    procedure SyncTextService;
    { ITextInput }
    function GetTextService: TTextService;
    function GetTargetClausePointF: TPointF;
    procedure StartIMEInput;
    procedure EndIMEInput;
    procedure IMEStateUpdated;
    function GetSelection: string;
    function GetSelectionRect: TRectF;
    function GetSelectionBounds: TRect;
    function GetSelectionPointSize: TSizeF;
    function HasText: Boolean;

    procedure ContentPaint(ASender: TObject; const ACanvas: ISkCanvas;
      const ADest: TRectF; const AOpacity: Single);
    procedure ContentResize(Sender: TObject);
    procedure ContentMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure ContentMouseMove(Sender: TObject; Shift: TShiftState;
      X, Y: Single);
    procedure ContentMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Single);
    procedure ContentDblClick(Sender: TObject);
    procedure SelectWordAt(ALine, ACol: Integer);

    // selection
    function ComparePos(const A, B: TCaretPos): Integer;
    function SelActive: Boolean;
    procedure SelBounds(out AStart, AEnd: TCaretPos);
    function TextInRange(const A, B: TCaretPos): string;
    function SelectedText: string;
    procedure SelectAll;

    // undo/redo
    function AdvancePos(const AStart: TCaretPos; const S: string): TCaretPos;
    procedure ApplyReplace(const A, B: TCaretPos; const ANewText: string;
      ACoalesce: Boolean);
    procedure ApplyRecord(const ARec: TEditAction; AInvert: Boolean);

    // clipboard (FMX IFMXClipboardService => cross-platform, no native text svc)
    function ClipboardService(out ASvc: IFMXClipboardService): Boolean;
    procedure CopySelection;
    procedure CutSelection;
    procedure PasteClipboard;

    // find/replace (single-line matches)
    procedure ShowBuiltInFindBar;
    procedure SetBuiltInFindUI(const Value: Boolean);
    function FindForward(const ASearch: string; AFromLine, AFromCol: Integer;
      AMatchCase, AWholeWord: Boolean; out AMLine, AMCol: Integer): Boolean;
    function FindBackward(const ASearch: string; AFromLine, AFromCol: Integer;
      AMatchCase, AWholeWord: Boolean; out AMLine, AMCol: Integer): Boolean;
    procedure SelectMatch(ALine, ACol, ALen: Integer);
    function LineMatches(AIndex: Integer): TArray<Integer>;
    procedure SetHighlightAllMatches(const Value: Boolean);

    // geometry / hit-testing
    function ColToX(ALineIdx, ACol: Integer; ARowInLine: Integer = -1): Single;
    function XToColInRow(ALineIdx, ARowStart, ARowEnd: Integer;
      AX: Single): Integer;
    function PointToCaret(const APt: TPointF; out AAtRowEnd: Boolean): TCaretPos;
    function MeasureRange(const AText: string; A, B: Integer): Single;
    procedure CaretTimer(Sender: TObject);
    procedure ResetCaretBlink;
    procedure EnsureCaretVisible;

    // font property setters -- each rebuilds Skia metrics and re-lays-out
    procedure ApplyFontChange;
    procedure SetFontSize(const Value: Single);
    procedure SetFontFamily(const Value: string);
    procedure SetMonospace(const Value: Boolean);
    procedure SetGutterVisible(const Value: Boolean);

    // colour property setters -- painting only, so they just repaint
    procedure SetColorField(var AField: TAlphaColor; const Value: TAlphaColor);
    procedure SetBackgroundColor(const Value: TAlphaColor);
    procedure SetTextColor(const Value: TAlphaColor);
    procedure SetGutterColor(const Value: TAlphaColor);
    procedure SetGutterTextColor(const Value: TAlphaColor);
    procedure SetCaretColor(const Value: TAlphaColor);
    procedure SetSelectionColor(const Value: TAlphaColor);
    procedure SetFindMatchColor(const Value: TAlphaColor);
    procedure SetFindHighlightColor(const Value: TAlphaColor);

    // editing primitives (mutate FLines/FCaret, then AfterEdit)
    procedure AfterEdit(AInvalidateFrom: Integer);
    procedure DeleteRangeRaw(const A, B: TCaretPos);   // no AfterEdit
    procedure InsertRaw(const S: string);              // no AfterEdit; handles newlines
    procedure ReplaceSelectionWith(const S: string; ACoalesce: Boolean = False);
    procedure DeleteSelection;
    procedure DeleteBackward;
    procedure DeleteForward;
    procedure MoveCaretHorizontal(ADelta: Integer; ASelecting: Boolean);
    procedure MoveCaretWord(ADir: Integer; ASelecting: Boolean);
    procedure MoveCaretVertical(ADelta: Integer; ASelecting: Boolean);
    procedure CaretToLineStart(ASelecting: Boolean);
    procedure CaretToLineEnd(ASelecting: Boolean);
  protected
    procedure DoMouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Single); virtual;
    procedure DoEnter; override;
    procedure DoExit; override;
    procedure Resize; override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer;
      var Handled: Boolean); override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar;
      Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    procedure SetText(const AText: string);
    function GetText: string;
    procedure SetTokenizer(const AProc: TTokenizeLineProc);
    procedure InvalidateAllTokens;

    // Built-in configurable syntax highlighter. First access creates one and
    // installs it as the tokenizer, so a caller can just write, e.g.:
    //   Editor.Highlighter.UsePascal;
    //   Editor.Highlighter.AddKeywords(['unit', 'begin', 'end']);
    // Colours/keywords/rules changed later re-lex automatically.
    function Highlighter: TSimpleHighlighter;

    procedure Undo;
    procedure Redo;
    function CanUndo: Boolean;
    function CanRedo: Boolean;

    // navigation
    function LineCount: Integer;
    procedure GoToLine(ALine: Integer);   // 1-based; caret to line start, centered
    property CaretLine: Integer read GetCaretLine;       // 1-based
    property CaretColumn: Integer read GetCaretColumn;   // 1-based
    property SelText: string read SelectedText;          // current selection

    // find / replace (host supplies the UI). Matches are single-line.
    function FindNext(const ASearch: string;
      AOptions: TFindOptions = [foWrapAround]): Boolean;
    function FindPrevious(const ASearch: string;
      AOptions: TFindOptions = [foWrapAround]): Boolean;
    function ReplaceCurrent(const ASearch, AReplace: string;
      AOptions: TFindOptions = [foWrapAround]): Boolean;
    function ReplaceAll(const ASearch, AReplace: string;
      AOptions: TFindOptions = []): Integer;   // returns count replaced

    // Highlight-all. FindNext/FindPrevious set the term themselves, so a host
    // driving the public find API gets highlights for free; call these directly
    // to highlight as the user types (the built-in find bar does exactly that).
    procedure HighlightMatches(const ASearch: string;
      AOptions: TFindOptions = []);
    procedure ClearHighlightMatches;

    // ---- markers: host-owned annotations (e.g. parser errors) ----
    // Purely visual: they never move the caret or selection, so you can mark up
    // a model without disturbing the user. All line/column args are 1-BASED, to
    // match GoToLine / CaretLine / CaretColumn. ALen <= 0 means "to end of line".
    // Each comes in a plain-text and a rich-tooltip flavour. The rich one takes
    // Tip([TipLine([TipRun('Error', TAlphaColors.Red, True), ...]), ...]).
    procedure AddMarker(ALine, ACol, ALen: Integer; AKind: TMarkerKind;
      AColor: TAlphaColor; const AMessage: string = ''); overload;
    procedure AddMarker(ALine, ACol, ALen: Integer; AKind: TMarkerKind;
      AColor: TAlphaColor; const ATip: TTipText); overload;
    // Whole line, from column 1 to its end.
    procedure MarkLine(ALine: Integer; AKind: TMarkerKind; AColor: TAlphaColor;
      const AMessage: string = ''); overload;
    procedure MarkLine(ALine: Integer; AKind: TMarkerKind; AColor: TAlphaColor;
      const ATip: TTipText); overload;
    // Marks the whole word starting at (or containing) ACol. Use when a parser
    // gives you a token's position but not its length.
    procedure MarkWordAt(ALine, ACol: Integer; AKind: TMarkerKind;
      AColor: TAlphaColor; const AMessage: string = ''); overload;
    procedure MarkWordAt(ALine, ACol: Integer; AKind: TMarkerKind;
      AColor: TAlphaColor; const ATip: TTipText); overload;
    procedure ClearMarkers;
    function MarkerCount: Integer;
    // Text of one line (1-based); '' if out of range. Lets a host locate a
    // sub-expression inside the line to convert a parser offset to a column.
    function LineText(ALine: Integer): string;
    // Message of the first marker covering (ALine, ACol), or '' -- drive a
    // tooltip or status bar off this. 1-based.
    function MarkerMessageAt(ALine, ACol: Integer): string;

    // True once the text has been edited since it was loaded. SetText (load)
    // clears it; set it False yourself after saving. Read it in your form's
    // OnCloseQuery to decide whether to prompt "save changes?". Runtime-only, so
    // it is public, not published. Undo does not clear it (matches TMemo).
    property Modified: Boolean read FModified write FModified;

  published
    // Everything the Object Inspector shows. Note TControl keeps Align/Anchors/
    // Size/Position/Visible/Enabled/TabOrder *public*, so a directly-derived
    // control has to re-publish them or the designer cannot lay it out.
    property Align;
    property Anchors;
    property Enabled;
    property Height;
    property Margins;
    property Padding;
    property Opacity;
    property Position;
    property Size;
    property TabOrder;
    property Visible;
    property Width;

    // Font. FontSize is a Single, so it takes no `default` specifier and is
    // always streamed -- harmless, and the alternative (a stored-function) buys
    // nothing here.
    property FontSize: Single read FFontSize write SetFontSize;
    property FontFamily: string read FFontFamily write SetFontFamily;
    property Monospace: Boolean read FMonospace write SetMonospace default True;
    property GutterVisible: Boolean read FGutterVisible write SetGutterVisible
      default True;
    // Wrap long lines to the viewport width instead of scrolling horizontally.
    // Off by default: the no-wrap path stays the fast one (one row per line, no
    // per-line break scan). Turning it on hides the horizontal scrollbar.
    property WordWrap: Boolean read FWordWrap write SetWordWrap default False;
    // When True (default), Ctrl/Cmd+F shows the component's own docked find bar.
    // Set False to handle OnRequestFind and supply your own find UI instead.
    property BuiltInFindUI: Boolean read FBuiltInFindUI write SetBuiltInFindUI
      default True;
    // When True (default), FindNext/FindPrevious and the built-in find bar tint
    // every visible occurrence of the search term. False = only the current match.
    property HighlightAllMatches: Boolean read FHighlightAll
      write SetHighlightAllMatches default True;
    // When True (default), any text edit drops all markers: they are stale the
    // moment the document changes. Set False to manage their lifetime yourself.
    property MarkersClearOnEdit: Boolean read FMarkersClearOnEdit
      write FMarkersClearOnEdit default True;

    // colours (ARGB TAlphaColor). Token colours come from the tokenizer /
    // Highlighter; these are the editor's own surfaces. No `default` specifier:
    // a TAlphaColor default would need a constant above MaxInt.
    property BackgroundColor: TAlphaColor read FBackColor write SetBackgroundColor;
    property TextColor: TAlphaColor read FTextColor write SetTextColor;
    property GutterColor: TAlphaColor read FGutterBackColor write SetGutterColor;
    property GutterTextColor: TAlphaColor read FGutterTextColor write SetGutterTextColor;
    property CaretColor: TAlphaColor read FCaretColor write SetCaretColor;
    property SelectionColor: TAlphaColor read FSelectionColor write SetSelectionColor;
    // Highlight for the match selected by FindNext/FindPrevious (distinct from a
    // normal selection so matches stand out). Use alpha < FF for translucency.
    property FindMatchColor: TAlphaColor read FFindMatchColor write SetFindMatchColor;
    // Tint painted behind every OTHER visible match of the current search term.
    // Keep it weaker than FindMatchColor so the current match still reads as
    // "the one you're on". Painted under the text, so use alpha < FF.
    property FindHighlightColor: TAlphaColor read FFindHighlightColor
      write SetFindHighlightColor;
    // Marker tooltip surfaces (own-drawn, so these are real colours, not a
    // platform hint style). TooltipTextColor is used by any run whose Color is
    // TAlphaColors.Null.
    property TooltipColor: TAlphaColor read FTooltipColor write SetTooltipColor;
    property TooltipTextColor: TAlphaColor read FTooltipTextColor
      write SetTooltipTextColor;
    property TooltipBorderColor: TAlphaColor read FTooltipBorderColor
      write SetTooltipBorderColor;

    // Fired after the caret moves or the text changes (good for a status bar).
    property OnCaretChange: TNotifyEvent read FOnCaretChange write FOnCaretChange;
    // Fired only when the text is mutated (typing, delete, paste, replace, undo/
    // redo) -- NOT on caret moves and NOT on SetText/load. Use it to enable a
    // Save action or flag the title bar; the Modified property is the persistent
    // dirty flag behind it.
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    // Fired when the user presses Ctrl/Cmd+G; the host shows a "go to line"
    // prompt and calls GoToLine (the control does not pop dialogs itself).
    property OnRequestGotoLine: TNotifyEvent read FOnRequestGotoLine
      write FOnRequestGotoLine;
    // Fired when the user presses Ctrl/Cmd+F; the host shows its find UI.
    property OnRequestFind: TNotifyEvent read FOnRequestFind write FOnRequestFind;
  end;

implementation

function TipRun(const AText: string; AColor: TAlphaColor;
  ABold: Boolean): TTipRun;
begin
  Result := uCodeEditorTypes.TipRun(AText, AColor, ABold);
end;

function TipLine(const ARuns: array of TTipRun): TTipLine;
begin
  Result := uCodeEditorTypes.TipLine(ARuns);
end;

function Tip(const ALines: array of TTipLine): TTipText;
begin
  Result := uCodeEditorTypes.Tip(ALines);
end;

{ TEditorLine }

constructor TEditorLine.Create(const AText: string);
begin
  inherited Create;
  Text := AText;
  TokensValid := False;
  StateIn := lsDefault;
  StateOut := lsDefault;
  SetLength(WrapStarts, 1);
  WrapStarts[0] := 0;   // every line has at least one visual row
  WrapValid := False;
  FirstRow := 0;
end;

{ TSkiaCodeEditor }

constructor TSkiaCodeEditor.Create(AOwner: TComponent);
var
  TextSvc: IFMXTextService;
begin
  inherited Create(AOwner);
  FLines := TObjectList<TEditorLine>.Create(True);
  FUndo := TList<TEditAction>.Create;
  FRedo := TList<TEditAction>.Create;
  FMarkers := TList<TEditorMarker>.Create;
  FMarkersClearOnEdit := True;
  FHoverMarker := -1;
  FTooltipColor       := $FF2D2D30;
  FTooltipTextColor   := $FFF0F0F0;
  FTooltipBorderColor := $FF6E6E70;

  FFontFamily := DefaultFontFamily;
  FFontSize := 13;
  FMonospace := True;
  FGutterVisible := True;
  FBuiltInFindUI := True;
  FGutterWidth := 48;
  FWordWrap := False;   // no-wrap stays the default (and the fast) path
  FWrapWidth := -1;
  FTotalRows := 1;

  FTextColor       := TAlphaColors.Black;
  FBackColor       := TAlphaColors.White;
  FGutterBackColor := $FFF0F0F0;
  FGutterTextColor := $FF808080;
  FCaretColor      := TAlphaColors.Black;
  FSelectionColor  := $400078D7;   // translucent selection
  FFindMatchColor  := $A0FF9800;   // orange find highlight (more prominent)
  FFindHighlightColor := $40FFC107;  // weaker amber for the other matches
  FHighlightAll    := True;

  CanFocus := True;
  AutoCapture := True;
  Width := 320;    // a sane footprint when dropped from the palette
  Height := 200;

  // We own scrolling with two real scrollbars rather than a TScrollBox: its
  // scrollbars auto-hide as overlays and its touch/inertia behavior differs
  // between Windows and macOS -- exactly the cross-platform divergence this
  // control exists to avoid. The paint surface is client-aligned (== viewport)
  // and we translate content by (FScrollX, FScrollY) ourselves.
  // NOTE Stored := False on every internally-created child. FMX streams a
  // control's children into the .fmx; without this, dropping the component on a
  // form at design time would write these three into the form file, and the
  // constructor would create them AGAIN on load -- duplicate scrollbars and
  // paint box. Same reason FFindBar sets it when lazily created.
  FVScroll := TScrollBar.Create(Self);
  FVScroll.Stored := False;
  FVScroll.Parent := Self;
  FVScroll.Orientation := TOrientation.Vertical;
  FVScroll.Align := TAlignLayout.Right;
  FVScroll.Width := 16;
  FVScroll.Margins.Bottom := 16;          // leave the bottom-right corner free
  FVScroll.OnChange := ScrollBarChange;

  FHScroll := TScrollBar.Create(Self);
  FHScroll.Stored := False;
  FHScroll.Parent := Self;
  FHScroll.Orientation := TOrientation.Horizontal;
  FHScroll.Align := TAlignLayout.Bottom;
  FHScroll.Height := 16;
  FHScroll.Margins.Right := 16;
  FHScroll.OnChange := ScrollBarChange;

  // FContent's OnDraw hands us an ISkCanvas so every glyph is measured and
  // drawn with Skia -- one identical paint path on Win/mac.
  FContent := TSkPaintBox.Create(Self);
  FContent.Stored := False;
  FContent.Parent := Self;
  FContent.Align := TAlignLayout.Client;  // fills the area left of the scrollbars
  FContent.HitTest := True;               // receive mouse; we forward to editor
  FContent.AutoCapture := True;           // keep getting MouseMove during drag-select
  TSkPaintBox(FContent).OnDraw := ContentPaint;
  // The wrap width is FContent's width, and FContent is realigned AFTER our own
  // Resize runs -- so re-flow off the paint surface's resize, not the editor's,
  // or every wrap is computed against the previous width.
  FContent.OnResize := ContentResize;
  FContent.OnMouseDown := ContentMouseDown;
  FContent.OnMouseMove := ContentMouseMove;
  FContent.OnMouseUp := ContentMouseUp;
  FContent.OnDblClick := ContentDblClick;
  FContent.OnMouseLeave := ContentMouseLeave;

  // Hover dwell before a marker tooltip appears (classic IDE feel; without the
  // delay the tip flickers as the pointer sweeps across code).
  FHoverTimer := TTimer.Create(Self);
  FHoverTimer.Interval := 500;
  FHoverTimer.OnTimer := HoverTimer;
  FHoverTimer.Enabled := False;

  FCaretTimer := TTimer.Create(Self);
  FCaretTimer.Interval := 500;
  FCaretTimer.OnTimer := CaretTimer;
  FCaretTimer.Enabled := False;   // only runs while focused
  FCaretVisible := True;

  // Native IME mediator. Absent on platforms without the service (harmless --
  // all IME code paths guard on FTextService <> nil).
  if TPlatformServices.Current.SupportsPlatformService(IFMXTextService, TextSvc) then
    FTextService := TextSvc.GetTextServiceClass.Create(Self, True);

  RebuildFontMetrics;
  SetText('');
end;

destructor TSkiaCodeEditor.Destroy;
begin
  FTextService.Free;
  FHighlighter.Free;
  FMarkers.Free;
  FUndo.Free;
  FRedo.Free;
  FLines.Free;
  inherited;
end;

procedure TSkiaCodeEditor.RebuildFontMetrics;
var
  Metrics: TSkFontMetrics;
begin
  // Build the Skia typeface/font ONCE and measure from it. This is the crux:
  // all metrics come from Skia, not from FMX TTextLayout or a native presenter,
  // so line height and char advance are identical on every platform.
  FSkTypeface := TSkTypeface.MakeFromName(FFontFamily, TSkFontStyle.Normal);
  FSkFont := TSkFont.Create(FSkTypeface, FFontSize);
  // Bold companion, used only by bold tooltip runs. Same family/size, so it
  // shares the line height computed below.
  FSkFontBold := TSkFont.Create(
    TSkTypeface.MakeFromName(FFontFamily, TSkFontStyle.Bold), FFontSize);
  FSkFont.GetMetrics(Metrics);
  FLineHeight := Ceil((-Metrics.Ascent) + Metrics.Descent + Metrics.Leading);
  FDigitWidth := FSkFont.MeasureText('0');   // a layout metric; always valid

  // FCharWidth > 0 is the monospace fast path: every geometry routine then
  // computes x as col * FCharWidth instead of measuring. Only take it if the
  // face really IS fixed-pitch. MakeFromName silently substitutes a default
  // (proportional) typeface for a missing family -- e.g. 'Consolas' on macOS --
  // and trusting Monospace there would drift the caret further from the glyph
  // the further right you go, while the text still rendered correctly. Zeroing
  // FCharWidth degrades to correct-but-slower per-character measurement.
  FCharWidth := 0;                           // 0 => measure per run
  if FMonospace and IsFixedPitch then
    FCharWidth := FDigitWidth;
end;

function TSkiaCodeEditor.IsFixedPitch: Boolean;
const
  Tolerance = 0.01;   // px; identical advances differ only by float noise
var
  W0, WW, WI: Single;
begin
  // Compare a digit, a wide glyph and a narrow one. A fixed-pitch face gives
  // all three the same advance; any proportional face separates 'W' from 'i'
  // by a wide margin.
  W0 := FSkFont.MeasureText('0');
  WW := FSkFont.MeasureText('W');
  WI := FSkFont.MeasureText('i');
  Result := (Abs(WW - W0) < Tolerance) and (Abs(WI - W0) < Tolerance);
end;

procedure TSkiaCodeEditor.ApplyFontChange;
begin
  // Shared tail for a font property change at run time: rebuild Skia metrics,
  // re-measure content (line height / widths changed), keep the caret visible,
  // repaint. Tokens are colour-only, so no re-lex is needed. Guarded so the
  // property setters are safe to call before the control is fully built.
  RebuildFontMetrics;
  FWrapWidth := -1;   // metrics changed => every wrap decision is stale
  InvalidateWrap;
  if Assigned(FContent) then
  begin
    UpdateContentSize;
    EnsureCaretVisible;
    RedrawContent;
  end;
end;

procedure TSkiaCodeEditor.SetFontSize(const Value: Single);
begin
  if (Value <= 0) or SameValue(FFontSize, Value) then
    Exit;
  FFontSize := Value;
  ApplyFontChange;
end;

procedure TSkiaCodeEditor.SetFontFamily(const Value: string);
begin
  if (Value = '') or (Value = FFontFamily) then
    Exit;
  FFontFamily := Value;
  ApplyFontChange;
end;

procedure TSkiaCodeEditor.SetMonospace(const Value: Boolean);
begin
  if Value = FMonospace then
    Exit;
  FMonospace := Value;
  ApplyFontChange;   // FCharWidth depends on Monospace
end;

procedure TSkiaCodeEditor.SetGutterVisible(const Value: Boolean);
begin
  if Value = FGutterVisible then
    Exit;
  FGutterVisible := Value;
  UpdateContentSize;   // recomputes FGutterWidth (0 when hidden)
  EnsureCaretVisible;
  RedrawContent;
end;

procedure TSkiaCodeEditor.SetWordWrap(const Value: Boolean);
begin
  if Value = FWordWrap then
    Exit;
  FWordWrap := Value;
  ResetCaretTarget;
  // No horizontal scrolling when wrapped: hide the bar and let the vertical one
  // run the full height (its bottom margin only exists to clear the corner).
  if Assigned(FHScroll) then
  begin
    FHScroll.Visible := not Value;
    if Value then
      FVScroll.Margins.Bottom := 0
    else
      FVScroll.Margins.Bottom := 16;
  end;
  FWrapWidth := -1;    // force a full re-wrap in UpdateContentSize
  InvalidateWrap;
  if Assigned(FContent) then
  begin
    UpdateContentSize;
    EnsureCaretVisible;
    RedrawContent;
  end;
end;

{ ---- word wrap ----

  Rows are the vertical coordinate everything else is expressed in. A line's
  WrapStarts lists the column each of its visual rows begins at; with wrap off
  that is always just [0], so row == line and the geometry below degenerates to
  the original one-row-per-line arithmetic without a second code path. }

function TSkiaCodeEditor.TextAreaWidth: Single;
begin
  // Width available to glyphs: the viewport minus the sticky gutter, minus one
  // digit of right margin so a caret parked at a row's end stays on screen.
  if not Assigned(FContent) then
    Exit(0);
  Result := FContent.Width - FGutterWidth - FDigitWidth;
  if Result < FDigitWidth then
    Result := FDigitWidth;   // degenerate viewport: still make progress
end;

function TSkiaCodeEditor.RowBreak(const AText: string; AStart: Integer;
  AAvail: Single): Integer;
var
  N, E, K, MaxChars: Integer;
  Acc, W: Single;
begin
  // First column NOT on the row that starts at AStart. Always > AStart, so a
  // caller looping on it terminates even when a single glyph exceeds AAvail.
  N := System.Length(AText);
  if FMonospace and (FCharWidth > 0) then
  begin
    MaxChars := Max(1, Trunc(AAvail / FCharWidth));
    E := Min(N, AStart + MaxChars);
  end
  else
  begin
    Acc := 0;
    E := AStart;
    while E < N do
    begin
      W := FSkFont.MeasureText(AText[E + 1]);   // 0-based col E = 1-based E+1
      if (Acc + W > AAvail) and (E > AStart) then
        Break;
      Acc := Acc + W;
      Inc(E);
    end;
    if E = AStart then
      Inc(E);
  end;

  // Prefer a word boundary: back up to the last space/tab inside the row, and
  // break just after it so the space trails this row rather than starting the
  // next. No boundary found => hard break mid-word (long identifiers, URLs).
  if E < N then
  begin
    K := E;
    while (K > AStart) and not CharInSet(AText[K], [' ', #9]) do
      Dec(K);
    if K > AStart then
      E := K;
  end;
  Result := E;
end;

procedure TSkiaCodeEditor.WrapLine(AIndex: Integer);
var
  L: TEditorLine;
  Avail: Single;
  N, S, E, Count: Integer;
begin
  L := FLines[AIndex];
  SetLength(L.WrapStarts, 1);
  L.WrapStarts[0] := 0;
  L.WrapValid := True;
  N := System.Length(L.Text);
  if (not FWordWrap) or (N = 0) then
    Exit;                       // wrap off (or empty line) => exactly one row
  Avail := TextAreaWidth;
  if Avail <= 0 then
    Exit;

  S := 0;
  Count := 1;
  repeat
    E := RowBreak(L.Text, S, Avail);
    if E >= N then
      Break;
    Inc(Count);
    SetLength(L.WrapStarts, Count);
    L.WrapStarts[Count - 1] := E;
    S := E;
  until False;
end;

procedure TSkiaCodeEditor.EnsureWrap(AIndex: Integer);
begin
  if not FLines[AIndex].WrapValid then
    WrapLine(AIndex);
end;

procedure TSkiaCodeEditor.InvalidateWrap;
var
  L: TEditorLine;
begin
  for L in FLines do
    L.WrapValid := False;
end;

function TSkiaCodeEditor.RowsInLine(AIndex: Integer): Integer;
begin
  EnsureWrap(AIndex);
  Result := System.Length(FLines[AIndex].WrapStarts);
end;

procedure TSkiaCodeEditor.RowColBounds(ALine, ARowInLine: Integer;
  out AStart, AEnd: Integer);
var
  L: TEditorLine;
begin
  // Columns [AStart, AEnd) drawn on this row. For every row but the last, AEnd
  // equals the next row's start, so a trailing space stays with this row.
  EnsureWrap(ALine);
  L := FLines[ALine];
  ARowInLine := Max(0, Min(ARowInLine, System.Length(L.WrapStarts) - 1));
  AStart := L.WrapStarts[ARowInLine];
  if ARowInLine < System.Length(L.WrapStarts) - 1 then
    AEnd := L.WrapStarts[ARowInLine + 1]
  else
    AEnd := System.Length(L.Text);
end;

function TSkiaCodeEditor.RowOfCol(ALine, ACol: Integer;
  APreferEnd: Boolean): Integer;
var
  WS: TArray<Integer>;
begin
  // A column sitting exactly on a wrap boundary belongs to two rows: it is the
  // end of one and the start of the next. APreferEnd (caret affinity) picks the
  // earlier row, which is what End-key / click-past-EOL on a wrapped row want.
  EnsureWrap(ALine);
  WS := FLines[ALine].WrapStarts;
  Result := High(WS);
  while (Result > 0) and (WS[Result] > ACol) do
    Dec(Result);
  if APreferEnd and (Result > 0) and (WS[Result] = ACol) then
    Dec(Result);
end;

function TSkiaCodeEditor.RowToLine(ARow: Integer): Integer;
var
  Lo, Hi, Mid: Integer;
begin
  // FirstRow is non-decreasing across lines, so binary search for the last line
  // that starts at or before ARow.
  if FLines.Count = 0 then
    Exit(0);
  Lo := 0;
  Hi := FLines.Count - 1;
  while Lo < Hi do
  begin
    Mid := (Lo + Hi + 1) div 2;
    if FLines[Mid].FirstRow <= ARow then
      Lo := Mid
    else
      Hi := Mid - 1;
  end;
  Result := Lo;
end;

function TSkiaCodeEditor.CaretRowInLine: Integer;
begin
  Result := RowOfCol(FCaret.Line, FCaret.Col, FCaretAtRowEnd);
end;

function TSkiaCodeEditor.CaretRow: Integer;
begin
  Result := FLines[FCaret.Line].FirstRow + CaretRowInLine;
end;

function TSkiaCodeEditor.CaretContentX: Single;
begin
  Result := ColToX(FCaret.Line, FCaret.Col, CaretRowInLine);
end;

procedure TSkiaCodeEditor.ResetCaretTarget;
begin
  // The caret was placed by something OTHER than a vertical move: it no longer
  // sits at a wrap boundary by choice, and a fresh Up/Down run must re-seed its
  // goal column from wherever the caret now is.
  FCaretAtRowEnd := False;
  FHasDesiredX := False;
end;

procedure TSkiaCodeEditor.SetColorField(var AField: TAlphaColor;
  const Value: TAlphaColor);
begin
  if AField <> Value then
  begin
    AField := Value;
    RedrawContent;   // colours only affect painting
  end;
end;

procedure TSkiaCodeEditor.SetBackgroundColor(const Value: TAlphaColor);
begin
  SetColorField(FBackColor, Value);
end;

procedure TSkiaCodeEditor.SetTextColor(const Value: TAlphaColor);
begin
  SetColorField(FTextColor, Value);
end;

procedure TSkiaCodeEditor.SetGutterColor(const Value: TAlphaColor);
begin
  SetColorField(FGutterBackColor, Value);
end;

procedure TSkiaCodeEditor.SetGutterTextColor(const Value: TAlphaColor);
begin
  SetColorField(FGutterTextColor, Value);
end;

procedure TSkiaCodeEditor.SetCaretColor(const Value: TAlphaColor);
begin
  SetColorField(FCaretColor, Value);
end;

procedure TSkiaCodeEditor.SetSelectionColor(const Value: TAlphaColor);
begin
  SetColorField(FSelectionColor, Value);
end;

procedure TSkiaCodeEditor.SetFindMatchColor(const Value: TAlphaColor);
begin
  SetColorField(FFindMatchColor, Value);
end;

procedure TSkiaCodeEditor.SetFindHighlightColor(const Value: TAlphaColor);
begin
  SetColorField(FFindHighlightColor, Value);
end;

procedure TSkiaCodeEditor.SetTooltipColor(const Value: TAlphaColor);
begin
  SetColorField(FTooltipColor, Value);
end;

procedure TSkiaCodeEditor.SetTooltipTextColor(const Value: TAlphaColor);
begin
  SetColorField(FTooltipTextColor, Value);
end;

procedure TSkiaCodeEditor.SetTooltipBorderColor(const Value: TAlphaColor);
begin
  SetColorField(FTooltipBorderColor, Value);
end;

procedure TSkiaCodeEditor.SetHighlightAllMatches(const Value: Boolean);
begin
  if FHighlightAll = Value then
    Exit;
  FHighlightAll := Value;
  RedrawContent;   // painting only; the term itself is left alone
end;

function TSkiaCodeEditor.LineCount: Integer;
begin
  Result := FLines.Count;
end;

function TSkiaCodeEditor.GetCaretLine: Integer;
begin
  Result := FCaret.Line + 1;   // 0-based internally, 1-based to callers
end;

function TSkiaCodeEditor.GetCaretColumn: Integer;
begin
  Result := FCaret.Col + 1;
end;

procedure TSkiaCodeEditor.GoToLine(ALine: Integer);
var
  Target: Integer;
begin
  // ALine is 1-based (as shown in the gutter). Caret to the start of that line,
  // scrolled roughly centered in the viewport.
  Target := Max(0, Min(LineCount - 1, ALine - 1));
  FCoalesceTyping := False;
  ResetCaretTarget;
  FCaret.Line := Target;
  FCaret.Col := 0;
  FSelAnchor := FCaret;   // collapse any selection
  if Assigned(FContent) then
    SetScrollPos(FScrollX,
      FLines[Target].FirstRow * FLineHeight
        - (FContent.Height - FLineHeight) / 2);  // center
  EnsureCaretVisible;     // safety-clamp into view
  ResetCaretBlink;
  RedrawContent;
end;

{ ---- find / replace (single-line matches) ---- }

function FindIsWordChar(C: Char): Boolean;
begin
  Result := CharInSet(C, ['A'..'Z', 'a'..'z', '0'..'9', '_']);
end;

// Is the [AStart0, AStart0+ALen) span in ALine bounded by non-word chars?
function FindIsWordBoundary(const ALine: string; AStart0, ALen: Integer): Boolean;
var
  Before, After: Boolean;
begin
  Before := (AStart0 = 0) or (not FindIsWordChar(ALine[AStart0]));      // char just before
  After := (AStart0 + ALen >= System.Length(ALine)) or
           (not FindIsWordChar(ALine[AStart0 + ALen + 1]));             // char just after
  Result := Before and After;
end;

function TSkiaCodeEditor.FindForward(const ASearch: string;
  AFromLine, AFromCol: Integer; AMatchCase, AWholeWord: Boolean;
  out AMLine, AMCol: Integer): Boolean;
var
  Li, StartC, P: Integer;
  Hay, Needle: string;
begin
  Needle := ASearch;
  if not AMatchCase then
    Needle := Needle.ToLower;
  for Li := AFromLine to LineCount - 1 do
  begin
    Hay := FLines[Li].Text;
    if not AMatchCase then
      Hay := Hay.ToLower;
    if Li = AFromLine then
      StartC := AFromCol + 1     // 1-based; skip past the current position
    else
      StartC := 1;
    P := PosEx(Needle, Hay, StartC);
    while P > 0 do
    begin
      if (not AWholeWord) or
         FindIsWordBoundary(FLines[Li].Text, P - 1, System.Length(ASearch)) then
      begin
        AMLine := Li;
        AMCol := P - 1;
        Exit(True);
      end;
      P := PosEx(Needle, Hay, P + 1);
    end;
  end;
  Result := False;
end;

function TSkiaCodeEditor.FindBackward(const ASearch: string;
  AFromLine, AFromCol: Integer; AMatchCase, AWholeWord: Boolean;
  out AMLine, AMCol: Integer): Boolean;
var
  Li, P, Last: Integer;
  Hay, Needle: string;
begin
  Needle := ASearch;
  if not AMatchCase then
    Needle := Needle.ToLower;
  for Li := AFromLine downto 0 do
  begin
    Hay := FLines[Li].Text;
    if not AMatchCase then
      Hay := Hay.ToLower;
    Last := 0;             // keep the last acceptable match on this line
    P := PosEx(Needle, Hay, 1);
    while P > 0 do
    begin
      // On the start line, only matches beginning before AFromCol count.
      if (Li < AFromLine) or (P - 1 < AFromCol) then
      begin
        if (not AWholeWord) or
           FindIsWordBoundary(FLines[Li].Text, P - 1, System.Length(ASearch)) then
          Last := P;
      end
      else
        Break;
      P := PosEx(Needle, Hay, P + 1);
    end;
    if Last > 0 then
    begin
      AMLine := Li;
      AMCol := Last - 1;
      Exit(True);
    end;
  end;
  Result := False;
end;

procedure TSkiaCodeEditor.HighlightMatches(const ASearch: string;
  AOptions: TFindOptions);
begin
  if (ASearch = FHighlightTerm) and (AOptions = FHighlightOptions) then
    Exit;
  FHighlightTerm := ASearch;
  FHighlightOptions := AOptions;
  RedrawContent;   // matches are found per visible line at paint time
end;

procedure TSkiaCodeEditor.ClearHighlightMatches;
begin
  if FHighlightTerm = '' then
    Exit;
  FHighlightTerm := '';
  RedrawContent;
end;

function TSkiaCodeEditor.LineMatches(AIndex: Integer): TArray<Integer>;
var
  Hay, Needle: string;
  P, N, Len: Integer;
  MatchCase, WholeWord: Boolean;
begin
  // Start columns (0-based) of every match of FHighlightTerm in this line. Only
  // ever called for VISIBLE lines, so the whole-document scan never happens.
  SetLength(Result, 0);
  if FHighlightTerm = '' then
    Exit;
  MatchCase := foMatchCase in FHighlightOptions;
  WholeWord := foWholeWord in FHighlightOptions;
  Len := System.Length(FHighlightTerm);
  Needle := FHighlightTerm;
  Hay := FLines[AIndex].Text;
  if not MatchCase then
  begin
    Needle := Needle.ToLower;
    Hay := Hay.ToLower;
  end;

  N := 0;
  P := PosEx(Needle, Hay, 1);
  while P > 0 do
  begin
    if (not WholeWord) or FindIsWordBoundary(FLines[AIndex].Text, P - 1, Len) then
    begin
      SetLength(Result, N + 1);
      Result[N] := P - 1;   // 1-based Pos -> 0-based column
      Inc(N);
    end;
    P := PosEx(Needle, Hay, P + 1);   // overlapping, as FindForward does
  end;
end;

{ ---- markers (host-owned annotations; independent of caret + selection) ---- }

function TSkiaCodeEditor.LineText(ALine: Integer): string;
begin
  if (ALine < 1) or (ALine > LineCount) then
    Exit('');
  Result := FLines[ALine - 1].Text;
end;

procedure TSkiaCodeEditor.AddMarker(ALine, ACol, ALen: Integer;
  AKind: TMarkerKind; AColor: TAlphaColor; const AMessage: string);
var
  M: TEditorMarker;
begin
  // 1-based in, 0-based stored. Out-of-range lines are ignored rather than
  // raising: a parser that reports a line past EOF shouldn't crash the editor.
  if (ALine < 1) or (ALine > LineCount) then
    Exit;
  M.Line := ALine - 1;
  M.StartCol := Max(0, ACol - 1);
  if ALen <= 0 then
    M.Length := 0            // 0 => span to end of line (resolved at paint)
  else
    M.Length := ALen;
  M.Kind := AKind;
  M.Color := AColor;
  M.Message := AMessage;
  M.Tip := nil;              // built from Message on demand
  FMarkers.Add(M);
  RedrawContent;
end;

procedure TSkiaCodeEditor.AddMarker(ALine, ACol, ALen: Integer;
  AKind: TMarkerKind; AColor: TAlphaColor; const ATip: TTipText);
var
  M: TEditorMarker;
  I, J: Integer;
  SB: TStringBuilder;
begin
  if (ALine < 1) or (ALine > LineCount) then
    Exit;
  AddMarker(ALine, ACol, ALen, AKind, AColor, '');
  M := FMarkers.Last;
  M.Tip := ATip;
  // Keep a plain-text Message in step, so MarkerMessageAt still works for a
  // status bar even when the caller supplied a rich tooltip.
  SB := TStringBuilder.Create;
  try
    for I := 0 to High(ATip) do
    begin
      if I > 0 then
        SB.Append(#10);
      for J := 0 to High(ATip[I]) do
        SB.Append(ATip[I][J].Text);
    end;
    M.Message := SB.ToString;
  finally
    SB.Free;
  end;
  FMarkers[FMarkers.Count - 1] := M;
end;

procedure TSkiaCodeEditor.MarkLine(ALine: Integer; AKind: TMarkerKind;
  AColor: TAlphaColor; const AMessage: string);
begin
  AddMarker(ALine, 1, 0, AKind, AColor, AMessage);
end;

procedure TSkiaCodeEditor.MarkLine(ALine: Integer; AKind: TMarkerKind;
  AColor: TAlphaColor; const ATip: TTipText);
begin
  AddMarker(ALine, 1, 0, AKind, AColor, ATip);
end;

function TSkiaCodeEditor.WordSpanAt(ALine, ACol: Integer;
  out AStartCol, ALen: Integer): Boolean;
var
  L: string;
  N, C, WS, WE: Integer;
begin
  // Parsers usually report where a token STARTS, not how long it is. Grow the
  // span over the word containing/starting at ACol (same notion of a word char
  // as double-click select). Not on a word => the single character at ACol.
  // In/out columns are 1-based. Shared by both MarkWordAt overloads.
  Result := False;
  if (ALine < 1) or (ALine > LineCount) then
    Exit;
  L := FLines[ALine - 1].Text;
  N := System.Length(L);
  C := Max(0, Min(ACol - 1, N));          // 0-based
  if (C >= N) or (not FindIsWordChar(L[C + 1])) then
  begin
    AStartCol := C + 1;
    ALen := 1;
    Exit(True);
  end;
  WS := C;
  while (WS > 0) and FindIsWordChar(L[WS]) do   // char at 0-based WS-1
    Dec(WS);
  WE := C + 1;
  while (WE < N) and FindIsWordChar(L[WE + 1]) do
    Inc(WE);
  AStartCol := WS + 1;
  ALen := WE - WS;
  Result := True;
end;

procedure TSkiaCodeEditor.MarkWordAt(ALine, ACol: Integer; AKind: TMarkerKind;
  AColor: TAlphaColor; const AMessage: string);
var
  WS, WLen: Integer;
begin
  if WordSpanAt(ALine, ACol, WS, WLen) then
    AddMarker(ALine, WS, WLen, AKind, AColor, AMessage);
end;

procedure TSkiaCodeEditor.MarkWordAt(ALine, ACol: Integer; AKind: TMarkerKind;
  AColor: TAlphaColor; const ATip: TTipText);
var
  WS, WLen: Integer;
begin
  if WordSpanAt(ALine, ACol, WS, WLen) then
    AddMarker(ALine, WS, WLen, AKind, AColor, ATip);
end;

procedure TSkiaCodeEditor.ClearMarkers;
begin
  if FMarkers.Count = 0 then
    Exit;
  HideTooltip;      // its marker is about to disappear
  FMarkers.Clear;
  RedrawContent;
end;

function TSkiaCodeEditor.MarkerCount: Integer;
begin
  Result := FMarkers.Count;
end;

procedure TSkiaCodeEditor.MarkerSpan(const AMarker: TEditorMarker;
  out AStart, AEnd: Integer);
var
  N: Integer;
begin
  // Resolve a marker to a concrete [AStart, AEnd) column span on its line.
  N := System.Length(FLines[AMarker.Line].Text);
  AStart := Max(0, Min(AMarker.StartCol, N));
  if AMarker.Length <= 0 then
    AEnd := N                                  // "to end of line"
  else
    AEnd := Min(AStart + AMarker.Length, N);
end;

function TSkiaCodeEditor.MarkerMessageAt(ALine, ACol: Integer): string;
var
  I, S, E, L0, C0: Integer;
begin
  Result := '';
  L0 := ALine - 1;
  C0 := ACol - 1;
  if (L0 < 0) or (L0 >= LineCount) then
    Exit;
  for I := 0 to FMarkers.Count - 1 do
    if (FMarkers[I].Line = L0) and (FMarkers[I].Message <> '') then
    begin
      MarkerSpan(FMarkers[I], S, E);
      // An empty line's whole-line marker still covers column 1.
      if ((C0 >= S) and (C0 < E)) or ((S = E) and (C0 = S)) then
        Exit(FMarkers[I].Message);
    end;
end;

procedure TSkiaCodeEditor.SelectMatch(ALine, ACol, ALen: Integer);
begin
  FCoalesceTyping := False;
  ResetCaretTarget;
  FSelAnchor.Line := ALine;
  FSelAnchor.Col := ACol;
  FCaret.Line := ALine;
  FCaret.Col := ACol + ALen;   // selection = the match
  if Assigned(FContent) then
    SetScrollPos(FScrollX,
      (FLines[ALine].FirstRow + RowOfCol(ALine, ACol)) * FLineHeight
        - (FContent.Height - FLineHeight) / 2);   // center the match's row
  EnsureCaretVisible;          // also brings the match's column into view
  ResetCaretBlink;
  FSelIsMatch := True;         // paint this selection with FindMatchColor
  RedrawContent;
end;

function TSkiaCodeEditor.FindNext(const ASearch: string;
  AOptions: TFindOptions): Boolean;
var
  StartL, StartC, ML, MC: Integer;
  A, B: TCaretPos;
begin
  if ASearch = '' then
    Exit(False);
  if FHighlightAll then
    HighlightMatches(ASearch, AOptions);
  if SelActive then
  begin
    SelBounds(A, B);
    StartL := B.Line;
    StartC := B.Col;
  end
  else
  begin
    StartL := FCaret.Line;
    StartC := FCaret.Col;
  end;

  if FindForward(ASearch, StartL, StartC, foMatchCase in AOptions,
     foWholeWord in AOptions, ML, MC) then
  begin
    SelectMatch(ML, MC, System.Length(ASearch));
    Exit(True);
  end;
  if (foWrapAround in AOptions) and
     FindForward(ASearch, 0, 0, foMatchCase in AOptions,
       foWholeWord in AOptions, ML, MC) then
  begin
    SelectMatch(ML, MC, System.Length(ASearch));
    Exit(True);
  end;
  Result := False;
end;

function TSkiaCodeEditor.FindPrevious(const ASearch: string;
  AOptions: TFindOptions): Boolean;
var
  StartL, StartC, ML, MC: Integer;
  A, B: TCaretPos;
begin
  if ASearch = '' then
    Exit(False);
  if FHighlightAll then
    HighlightMatches(ASearch, AOptions);
  if SelActive then
  begin
    SelBounds(A, B);
    StartL := A.Line;
    StartC := A.Col;
  end
  else
  begin
    StartL := FCaret.Line;
    StartC := FCaret.Col;
  end;

  if FindBackward(ASearch, StartL, StartC, foMatchCase in AOptions,
     foWholeWord in AOptions, ML, MC) then
  begin
    SelectMatch(ML, MC, System.Length(ASearch));
    Exit(True);
  end;
  if (foWrapAround in AOptions) and
     FindBackward(ASearch, LineCount - 1, MaxInt, foMatchCase in AOptions,
       foWholeWord in AOptions, ML, MC) then
  begin
    SelectMatch(ML, MC, System.Length(ASearch));
    Exit(True);
  end;
  Result := False;
end;

function TSkiaCodeEditor.ReplaceCurrent(const ASearch, AReplace: string;
  AOptions: TFindOptions): Boolean;
var
  A, B: TCaretPos;
  Seg: string;
  IsMatch: Boolean;
begin
  Result := False;
  if ASearch = '' then
    Exit;
  // If the current selection IS the search term, replace it (undoable) first.
  if SelActive then
  begin
    SelBounds(A, B);
    if A.Line = B.Line then
    begin
      Seg := TextInRange(A, B);
      if (foMatchCase in AOptions) then
        IsMatch := Seg = ASearch
      else
        IsMatch := SameText(Seg, ASearch);
      if IsMatch then
      begin
        ApplyReplace(A, B, AReplace, False);   // recorded for undo
        Result := True;
      end;
    end;
  end;
  FindNext(ASearch, AOptions);   // advance to the following match
end;

function TSkiaCodeEditor.ReplaceAll(const ASearch, AReplace: string;
  AOptions: TFindOptions): Integer;
var
  SB: TStringBuilder;
  Li, P, FromPos: Integer;
  Hay, Needle, Line: string;
  MatchCase, WholeWord: Boolean;
  A, B: TCaretPos;
begin
  Result := 0;
  if ASearch = '' then
    Exit;
  MatchCase := foMatchCase in AOptions;
  WholeWord := foWholeWord in AOptions;
  Needle := ASearch;
  if not MatchCase then
    Needle := Needle.ToLower;

  // Build the whole new document once, then apply it as a single undoable edit.
  SB := TStringBuilder.Create;
  try
    for Li := 0 to LineCount - 1 do
    begin
      Line := FLines[Li].Text;
      Hay := Line;
      if not MatchCase then
        Hay := Hay.ToLower;
      FromPos := 1;   // 1-based, how far of Line has been copied
      P := PosEx(Needle, Hay, 1);
      while P > 0 do
      begin
        if (not WholeWord) or
           FindIsWordBoundary(Line, P - 1, System.Length(ASearch)) then
        begin
          SB.Append(Copy(Line, FromPos, P - FromPos));   // original-case prefix
          SB.Append(AReplace);
          Inc(Result);
          FromPos := P + System.Length(ASearch);
          P := PosEx(Needle, Hay, FromPos);
        end
        else
          P := PosEx(Needle, Hay, P + 1);
      end;
      SB.Append(Copy(Line, FromPos, MaxInt));
      if Li < LineCount - 1 then
        SB.Append(#10);
    end;

    if Result > 0 then
    begin
      A.Line := 0;
      A.Col := 0;
      B.Line := LineCount - 1;
      B.Col := System.Length(FLines[LineCount - 1].Text);
      ApplyReplace(A, B, SB.ToString, False);   // one undo step for the lot
    end;
  finally
    SB.Free;
  end;
end;

procedure TSkiaCodeEditor.ShowBuiltInFindBar;
begin
  if FFindBar = nil then
  begin
    FFindBar := TFindBar.Create(Self);
    FFindBar.Stored := False;   // never stream into a .fmx (see constructor)
    FFindBar.Parent := Self;
    FFindBar.Align := TAlignLayout.Top;
    FFindBar.Index := 0;   // claim the full-width top strip before the scrollbars
    // Wire the bar's buttons straight to our public search methods.
    FFindBar.OnFindNext :=
      function(const S: string; O: TFindOptions): Boolean
      begin
        Result := FindNext(S, O);
      end;
    FFindBar.OnFindPrev :=
      function(const S: string; O: TFindOptions): Boolean
      begin
        Result := FindPrevious(S, O);
      end;
    FFindBar.OnReplace :=
      function(const S, R: string; O: TFindOptions): Boolean
      begin
        Result := ReplaceCurrent(S, R, O);
      end;
    FFindBar.OnReplaceAll :=
      function(const S, R: string; O: TFindOptions): Integer
      begin
        Result := ReplaceAll(S, R, O);
      end;
    // Live highlight-all as the term / options change in the bar.
    FFindBar.OnSearchChanged :=
      procedure(const S: string; O: TFindOptions)
      begin
        if FHighlightAll then
          HighlightMatches(S, O);
      end;
    FFindBar.OnClosed :=
      procedure
      begin
        ClearHighlightMatches;   // closing the bar drops the highlights
        if CanFocus then
          SetFocus;
      end;
  end;
  FFindBar.ApplyTheme(FGutterBackColor, FTextColor);
  FFindBar.Activate(SelText);
end;

procedure TSkiaCodeEditor.SetBuiltInFindUI(const Value: Boolean);
begin
  FBuiltInFindUI := Value;
  if (not Value) and Assigned(FFindBar) then
  begin
    FFindBar.Visible := False;   // hide any open built-in bar
    ClearHighlightMatches;
  end;
end;

procedure TSkiaCodeEditor.SelectWordAt(ALine, ACol: Integer);
var
  L: string;
  N, Anchor, WS, WE: Integer;
begin
  // Select the maximal run of word chars containing the click point. Reuses the
  // find helper's notion of a word char (letters, digits, underscore).
  if (ALine < 0) or (ALine >= LineCount) then
    Exit;
  L := FLines[ALine].Text;
  N := System.Length(L);
  // A word char just right of the caret? else just left? else not on a word.
  if (ACol < N) and FindIsWordChar(L[ACol + 1]) then
    Anchor := ACol
  else if (ACol > 0) and FindIsWordChar(L[ACol]) then
    Anchor := ACol - 1
  else
    Exit;
  WS := Anchor;
  while (WS > 0) and FindIsWordChar(L[WS]) do    // char at 0-based WS-1
    Dec(WS);
  WE := Anchor + 1;
  while (WE < N) and FindIsWordChar(L[WE + 1]) do // char at 0-based WE
    Inc(WE);

  FCoalesceTyping := False;
  ResetCaretTarget;
  FSelAnchor.Line := ALine;
  FSelAnchor.Col := WS;
  FCaret.Line := ALine;
  FCaret.Col := WE;
  EnsureCaretVisible;
  ResetCaretBlink;
  RedrawContent;
end;

procedure TSkiaCodeEditor.ContentDblClick(Sender: TObject);
begin
  // The second click's MouseDown already placed the caret; select its word.
  SelectWordAt(FCaret.Line, FCaret.Col);
end;

procedure TSkiaCodeEditor.SetText(const AText: string);
var
  Arr: TArray<string>;
  S: string;
begin
  FLines.Clear;
  // Normalize CRLF/CR/LF. A real impl should preserve the original EOL for
  // round-tripping; here we split simply.
  Arr := AText.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  if System.Length(Arr) = 0 then
    FLines.Add(TEditorLine.Create(''))
  else
    for S in Arr do
      FLines.Add(TEditorLine.Create(S));
  FCaret := Default(TCaretPos);
  FSelAnchor := FCaret;
  ResetCaretTarget;
  // A fresh document discards edit history and any markers on the old text,
  // whatever MarkersClearOnEdit says -- they refer to lines that no longer exist.
  HideTooltip;
  FMarkers.Clear;
  FUndo.Clear;
  FRedo.Clear;
  FCoalesceTyping := False;
  FModified := False;   // freshly loaded text is, by definition, unmodified
  InvalidateAllTokens;
  UpdateContentSize;
  // Deliberately NOT firing OnChange here: OnChange means "the user/programmatic
  // edit changed the text", and loading a document is not that. OnCaretChange
  // below covers "content replaced, refresh the status bar".
  if Assigned(FOnCaretChange) then   // caret reset to (0,0); line count changed
    FOnCaretChange(Self);
end;

function TSkiaCodeEditor.GetText: string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  SB := TStringBuilder.Create;
  try
    for I := 0 to FLines.Count - 1 do
    begin
      SB.Append(FLines[I].Text);
      if I < FLines.Count - 1 then
        SB.Append(#10);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TSkiaCodeEditor.SetTokenizer(const AProc: TTokenizeLineProc);
begin
  FTokenizeLine := AProc;
  InvalidateAllTokens;
end;

function TSkiaCodeEditor.Highlighter: TSimpleHighlighter;
begin
  if FHighlighter = nil then
  begin
    FHighlighter := TSimpleHighlighter.Create;
    FHighlighter.OnChange := HighlighterChanged;
    SetTokenizer(FHighlighter.Tokenize);
  end;
  Result := FHighlighter;
end;

procedure TSkiaCodeEditor.HighlighterChanged(Sender: TObject);
begin
  // Keywords/rules/colours changed -> everything must be re-lexed.
  InvalidateAllTokens;
end;

procedure TSkiaCodeEditor.InvalidateAllTokens;
var
  L: TEditorLine;
begin
  for L in FLines do
    L.TokensValid := False;
  RedrawContent;
end;

function TSkiaCodeEditor.LexLine(AIndex: Integer;
  AStateIn: TLexState): TLexState;
var
  L: TEditorLine;
begin
  // Tokenize one line with a given incoming state; record its runs and states.
  L := FLines[AIndex];
  L.StateIn := AStateIn;
  if Assigned(FTokenizeLine) then
    L.StateOut := FTokenizeLine(L.Text, AStateIn, L.Tokens)
  else
  begin
    SetLength(L.Tokens, 0);           // no tokenizer => whole line default color
    L.StateOut := lsDefault;
  end;
  L.TokensValid := True;
  Result := L.StateOut;
end;

procedure TSkiaCodeEditor.EnsureTokens(AIndex: Integer);
var
  StateIn: TLexState;
begin
  // Re-tokenize this line if stale. Because lex state flows line-to-line, we
  // must walk back to the nearest valid line to establish the incoming state.
  if (AIndex < 0) or (AIndex >= FLines.Count) then
    Exit;
  if FLines[AIndex].TokensValid then
    Exit;

  if AIndex = 0 then
    StateIn := lsDefault
  else
  begin
    EnsureTokens(AIndex - 1);          // recurse to establish incoming state
    StateIn := FLines[AIndex - 1].StateOut;
  end;
  LexLine(AIndex, StateIn);
end;

procedure TSkiaCodeEditor.RetokenizeAfterEdit(AStart, AEnd: Integer);
var
  I: Integer;
  Incoming: TLexState;
begin
  // Called after an edit changed the text of lines [AStart..AEnd]. Re-lex those
  // lines, then cascade forward through following lines ONLY while the incoming
  // lex state keeps changing (e.g. a newly opened/closed block comment). Stop as
  // soon as it re-converges -- or reaches an untokenized line, which stays lazy
  // and will pick up the correct state when it is first painted. This is the
  // downstream-invalidation the tokenizer contract needs: the common edit (state
  // unchanged) touches only the edited lines.
  if FLines.Count = 0 then
    Exit;
  AStart := Max(0, AStart);
  AEnd := Min(AEnd, FLines.Count - 1);

  if AStart = 0 then
    Incoming := lsDefault
  else
  begin
    EnsureTokens(AStart - 1);
    Incoming := FLines[AStart - 1].StateOut;
  end;

  I := AStart;
  while I < FLines.Count do
  begin
    if I > AEnd then
      // Beyond the edited span: only continue while we would actually change a
      // previously-tokenized line's incoming state.
      if (not FLines[I].TokensValid) or (FLines[I].StateIn = Incoming) then
        Break;
    Incoming := LexLine(I, Incoming);
    Inc(I);
  end;
end;

procedure TSkiaCodeEditor.RedrawContent;
begin
  // TSkPaintBox caches its last frame; plain Repaint just re-blits that stale
  // buffer without re-invoking OnDraw. Redraw discards the cache and forces
  // ContentPaint to run again. This is essential -- edits that don't resize
  // the surface (e.g. typing a shorter line) would otherwise never appear.
  if Assigned(FContent) then
    TSkPaintBox(FContent).Redraw;
end;

procedure TSkiaCodeEditor.CaretTimer(Sender: TObject);
begin
  FCaretVisible := not FCaretVisible;
  RedrawContent;
end;

procedure TSkiaCodeEditor.ResetCaretBlink;
begin
  // Show the caret solid immediately after any caret-moving action, then
  // resume blinking from a full "on" phase.
  FCaretVisible := True;
  if Assigned(FCaretTimer) and IsFocused then
  begin
    FCaretTimer.Enabled := False;
    FCaretTimer.Enabled := True;
  end;
  SyncTextService;   // keep the IME's notion of line/caret current
  FSelIsMatch := False;   // any caret action ends the "find match" highlight
  if Assigned(FOnCaretChange) then
    FOnCaretChange(Self);
end;

procedure TSkiaCodeEditor.DoEnter;
begin
  inherited;
  FCaretVisible := True;
  if Assigned(FCaretTimer) then
    FCaretTimer.Enabled := True;
  if (FTextService <> nil) and (FormHandle <> nil) then
  begin
    SyncTextService;
    FTextService.EnterControl(FormHandle);
  end;
  RedrawContent;
end;

procedure TSkiaCodeEditor.DoExit;
begin
  inherited;
  if Assigned(FCaretTimer) then
    FCaretTimer.Enabled := False;
  if (FTextService <> nil) and (FormHandle <> nil) then
    FTextService.ExitControl(FormHandle);
  FIMEActive := False;
  FMarkedText := '';
  RedrawContent;
end;

procedure TSkiaCodeEditor.Resize;
begin
  inherited;
  // Viewport (FContent) changed size -> recompute scroll ranges and repaint.
  // Re-wrapping is driven from ContentResize instead: FContent has not been
  // realigned to its new size yet at this point.
  UpdateScrollBars;
  RedrawContent;
end;

procedure TSkiaCodeEditor.MouseWheel(Shift: TShiftState; WheelDelta: Integer;
  var Handled: Boolean);
begin
  inherited;
  if Handled then
    Exit;
  // One notch (120) scrolls three lines. Positive delta = wheel up = content down.
  SetScrollPos(FScrollX, FScrollY - (WheelDelta / 120) * 3 * FLineHeight);
  Handled := True;
end;

procedure TSkiaCodeEditor.EnsureCaretVisible;
var
  CaretTop, CaretBot, CaretX, ScreenX, VW, VH, NewX, NewY: Single;
begin
  if not Assigned(FContent) then
    Exit;
  VW := FContent.Width;
  VH := FContent.Height;
  NewX := FScrollX;
  NewY := FScrollY;

  CaretTop := CaretRow * FLineHeight;
  CaretBot := CaretTop + FLineHeight;
  if CaretTop < FScrollY then
    NewY := CaretTop
  else if CaretBot > FScrollY + VH then
    NewY := CaretBot - VH;

  // Keep the caret clear of the sticky gutter on the left and inside the right
  // edge. CaretContentX is content-space (includes the gutter); screen =
  // content - scroll. When wrapped nothing ever extends past the viewport.
  if FWordWrap then
    NewX := 0
  else
  begin
    CaretX := CaretContentX;
    ScreenX := CaretX - FScrollX;
    if ScreenX < FGutterWidth then
      NewX := CaretX - FGutterWidth
    else if ScreenX > VW then
      NewX := CaretX - VW + FDigitWidth;   // FCharWidth is 0 when proportional
  end;

  SetScrollPos(NewX, NewY);
end;

function TSkiaCodeEditor.LineWidth(AIndex: Integer): Single;
var
  L: string;
begin
  if (AIndex < 0) or (AIndex >= FLines.Count) then
    Exit(0);
  L := FLines[AIndex].Text;
  if FMonospace and (FCharWidth > 0) then
    Result := System.Length(L) * FCharWidth
  else
    Result := FSkFont.MeasureText(L);
end;

procedure TSkiaCodeEditor.UpdateContentSize;
var
  I, Row: Integer;
  W: Single;
begin
  // Gutter sizes to the widest line number at the current font, so it stays
  // correct across font-size changes and as the line count grows digits.
  // Width = (max digits + padding) * digit advance; the 1.2 leaves ~0.6em on
  // each side, matching PaintGutter's right margin. Hidden gutter => width 0,
  // which makes text/caret/selection start at x = 0 with no other changes.
  // Computed first: the wrap width below is measured against it.
  if FGutterVisible then
    FGutterWidth := Ceil(FDigitWidth *
      (System.Length(IntToStr(Max(1, LineCount))) + 1.2))
  else
    FGutterWidth := 0;

  // A changed text-area width (resize, gutter grew a digit) invalidates every
  // wrap decision. Unchanged => the per-line caches below all hit.
  if FWordWrap and not SameValue(TextAreaWidth, FWrapWidth) then
  begin
    FWrapWidth := TextAreaWidth;
    InvalidateWrap;
  end;

  // One pass assigns each line its absolute first row and (when not wrapping)
  // tracks the true max line width. EnsureWrap is cached, so after the first
  // pass an edit only re-wraps the lines it touched and this loop is O(lines)
  // of integer addition -- the same order as the width scan it replaces.
  Row := 0;
  FMaxLineWidth := 0;
  for I := 0 to FLines.Count - 1 do
  begin
    EnsureWrap(I);
    FLines[I].FirstRow := Row;
    Inc(Row, System.Length(FLines[I].WrapStarts));
    if not FWordWrap then
    begin
      W := LineWidth(I);
      if W > FMaxLineWidth then
        FMaxLineWidth := W;
    end;
  end;
  FTotalRows := Max(1, Row);

  if FWordWrap then
  begin
    FScrollX := 0;      // nothing extends past the viewport when wrapped
    FContentW := 0;
  end
  else
    // FDigitWidth, not FCharWidth: the latter is 0 on a proportional face.
    FContentW := FGutterWidth + FMaxLineWidth + FDigitWidth * 2;  // caret margin
  FContentH := FTotalRows * FLineHeight;
  UpdateScrollBars;
end;

procedure TSkiaCodeEditor.UpdateScrollBars;
var
  VW, VH, MaxX, MaxY: Single;
begin
  if not (Assigned(FContent) and Assigned(FVScroll) and Assigned(FHScroll)) then
    Exit;
  VW := FContent.Width;
  VH := FContent.Height;
  MaxX := Max(0, FContentW - VW);
  MaxY := Max(0, FContentH - VH);

  // FMX TScrollBar: Value ranges [Min, Max - ViewportSize], thumb size is
  // ViewportSize/(Max-Min). Max >= ViewportSize keeps it well-formed.
  FScrollY := Min(FScrollY, MaxY);
  FVScroll.Enabled := MaxY > 0;
  FVScroll.Min := 0;
  FVScroll.Max := Max(FContentH, VH);
  FVScroll.ViewportSize := VH;
  FVScroll.SmallChange := FLineHeight;
  FVScroll.Value := FScrollY;

  FScrollX := Min(FScrollX, MaxX);
  FHScroll.Enabled := MaxX > 0;
  FHScroll.Min := 0;
  FHScroll.Max := Max(FContentW, VW);
  FHScroll.ViewportSize := VW;
  FHScroll.SmallChange := FDigitWidth * 4;   // FCharWidth is 0 when proportional
  FHScroll.Value := FScrollX;
end;

procedure TSkiaCodeEditor.SetScrollPos(AX, AY: Single);
begin
  if not Assigned(FContent) then
    Exit;
  AX := Max(0, Min(AX, Max(0, FContentW - FContent.Width)));
  AY := Max(0, Min(AY, Max(0, FContentH - FContent.Height)));
  if (SameValue(AX, FScrollX) and SameValue(AY, FScrollY)) then
    Exit;
  HideTooltip;   // the tip is anchored to a screen position that just moved
  FScrollX := AX;
  FScrollY := AY;
  // Reflect into the bars (their OnChange re-reads FScrollX/Y and redraws).
  FVScroll.Value := FScrollY;
  FHScroll.Value := FScrollX;
  RedrawContent;
end;

procedure TSkiaCodeEditor.ScrollBarChange(Sender: TObject);
begin
  HideTooltip;
  FScrollX := FHScroll.Value;
  FScrollY := FVScroll.Value;
  RedrawContent;
end;

function TSkiaCodeEditor.VisibleRowRange(out AFirst, ALast: Integer): Boolean;
var
  TopY, BotY: Single;
begin
  // Map the scroll viewport to an absolute visual-row range. Only these rows
  // get laid out. Rows are uniform height, so this stays a division.
  TopY := FScrollY;
  BotY := FScrollY + FContent.Height;
  AFirst := Max(0, Trunc(TopY / FLineHeight));
  ALast := Min(FTotalRows - 1, Ceil(BotY / FLineHeight));
  Result := (LineCount > 0) and (AFirst <= ALast);
end;

{ ---- painting (all Skia => identical Win/mac) ---- }

procedure TSkiaCodeEditor.ContentPaint(ASender: TObject;
  const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
begin
  PaintContent(ACanvas, ADest);
end;

procedure TSkiaCodeEditor.ContentMouseDown(Sender: TObject;
  Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  // Mouse lands on FContent (the paint surface); X,Y are viewport/screen coords.
  // PointToCaret adds the scroll offset. Take focus, then place the caret.
  if CanFocus then
    SetFocus;
  DoMouseDown(Button, Shift, X, Y);
end;

procedure TSkiaCodeEditor.ContentResize(Sender: TObject);
begin
  // The viewport just took its final size. Only wrapping cares about width;
  // UpdateContentSize no-ops the re-flow when TextAreaWidth is unchanged.
  if FWordWrap then
  begin
    UpdateContentSize;
    RedrawContent;
  end;
end;

procedure TSkiaCodeEditor.PaintContent(const ACanvas: ISkCanvas;
  const ADest: TRectF);
var
  FirstRow, LastRow, FirstLine, LastLine, I, Row, Li: Integer;
  Paint: ISkPaint;
begin
  Paint := TSkPaint.Create;
  Paint.Color := FBackColor;
  ACanvas.DrawRect(ADest, Paint);

  if not VisibleRowRange(FirstRow, LastRow) then
    Exit;
  FirstLine := RowToLine(FirstRow);
  LastLine := RowToLine(LastRow);

  // Tokenize only what we're about to draw.
  for I := FirstLine to LastLine do
    EnsureTokens(I);

  // Marker tints sit at the bottom of the stack (under find hits + selection),
  // so a selected error still reads as selected.
  PaintMarkers(ACanvas, FirstRow, LastRow, mkTint);
  // Other matches next, so the current match's selection paints over them.
  PaintFindMatches(ACanvas, FirstRow, LastRow);
  PaintSelection(ACanvas, FirstRow, LastRow);

  // Screen Y = content Y - vertical scroll. Text scrolls; the gutter (painted
  // after, on top) is only vertically scrolled, never horizontally. Walk the
  // rows, advancing the line cursor as we cross each line's row span, rather
  // than binary-searching RowToLine per row.
  Li := FirstLine;
  for Row := FirstRow to LastRow do
  begin
    while (Li < FLines.Count - 1) and (FLines[Li + 1].FirstRow <= Row) do
      Inc(Li);
    PaintRow(ACanvas, Li, Row - FLines[Li].FirstRow, Row * FLineHeight - FScrollY);
  end;

  // Squiggles go OVER the glyphs -- they sit below the baseline, and drawing
  // them under the text would let descenders hide them.
  PaintMarkers(ACanvas, FirstRow, LastRow, mkSquiggle);

  if FGutterVisible then
    PaintGutter(ACanvas, FirstRow, LastRow);
  PaintMarkedText(ACanvas);
  PaintCaret(ACanvas);
  PaintTooltip(ACanvas);   // last: the tooltip floats over everything
end;

procedure TSkiaCodeEditor.PaintSquiggle(const ACanvas: ISkCanvas;
  const APaint: ISkPaint; AX1, AX2, ABaseY: Single);
const
  Step = 3;       // half-period, px
  Amp  = 2;       // peak height, px
var
  X, NextX, Y, NextY: Single;
  Up: Boolean;
begin
  // A zig-zag between (X, ABaseY) and (X, ABaseY - Amp), drawn as short line
  // segments. Cheap, and identical on both platforms because it is pure Skia.
  X := AX1;
  Up := True;
  Y := ABaseY;
  while X < AX2 do
  begin
    NextX := Min(X + Step, AX2);
    if Up then NextY := ABaseY - Amp else NextY := ABaseY;
    ACanvas.DrawLine(TPointF.Create(X, Y), TPointF.Create(NextX, NextY), APaint);
    X := NextX;
    Y := NextY;
    Up := not Up;
  end;
end;

function TSkiaCodeEditor.MarkerRowRect(const AMarker: TEditorMarker;
  ARowInLine: Integer; out ARect: TRectF): Boolean;
var
  RS, RE, MS, ME, S, E: Integer;
  X1, X2, Y: Single;
begin
  // Screen rect of the part of AMarker that falls on one of its line's rows.
  // Shared by painting and hit-testing so the tooltip triggers exactly where
  // the marker is drawn.
  Result := False;
  if (AMarker.Line < 0) or (AMarker.Line >= FLines.Count) then
    Exit;
  MarkerSpan(AMarker, MS, ME);
  RowColBounds(AMarker.Line, ARowInLine, RS, RE);
  S := Max(MS, RS);
  E := Min(ME, RE);
  if E < S then
    Exit;

  X1 := FGutterWidth + MeasureRange(FLines[AMarker.Line].Text, RS, S) - FScrollX;
  X2 := FGutterWidth + MeasureRange(FLines[AMarker.Line].Text, RS, E) - FScrollX;
  if E = S then
    X2 := X1 + FDigitWidth;     // empty line / empty span: still show something
  X1 := Max(X1, FGutterWidth);  // never under the sticky gutter
  X2 := Max(X2, FGutterWidth);
  if X2 <= X1 then
    Exit;

  Y := (FLines[AMarker.Line].FirstRow + ARowInLine) * FLineHeight - FScrollY;
  ARect := TRectF.Create(X1, Y, X2, Y + FLineHeight);
  Result := True;
end;

procedure TSkiaCodeEditor.PaintMarkers(const ACanvas: ISkCanvas;
  AFirstRow, ALastRow: Integer; AKind: TMarkerKind);
var
  Paint: ISkPaint;
  M: TEditorMarker;
  I, R, R0, R1, Row, MS, ME: Integer;
  Rect: TRectF;
begin
  // Markers are few (parser errors), so loop them outer and touch only the rows
  // each one covers -- the inverse of the find-match loop, which is many hits
  // over few rows. Each marker is clipped to a row's column span, so one that
  // spans a wrap break draws on each row it crosses.
  if FMarkers.Count = 0 then
    Exit;
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  if AKind = mkSquiggle then
  begin
    Paint.Style := TSkPaintStyle.Stroke;
    Paint.StrokeWidth := 1.2;
  end;

  for I := 0 to FMarkers.Count - 1 do
  begin
    M := FMarkers[I];
    if (M.Kind <> AKind) or (M.Line < 0) or (M.Line >= FLines.Count) then
      Continue;
    MarkerSpan(M, MS, ME);
    R0 := RowOfCol(M.Line, MS);
    R1 := RowOfCol(M.Line, Max(MS, ME - 1));   // row holding the last marked col
    Paint.Color := M.Color;

    for R := R0 to R1 do
    begin
      Row := FLines[M.Line].FirstRow + R;
      if (Row < AFirstRow) or (Row > ALastRow) then
        Continue;                              // off-screen row
      if not MarkerRowRect(M, R, Rect) then
        Continue;
      if AKind = mkTint then
        ACanvas.DrawRect(Rect, Paint)
      else
        PaintSquiggle(ACanvas, Paint, Rect.Left, Rect.Right, Rect.Bottom - 2);
    end;
  end;
end;

function TSkiaCodeEditor.MarkerAtPoint(const APt: TPointF): Integer;
var
  I, R, R0, R1, MS, ME: Integer;
  M: TEditorMarker;
  Rect: TRectF;
begin
  // Which marker (if any) is under this viewport point? Tests the same rects
  // that PaintMarkers fills, so hover matches what the user sees.
  Result := -1;
  if APt.X < FGutterWidth then
    Exit;                       // pointer is over the sticky gutter
  for I := 0 to FMarkers.Count - 1 do
  begin
    M := FMarkers[I];
    if (M.Line < 0) or (M.Line >= FLines.Count) then
      Continue;
    MarkerSpan(M, MS, ME);
    R0 := RowOfCol(M.Line, MS);
    R1 := RowOfCol(M.Line, Max(MS, ME - 1));
    for R := R0 to R1 do
      if MarkerRowRect(M, R, Rect) and Rect.Contains(APt) then
        Exit(I);
  end;
end;

procedure TSkiaCodeEditor.PaintFindMatches(const ACanvas: ISkCanvas;
  AFirstRow, ALastRow: Integer);
var
  Paint: ISkPaint;
  Matches: TArray<Integer>;
  Row, Li, CurLi, RS, RE, I, MS, ME, S, E, Len: Integer;
  X1, X2, Y: Single;
begin
  // Tint every visible occurrence of the search term. Matches are single-line
  // but a wrapped line can split one across rows, so each match is clipped to
  // the row's column span exactly as a selection is.
  if (not FHighlightAll) or (FHighlightTerm = '') then
    Exit;
  Len := System.Length(FHighlightTerm);
  Paint := TSkPaint.Create;
  Paint.Color := FFindHighlightColor;

  Li := RowToLine(AFirstRow);
  CurLi := -1;
  for Row := AFirstRow to ALastRow do
  begin
    while (Li < FLines.Count - 1) and (FLines[Li + 1].FirstRow <= Row) do
      Inc(Li);
    if Li <> CurLi then      // rows of a line are contiguous: scan it once
    begin
      Matches := LineMatches(Li);
      CurLi := Li;
    end;
    if System.Length(Matches) = 0 then
      Continue;

    RowColBounds(Li, Row - FLines[Li].FirstRow, RS, RE);
    Y := Row * FLineHeight - FScrollY;
    for I := 0 to High(Matches) do
    begin
      MS := Matches[I];
      ME := MS + Len;
      if (ME <= RS) or (MS >= RE) then
        Continue;            // this match lies entirely on another row
      S := Max(MS, RS);
      E := Min(ME, RE);
      X1 := FGutterWidth + MeasureRange(FLines[Li].Text, RS, S) - FScrollX;
      X2 := FGutterWidth + MeasureRange(FLines[Li].Text, RS, E) - FScrollX;
      X1 := Max(X1, FGutterWidth);   // never paint under the sticky gutter
      X2 := Max(X2, FGutterWidth);
      if X2 <= X1 then
        Continue;
      ACanvas.DrawRect(TRectF.Create(X1, Y, X2, Y + FLineHeight), Paint);
    end;
  end;
end;

procedure TSkiaCodeEditor.PaintGutter(const ACanvas: ISkCanvas;
  AFirstRow, ALastRow: Integer);
var
  Paint: ISkPaint;
  Row, Li: Integer;
  Y, Baseline: Single;
  NumStr: string;
  Metrics: TSkFontMetrics;
  TextW: Single;
begin
  // Gutter is sticky to the left viewport edge (screen x 0..FGutterWidth); it
  // scrolls only vertically. Painted after the text so it masks any glyphs that
  // scrolled left underneath it.
  Paint := TSkPaint.Create;
  Paint.Color := FGutterBackColor;
  ACanvas.DrawRect(
    TRectF.Create(0, AFirstRow * FLineHeight - FScrollY,
      FGutterWidth, (ALastRow + 1) * FLineHeight - FScrollY),
    Paint);

  Paint.Color := FGutterTextColor;
  FSkFont.GetMetrics(Metrics);
  Li := RowToLine(AFirstRow);
  for Row := AFirstRow to ALastRow do
  begin
    while (Li < FLines.Count - 1) and (FLines[Li + 1].FirstRow <= Row) do
      Inc(Li);
    // A wrapped line numbers only its first row; continuation rows stay blank.
    if FLines[Li].FirstRow <> Row then
      Continue;
    Y := Row * FLineHeight - FScrollY;
    Baseline := Y + (-Metrics.Ascent);     // baseline aligned to text baseline
    NumStr := IntToStr(Li + 1);
    TextW := FSkFont.MeasureText(NumStr);
    // right-align within gutter with a ~0.6em right margin (font-proportional)
    ACanvas.DrawSimpleText(NumStr,
      FGutterWidth - TextW - FDigitWidth * 0.6, Baseline, FSkFont, Paint);
  end;
end;

procedure TSkiaCodeEditor.PaintRow(const ACanvas: ISkCanvas;
  ALineIdx, ARowInLine: Integer; AY: Single);
var
  L: TEditorLine;
  Paint: ISkPaint;
  Metrics: TSkFontMetrics;
  Baseline, X: Single;
  Sub: string;
  I, RS, RE, Cursor, S, E: Integer;
begin
  // Draws the columns [RS, RE) of one logical line on one visual row. With wrap
  // off that is the whole line, so this is the old PaintLine; with wrap on the
  // token runs get clipped to the row's column span.
  L := FLines[ALineIdx];
  RowColBounds(ALineIdx, ARowInLine, RS, RE);
  if RE <= RS then
    Exit;                          // empty line / empty row: nothing to draw

  FSkFont.GetMetrics(Metrics);
  Baseline := AY + (-Metrics.Ascent);
  X := FGutterWidth - FScrollX;   // text origin, shifted by horizontal scroll
  Paint := TSkPaint.Create;

  if System.Length(L.Tokens) = 0 then
  begin
    Paint.Color := FTextColor;
    ACanvas.DrawSimpleText(Copy(L.Text, RS + 1, RE - RS), X, Baseline,
      FSkFont, Paint);
    Exit;
  end;

  // Draw run by run, clipped to [RS, RE). Runs are ascending and disjoint, so a
  // single cursor walks the row. Gaps between runs use the default text color.
  Cursor := RS;
  for I := 0 to High(L.Tokens) do
  begin
    S := L.Tokens[I].StartCol;
    E := S + L.Tokens[I].Length;
    if E <= Cursor then
      Continue;                    // run ends before this row starts
    if S >= RE then
      Break;                       // runs from here on start past the row
    S := Max(S, Cursor);
    E := Min(E, RE);

    if S > Cursor then             // default-colored gap before this run
    begin
      Sub := Copy(L.Text, Cursor + 1, S - Cursor);
      Paint.Color := FTextColor;
      ACanvas.DrawSimpleText(Sub, X, Baseline, FSkFont, Paint);
      X := X + FSkFont.MeasureText(Sub);
      Cursor := S;
    end;
    if E > S then
    begin
      Sub := Copy(L.Text, S + 1, E - S);
      Paint.Color := L.Tokens[I].Color;
      // TODO: bold/italic => swap FSkFont for a styled variant
      ACanvas.DrawSimpleText(Sub, X, Baseline, FSkFont, Paint);
      X := X + FSkFont.MeasureText(Sub);
      Cursor := E;
    end;
  end;
  // trailing default-colored remainder
  if Cursor < RE then
  begin
    Sub := Copy(L.Text, Cursor + 1, RE - Cursor);
    Paint.Color := FTextColor;
    ACanvas.DrawSimpleText(Sub, X, Baseline, FSkFont, Paint);
  end;
end;

procedure TSkiaCodeEditor.PaintSelection(const ACanvas: ISkCanvas;
  AFirstRow, ALastRow: Integer);
var
  A, B: TCaretPos;
  Paint: ISkPaint;
  Row, Li, RS, RE, StartCol, EndCol: Integer;
  X1, X2, Y: Single;
  LastRowOfLine, WantNewlineMark: Boolean;
begin
  if not SelActive then
    Exit;
  SelBounds(A, B);

  Paint := TSkPaint.Create;
  if FSelIsMatch then
    Paint.Color := FFindMatchColor   // find match stands out from a normal selection
  else
    Paint.Color := FSelectionColor;

  // Fill per visible row: intersect the row's column span with the selection's
  // span on that row's line. Rows of unselected lines drop out immediately.
  Li := RowToLine(AFirstRow);
  for Row := AFirstRow to ALastRow do
  begin
    while (Li < FLines.Count - 1) and (FLines[Li + 1].FirstRow <= Row) do
      Inc(Li);
    if (Li < A.Line) or (Li > B.Line) then
      Continue;

    RowColBounds(Li, Row - FLines[Li].FirstRow, RS, RE);
    StartCol := RS;
    EndCol := RE;
    if Li = A.Line then StartCol := Max(RS, A.Col);
    if Li = B.Line then EndCol := Min(RE, B.Col);
    if EndCol < StartCol then
      Continue;                    // selection doesn't reach this row

    // A line whose trailing newline is selected shows that on its LAST row, by
    // extending a little past the text.
    LastRowOfLine := (Row - FLines[Li].FirstRow) = RowsInLine(Li) - 1;
    WantNewlineMark := LastRowOfLine and (Li < B.Line);

    X1 := FGutterWidth + MeasureRange(FLines[Li].Text, RS, StartCol) - FScrollX;
    X2 := FGutterWidth + MeasureRange(FLines[Li].Text, RS, EndCol) - FScrollX;
    if WantNewlineMark then
      X2 := X2 + FDigitWidth;
    // Never paint under the sticky gutter.
    X1 := Max(X1, FGutterWidth);
    X2 := Max(X2, FGutterWidth);
    if X2 <= X1 then
      Continue;

    Y := Row * FLineHeight - FScrollY;
    ACanvas.DrawRect(TRectF.Create(X1, Y, X2, Y + FLineHeight), Paint);
  end;
end;

procedure TSkiaCodeEditor.PaintCaret(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  X, Y: Single;
begin
  if FIMEActive then
    Exit;                        // composition draws its own caret
  if not (IsFocused and FCaretVisible) then
    Exit;
  X := CaretContentX - FScrollX;              // content -> screen
  Y := CaretRow * FLineHeight - FScrollY;
  // Don't draw the caret where it would sit under the sticky gutter.
  if X < FGutterWidth then
    Exit;
  Paint := TSkPaint.Create;
  Paint.Color := FCaretColor;
  Paint.StrokeWidth := 1;
  ACanvas.DrawLine(TPointF.Create(X, Y),
    TPointF.Create(X, Y + FLineHeight), Paint);
end;

procedure TSkiaCodeEditor.PaintMarkedText(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  Metrics: TSkFontMetrics;
  X, Y, Baseline, W: Single;
begin
  // The uncommitted composition string is drawn as an overlay at the caret (we
  // never touch FLines during composition). It masks any text it covers, is
  // underlined to read as "in progress", and carries its own caret at its end.
  if not FIMEActive then
    Exit;
  X := CaretContentX - FScrollX;
  Y := CaretRow * FLineHeight - FScrollY;
  if X < FGutterWidth then
    Exit;
  FSkFont.GetMetrics(Metrics);
  Baseline := Y + (-Metrics.Ascent);
  Paint := TSkPaint.Create;

  if FMarkedText <> '' then
  begin
    W := FSkFont.MeasureText(FMarkedText);
    Paint.Color := FBackColor;                 // mask text underneath
    ACanvas.DrawRect(TRectF.Create(X, Y, X + W, Y + FLineHeight), Paint);
    Paint.Color := FTextColor;
    ACanvas.DrawSimpleText(FMarkedText, X, Baseline, FSkFont, Paint);
    Paint.StrokeWidth := 1;
    ACanvas.DrawLine(TPointF.Create(X, Y + FLineHeight - 1),
      TPointF.Create(X + W, Y + FLineHeight - 1), Paint);
  end
  else
    W := 0;

  Paint.Color := FCaretColor;                  // composition caret at the end
  Paint.StrokeWidth := 1;
  ACanvas.DrawLine(TPointF.Create(X + W, Y),
    TPointF.Create(X + W, Y + FLineHeight), Paint);
end;

{ ---- marker tooltip (own-drawn: multi-line, per-run colour, one paint path) -- }

function TSkiaCodeEditor.TipFontFor(ABold: Boolean): ISkFont;
begin
  if ABold then
    Result := FSkFontBold
  else
    Result := FSkFont;
end;

function TSkiaCodeEditor.MarkerTip(const AMarker: TEditorMarker): TTipText;
begin
  // A rich tip if the host supplied one, else the plain Message split on #10.
  if System.Length(AMarker.Tip) > 0 then
    Result := AMarker.Tip
  else
    Result := TipFromText(AMarker.Message);
end;

procedure TSkiaCodeEditor.PaintTooltip(const ACanvas: ISkCanvas);
const
  PadX = 8;
  PadY = 5;
  Gap  = 14;   // offset from the pointer
var
  Tips: TTipText;
  Paint: ISkPaint;
  Metrics: TSkFontMetrics;
  I, J: Integer;
  W, H, LineW, X, Y, TX, Baseline: Single;
  R: TTipRun;
  Rect: TRectF;
begin
  if (not FTipVisible) or (FHoverMarker < 0) or
     (FHoverMarker >= FMarkers.Count) then
    Exit;
  Tips := MarkerTip(FMarkers[FHoverMarker]);
  if System.Length(Tips) = 0 then
    Exit;

  // Measure: width = widest line, height = line count. Runs may mix fonts.
  W := 0;
  for I := 0 to High(Tips) do
  begin
    LineW := 0;
    for J := 0 to High(Tips[I]) do
      LineW := LineW + TipFontFor(Tips[I][J].Bold).MeasureText(Tips[I][J].Text);
    W := Max(W, LineW);
  end;
  W := W + PadX * 2;
  H := System.Length(Tips) * FLineHeight + PadY * 2;

  // Place below-right of the pointer, flipping/clamping to stay in the viewport.
  // An own-drawn tip lives inside the paint surface, so it cannot spill outside
  // the control the way a native popup would.
  X := FHoverPt.X + Gap;
  Y := FHoverPt.Y + Gap + 4;
  if X + W > FContent.Width then
    X := FContent.Width - W - 2;
  if X < 0 then
    X := 0;
  if Y + H > FContent.Height then
    Y := FHoverPt.Y - H - 6;      // flip above the pointer
  if Y < 0 then
    Y := 0;

  Rect := TRectF.Create(X, Y, X + W, Y + H);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Color := FTooltipColor;
  ACanvas.DrawRoundRect(Rect, 3, 3, Paint);
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 1;
  Paint.Color := FTooltipBorderColor;
  ACanvas.DrawRoundRect(Rect, 3, 3, Paint);

  Paint.Style := TSkPaintStyle.Fill;
  FSkFont.GetMetrics(Metrics);
  for I := 0 to High(Tips) do
  begin
    Baseline := Y + PadY + I * FLineHeight + (-Metrics.Ascent);
    TX := X + PadX;
    for J := 0 to High(Tips[I]) do
    begin
      R := Tips[I][J];
      if R.Color = TAlphaColors.Null then   // sentinel: "use the default"
        Paint.Color := FTooltipTextColor
      else
        Paint.Color := R.Color;
      ACanvas.DrawSimpleText(R.Text, TX, Baseline, TipFontFor(R.Bold), Paint);
      TX := TX + TipFontFor(R.Bold).MeasureText(R.Text);
    end;
  end;
end;

procedure TSkiaCodeEditor.HoverTimer(Sender: TObject);
begin
  FHoverTimer.Enabled := False;   // one shot: fire, then wait for the next hover
  if (FHoverMarker >= 0) and (FHoverMarker < FMarkers.Count) then
  begin
    FTipVisible := True;
    RedrawContent;
  end;
end;

procedure TSkiaCodeEditor.HideTooltip;
begin
  if Assigned(FHoverTimer) then
    FHoverTimer.Enabled := False;
  FHoverMarker := -1;
  if FTipVisible then
  begin
    FTipVisible := False;
    RedrawContent;
  end;
end;

procedure TSkiaCodeEditor.ContentMouseLeave(Sender: TObject);
begin
  HideTooltip;
end;

{ ---- IME / composition ---- }

function TSkiaCodeEditor.FormHandle: TWindowHandle;
var
  R: IRoot;
begin
  Result := nil;
  R := Root;
  if (R <> nil) and (R.GetObject is TCommonCustomForm) then
    Result := TCommonCustomForm(R.GetObject).Handle;
end;

procedure TSkiaCodeEditor.SyncTextService;
begin
  // Give the IME the current line and caret column as context. Skipped during
  // composition (the service owns the marked text then) and when unfocused.
  if (FTextService = nil) or FIMEActive or (not IsFocused) then
    Exit;
  FTextService.Text := FLines[FCaret.Line].Text;
  FTextService.CaretPosition := TPoint.Create(FCaret.Col, FCaret.Line);
end;

function TSkiaCodeEditor.GetTextService: TTextService;
begin
  Result := FTextService;
end;

function TSkiaCodeEditor.GetTargetClausePointF: TPointF;
var
  LocalPt: TPointF;
begin
  // Absolute screen point just below the composition, where the OS should place
  // the candidate window.
  if FContent = nil then
    Exit(TPointF.Zero);
  LocalPt := TPointF.Create(
    CaretContentX - FScrollX + FSkFont.MeasureText(FMarkedText),
    (CaretRow + 1) * FLineHeight - FScrollY);
  Result := FContent.LocalToAbsolute(LocalPt);
end;

procedure TSkiaCodeEditor.StartIMEInput;
begin
  if FTextService = nil then
    Exit;
  FTextService.Text := FLines[FCaret.Line].Text;
  FTextService.CaretPosition := TPoint.Create(FCaret.Col, FCaret.Line);
  FIMEActive := True;
  FMarkedText := '';
  RedrawContent;
end;

procedure TSkiaCodeEditor.IMEStateUpdated;
begin
  if FTextService = nil then
    Exit;
  FMarkedText := FTextService.MarkedText;   // in-progress composition string
  RedrawContent;
end;

procedure TSkiaCodeEditor.EndIMEInput;
begin
  // Composition finished. Any committed text arrives right after, as KeyDown
  // KeyChar events (see the class comment), and inserts at the caret normally.
  FIMEActive := False;
  FMarkedText := '';
  RedrawContent;
end;

function TSkiaCodeEditor.GetSelection: string;
begin
  Result := SelectedText;
end;

function TSkiaCodeEditor.GetSelectionRect: TRectF;
var
  X, Y: Single;
begin
  X := CaretContentX - FScrollX;
  Y := CaretRow * FLineHeight - FScrollY;
  Result := TRectF.Create(X, Y, X + 1, Y + FLineHeight);
end;

function TSkiaCodeEditor.GetSelectionBounds: TRect;
var
  A, B: TCaretPos;
begin
  if SelActive then
    SelBounds(A, B)
  else
  begin
    A := FCaret;
    B := FCaret;
  end;
  Result := TRect.Create(A.Col, A.Line, B.Col, B.Line);
end;

function TSkiaCodeEditor.GetSelectionPointSize: TSizeF;
begin
  Result := TSizeF.Create(1, FLineHeight);
end;

function TSkiaCodeEditor.HasText: Boolean;
begin
  Result := (LineCount > 1) or ((LineCount = 1) and (FLines[0].Text <> ''));
end;

{ ---- geometry / hit-testing ---- }

function TSkiaCodeEditor.MeasureRange(const AText: string; A, B: Integer): Single;
begin
  // Advance of the 0-based half-open column span [A, B) of AText.
  A := Max(0, Min(A, System.Length(AText)));
  B := Max(A, Min(B, System.Length(AText)));
  if FMonospace and (FCharWidth > 0) then
    Result := (B - A) * FCharWidth
  else
    Result := FSkFont.MeasureText(Copy(AText, A + 1, B - A));
end;

function TSkiaCodeEditor.ColToX(ALineIdx, ACol, ARowInLine: Integer): Single;
var
  RS, RE: Integer;
begin
  // Content x of a column. A wrapped row restarts at the left margin, so the
  // measurement runs from the row's first column, not the line's. ARowInLine
  // < 0 means "work it out" (no caret affinity).
  if (ALineIdx < 0) or (ALineIdx >= FLines.Count) then
    Exit(FGutterWidth);
  if ARowInLine < 0 then
    ARowInLine := RowOfCol(ALineIdx, ACol);
  RowColBounds(ALineIdx, ARowInLine, RS, RE);
  Result := FGutterWidth + MeasureRange(FLines[ALineIdx].Text, RS, ACol);
end;

function TSkiaCodeEditor.XToColInRow(ALineIdx, ARowStart, ARowEnd: Integer;
  AX: Single): Integer;
var
  L: string;
  Target, Acc, W: Single;
  I: Integer;
begin
  // Nearest column boundary to content x AX, constrained to this row's span.
  if (ALineIdx < 0) or (ALineIdx >= FLines.Count) then
    Exit(0);
  L := FLines[ALineIdx].Text;
  Target := AX - FGutterWidth;
  if Target <= 0 then
    Exit(ARowStart);
  if FMonospace and (FCharWidth > 0) then
    Exit(Max(ARowStart, Min(ARowEnd, ARowStart + Round(Target / FCharWidth))));
  // proportional: walk chars accumulating advance, pick nearest boundary
  Acc := 0;
  for I := ARowStart + 1 to ARowEnd do
  begin
    W := FSkFont.MeasureText(L[I]);
    if Acc + W / 2 >= Target then
      Exit(I - 1);
    Acc := Acc + W;
  end;
  Result := ARowEnd;
end;

function TSkiaCodeEditor.PointToCaret(const APt: TPointF;
  out AAtRowEnd: Boolean): TCaretPos;
var
  Row, RowInLine, RS, RE: Integer;
begin
  // APt is in viewport/screen coords (paint surface local); convert to content
  // by adding the scroll offset before mapping to row, then row to line/column.
  Row := Max(0, Min(FTotalRows - 1, Trunc((APt.Y + FScrollY) / FLineHeight)));
  Result.Line := RowToLine(Row);
  RowInLine := Row - FLines[Result.Line].FirstRow;
  RowColBounds(Result.Line, RowInLine, RS, RE);
  Result.Col := XToColInRow(Result.Line, RS, RE, APt.X + FScrollX);
  // Clicking at/past the end of a wrapped row must keep the caret on THAT row
  // rather than jumping to the identical column at the next row's start.
  AAtRowEnd := (Result.Col = RE) and (RowInLine < RowsInLine(Result.Line) - 1);
end;

{ ---- editing ---- }

procedure TSkiaCodeEditor.AfterEdit(AInvalidateFrom: Integer);
var
  I: Integer;
begin
  // Common tail for every mutation. The text of lines [AInvalidateFrom..caret]
  // changed; re-lex them and cascade downstream only as far as the lex state
  // actually propagates. Then recompute extent, keep caret on screen, reblink.
  //
  // Those same lines' wraps are stale. UpdateContentSize below re-wraps exactly
  // these (the rest hit their cache) and rebuilds the FirstRow running sum.
  ResetCaretTarget;
  // Markers describe the text as it was parsed; the edit just invalidated them.
  if FMarkersClearOnEdit and (FMarkers.Count > 0) then
  begin
    HideTooltip;
    FMarkers.Clear;
  end;
  for I := Max(0, AInvalidateFrom) to Min(FCaret.Line, FLines.Count - 1) do
    FLines[I].WrapValid := False;
  RetokenizeAfterEdit(AInvalidateFrom, FCaret.Line);
  FSelAnchor := FCaret;   // any edit collapses the selection
  UpdateContentSize;
  EnsureCaretVisible;
  ResetCaretBlink;
  RedrawContent;
  // Every text mutation (incl. undo/redo) passes through here -- the single
  // place to raise the dirty flag and notify. Simple policy: undo does NOT
  // clear Modified (matches TMemo). Load resets it in SetText.
  FModified := True;
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TSkiaCodeEditor.ComparePos(const A, B: TCaretPos): Integer;
begin
  if A.Line <> B.Line then
    Result := CompareValue(A.Line, B.Line)
  else
    Result := CompareValue(A.Col, B.Col);
end;

function TSkiaCodeEditor.SelActive: Boolean;
begin
  Result := ComparePos(FSelAnchor, FCaret) <> 0;
end;

procedure TSkiaCodeEditor.SelBounds(out AStart, AEnd: TCaretPos);
begin
  if ComparePos(FSelAnchor, FCaret) <= 0 then
  begin
    AStart := FSelAnchor;
    AEnd := FCaret;
  end
  else
  begin
    AStart := FCaret;
    AEnd := FSelAnchor;
  end;
end;

function TSkiaCodeEditor.TextInRange(const A, B: TCaretPos): string;
var
  SB: TStringBuilder;
  I: Integer;
begin
  // A <= B assumed. Lines are joined with #10 (line texts never contain EOLs).
  if A.Line = B.Line then
    Exit(Copy(FLines[A.Line].Text, A.Col + 1, B.Col - A.Col));
  SB := TStringBuilder.Create;
  try
    SB.Append(Copy(FLines[A.Line].Text, A.Col + 1, MaxInt));
    for I := A.Line + 1 to B.Line - 1 do
    begin
      SB.Append(#10);
      SB.Append(FLines[I].Text);
    end;
    SB.Append(#10);
    SB.Append(Copy(FLines[B.Line].Text, 1, B.Col));
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TSkiaCodeEditor.SelectedText: string;
var
  A, B: TCaretPos;
begin
  if not SelActive then
    Exit('');
  SelBounds(A, B);
  Result := TextInRange(A, B);
end;

procedure TSkiaCodeEditor.SelectAll;
begin
  FCoalesceTyping := False;
  ResetCaretTarget;
  FSelAnchor.Line := 0;
  FSelAnchor.Col := 0;
  FCaret.Line := LineCount - 1;
  FCaret.Col := System.Length(FLines[FCaret.Line].Text);
  EnsureCaretVisible;
  ResetCaretBlink;
  RedrawContent;
end;

procedure TSkiaCodeEditor.DeleteRangeRaw(const A, B: TCaretPos);
var
  Head, Tail: string;
  I: Integer;
begin
  // A <= B assumed. Removes the [A, B) span; leaves FCaret at A. No AfterEdit.
  if A.Line = B.Line then
    System.Delete(FLines[A.Line].Text, A.Col + 1, B.Col - A.Col)
  else
  begin
    Head := Copy(FLines[A.Line].Text, 1, A.Col);
    Tail := Copy(FLines[B.Line].Text, B.Col + 1, MaxInt);
    for I := B.Line downto A.Line + 1 do
      FLines.Delete(I);
    FLines[A.Line].Text := Head + Tail;
  end;
  FCaret := A;
end;

procedure TSkiaCodeEditor.InsertRaw(const S: string);
var
  Parts: TArray<string>;
  L: TEditorLine;
  Tail: string;
  K, LastIdx: Integer;
begin
  // Insert S at the caret, splitting on newlines into new lines. No AfterEdit.
  Parts := S.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  if System.Length(Parts) <= 1 then
  begin
    System.Insert(S, FLines[FCaret.Line].Text, FCaret.Col + 1);
    Inc(FCaret.Col, System.Length(S));
    Exit;
  end;
  L := FLines[FCaret.Line];
  Tail := Copy(L.Text, FCaret.Col + 1, MaxInt);   // text right of caret
  L.Text := Copy(L.Text, 1, FCaret.Col) + Parts[0];
  for K := 1 to High(Parts) do
    FLines.Insert(FCaret.Line + K, TEditorLine.Create(Parts[K]));
  LastIdx := FCaret.Line + High(Parts);
  FCaret.Line := LastIdx;
  FCaret.Col := System.Length(Parts[High(Parts)]);
  FLines[LastIdx].Text := FLines[LastIdx].Text + Tail;
end;

function TSkiaCodeEditor.AdvancePos(const AStart: TCaretPos;
  const S: string): TCaretPos;
var
  I, NL, LastNL: Integer;
begin
  // Position of the caret after inserting S (assumed #10-normalized) at AStart.
  NL := 0;
  LastNL := 0;
  for I := 1 to System.Length(S) do
    if S[I] = #10 then
    begin
      Inc(NL);
      LastNL := I;
    end;
  if NL = 0 then
  begin
    Result.Line := AStart.Line;
    Result.Col := AStart.Col + System.Length(S);
  end
  else
  begin
    Result.Line := AStart.Line + NL;
    Result.Col := System.Length(S) - LastNL;   // chars after the last newline
  end;
end;

procedure TSkiaCodeEditor.ApplyReplace(const A, B: TCaretPos;
  const ANewText: string; ACoalesce: Boolean);
var
  Rec: TEditAction;
  Last: TEditAction;
  Merged: Boolean;
begin
  // THE choke point for every text mutation. Records an invertible edit, then
  // performs it. A..B is the (ordered) span being replaced by ANewText.
  Rec.CaretBefore := FCaret;
  Rec.RangeStart := A;
  Rec.OldText := TextInRange(A, B);
  Rec.NewText := ANewText.Replace(#13#10, #10).Replace(#13, #10);

  DeleteRangeRaw(A, B);
  InsertRaw(Rec.NewText);
  Rec.CaretAfter := FCaret;

  // Fold consecutive single-char typing into the previous record so undo works
  // per word-ish run, not per keystroke.
  Merged := False;
  if ACoalesce and FCoalesceTyping and (FUndo.Count > 0) then
  begin
    Last := FUndo.Last;
    if (Last.OldText = '') and (Rec.OldText = '') and (Pos(#10, Rec.NewText) = 0)
       and (ComparePos(Rec.RangeStart, Last.CaretAfter) = 0) then
    begin
      Last.NewText := Last.NewText + Rec.NewText;
      Last.CaretAfter := Rec.CaretAfter;
      FUndo[FUndo.Count - 1] := Last;
      Merged := True;
    end;
  end;
  if not Merged then
  begin
    FUndo.Add(Rec);
    while FUndo.Count > 1000 do   // bound history
      FUndo.Delete(0);
  end;
  FRedo.Clear;                    // any new edit invalidates redo
  FCoalesceTyping := ACoalesce;   // only a typed char keeps the run open

  FSelAnchor := FCaret;
  AfterEdit(A.Line);
end;

procedure TSkiaCodeEditor.ApplyRecord(const ARec: TEditAction; AInvert: Boolean);
var
  FromText, ToText: string;
  RangeEnd: TCaretPos;
begin
  // Re-apply (redo) or invert (undo) a stored record. Undo replaces NewText
  // back with OldText; redo does the opposite. No new history is recorded.
  if AInvert then
  begin
    FromText := ARec.NewText;
    ToText := ARec.OldText;
  end
  else
  begin
    FromText := ARec.OldText;
    ToText := ARec.NewText;
  end;
  RangeEnd := AdvancePos(ARec.RangeStart, FromText);
  DeleteRangeRaw(ARec.RangeStart, RangeEnd);
  InsertRaw(ToText);
  if AInvert then FCaret := ARec.CaretBefore else FCaret := ARec.CaretAfter;
  FSelAnchor := FCaret;
  FCoalesceTyping := False;
  AfterEdit(ARec.RangeStart.Line);
end;

procedure TSkiaCodeEditor.Undo;
var
  Rec: TEditAction;
begin
  if FUndo.Count = 0 then
    Exit;
  Rec := FUndo.Last;
  FUndo.Delete(FUndo.Count - 1);
  ApplyRecord(Rec, True);         // AfterEdit inside would clear FRedo -- guard:
  FRedo.Add(Rec);                 // ...so push AFTER (ApplyRecord doesn't touch FRedo)
end;

procedure TSkiaCodeEditor.Redo;
var
  Rec: TEditAction;
begin
  if FRedo.Count = 0 then
    Exit;
  Rec := FRedo.Last;
  FRedo.Delete(FRedo.Count - 1);
  ApplyRecord(Rec, False);
  FUndo.Add(Rec);
end;

function TSkiaCodeEditor.CanUndo: Boolean;
begin
  Result := FUndo.Count > 0;
end;

function TSkiaCodeEditor.CanRedo: Boolean;
begin
  Result := FRedo.Count > 0;
end;

procedure TSkiaCodeEditor.ReplaceSelectionWith(const S: string;
  ACoalesce: Boolean);
var
  A, B: TCaretPos;
begin
  // The single entry point for typing, Enter (S = #10), and paste.
  if SelActive then
    SelBounds(A, B)
  else
  begin
    A := FCaret;
    B := FCaret;
  end;
  ApplyReplace(A, B, S, ACoalesce);
end;

procedure TSkiaCodeEditor.DeleteSelection;
var
  A, B: TCaretPos;
begin
  if not SelActive then
    Exit;
  SelBounds(A, B);
  ApplyReplace(A, B, '', False);
end;

function TSkiaCodeEditor.ClipboardService(out ASvc: IFMXClipboardService): Boolean;
begin
  Result := TPlatformServices.Current.SupportsPlatformService(
    IFMXClipboardService, ASvc);
end;

procedure TSkiaCodeEditor.CopySelection;
var
  Svc: IFMXClipboardService;
begin
  if SelActive and ClipboardService(Svc) then
    Svc.SetClipboard(SelectedText);
end;

procedure TSkiaCodeEditor.CutSelection;
begin
  if SelActive then
  begin
    CopySelection;
    DeleteSelection;
  end;
end;

procedure TSkiaCodeEditor.PasteClipboard;
var
  Svc: IFMXClipboardService;
  V: TValue;
begin
  if not ClipboardService(Svc) then
    Exit;
  V := Svc.GetClipboard;
  if V.IsType<string> and (V.AsString <> '') then
    ReplaceSelectionWith(V.AsString);
end;

procedure TSkiaCodeEditor.DeleteBackward;
var
  A, B: TCaretPos;
begin
  // Delete the char before the caret, or (at column 0) the newline joining the
  // previous line. Expressed as a range replacement so it's recorded for undo.
  B := FCaret;
  if FCaret.Col > 0 then
  begin
    A.Line := FCaret.Line;
    A.Col := FCaret.Col - 1;
  end
  else if FCaret.Line > 0 then
  begin
    A.Line := FCaret.Line - 1;
    A.Col := System.Length(FLines[FCaret.Line - 1].Text);
  end
  else
    Exit;                        // start of document: nothing to delete
  ApplyReplace(A, B, '', False);
end;

procedure TSkiaCodeEditor.DeleteForward;
var
  A, B: TCaretPos;
begin
  // Delete the char after the caret, or (at line end) the newline pulling the
  // next line up.
  A := FCaret;
  if FCaret.Col < System.Length(FLines[FCaret.Line].Text) then
  begin
    B.Line := FCaret.Line;
    B.Col := FCaret.Col + 1;
  end
  else if FCaret.Line < LineCount - 1 then
  begin
    B.Line := FCaret.Line + 1;
    B.Col := 0;
  end
  else
    Exit;                        // end of document: nothing to delete
  ApplyReplace(A, B, '', False);
end;

procedure TSkiaCodeEditor.MoveCaretHorizontal(ADelta: Integer;
  ASelecting: Boolean);
var
  NewCol: Integer;
  A, B: TCaretPos;
begin
  FCoalesceTyping := False;   // moving the caret ends a typing run
  ResetCaretTarget;    // stepping through text follows the text order
  // Plain arrow over an active selection collapses to the near edge.
  if (not ASelecting) and SelActive then
  begin
    SelBounds(A, B);
    if ADelta < 0 then FCaret := A else FCaret := B;
    FSelAnchor := FCaret;
    EnsureCaretVisible;
    ResetCaretBlink;
    RedrawContent;
    Exit;
  end;

  NewCol := FCaret.Col + ADelta;
  if NewCol < 0 then
  begin
    if FCaret.Line > 0 then     // wrap to end of previous line
    begin
      Dec(FCaret.Line);
      FCaret.Col := System.Length(FLines[FCaret.Line].Text);
    end;
  end
  else if NewCol > System.Length(FLines[FCaret.Line].Text) then
  begin
    if FCaret.Line < LineCount - 1 then   // wrap to start of next line
    begin
      Inc(FCaret.Line);
      FCaret.Col := 0;
    end;
  end
  else
    FCaret.Col := NewCol;

  if not ASelecting then
    FSelAnchor := FCaret;       // collapse
  EnsureCaretVisible;
  ResetCaretBlink;
  RedrawContent;
end;

procedure TSkiaCodeEditor.MoveCaretWord(ADir: Integer; ASelecting: Boolean);
var
  L: string;
  N: Integer;
begin
  // Ctrl/Option+Arrow: jump by word. Word chars are the find helper's set
  // (letters, digits, underscore) -- same notion as double-click select. At a
  // line boundary the caret steps to the adjacent line, like a plain arrow.
  FCoalesceTyping := False;
  ResetCaretTarget;
  L := FLines[FCaret.Line].Text;
  N := System.Length(L);

  if ADir > 0 then
  begin
    if FCaret.Col >= N then
    begin
      if FCaret.Line < LineCount - 1 then   // at line end -> next line start
      begin
        Inc(FCaret.Line);
        FCaret.Col := 0;
      end;
    end
    else
    begin
      // skip the rest of the current word, then the separators after it,
      // landing at the start of the next word (or the line end).
      while (FCaret.Col < N) and FindIsWordChar(L[FCaret.Col + 1]) do
        Inc(FCaret.Col);
      while (FCaret.Col < N) and not FindIsWordChar(L[FCaret.Col + 1]) do
        Inc(FCaret.Col);
    end;
  end
  else
  begin
    if FCaret.Col = 0 then
    begin
      if FCaret.Line > 0 then                // at line start -> prev line end
      begin
        Dec(FCaret.Line);
        FCaret.Col := System.Length(FLines[FCaret.Line].Text);
      end;
    end
    else
    begin
      // skip separators to the left, then the word chars, landing at the
      // start of the current/previous word.
      while (FCaret.Col > 0) and not FindIsWordChar(L[FCaret.Col]) do
        Dec(FCaret.Col);
      while (FCaret.Col > 0) and FindIsWordChar(L[FCaret.Col]) do
        Dec(FCaret.Col);
    end;
  end;

  if not ASelecting then
    FSelAnchor := FCaret;         // collapse when not extending
  EnsureCaretVisible;
  ResetCaretBlink;
  RedrawContent;
end;

procedure TSkiaCodeEditor.MoveCaretVertical(ADelta: Integer;
  ASelecting: Boolean);
var
  Row, NewRow, RowInLine, RS, RE: Integer;
  X: Single;
begin
  // Up/Down and PageUp/Dn move by VISUAL row, so a wrapped line takes several
  // presses to cross. The caret keeps its horizontal position (measured, not
  // by column index), which is also what proportional fonts want.
  //
  // The x it keeps is FDesiredX, seeded from the caret when a vertical run
  // begins and held for the whole run. Re-reading the caret's x each press
  // would let a short row ratchet it leftwards permanently: down through a
  // 3-char line then back up would land at column 3, not where you started.
  // Any non-vertical caret action clears it (ResetCaretTarget).
  FCoalesceTyping := False;
  Row := CaretRow;
  if not FHasDesiredX then
  begin
    FDesiredX := CaretContentX;
    FHasDesiredX := True;
  end;
  X := FDesiredX;
  NewRow := Max(0, Min(FTotalRows - 1, Row + ADelta));

  FCaret.Line := RowToLine(NewRow);
  RowInLine := NewRow - FLines[FCaret.Line].FirstRow;
  RowColBounds(FCaret.Line, RowInLine, RS, RE);
  FCaret.Col := XToColInRow(FCaret.Line, RS, RE, X);
  // Landing on a wrapped row's last column must stay on that row.
  FCaretAtRowEnd := (FCaret.Col = RE) and
    (RowInLine < RowsInLine(FCaret.Line) - 1);

  if not ASelecting then
    FSelAnchor := FCaret;
  EnsureCaretVisible;
  ResetCaretBlink;
  RedrawContent;
end;

procedure TSkiaCodeEditor.CaretToLineStart(ASelecting: Boolean);
var
  RS, RE: Integer;
begin
  // Home/End act on the visual row (they collapse to the logical line when the
  // line isn't wrapped, which is the no-wrap behaviour unchanged).
  FCoalesceTyping := False;
  RowColBounds(FCaret.Line, CaretRowInLine, RS, RE);
  FCaret.Col := RS;
  ResetCaretTarget;
  if not ASelecting then
    FSelAnchor := FCaret;
  EnsureCaretVisible;
  ResetCaretBlink;
  RedrawContent;
end;

procedure TSkiaCodeEditor.CaretToLineEnd(ASelecting: Boolean);
var
  RowInLine, RS, RE: Integer;
begin
  FCoalesceTyping := False;
  FHasDesiredX := False;   // End re-anchors the goal column (affinity is set below)
  RowInLine := CaretRowInLine;
  RowColBounds(FCaret.Line, RowInLine, RS, RE);
  FCaret.Col := RE;
  // On a wrapped row the end column is also the next row's start column; keep
  // the caret visually at this row's end.
  FCaretAtRowEnd := RowInLine < RowsInLine(FCaret.Line) - 1;
  if not ASelecting then
    FSelAnchor := FCaret;
  EnsureCaretVisible;
  ResetCaretBlink;
  RedrawContent;
end;

{ ---- input ---- }

procedure TSkiaCodeEditor.DoMouseDown(Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  HideTooltip;
  if Button <> TMouseButton.mbLeft then
    Exit;
  FCoalesceTyping := False;   // clicking ends a typing run
  FHasDesiredX := False;      // click re-anchors the goal column
  FCaret := PointToCaret(TPointF.Create(X, Y), FCaretAtRowEnd);
  // Shift+click extends from the existing anchor; a plain click collapses.
  if not (ssShift in Shift) then
    FSelAnchor := FCaret;
  FMouseSelecting := True;
  ResetCaretBlink;
  RedrawContent;
end;

procedure TSkiaCodeEditor.ContentMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Single);
var
  Idx: Integer;
begin
  if FMouseSelecting and (ssLeft in Shift) then
  begin
    // Extend the selection: move the caret, leave the anchor fixed.
    FHasDesiredX := False;
    FCaret := PointToCaret(TPointF.Create(X, Y), FCaretAtRowEnd);
    EnsureCaretVisible;   // auto-scroll when dragging past an edge
    ResetCaretBlink;
    RedrawContent;
    Exit;
  end;

  // Hover: restart the dwell timer whenever the marker under the pointer
  // changes. Moving within one marker keeps a shown tip up and doesn't retrigger.
  if FMarkers.Count = 0 then
    Exit;
  FHoverPt := TPointF.Create(X, Y);
  Idx := MarkerAtPoint(FHoverPt);
  if Idx = FHoverMarker then
    Exit;
  FHoverMarker := Idx;
  FHoverTimer.Enabled := False;
  if FTipVisible then          // moved off (or onto another) marker: drop it
  begin
    FTipVisible := False;
    RedrawContent;
  end;
  if Idx >= 0 then
    FHoverTimer.Enabled := True;
end;

procedure TSkiaCodeEditor.ContentMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Single);
begin
  FMouseSelecting := False;
end;

procedure TSkiaCodeEditor.KeyDown(var Key: Word; var KeyChar: WideChar;
  Shift: TShiftState);
var
  PageLines: Integer;
  Sel, Cmd, WordMove: Boolean;
begin
  inherited;
  HideTooltip;   // any key dismisses a hover tip
  Sel := ssShift in Shift;
  Cmd := (ssCtrl in Shift) or (ssCommand in Shift);   // Ctrl on Win, Cmd on mac
  // Word-jump modifier: Ctrl on Windows; Option (Alt) on macOS, where Ctrl+Arrow
  // is a system Spaces shortcut and never reaches the app. Ctrl works too where
  // the OS lets it through. Shift held as well => extend the selection by word.
  WordMove := (ssCtrl in Shift) or (ssAlt in Shift);

  // Clipboard / select-all. Match on the virtual key (letters come as Ord('C')
  // etc.), since with the modifier held KeyChar is a control char.
  if Cmd then
  begin
    case Key of
      Ord('C'): begin CopySelection; Key := 0; Exit; end;
      Ord('X'): begin CutSelection;  Key := 0; Exit; end;
      Ord('V'): begin PasteClipboard; Key := 0; Exit; end;
      Ord('A'): begin SelectAll;     Key := 0; Exit; end;
      Ord('Z'): begin if Sel then Redo else Undo; Key := 0; Exit; end;  // Shift = redo
      Ord('Y'): begin Redo; Key := 0; Exit; end;
      Ord('G'): begin
                  if Assigned(FOnRequestGotoLine) then FOnRequestGotoLine(Self);
                  Key := 0; Exit;
                end;
      Ord('F'): begin
                  if FBuiltInFindUI then
                    ShowBuiltInFindBar
                  else if Assigned(FOnRequestFind) then
                    FOnRequestFind(Self);
                  Key := 0; Exit;
                end;
    end;
  end;

  // Control/navigation keys arrive in Key (KeyChar = #0); printable text
  // arrives in KeyChar. Shift extends the selection on navigation keys.
  // TODO: undo; IME on macOS via FMX ITextInput / IFMXTextService.
  case Key of
    vkLeft:   begin
                if WordMove then MoveCaretWord(-1, Sel)
                else MoveCaretHorizontal(-1, Sel);
                Key := 0; Exit;
              end;
    vkRight:  begin
                if WordMove then MoveCaretWord(1, Sel)
                else MoveCaretHorizontal(1, Sel);
                Key := 0; Exit;
              end;
    vkUp:     begin MoveCaretVertical(-1, Sel);   Key := 0; Exit; end;
    vkDown:   begin MoveCaretVertical(1, Sel);    Key := 0; Exit; end;
    vkHome:   begin CaretToLineStart(Sel);        Key := 0; Exit; end;
    vkEnd:    begin CaretToLineEnd(Sel);          Key := 0; Exit; end;
    vkPrior:
      begin
        PageLines := Max(1, Trunc(FContent.Height / FLineHeight) - 1);
        MoveCaretVertical(-PageLines, Sel); Key := 0; Exit;
      end;
    vkNext:
      begin
        PageLines := Max(1, Trunc(FContent.Height / FLineHeight) - 1);
        MoveCaretVertical(PageLines, Sel); Key := 0; Exit;
      end;
    vkBack:   begin if SelActive then DeleteSelection else DeleteBackward;
                Key := 0; Exit; end;
    vkDelete: begin if SelActive then DeleteSelection else DeleteForward;
                Key := 0; Exit; end;
    vkReturn: begin ReplaceSelectionWith(#10); Key := 0; Exit; end;
    vkEscape:
      begin
        // Dismiss the find UI and its highlights without touching the caret.
        if Assigned(FFindBar) and FFindBar.Visible then
          FFindBar.Visible := False;
        ClearHighlightMatches;
        Key := 0; Exit;
      end;
  end;

  // Printable character (exclude control range, DEL, and modifier combos).
  // Pass ACoalesce=True so a run of typed chars folds into one undo step.
  if (KeyChar >= #32) and (KeyChar <> #127) and not Cmd then
  begin
    ReplaceSelectionWith(KeyChar, True);
    KeyChar := #0;
  end;
end;

end.
