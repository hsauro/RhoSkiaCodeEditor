unit ufMain;

interface

uses
  System.SysUtils,
  System.Types,
  System.UIConsts,
  System.UITypes,
  System.Classes,
  System.Variants,
  FMX.Types,
  FMX.Controls,
  FMX.Forms,
  FMX.Graphics,
  FMX.Dialogs,
  FMX.StdCtrls,
  FMX.Edit,
  FMX.DialogService,
  uSkiaCodeEditor,
  FMX.Menus, IOUtils, uLipsumGenerator, FMX.Layouts,
  FMX.Controls.Presentation,
  FMX.Objects,
  uFeatherIcons, System.Skia, FMX.Skia, System.ImageList,
  FMX.ImgList;

type
  TfrmMain = class(TForm)
    MainMenu1: TMainMenu;
    mnuFIle: TMenuItem;
    mnuLoad1: TMenuItem;
    mnuCreate: TMenuItem;
    mnuOpen: TMenuItem;
    Layout1: TLayout;
    Rectangle1: TRectangle;
    btnOpen: TSpeedButton;
    btnSave: TSpeedButton;
    btnNew: TSpeedButton;
    mnuNew: TMenuItem;
    mnuSave: TMenuItem;
    mnuSaveAs: TMenuItem;
    btnSaveAs: TSpeedButton;
    MenuItem1: TMenuItem;
    MenuItem2: TMenuItem;
    mnuQuit: TMenuItem;
    ImageList1: TImageList;
    mnuEdit: TMenuItem;
    mnuUndo: TMenuItem;
    MenuItem4: TMenuItem;
    mnuCut: TMenuItem;
    mnuCopy: TMenuItem;
    mnuPaste: TMenuItem;
    MenuItem8: TMenuItem;
    mnuSelectAll: TMenuItem;
    mnuFind: TMenuItem;
    mnuDelete: TMenuItem;
    mnuFormat: TMenuItem;
    mnuWordWrap: TMenuItem;
    StyleBook1: TStyleBook;
    mnuHelp: TMenuItem;
    mnuAbout: TMenuItem;
    SkiaCodeEditor1: TSkiaCodeEditor;
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure mnuLoad1Click(Sender: TObject);
    procedure mnuCreateClick(Sender: TObject);
    procedure mnuOpenClick(Sender: TObject);
    procedure btnNewClick(Sender: TObject);
    procedure btnOpenClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure mnuNewClick(Sender: TObject);
    procedure mnuSaveClick(Sender: TObject);
    procedure mnuSaveAsClick(Sender: TObject);
    procedure btnSaveAsClick(Sender: TObject);
    procedure mnuQuitClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure mnuWordWrapClick(Sender: TObject);
    procedure mnuCutClick(Sender: TObject);
    procedure mnuCopyClick(Sender: TObject);
    procedure mnuPasteClick(Sender: TObject);
    procedure mnuUndoClick(Sender: TObject);
    procedure mnuSelectAllClick(Sender: TObject);
    procedure mnuFindClick(Sender: TObject);
    procedure mnuDeleteClick(Sender: TObject);
    procedure mnuAboutClick(Sender: TObject);
  private
    FEditor: TSkiaCodeEditor;
    FStatusBar: TRectangle;
    FStatus: TLabel;
    FFileLabel: TLabel;   // current file name, shown in-app (title bar is unreliable on macOS)
    CurrentFileName : String;
    CurrentPath : String;
    UnTitledFileNameCount : Integer;
    HomeIconSVGPathData : String;
    FForceClose : Boolean;   // set once the save prompt has been resolved
    procedure UpdateStatus;
    procedure EditorCaretChange(Sender: TObject);
    procedure EditorRequestGotoLine(Sender: TObject);
    function  GetUntitledFilename : String;
    procedure SetCurrentFileNameAndPath (FileName, Path : String);
  public
    { Public declarations }
    procedure NewDocument;
    procedure OpenDocument;
    procedure SaveDocument (FileName : String);
    procedure SaveAsDocument (FileName : String);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.fmx}

