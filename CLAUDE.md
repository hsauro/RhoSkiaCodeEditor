# CLAUDE.md — TSkiaCodeEditor

An owner-drawn, Skia-backed code editor control for **FMX / Delphi** (Object
Pascal). A memo-like control that displays line numbers and syntax-highlighted
text and works **identically on Windows and macOS**.

## Why this exists / the core constraint

The predecessor (`TRichEditStyled`, a `TMemo`-derived styled memo) is bugged
cross-platform. Root cause: FMX `TMemo` routes through **different presenters
per OS** — the styled/FMX-drawn presenter on Windows, the **native NSTextView**
presenter on macOS. Per-character coloring, gutter alignment, and caret math
tuned on one platform silently diverge on the other because the underlying text
layout and metrics engines differ. No amount of patching unifies them.

**The whole design premise:** remove the native presenter from the loop. Every
glyph is measured and drawn with **Skia** directly, so there is one paint path
and one set of metrics on every platform. Do not reintroduce `TMemo`,
`TTextLayout`, or native text services for layout/measurement. If a change
would make behavior depend on the OS text engine, it's wrong.

**Rule:** all text measurement and layout go through the single `ISkFont`
(`FSkFont`) built in `RebuildFontMetrics`. Never measure with FMX
`TTextLayout` / `Canvas.MeasureText` — that path is exactly the cross-platform
divergence we're escaping.

## Repo layout

Restructured as a redistributable component (MIT, see `LICENSE` / `README.md`):

- `Source/` — the four component units + `uSkiaCodeEditorReg.pas` (`Register`
  only; registers on the **`Rhody Controls`** palette page — the user's `Rho*`
  house convention for their component set).
- `Packages/` — `SkiaCodeEditor.dpk` (runtime, `{$RUNONLY}`) and
  `dclSkiaCodeEditor.dpk` (design-time, `{$DESIGNONLY}`, requires the runtime
  package + `designide`), each with an IDE-generated `.dproj`. The `.dpk`s carry
  no `{$R *.res}`, so a `dcc` build works from a clean clone. The design-time
  package is **Win32** — the IDE is a 32-bit process — and needs a Win32 build of
  the runtime package first. `RhoFMXEditorGroup.groupproj` ties both packages and
  the demo together for IDE development.
- `Demo/` — `SkiaCodeEditorDemo.dproj` (was `NewMemoFMXProject`). It finds the
  component through `DCC_UnitSearchPath = ..\Source`, not by listing the units,
  so it compiles the way a consumer's project would (and F9 recompiles edited
  component source straight in).

