unit uFindBar;

{
  TFindBar -- a self-contained find/replace bar for the Skia code editor.

  It knows nothing about the editor type: the host wires the callbacks (find
  next / prev / replace / replace all, plus OnSearchChanged for live
  highlight-all and OnClosed) and the bar drives them, so there is no circular
  dependency on uSkiaCodeEditor. TSkiaCodeEditor owns one of these lazily when
  its BuiltInFindUI flag is on; a host that wants its own UI turns the flag off
  and handles OnRequestFind instead.

  Docked style: the bar is TAlignLayout.Top on the editor, so showing it shifts
  the text down; hiding it gives the space back.
}

interface

uses
  System.SysUtils, System.Classes, System.UITypes,
  FMX.Types, FMX.Controls, FMX.Graphics, FMX.Objects, FMX.Edit, FMX.StdCtrls,
  uCodeEditorTypes;

type
  TFindFunc = reference to function(const ASearch: string;
    AOptions: TFindOptions): Boolean;
  TReplaceFunc = reference to function(const ASearch, AReplace: string;
    AOptions: TFindOptions): Boolean;
  TReplaceAllFunc = reference to function(const ASearch, AReplace: string;
    AOptions: TFindOptions): Integer;
  // Fired whenever the search term or its options change, so the host can
  // highlight matches live as the user types (rather than only on Next/Prev).
  TSearchChangedProc = reference to procedure(const ASearch: string;
    AOptions: TFindOptions);

  TFindBar = class(TRectangle)
  private
    FSearch: TEdit;
    FReplace: TEdit;
    FMatchCase: TCheckBox;
    FWholeWord: TCheckBox;
    FStatus: TLabel;
    FOnFindNext: TFindFunc;
    FOnFindPrev: TFindFunc;
    FOnReplace: TReplaceFunc;
    FOnReplaceAll: TReplaceAllFunc;
    FOnClosed: TProc;
    FOnSearchChanged: TSearchChangedProc;
    function Options: TFindOptions;
    procedure SearchChanged(Sender: TObject);
    procedure DoNext(Sender: TObject);
    procedure DoPrev(Sender: TObject);
    procedure DoReplace(Sender: TObject);
    procedure DoReplaceAll(Sender: TObject);
    procedure DoClose(Sender: TObject);
    procedure SearchKeyDown(Sender: TObject; var Key: Word;
      var KeyChar: WideChar; Shift: TShiftState);
  public
    constructor Create(AOwner: TComponent); override;
    // Show, seed the search box (e.g. with the current selection) and focus it.
    procedure Activate(const ASeed: string);
    // Tint the bar to match the editor theme.
    procedure ApplyTheme(ABarColor, ATextColor: TAlphaColor);
    // Host pushes the "N of M" match count into the status label. ATotal < 0
    // blanks it; ATotal = 0 shows "No matches"; ACurrent = 0 shows "M matches".
    procedure SetMatchInfo(ACurrent, ATotal: Integer);

    property OnFindNext: TFindFunc read FOnFindNext write FOnFindNext;
    property OnFindPrev: TFindFunc read FOnFindPrev write FOnFindPrev;
    property OnReplace: TReplaceFunc read FOnReplace write FOnReplace;
    property OnReplaceAll: TReplaceAllFunc read FOnReplaceAll write FOnReplaceAll;
    property OnClosed: TProc read FOnClosed write FOnClosed;
    property OnSearchChanged: TSearchChangedProc read FOnSearchChanged
      write FOnSearchChanged;
  end;

implementation

{ TFindBar }