const
   ExampleText =
    'unit Demo;'#10 +
    ''#10 +
    '{ This is a block comment'#10 +
    '  that spans several lines,'#10 +
    '  to show multi-line lexing }'#10 +
    ''#10 +
    'interface'#10 +
    ''#10 +
    'procedure Hello;'#10 +
    'procedure ThisIsADeliberatelyVeryLongLineToForceTheHorizontalScrollBarToAppearAcrossTheViewport;'#10 +
    ''#10 +
    'implementation'#10 +
    ''#10 +
    'procedure Hello;'#10 +
    'begin'#10 +
    '  // a Skia-drawn code editor'#10 +
    '  Writeln(''Hello, world'');'#10 +
    'end;'#10 +
    ''#10 +
    'procedure Counting;'#10 +
    'var i: Integer;'#10 +
    'begin'#10 +
    '  for i := 1 to 40 do'#10 +
    '    Writeln(i);'#10 +
    'end;'#10 +
    ''#10 +
    '// line 23'#10 + '// line 24'#10 + '// line 25'#10 + '// line 26'#10 +
    '// line 27'#10 + '// line 28'#10 + '// line 29'#10 + '// line 30'#10 +
    '// line 31'#10 + '// line 32'#10 + '// line 33'#10 + '// line 34'#10 +
    ''#10 +
    'end.';


procedure TfrmMain.NewDocument;
begin
  FEditor.Settext ('');
  SetCurrentFileNameAndPath(GetUntitledFilename, CurrentPath);
end;


procedure TfrmMain.OpenDocument;
var OpenDialog: TOpenDialog;
begin
  OpenDialog := TOpenDialog.Create(nil);
  try
    OpenDialog.Title := 'Select a Text File';
    // Filter is Windows-only here. On macOS NSOpenPanel greys out every file
    // that doesn't match the active filter's extensions, "*.*" is NOT "all
    // files" (it matches nothing), and the default filter is the FIRST entry
    // (*.txt) with no reliable dropdown to switch it -- so a Windows-style
    // filter leaves all files unselectable. An empty filter = allow any file.
    {$IFDEF MSWINDOWS}
    OpenDialog.Filter := 'Text files (*.txt)|*.txt|All files (*.*)|*.*';
    {$ENDIF}

    // 3. Execute and load the file if successful
    if OpenDialog.Execute then
    begin
      FEditor.SetText(TFile.ReadAllText(OpenDialog.FileName));
      SetCurrentFileNameAndPath(ExtractFileName(OpenDialog.FileName), ExtractFilePath(OpenDialog.FileName));
    end;

  finally
    // 4. Free the memory immediately after use
    OpenDialog.Free;
  end;
end;


procedure TfrmMain.SaveDocument (FileName : String);
begin
   TFile.WriteAllText(IOUtils.TPath.Combine(CurrentPath, FileName), FEditor.GetText);
   FEditor.Modified := False;   // on disk now => no longer dirty
end;


procedure TfrmMain.SaveAsDocument (FileName : String);
var
  SaveDialog: TSaveDialog;
begin
  // 1. Create the dialog dynamically in memory
  SaveDialog := TSaveDialog.Create(Self);
  try
    // 2. Configure the dialog options
   {$IFDEF MSWINDOWS}
    SaveDialog.Filter := 'Text Files|*.txt;*.log|All Files|*.*';
   {$ENDIF}
    SaveDialog.Title := 'Save Text File As';
    SaveDialog.DefaultExt := 'txt'; // Appends extension if user omits it

    // 3. Execute the dialog and save the file
    if SaveDialog.Execute then
    begin
      TFile.WriteAllText(SaveDialog.FileName, FEditor.GetText);
      CurrentFileName := ExtractFileName(SaveDialog.FileName);
      SetCurrentFileNameAndPath (CurrentFileName, ExtractFilePath(SaveDialog.FileName));
      FEditor.Modified := False;   // on disk now => no longer dirty
    end;
  finally
    // 4. Free the memory safely
    SaveDialog.Free;
  end;