**Design-time gotchas** (both already handled; don't regress them):
- All designer-facing properties are `published`. `TControl` keeps
  `Align`/`Anchors`/`Size`/`Position`/`Visible`/`Enabled`/`TabOrder` **public**,
  so a directly-derived control must re-publish them or it can't be laid out.
  `TAlphaColor` properties take no `default` (the constant exceeds `MaxInt`);
  `FontSize` is a `Single`, which can't have one either.
- `FContent`, `FVScroll`, `FHScroll`, `FFindBar` all set **`Stored := False`**.
  FMX streams a control's children into the `.fmx`; without this, dropping the
  component on a form writes them to the form file and the constructor creates
  them again on load — duplicate scrollbars and paint box.

## Files

- `uCodeEditorTypes.pas` — shared token/lexer types (`TTokenRun`, `TLexState`,
  `TTokenizeLineProc`, `ls*`). Its own unit so the editor and highlighter can
  both use it without a circular dependency. `uSkiaCodeEditor` re-exports these
  names as aliases for callers.
- `uSkiaCodeEditor.pas` — the control. Rendering, editing, scrolling, selection,
  clipboard, undo/redo, downstream token invalidation, and IME are all
  implemented (see build-order status below).
- `uSyntaxHighlighter.pas` — `TSimpleHighlighter`, a configurable ready-made
  tokenizer (comment/string rules, keyword list, colours) so callers don't
  hand-write a `TTokenizeLineProc`. The editor owns one lazily via the
  `Highlighter` property (`Editor.Highlighter.UsePascal; ...AddKeywords([...])`);
  its `OnChange` re-lexes. Standalone-usable too (pass `.Tokenize` to
  `SetTokenizer`). Block comments are multi-line (state N+1 = inside rule N).
  Presets: `UsePascal`, `UseCLike`, `UseAntimony` (Antimony/SBML — both `#` and
  `//` line comments plus `/* */` blocks), `UsePython` (`#` line; `'''`/`"""`
  triple-quote strings modelled as **block comments** — the engine has no
  multi-line *string* rule, only block *comments*, so docstrings render
  comment-coloured). A preset sets comment/string rules only; keywords are added
  separately with `AddKeywords`.
- `uLanguageKeywords.pas` — ready-made keyword lists for the presets
  (`PascalKeywords`, `CKeywords`, `AntimonyKeywords`, `PythonKeywords` — each a
  `TArray<string>` const). Data-only, no editor/highlighter dependency, so a
  caller does `AddKeywords(PythonKeywords)` instead of hand-typing the list (and
  the lists work with a hand-written tokenizer too). Not wired into the packages
  yet — consumers get it via `Source` on the search path.
- `uFindBar.pas` — `TFindBar`, the built-in docked find/replace bar. Knows
  nothing about the editor: the host wires callbacks (find next/prev, replace,
  replace all, `OnSearchChanged` for live highlight-all, `OnClosed`). The editor owns one lazily behind `BuiltInFindUI` (see
  find/replace below). Same "batteries included but overridable" split as the
  highlighter, and no circular dependency (it uses only `uCodeEditorTypes`).

## Architecture

- `TSkiaCodeEditor` (`TControl`) hosts a **client-aligned** Skia paint surface
  (`FContent`, a `TSkPaintBox` whose `OnDraw` is `ContentPaint`) plus two real
  `TScrollBar`s (`FVScroll`/`FHScroll`). **We own scrolling ourselves** — no
  `TScrollBox`. `FContent` is always exactly the viewport; content is offset by
  `FScrollX`/`FScrollY` (content coords) at paint time. This was a deliberate
  move away from `TScrollBox`: its scrollbars auto-hide as overlays and its
  touch/inertia scrolling differs Windows↔macOS, which is exactly the
  cross-platform divergence this control exists to avoid.
  - Screen (viewport-local) = content − scroll offset. Painters subtract
    `FScrollX`/`FScrollY`; hit-testing (`PointToCaret`) adds them back. The
    gutter is sticky: vertically scrolled, never horizontally, and painted
    last so it masks glyphs scrolled under it.
  - `UpdateContentSize` sets `FContentW`/`FContentH`; `UpdateScrollBars` maps
    those onto the bars (`Max`/`ViewportSize`); `SetScrollPos` clamps and is the
    one entry point for programmatic scroll (`EnsureCaretVisible`, `MouseWheel`).
- `TEditorLine` = one logical line: `Text` + cached `Tokens` + lex state
  (`StateIn`/`StateOut`) + `TokensValid` + wrap layout (`WrapStarts`,
  `WrapValid`, `FirstRow`).
- **Visual rows are the vertical coordinate**, not logical lines. See word wrap
  below; with `WordWrap` off a line is exactly one row, so `Y = FirstRow *
  FLineHeight` degenerates to the old `Y = idx * FLineHeight`.
- `TTokenRun` = a colored span within a line `[StartCol, StartCol+Length)`.
- **Syntax highlighting is pluggable**: a `TTokenizeLineProc` via `SetTokenizer`,
  pure and per-line: `(text, stateIn) -> (runs, stateOut)`. Lex state
  (`TLexState`) flows line-to-line for multi-line constructs. Most callers use
  the built-in `TSimpleHighlighter` via the `Highlighter` property instead of
  writing one (see Files).
- **Colours**: token colours come from the tokenizer/highlighter; the editor's
  own surfaces are live `TAlphaColor` properties — `BackgroundColor`,
  `TextColor`, `GutterColor`, `GutterTextColor`, `CaretColor`, `SelectionColor`,
  `FindMatchColor` (all just repaint, no re-lex). `FindMatchColor` is used only
  for the current find match: `SelectMatch` sets an `FSelIsMatch` flag (cleared
  by any caret action, since all funnel through `ResetCaretBlink` before
  repainting), and `PaintSelection` picks the colour off it — so a find match
  reads differently from a normal selection.
  - **Theme presets** (`ApplyTheme(etLight | etDark)`): sets all of the editor's
    own colour surfaces from one curated, **cross-platform-identical** palette in
    a single call — it deliberately does **not** read the active FMX style (FMX
    has no colour-token API; a style is a tree of drawables, and the default
    style differs Win↔mac, which would reintroduce the very divergence this
    control avoids). `etLight` is the constructor defaults; `etDark` is VS Code
    Dark+. If a Highlighter already exists it also retunes its syntax colours
    (keyword/string/comment/number); a hand-written tokenizer with no Highlighter
    is left alone (checks the `FHighlighter` field, never force-creates one).
    It's a **method, not a stored property** — a published `Theme` would re-apply
    on `.fmx` load and clobber hand-set colours (same reasoning as the
    `Highlighter.Use*` presets). Every colour stays individually overridable
    after the call.
- **Current-line highlight** (`HighlightCurrentLine`, default **off**;
  `CurrentLineColor`): a faint full-width band behind the caret's logical line
  (all its wrapped rows), painted *first* in `PaintContent` so everything else
  sits on top. Off by default because some find it distracting — opt in per host.
  `PaintCurrentLine` reads `FCaret.Line` and every caret move already repaints,
  so it follows the caret for free.
- **Navigation API**: `LineCount`, `GoToLine(n)` (1-based; caret to line start,
  scrolled centered), and read-only `CaretLine` / `CaretColumn` (1-based).
  Internally lines/cols are 0-based — these convert at the boundary.
- **Word wrap** (`WordWrap`, default False). Each `TEditorLine` caches
  `WrapStarts` — the columns its visual rows begin at, `[0]` always 0, so
  `Length(WrapStarts)` is its row count and is always ≥ 1 — plus `FirstRow`, its
  absolute row index (a running sum rebuilt by `UpdateContentSize`). With wrap
  **off** every line yields one row, so **there is no second code path**: paint,
  hit-test, scroll and gutter are written once in row terms and collapse to the
  old line arithmetic. That's the whole trick; don't reintroduce
  `if FWordWrap then` branching into geometry.
  - `RowBreak` picks a row's end column: monospace divides, proportional
    accumulates advances, then both back up to the last space/tab (hard-break
    mid-word if there is none). It always returns > start, so callers terminate.
  - Row ↔ line: `RowToLine` binary-searches `FirstRow`; paint loops instead walk
    a line cursor forward. `RowsInLine`, `RowColBounds`, `RowOfCol` are the rest.
  - **Caret affinity** (`FCaretAtRowEnd`): a column on a wrap boundary is both
    one row's end and the next row's start. The flag picks the earlier row, so
    End / click-past-EOL park the caret at the end of the wrapped row instead of
    teleporting it to the next. Every caret-moving routine sets it explicitly.
  - Up/Down/PgUp/PgDn move by **visual row** and preserve measured x (not column
    index); Home/End act on the **visual row**. Wrapped => no horizontal scroll
    (`FHScroll` hidden, `FScrollX` pinned to 0, `FContentW` = 0).
  - **Goal column** (`FDesiredX` / `FHasDesiredX`): the x a vertical run aims
    for, seeded from the caret on the first Up/Down and held for the whole run.
    Re-reading the caret's x each press would let a short row ratchet it
    leftwards permanently (down past a 3-char line and back up would land at
    column 3). It's an x, not a column index, so it works across wrapped rows
    and proportional fonts alike. **`ResetCaretTarget` clears it together with
    the affinity flag** — call that from any caret action that isn't a vertical
    move; the two always invalidate together, which is why they share a helper.
  - Re-wrap triggers: edited lines (`AfterEdit`), font/metrics change
    (`ApplyFontChange`), gutter width change, and viewport **width** change —
    the last via `FContent.OnResize`, not the editor's `Resize` (see notes).
    `UpdateContentSize` compares `TextAreaWidth` against `FWrapWidth` and skips
    the re-flow when unchanged, so a height-only resize costs nothing.
- **Find / replace**: `FindNext` / `FindPrevious` (select + center the match,
  wrap-around), `ReplaceCurrent` (replace the selection if it's a match, then
  find next), `ReplaceAll` (returns count; one undo step — rebuilds the doc
  once). Options: `foMatchCase`, `foWholeWord`, `foWrapAround`. **Matches are
  single-line** (search has no newline). All go through the same `ApplyReplace`
  choke point, so they're undoable. `SelText` exposes the current selection.
  - **UI**: `BuiltInFindUI` (default True) → Ctrl/Cmd+F shows the component's own
    docked `TFindBar` (lazily created, themed from `GutterColor`/`TextColor`,
    reflows the text down; Esc/Close reclaims the space). Set it False to instead
    fire `OnRequestFind` and drive the public find methods from your own UI.
  - **Highlight-all** (`HighlightAllMatches`, default True): every visible
    occurrence of the current term is tinted `FindHighlightColor` (keep it weaker
    than `FindMatchColor`, which still marks the one you're on).
    `PaintFindMatches` runs *before* `PaintSelection` so the current match paints
    over the rest. The term lives in `FHighlightTerm`; `FindNext`/`FindPrevious`
    set it, and `TFindBar.OnSearchChanged` (new) updates it per keystroke and on
    a Match-case/Whole-word toggle, so highlighting is live as you type. Esc or
    closing the bar calls `ClearHighlightMatches`. Hosts with their own find UI
    call `HighlightMatches` / `ClearHighlightMatches` directly.
    - Matches are found per **visible line** at paint time (`LineMatches`), never
      document-wide — same lazy discipline as tokenizing. Each match is clipped
      to the row's column span, so a match straddling a wrap break paints as two
      rects.
- **Markers** (host-owned annotations, e.g. parser errors). `TEditorMarker` =
  `(Line, StartCol, Length, Kind, Color, Message)` in `uCodeEditorTypes`; `Kind`
  is `mkTint` (translucent rect behind the text) or `mkSquiggle` (wavy underline).
  The two are orthogonal to what's spanned: either kind can cover a token or a
  whole line. **Purely visual — markers never touch the caret or selection**, so
  a host can annotate a model without moving the user's cursor.
  - API is **1-based** (matching `GoToLine`/`CaretLine`): `AddMarker`,
    `MarkLine`, `MarkWordAt` (grows the span over the word at a column — parsers
    report where a token starts, not its length), `ClearMarkers`, `MarkerCount`,
    `LineText` (read one line, to map a parser offset into a sub-expression onto
    a real column), `MarkerMessageAt` (drive a tooltip / status bar).
    `ALen <= 0` means "to end of line". Out-of-range lines are ignored, not raised.
  - `MarkersClearOnEdit` (default True): any edit drops them, since they describe
    text that just changed. `SetText` always drops them regardless.
  - Painted on the same row-clipped path as find matches, so a marker spanning a
    wrap break draws on each row it crosses. Tints paint at the **bottom** of the
    stack (under find hits and selection); squiggles paint **over the glyphs**,
    or descenders would hide them.
  - `mkTint`/`mkSquiggle` are re-exported as consts from `uSkiaCodeEditor` — a
    type alias re-exports the type but *not* its enum values. Ditto the `TipRun`
    / `TipLine` / `Tip` builders (as plain, **non-inline** wrappers: an inline
    body in another unit makes every host emit `H2443` unless it also uses
    `uCodeEditorTypes`, which is what the re-export exists to avoid).
- **Marker tooltips** are **own-drawn with Skia** (`PaintTooltip`, painted last,
  over the caret), not FMX `Hint`/`ShowHint`. A native hint service can't do
  multi-line + per-run colour, and renders through different machinery per OS —
  the exact divergence this control exists to avoid.
  - Content is a `TTipText` = lines of `TTipRun` = `(Text, Color, Bold)`, so a
    tooltip is measured and drawn run-by-run just like a line of code. A run with
    `Color = TAlphaColors.Null` uses `TooltipTextColor`. Bold runs use
    `FSkFontBold` (same family/size, built in `RebuildFontMetrics`). A marker
    given only a plain `Message` gets one default-coloured run per `#10` line
    (`TipFromText`), so the simple path stays simple.
  - Hover: `ContentMouseMove` → `MarkerAtPoint` → 500 ms `FHoverTimer` dwell →
    `FTipVisible`. `MarkerAtPoint` tests the **same rects `PaintMarkers` fills**
    (`MarkerRowRect` is shared), so the tip triggers exactly where the marker is
    drawn. Dismissed by any key, click, scroll, mouse-leave, or marker clear.
  - It lives **inside** `FContent`, so it is clamped to the viewport (and flips
    above the pointer near the bottom) rather than spilling outside the control.
    Escaping the control would need a popup form — i.e. a native window back in
    the loop. Colours: `TooltipColor` / `TooltipTextColor` / `TooltipBorderColor`.
- **Events**: `OnCaretChange` (fires from `ResetCaretBlink` + `SetText`, i.e.
  after any caret move / edit / load — drive a status bar off it),
  `OnRequestGotoLine` (Ctrl/Cmd+G) and `OnRequestFind` (Ctrl/Cmd+F). The control
  itself never pops dialogs — it fires these so the host shows the UI. The demo
  (`ufMain`) wires them to a bottom status bar, a `TDialogService.InputQuery`
  go-to-line prompt, and a toggleable find/replace bar.

### Paint pipeline (`PaintContent`)
1. Fill background.
2. `VisibleRowRange` maps the viewport to an absolute **row** range — **only
   visible rows are ever laid out**. Keep it that way; never iterate all lines
   in paint. `RowToLine` converts the ends to a line range.
3. `EnsureTokens` for visible lines (lazy; recurses backward to establish
   incoming lex state).
4. Paint selection, then rows (`PaintRow` draws one line's `[rowStart, rowEnd)`
   run-by-run with per-run color, clipping runs to the row; gaps fall back to
   default text color), then gutter, then caret. A wrapped line numbers only its
   first row; continuation rows get a blank gutter.

### Metrics / geometry
- **Font family is per-platform** (`DefaultFontFamily`): Consolas on Windows,
  **Menlo on macOS**, DejaVu Sans Mono elsewhere. `TSkTypeface.MakeFromName`
  does **not** fail on a missing family — it silently returns a default
  *proportional* typeface, so hardcoding Consolas made macOS take the monospace
  fast path against a proportional face.
- **`IsFixedPitch` guards the fast path.** `RebuildFontMetrics` measures `'0'`,
  `'W'` and `'i'`; only if all three advances match does it set `FCharWidth`
  (> 0 = "use `col * FCharWidth`"). Otherwise `FCharWidth := 0` and everything
  degrades to correct-but-slower per-character measurement. Symptom it prevents:
  text renders fine but the caret drifts further from the glyph the further
  right you go, clicks land on the wrong column, and wrap breaks early.
  **`FCharWidth` is therefore 0 on proportional faces** — never use it as a
  margin or step; use `FDigitWidth` (always valid) as `UpdateContentSize`,
  `UpdateScrollBars`, `EnsureCaretVisible` and `PaintSelection` now do.
- `RebuildFontMetrics` builds `FSkTypeface`/`FSkFont`; line height and
  (monospace) char advance derive from Skia `TSkFontMetrics`. The `FontSize` /
  `FontFamily` / `Monospace` properties are **live** — their setters call
  `ApplyFontChange` (rebuild metrics → `UpdateContentSize` → repaint). A plain
  field write would silently do nothing, which is why they must stay setters.
- `FGutterWidth` is **not fixed**: `UpdateContentSize` sizes it to the widest
  line number at the current font (`digitAdvance * (maxDigits + padding)`), so
  it stays right across font sizes and growing line counts. The `GutterVisible`
  property toggles it — when off, `FGutterWidth` becomes 0 (text/caret/selection
  all start at x=0 with no other changes) and `PaintGutter` is skipped.
  - **Gutter separator** (`GutterLineColor`, `GutterLineThickness`; default a
    1px grey rule, thickness 0 hides it). `PaintGutter` fills it as the gutter's
    **rightmost `thickness` pixels** (`x = FGutterWidth − thickness … FGutterWidth`),
    so it sits on the gutter side and never eats into the text area. Purely
    visual — the setters just repaint, no re-layout; it spans the same visible
    row range as the gutter background.
- `ColToX` / `XToColInRow` / `PointToCaret` are the hit-testing spine, all
  row-relative: a wrapped row restarts at the left margin, so `ColToX` measures
  from the row's first column (`MeasureRange`), not the line's. Monospace
  fast-path uses `FCharWidth`; proportional measures per char.
- **Baseline alignment**: gutter numbers and line text share
  `Baseline = Y + (-Metrics.Ascent)`. Keep them consistent — misaligned gutter
  baselines were a real bug class in the predecessor.

## Build order / status

Done:
1. ✅ **`FContent` wired to a real `TSkPaintBox`**; `ContentPaint` fires.
   Repaints go through `RedrawContent`, which calls `TSkPaintBox.Redraw`
   (**not** `Repaint` — plain `Repaint` re-blits the stale cached frame and
   edits that don't resize the surface never appear).
2. ✅ **Caret rendering + blink timer + focus** (`PaintCaret`, `FCaretTimer`,
   `DoEnter`/`DoExit`, gated on `IsFocused and FCaretVisible`).
3. ✅ **Keyboard editing** (`KeyDown` → editing primitives): insertion,
   Backspace/Delete (with line merge), Enter (split), arrows/Home/End/PgUp/Dn,
   word-jump (`MoveCaretWord`, on Ctrl+←/→ or Option+←/→ — the `WordMove` flag is
   `ssCtrl or ssAlt`, since macOS eats Ctrl+Arrow for Spaces; Shift extends by
   word). Each mutation ends in `AfterEdit` (invalidate tokens,
   `UpdateContentSize`, `EnsureCaretVisible`, `RedrawContent`).
4. ✅ **Scrolling**: owned scrollbars + mouse wheel (see Architecture).
   `UpdateContentSize` tracks true max line width.
5. ✅ **Selection**: `[FSelAnchor .. FCaret]` range (no bool flag; `SelActive`
   = anchor ≠ caret). Shift+navigation extends; plain move collapses; mouse
   drag-select (`ContentMouseMove`, `FContent.AutoCapture`); double-click selects
   the word (`ContentDblClick` → `SelectWordAt`); Ctrl/Cmd+A.
   `PaintSelection` fills per-line rects behind the text (scroll-offset aware).
6. ✅ **Clipboard**: Ctrl/Cmd+C/X/V via FMX `IFMXClipboardService` (cross-
   platform, no native text services).
7. ✅ **Undo/redo** (Ctrl/Cmd+Z, Ctrl+Y / Shift+Cmd+Z). All text mutation
   funnels through one choke point, `ApplyReplace(A, B, NewText)`, which records
   an invertible `TEditAction` `(RangeStart, OldText, NewText, caretBefore/After)`
   then does `DeleteRangeRaw` + `InsertRaw`. Undo/redo replay via `ApplyRecord`
   (using `AdvancePos` to find the current span) and record nothing. Consecutive
   single-char typing coalesces into one record (`FCoalesceTyping`, broken by any
   caret move/click); `FRedo` clears on any fresh edit. History bounded at 1000.

8. ✅ **Downstream token invalidation** (`RetokenizeAfterEdit`, called from
   `AfterEdit`). After an edit to lines `[start..caret]`, re-lex those, then
   cascade forward through following lines only while the incoming lex state
   keeps changing; stop at the first line whose incoming state is unchanged
   (re-converged) or that is still untokenized (stays lazy for paint). The
   common edit (state unchanged) touches only the edited lines; a `{`/`}` block
   comment ripples down until it re-closes. `LexLine` is the shared one-line
   tokenizer used by both this and `EnsureTokens`. The demo (`ufMain`) installs
   a small Pascal tokenizer (`TokenizePascal`) exercising all of it.

9. ✅ **IME / composition** (macOS + Windows). The control implements
   `ITextInput` and owns a `TTextService` (from `IFMXTextService`), entered/
   exited on focus (`DoEnter`/`DoExit`). Key insight from the RTL source:
   **committed** composition text is delivered as ordinary `KeyDown`/`KeyChar`
   events (macOS `insertText:` → `DispatchKeyPress`; Windows `WM_CHAR`), so it
   already inserts via our normal path — the interface only adds the in-progress
   **marked** string (`PaintMarkedText` draws it underlined at the caret, masking
   underlying glyphs, with its own caret) and candidate-window placement
   (`GetTargetClausePointF`). `SyncTextService` feeds the current line+caret to
   the service on every caret change. No regression risk on Windows: `WM_CHAR`
   always routes to `KeyDown` regardless of the text service.
   - ⚠️ **Untested on real macOS from this Windows box.** Verified here: clean
     build, no input regression, and the marked-text overlay renders correctly
     (forced via a temporary hook). The live CJK composition flow (candidate
     window, commit ordering) needs on-device testing.
   - ⚠️ **CJK glyphs need a font with them.** `RebuildFontMetrics` builds one
     `ISkFont` from `FFontFamily` (Consolas) with no fallback, so CJK marked/
     committed text renders as tofu until a fallback face is added.

10. ✅ **Word wrap** (`WordWrap` property, default off). Visual rows became the
    vertical coordinate everywhere; see Architecture above for the model, the
    `RowBreak` algorithm, and caret affinity. Verified in the running app:
    word-boundary breaks, token colours clipped across a break, gutter numbers
    only on first rows, row-based Up/Down (lands on the continuation row's start
    column), End honouring affinity, selection across a wrap boundary (incl. the
    trailing-newline marker on a line's last row), re-flow on window resize, and
    re-flow + undo on edit. Wrap-off was re-verified unchanged (h-scrollbar,
    horizontal scroll, find bar).

11. ✅ **Goal-column memory** for vertical movement (`FDesiredX`; see the word
    wrap section above). Verified in both modes: Col 57 → down through short
    lines (clamps to Col 9) → back up restores Col 57; a horizontal move
    re-anchors it (Col 55 stays Col 55); holds across wrapped rows.

12. ✅ **Highlight-all find matches** (see find/replace above). Verified: live
    tinting as the term is typed into the find bar, the current match still
    distinct (bright `FindMatchColor` over the weak tint), Esc/Close clearing the
    highlights, and — with wrap on — a match straddling a row break painting as
    two rects on consecutive rows.

13. ✅ **Markers** (`AddMarker` / `MarkLine` / `MarkWordAt`; see Architecture).
    Built for showing Antimony parse errors. Verified: whole-line tint, a red
    squiggle under a word, a second squiggle in another colour, and markers
    clearing on the first keystroke. Note Antimony reports a position **inside a
    quoted sub-expression**, not a line column — hence `LineText`, so the host
    can `Pos()` the sub-expression within the line and add the offset.

14. ✅ **Marker tooltips** — own-drawn, multi-line, per-run colour + bold, on a
    500 ms hover dwell (see Architecture). Confirmed on-device by the user:
    hovering the squiggle shows the coloured multi-line tip. Note the automated
    SendKeys/`SetCursorPos` harness did **not** reproduce the hover (a synthetic
    cursor warp doesn't drive it the way a real pointer does) — drive tooltips by
    hand, or move the cursor in small steps, when verifying.

15. ✅ **Modified flag + `OnChange`.** `FModified` is raised in `AfterEdit` (the
    single mutation tail, so undo/redo count too) and cleared in `SetText`;
    `OnChange` fires from the same spot but **not** from `SetText` (load isn't an
    "edit"). Simple policy — undo does not clear `Modified` (matches `TMemo`).
    `Modified` is public (runtime state, not a design property); `OnChange` is
    published. The demo's `OnCloseQuery` is the single save-prompt gatekeeper
    (the Quit menu just calls `Close`), so the window's X button and the menu
    share one path. Because `TDialogService` is async, `OnCloseQuery` sets
    `CanClose := False`, prompts, and re-closes from the callback via
    `TThread.ForceQueue` (deferring the `Close` past the modal stack — a direct
    re-entrant `Close` can crash). Verified: type → native Yes/No/Cancel dialog
    on both X-button and Quit; Cancel keeps it open; No closes; unmodified quits
    with no prompt.

16. ✅ **Current-line highlight** (`HighlightCurrentLine`, default **off**;
    `CurrentLineColor`). Faint full-width band behind the caret's logical line
    (all wrapped rows), painted first so everything sits on top. `PaintCurrentLine`
    reads `FCaret.Line` and every caret move already repaints, so it follows for
    free. Off by default — the user finds always-on line highlight distracting.

17. ✅ **"N of M" find counter + bracket matching.**
    - Counter: `CountMatches(term, opts, out N): M` scans the whole doc (the one
      deliberately non-lazy find op — O(doc), but only per term/options change or
      Next/Prev, not per paint). `PushFindCount` feeds the bar's new
      `SetMatchInfo`; `DoNext`/`DoPrev` no longer set 'Found'/'Not found' (would
      clobber it). Verified deterministically (`1 of 7` for `S1` in the sample);
      the live find-bar "N of M" display confirmed by the user.
    - Bracket matching (`BracketMatching`, default **on**; `BracketMatchColor`):
      `UpdateBracketMatch` (from `ResetCaretBlink`) picks the bracket before/at the
      caret and scans for its partner via `NextCharPos`, counting same-type nesting,
      capped at 20k chars. `PaintBracketMatch` strokes a box round each. **Naive**:
      does not skip brackets in strings/comments (would need tokenizer semantics).
      Verified: `(X0 - S1/Keq1)` pair boxed, nothing else.

18. ✅ **Comment toggle + context menu.**
    - `ToggleLineComment` (public; **Ctrl/Cmd+/**, `vkSlash`/`vkDivide` in the
      `Cmd` case block). Acts on the selected lines (or caret line). Comments if
      any target line is uncommented, else uncomments. Prefix inserted at **column
      0** (flush left; **not** indented — a column-0 marker gives a clean left rail
      so you can scan at a glance what's commented vs live, which is the whole point
      of block-commenting; indented markers dissolve into the code's indentation).
      + a trailing space; the line's indentation is preserved after the marker, so
      uncomment (strip prefix + one optional space) restores it. Blank lines
      commented too (empty line => bare marker, no trailing space, so round-trip
      stays exact); selection preserved, **one undo step** via a single `ApplyReplace` over the
      whole line range. The prefix comes from `LineCommentPrefix` (published), or
      falls back to `TSimpleHighlighter.LineComment` (new accessor = first
      configured line comment) so `Highlighter.UsePython` makes it just work.
      Verified deterministically: comment→uncomment round-trips to the original,
      indentation + blank-line skip + col-0 line all correct.
    - Context menu (`BuiltInContextMenu`, default **on**): right-click builds a
      lazy `TPopupMenu` (Cut/Copy/Paste/Select All/Toggle Comment), Tag-dispatched
      via `ContextItemClick`, enabled-state refreshed in `UpdateContextMenuState`
      before `Popup`. A host-assigned `TControl.PopupMenu` wins over the built-in.
      The one deliberate **native** widget (a context menu isn't text layout, so
      it's outside the "no native presenter" rule). `FContextMenu.Stored := False`
      so it never streams into the `.fmx`. My private show method is
      `PopupContextMenu` (renamed off `ShowContextMenu` to avoid hiding
      `TControl`'s virtual). Popup itself not screenshot-verified — foreground
      stealing blocked the synthetic right-click — but wiring compiles and the
      toggle it calls is verified.

19. ✅ **Design-time `Lines: TStrings` property.** Content can now be set in the
    Object Inspector (standard multi-line string editor) and streams into the
    `.fmx`, not only via the runtime-only `SetText`. It's a **facade over the
    document, not the master copy** — `FLines` stays authoritative. `GetLines`
    rebuilds an internal `FLinesProxy: TStringList` from `FLines` on read
    (guarded by `FSyncingLines` + `BeginUpdate` so the rebuild never re-enters
    the edit path); the proxy's `OnChange` funnels OI/host edits back through
    `SetTextFromProxy` → `SetText`. Runtime typing is untouched (still the
    `ApplyReplace` fast path); reading `Lines` is the only O(lines) op and it's
    on-demand. **Streamed loads apply once in `Loaded`, not per line**:
    `LinesProxyChanged` early-outs while `csLoading`, and `Loaded` calls
    `SetTextFromProxy` once (skipped when the proxy is empty). `SetTextFromProxy`
    joins with `#10` and **no trailing newline** — the proxy has exactly one
    entry per document line, so `TStrings.Text` (trailing break) would grow the
    doc by a blank line each round-trip. Verified: clean build, app launches
    (Loaded path runs on the demo form), no runtime-edit regression.

⚠️ **GUI keystroke automation was unreliable this session** (SendKeys not
reaching the FMX window despite AttachThreadInput — environmental focus-stealing).
Both features were verified *deterministically* instead: drive the feature from a
temp hook (`FindNext`, `GoToLine`, `CountMatches`) and read the result from the
title bar / a zoomed `PrintWindow` shot, rather than synthesising keypresses.

## Conventions

- Object Pascal, FMX. Target Windows + macOS; every feature must behave
  identically on both — if it can't, the approach is suspect.
- 0-based line and column indices internally; gutter displays 1-based.
- Prefer lazy work: tokenize and lay out only visible lines.
- Keep the tokenizer contract pure and per-line so re-tokenizing one edited
  line stays cheap.
- Watch `Copy()` (1-based) vs the 0-based `StartCol` when slicing runs — the
  `+1` offsets in `PaintLine` are load-bearing.

## Build

Delphi 13 = RAD Studio 37.0. Skia enabled (`System.Skia` + `FMX.Skia`).

**In the IDE:** open `Packages/RhoFMXEditorGroup.groupproj` — a project group of
the runtime package, the design package, and the demo (in that order, which is
also the required build order: the design package needs the runtime `.dcp`).
The component registers on the **`Rhody Controls`** palette page. Editing the
component units and pressing F9 on the demo recompiles them straight in (the
demo links `..\Source` statically, so no package rebuild is needed for the dev
loop; reinstall the design package only to refresh design-time behaviour).

**Command line — demo** (from `Demo/`; `rsvars.bat` works even non-interactively):

```
& "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\rsvars.bat"
msbuild SkiaCodeEditorDemo.dproj /t:Build /p:Config=Debug /p:Platform=Win64
```

Output: `Demo\Win64\Debug\SkiaCodeEditorDemo.exe`.

**Command line — packages** now have IDE-generated `.dproj` files, so msbuild
them (Win32 — the IDE loads only 32-bit design packages; runtime package first):

```
msbuild Packages\SkiaCodeEditor.dproj    /t:Build /p:Config=Debug /p:Platform=Win32
msbuild Packages\dclSkiaCodeEditor.dproj /t:Build /p:Config=Debug /p:Platform=Win32
```

⚠️ A package msbuild fails with `F2039: Could not create output file ...bpl`
when the **IDE is running with the design package installed** — it holds the
`.bpl` open. That is a file lock, not a project error; close the IDE (or
uninstall the package) to build from the shell.

## Working notes (read before changing things)

- **Verify in the running app, not just the build.** Launch the exe and drive it
  with SendKeys + screenshot from PowerShell (enumerate the process's visible
  top-level window; call `SetProcessDPIAware()` or coords are wrong on this
  multi-monitor box). To check a feature, add a clearly-marked `// TEMP` hook,
  screenshot, then remove it. FMX `TDialogService.InputQuery` centers on the
  **primary monitor**, not the window.
- **`Demo/ufMain.pas` is the user's live test harness** — they actively edit it
  (menus, file open/save, Antimony sample, theme, multi-line string literals).
  **Do not modify or revert it unless asked.** When a feature needs a demo change, make the
  smallest addition and remove any temp code exactly.
- **"Batteries included, overridable"** is the house style: ship a working default
  the host can replace — highlighter via the `Highlighter` property; find UI via
  `BuiltInFindUI` / `OnRequestFind`. A new optional subsystem gets its **own unit**
  wired via callbacks (or a small interface), with shared types in
  `uCodeEditorTypes`, so the editor never has a circular dependency on it.
- **All text mutation must funnel through `ApplyReplace`** (which records undo and
  triggers `RetokenizeAfterEdit`). The only raw mutators are `DeleteRangeRaw` /
  `InsertRaw`; never touch `FLines` outside them.
- Each color/font/display property is a **live setter** (repaints, or
  `ApplyFontChange` for metrics). A plain field-write silently does nothing —
  that was a real bug (font size). Keep them setters.
- **`FContent` is realigned *after* the editor's own `Resize` runs**, so inside
  `Resize` the paint box still reports its **previous** width. Anything that
  depends on the viewport width (i.e. word wrap) must hang off
  `FContent.OnResize` (`ContentResize`) instead. Wrapping computed in `Resize`
  silently lags one resize behind — it looks like "wrap just doesn't work".

## Possible next features (backlog)

- (all backlog visual features done — see build-order 16/17.)
- **LaTeX/TeX built-in support.** Add a `UseLaTeX` preset to `TSimpleHighlighter`
  (`%` line comments; no block comments; control sequences `\word` as the main
  token) plus a `LaTeXKeywords` list in `uLanguageKeywords.pas` (common commands /
  environments: `\begin`, `\end`, `\section`, `\documentclass`, `\usepackage`,
  `\item`, etc.). Fits the existing preset + keyword-list pattern; the user works
  in WinEdt, so this is a natural target. Note the tokenizer keys off identifier
  chars `[A-Za-z_]` — TeX control words start with `\`, so highlighting `\command`
  as a unit may need a small lexer tweak (treat a leading `\` + letters as one
  token) rather than just a keyword list.
- Word-wrap follow-up: `UpdateContentSize` is still O(lines) per edit (fine at
  current scale, but the `FirstRow` running sum is what a production impl would
  maintain incrementally).

## Non-goals

- Not a `TMemo` replacement API-wise; it's a purpose-built editor surface.
- No RTF, no rich embedded objects — plain text + token colors only.
- **CJK / non-Latin glyph fallback: deliberately not done.** The target is a
  Latin/US code editor; accented Latin, typographic punctuation, arrows, etc.
  are all covered by the single primary font (Consolas / Menlo). Rendering CJK
  or emoji would need a font-run-aware rewrite of the measurement/paint spine
  (`MeasureRange`/`PaintRow`/`XToColInRow`) plus a named fallback list — Skia's
  Delphi binding has no font manager for automatic matching — which isn't worth
  the caret-drift risk for glyphs this audience won't type. CJK renders as tofu;
  that's accepted, not a bug. The design is additive if the need ever arises
  (fallback list + `UnicharToGlyph`-driven run splitting; keep the monospace
  fast path for pure-primary lines). IME committed text still inserts via the
  normal `KeyChar` path, so Latin/Option-key input is unaffected.