constructor TFindBar.Create(AOwner: TComponent);

  function MakeButton(const ACaption: string; AX, AY, AW: Single;
    AClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Self;
    Result.Text := ACaption;
    Result.SetBounds(AX, AY, AW, 28);
    Result.OnClick := AClick;
  end;

  function MakeCheck(const ACaption: string; AX, AY: Single): TCheckBox;
  begin
    Result := TCheckBox.Create(Self);
    Result.Parent := Self;
    Result.Text := ACaption;
    Result.SetBounds(AX, AY, 110, 22);
  end;

begin
  inherited Create(AOwner);
  Height := 80;
  Stroke.Kind := TBrushKind.None;
  Fill.Color := TAlphaColor($FF2D2D30);
  Visible := False;

  FSearch := TEdit.Create(Self);
  FSearch.Parent := Self;
  FSearch.SetBounds(10, 8, 240, 28);
  FSearch.TextPrompt := 'Find';
  FSearch.OnKeyDown := SearchKeyDown;
  FSearch.OnChangeTracking := SearchChanged;   // highlight live, per keystroke

  MakeButton('Next', 258, 8, 66, DoNext);
  MakeButton('Prev', 328, 8, 66, DoPrev);
  FMatchCase := MakeCheck('Match case', 404, 11);
  FMatchCase.OnChange := SearchChanged;        // options change the match set

  FReplace := TEdit.Create(Self);
  FReplace.Parent := Self;
  FReplace.SetBounds(10, 44, 240, 28);
  FReplace.TextPrompt := 'Replace with';

  MakeButton('Replace', 258, 44, 66, DoReplace);
  MakeButton('Replace All', 328, 44, 100, DoReplaceAll);
  FWholeWord := MakeCheck('Whole word', 438, 47);
  FWholeWord.OnChange := SearchChanged;

  MakeButton('Close', 500, 8, 70, DoClose);

  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.SetBounds(540, 46, 180, 24);
  FStatus.StyledSettings := [];
  FStatus.TextSettings.FontColor := TAlphaColors.Silver;
end;

procedure TFindBar.Activate(const ASeed: string);
begin
  Visible := True;
  if ASeed <> '' then
    FSearch.Text := ASeed;
  FStatus.Text := '';
  FSearch.SelectAll;
  FSearch.SetFocus;
  SearchChanged(nil);   // re-highlight for whatever term the box now holds
end;

procedure TFindBar.ApplyTheme(ABarColor, ATextColor: TAlphaColor);

  procedure Tint(ACheck: TCheckBox);
  begin
    ACheck.StyledSettings := ACheck.StyledSettings - [TStyledSetting.FontColor];
    ACheck.TextSettings.FontColor := ATextColor;
  end;

begin
  Fill.Color := ABarColor;
  FStatus.TextSettings.FontColor := ATextColor;
  Tint(FMatchCase);
  Tint(FWholeWord);
end;

procedure TFindBar.SearchChanged(Sender: TObject);
begin
  if Assigned(FOnSearchChanged) then
    FOnSearchChanged(FSearch.Text, Options);
end;

function TFindBar.Options: TFindOptions;
begin
  Result := [foWrapAround];
  if FMatchCase.IsChecked then
    Include(Result, foMatchCase);
  if FWholeWord.IsChecked then
    Include(Result, foWholeWord);
end;

procedure TFindBar.DoNext(Sender: TObject);
begin
  // The host's find method updates the status via SetMatchInfo ("N of M"), so
  // we don't set 'Found'/'Not found' here -- that would clobber the count.
  if Assigned(FOnFindNext) then
    FOnFindNext(FSearch.Text, Options);
end;

procedure TFindBar.DoPrev(Sender: TObject);
begin
  if Assigned(FOnFindPrev) then
    FOnFindPrev(FSearch.Text, Options);
end;

procedure TFindBar.SetMatchInfo(ACurrent, ATotal: Integer);
begin
  // Host pushes the document-wide match count here. ATotal < 0 clears it.
  if ATotal < 0 then
    FStatus.Text := ''
  else if ATotal = 0 then
    FStatus.Text := 'No matches'
  else if ACurrent > 0 then
    FStatus.Text := Format('%d of %d', [ACurrent, ATotal])
  else
    FStatus.Text := Format('%d matches', [ATotal]);
end;

procedure TFindBar.DoReplace(Sender: TObject);
begin
  if Assigned(FOnReplace) then
    FOnReplace(FSearch.Text, FReplace.Text, Options);
end;

procedure TFindBar.DoReplaceAll(Sender: TObject);
begin
  if Assigned(FOnReplaceAll) then
    FStatus.Text := Format('%d replaced',
      [FOnReplaceAll(FSearch.Text, FReplace.Text, Options)]);
end;

procedure TFindBar.DoClose(Sender: TObject);
begin
  Visible := False;
  if Assigned(FOnClosed) then
    FOnClosed();
end;

procedure TFindBar.SearchKeyDown(Sender: TObject; var Key: Word;
  var KeyChar: WideChar; Shift: TShiftState);
begin
  if Key = vkReturn then
  begin
    DoNext(Sender);
    Key := 0;
  end
  else if Key = vkEscape then
  begin
    DoClose(Sender);
    Key := 0;
  end;
end;

end.