end;


function TfrmMain.GetUntitledFilename : String;
begin
  Inc (UnTitledFileNameCount);
  result := 'Untitled-' + Inttostr (UnTitledFileNameCount) + '.txt';
end;


procedure TfrmMain.SetCurrentFileNameAndPath (FileName, Path :String);
begin
  Caption := FileName + ' - ' + 'Skia Memo Editor';   // Windows title bar
  CurrentFileName := FileName;
  CurrentPath := Path;
  // In-app filename display: the macOS window title doesn't reliably show a
  // runtime Caption, so we own the pixels. Guarded because the first call
  // happens in FormCreate before the status bar exists.
  if Assigned(FFileLabel) then
    FFileLabel.Text := FileName;
end;

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  UnTitledFileNameCount := 0;
  OnCloseQuery := FormCloseQuery;   // one gatekeeper for the X button and Quit

  SetCurrentFileNameAndPath (GetUntitledFilename, IOUtils.TPath.GetDocumentsPath);

  // Status bar along the bottom (a coloured rectangle with a label on it).
  FStatusBar := TRectangle.Create(Self);
  FStatusBar.Parent := Self;
  FStatusBar.Align := TAlignLayout.Bottom;
  FStatusBar.Height := 26;
  FStatusBar.Fill.Color := $FF007ACC;
  FStatusBar.Stroke.Kind := TBrushKind.None;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := FStatusBar;
  FStatus.Align := TAlignLayout.Left;
  FStatus.Width := 168;
  FStatus.StyledSettings := [];   // take full control of font/colour
  FStatus.TextSettings.FontColor := TAlphaColors.White;
  FStatus.TextSettings.Font.Size := 13;
  FStatus.TextSettings.HorzAlign := TTextAlign.Leading;
  FStatus.Margins.Left := 10;

  // Current file name, right-aligned opposite the Ln/Col readout. Fills the
  // rest of the bar, so it works the same on Windows and macOS.
  FFileLabel := TLabel.Create(Self);
  FFileLabel.Parent := FStatusBar;
  FFileLabel.Align := TAlignLayout.Client;
  FFileLabel.StyledSettings := [];
  FFileLabel.TextSettings.FontColor := TAlphaColors.White;
  FFileLabel.TextSettings.Font.Size := 13;
  FFileLabel.TextSettings.HorzAlign := TTextAlign.Trailing;
  FFileLabel.Margins.Right := 12;
  FFileLabel.Text := CurrentFileName;   // seed with the name set above

  FEditor := TSkiaCodeEditor.Create(Self);
  FEditor.Parent := Self;
  FEditor.Align := TAlignLayout.Client;
  FEditor.OnCaretChange := EditorCaretChange;         // live status updates
  FEditor.OnRequestGotoLine := EditorRequestGotoLine; // Ctrl+G
  // Ctrl+F now uses the component's own built-in find bar (BuiltInFindUI is on
  // by default). To supply a custom UI instead, set BuiltInFindUI := False and
  // handle OnRequestFind.

  // Syntax highlighting is now a few lines: pick a comment/string style, add
  // keywords, and (optionally) tweak colours. No hand-written scanner.
  //FEditor.Highlighter.UseAntimony;
  //FEditor.Highlighter.AddKeywords(['species', 'compartment', 'model', 'end']);
  FEditor.Highlighter.UsePython;
  //FEditor.Highlighter.AddKeywords([
  //  'unit', 'interface', 'implementation', 'uses', 'procedure', 'function',
  //  'begin', 'end', 'var', 'const', 'type', 'if', 'then', 'else', 'for', 'to',
  //  'do', 'while', 'repeat', 'until', 'case', 'of', 'class', 'record',
   // 'string', 'integer']);

   FEditor.Highlighter.AddKeywords([
    'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await',
    'break', 'class', 'continue', 'def', 'del', 'elif', 'else', 'except',
    'finally', 'for', 'from', 'global', 'if', 'import', 'in', 'is',
    'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'try',
    'while', 'with', 'yield'
]);


  // Editor surface colours (ARGB). A VS Code-ish dark theme, paired with
  // matching token colours on the highlighter.
  FEditor.BackgroundColor := $FF1E1E1E;
  FEditor.TextColor       := $FFD4D4D4;
  FEditor.GutterColor     := $FF252526;
  FEditor.GutterTextColor := $FF858585;
  FEditor.CaretColor      := $FFAEAFAD;
  FEditor.SelectionColor  := $8099bce0;   // Original color $80264F78;
  FEditor.FindMatchColor  := $C0FFA500;   // prominent amber for find matches
  FEditor.Highlighter.KeywordColor := $FF569CD6;
  FEditor.Highlighter.StringColor  := $FFCE9178;
  FEditor.Highlighter.CommentColor := claLightblue;
  FEditor.Highlighter.NumberColor  := claCoral;

  FEditor.FontSize := 16;
  FEditor.SetText(ExampleText);
