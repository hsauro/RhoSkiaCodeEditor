# TSkiaCodeEditor

An owner-drawn, Skia-backed code editor control for **FireMonkey (FMX) / Delphi**.
A memo-like control with a line-number gutter, pluggable syntax highlighting,
find/replace, word wrap, and error markers — that behaves **identically on
Windows and macOS**.

## Why it exists

FMX's `TMemo` routes through **different presenters per OS**: the FMX-drawn
styled presenter on Windows, and a native `NSTextView` on macOS. Per-character
colouring, gutter alignment, and caret arithmetic tuned on one platform silently
diverge on the other, because the underlying text layout and metrics engines are
not the same. No amount of patching unifies them.

`TSkiaCodeEditor` removes the native presenter from the loop. **Every glyph is
measured and drawn with Skia**, so there is one paint path and one set of
metrics on every platform. Text layout never touches `TTextLayout`,
`Canvas.MeasureText`, or native text services.

## Features

- **Skia rendering** — one paint path, identical metrics on Windows and macOS.
- **Pluggable syntax highlighting** — a pure, per-line tokenizer
  `(text, stateIn) -> (runs, stateOut)`. Lex state flows line to line, so
  multi-line constructs (block comments) work. A ready-made `TSimpleHighlighter`
  ships with Pascal, C-like, and Antimony presets.
- **Word wrap** — optional; off by default so the fast no-wrap path stays default.
- **Editing** — full keyboard editing, selection (shift/drag/double-click word),
  clipboard, and undo/redo with typing coalesced into sensible steps.
- **Find / replace** — with a built-in docked find bar, highlight-all matches,
  match case, and whole word. Or supply your own UI.
- **Markers** — host-owned annotations for parser errors: whole-line tints or
  wavy underlines, with **own-drawn multi-line, per-run-coloured tooltips** on
  hover.
- **Owned scrolling** — real scrollbars, not a `TScrollBox` (whose overlay
  scrollbars and inertia differ between Windows and macOS).
- **Lazy work** — only visible rows are ever laid out or tokenized.

## Requirements

- RAD Studio / Delphi **12 or later** (developed against Delphi 13 / BDS 37.0).
- **Skia**, which ships with RAD Studio — no external Skia4Delphi dependency.
  Enable it for your application: *Project > Options > Application > Skia* →
  **Enable Skia**.

## Installation

1. Open `Packages\SkiaCodeEditor.dpk` and **Build** it (this is the runtime
   package; build it for every platform you target).
2. Open `Packages\dclSkiaCodeEditor.dpk` and **Install** it. Design-time
   packages are loaded by the IDE, which is a 32-bit process — build this one
   for **Win32** regardless of what your application targets.
3. Add the `Source` folder to your project's *Library path* (or its unit search
   path) so the compiler can find the units.

`TSkiaCodeEditor` then appears on the **Skia** palette page, for FireMonkey
forms only.

You can also skip packages entirely and just add the four units from `Source`
to your project — the component works fine constructed in code.

## Quick start

```pascal
uses uSkiaCodeEditor;

Editor := TSkiaCodeEditor.Create(Self);
Editor.Parent := Self;
Editor.Align := TAlignLayout.Client;

// Batteries included: pick a comment/string style and add keywords.
Editor.Highlighter.UseAntimony;
Editor.Highlighter.AddKeywords(['species', 'compartment', 'model', 'end']);

Editor.WordWrap := True;
Editor.SetText(TFile.ReadAllText('model.txt'));
```

Ctrl/Cmd+F opens the built-in find bar; Ctrl/Cmd+G fires `OnRequestGotoLine` so
the host can prompt for a line number (the control never pops dialogs itself).

## Showing parser errors

Markers are purely visual — they never move the caret or the selection, so you
can annotate a document without disturbing the user. All line and column
arguments are **1-based**, matching `CaretLine` / `CaretColumn` / `GoToLine`.

```pascal
Editor.ClearMarkers;

// Squiggle the offending token, with a rich multi-line tooltip.
Editor.MarkWordAt(10, Col, mkSquiggle, TAlphaColors.Red,
  Tip([ TipLine([TipRun('Error', TAlphaColors.Red, True),
                 TipRun(' in reaction rate "k9*S0S1"')]),
        TipLine([TipRun('  syntax error, unexpected element name')]) ]));

// Or tint a whole line when you only have a line number.
Editor.MarkLine(12, mkTint, $30FF0000, 'unused species');
```

A plain `string` message works too — it becomes one default-coloured tooltip
line per `#10`. Markers clear on the next edit (`MarkersClearOnEdit`), since
they describe text that just changed.

If your parser reports a position **inside a sub-expression** rather than a
column in the line — as Antimony does — use `LineText` to map it:

```pascal
P := Pos('k9*S0 S1', Editor.LineText(10));
if P > 0 then
  Editor.MarkWordAt(10, P + PosInExpr - 1, mkSquiggle, TAlphaColors.Red, ErrText);
```

## Layout

| Folder      | Contents |
|-------------|----------|
| `Source`    | The component. Add this to your library path. |
| `Packages`  | Runtime (`SkiaCodeEditor`) and design-time (`dclSkiaCodeEditor`) packages. |
| `Demo`      | A working host application: theming, file open/save, go-to-line, status bar. |

`Source` units:

- `uCodeEditorTypes.pas` — shared token, marker, and tooltip types. Its own unit
  so the editor and highlighters can both use it with no circular dependency.
- `uSkiaCodeEditor.pas` — the control.
- `uSyntaxHighlighter.pas` — `TSimpleHighlighter`, a configurable tokenizer.
- `uFindBar.pas` — `TFindBar`, the built-in docked find/replace bar.
- `uSkiaCodeEditorReg.pas` — design-time registration only.

## Design notes

**Batteries included, overridable.** Every subsystem ships a working default the
host can replace: the highlighter via the `Highlighter` property or
`SetTokenizer`; the find UI via `BuiltInFindUI` / `OnRequestFind`.

**Visual rows, not logical lines.** With word wrap on, one line may occupy
several visual rows. Rows are the vertical coordinate everywhere — and with wrap
off, every line is exactly one row, so there is no second code path.

**Tooltips are drawn with Skia**, not FMX `Hint`. A native hint service can do
neither multi-line nor per-run colour, and renders through different machinery
on each OS — the very divergence this component exists to avoid.

## Status

Windows: developed and tested. macOS: the design is platform-neutral by
construction, but the IME composition path and CJK font fallback have not been
exercised on real hardware.

## Licence

MIT — see [LICENSE](LICENSE).