//  FEditor.SetText('''
//      // A negative-feeback oscillator
//      // I think this orginally came from a
//      // model by Athel Cornish-Bowden
//
//      // Reactions:
//      J0: $X0 => S1; VM1*(X0 - S1/Keq1)/(1 + X0 + S1 + S4^h)
//      J1: S1 => S2; (10*S1 - 2*S2)/(1 + S1 + S2)
//      J2: S2 => S3; (10*S2 - 2*S3)/(1 + S2 + S3)
//      J3: S3 => S4; (10*S3 - 2*S4)/(1 + S3 + S4)
//      J4: S4 => $X1; V4*S4/(KS4 + S4)
//
//      // Species initializations:
//      S1 = 0
//      S2 = 0
//      S3 = 0
//      S4 = 0
//      X0 = 10
//      X1 = 0
//
//      // Variable initializations:
//      VM1 = 10
//      Keq1 = 10
//      h = 10
//      V4 = 2.5
//      KS4 = 0.5;
//    ''');
  //FEditor.WordWrap := True;
end;

procedure TfrmMain.FormShow(Sender: TObject);
begin
  if FEditor.CanFocus then
    FEditor.SetFocus;
end;

procedure TfrmMain.UpdateStatus;
begin
  FStatus.Text := Format('Ln %d, Col %d     %d lines',
    [FEditor.CaretLine, FEditor.CaretColumn, FEditor.LineCount]);
end;

procedure TfrmMain.btnNewClick(Sender: TObject);
begin
  NewDocument;
end;

procedure TfrmMain.btnOpenClick(Sender: TObject);
begin
  OpenDocument;
end;

procedure TfrmMain.btnSaveAsClick(Sender: TObject);
begin
  SaveAsDocument(CurrentFileName);
end;

procedure TfrmMain.btnSaveClick(Sender: TObject);
begin
  SaveDocument(CurrentFileName);
end;

procedure TfrmMain.EditorCaretChange(Sender: TObject);
begin
  UpdateStatus;
end;

procedure TfrmMain.EditorRequestGotoLine(Sender: TObject);
begin
  // Ctrl+G -> prompt for a line number, then jump there.
  TDialogService.InputQuery('Go to line',
    ['Line (1..' + IntToStr(FEditor.LineCount) + ')'],
    [IntToStr(FEditor.CaretLine)],
    procedure(const AResult: TModalResult; const AValues: array of string)
    var
      N: Integer;
    begin
      if (AResult = mrOk) and (System.Length(AValues) > 0) and
         TryStrToInt(Trim(AValues[0]), N) then
        FEditor.GoToLine(N);
    end);
end;

procedure TfrmMain.mnuAboutClick(Sender: TObject);
begin
   Showmessage ('Sample Editor using FMXCodeEditor Control, version:' + FEditor.Version);
end;

procedure TfrmMain.mnuCopyClick(Sender: TObject);
begin
  FEditor.CopySelection;
end;

procedure TfrmMain.mnuCreateClick(Sender: TObject);
var lip : TLipsumGen;
begin
  Lip := TLipsumGen.Create;
  try
     FEditor.SetText(Lip.GenerateParagraph(2000));
  finally
    Lip.Free;
  end;
end;

procedure TfrmMain.mnuCutClick(Sender: TObject);
begin
  FEditor.CutSelection;
end;

procedure TfrmMain.mnuDeleteClick(Sender: TObject);
begin
  FEditor.DeleteSelection;
end;

procedure TfrmMain.mnuFindClick(Sender: TObject);
begin
  FEditor.ShowBuiltInFindBar;
end;

procedure TfrmMain.mnuLoad1Click(Sender: TObject);
begin
  FEditor.SetText(TFile.ReadAllText('text1.txt'));
end;

procedure TfrmMain.mnuNewClick(Sender: TObject);
begin
  NewDocument;
end;

procedure TfrmMain.mnuOpenClick(Sender: TObject);
begin
  OpenDocument;
end;

procedure TfrmMain.mnuPasteClick(Sender: TObject);
begin
  FEditor.PasteClipboard;
end;

procedure TfrmMain.mnuQuitClick(Sender: TObject);
begin
  Close;   // routes through FormCloseQuery -- the single save-prompt gatekeeper
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // Catches every exit path: the window's X button AND the Quit menu (which
  // just calls Close). Nothing unsaved, or the prompt already resolved => let
  // it close.
  if FForceClose or (not FEditor.Modified) then
  begin
    CanClose := True;
    Exit;
  end;

  // TDialogService is asynchronous, so we can't decide CanClose here: hold the
  // close, ask, and re-close from the callback. ForceQueue defers that Close to
  // the next message-loop turn, so it runs AFTER this OnCloseQuery/dialog stack
  // unwinds -- calling Close re-entrantly from inside a modal dialog can crash.
  CanClose := False;
  TDialogService.MessageDialog(
    Format('Save changes to "%s" before closing?', [CurrentFileName]),
    TMsgDlgType.mtConfirmation,
    [TMsgDlgBtn.mbYes, TMsgDlgBtn.mbNo, TMsgDlgBtn.mbCancel],
    TMsgDlgBtn.mbYes, 0,
    procedure(const AResult: TModalResult)
    begin
      if AResult = mrCancel then
        Exit;                                   // stay open
      if AResult = mrYes then
        SaveDocument(CurrentFileName);
      FForceClose := True;
      TThread.ForceQueue(nil, procedure begin Close; end);
    end);
end;

procedure TfrmMain.mnuSaveAsClick(Sender: TObject);
begin
  SaveAsDocument(CurrentFileName);
end;

procedure TfrmMain.mnuSaveClick(Sender: TObject);
begin
  SaveDocument(CurrentFileName);
end;

procedure TfrmMain.mnuSelectAllClick(Sender: TObject);
begin
  FEditor.SelectAll;
end;

procedure TfrmMain.mnuUndoClick(Sender: TObject);
begin
  FEditor.Undo;
end;

procedure TfrmMain.mnuWordWrapClick(Sender: TObject);
begin
  // The menu check is the source of truth -- it's what the user sees. AutoCheck
  // is off (see .fmx) so we flip the check ourselves here, deterministically,
  // then bring the editor in line with it.
  mnuWordWrap.IsChecked := not mnuWordWrap.IsChecked;
  FEditor.WordWrap := mnuWordWrap.IsChecked;
end;

end.
