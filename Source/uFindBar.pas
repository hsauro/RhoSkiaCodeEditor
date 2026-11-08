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

  ShowReplace := False makes it a one-row find bar (no replace box or
  buttons), for read-only hosts such as a markdown viewer.
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
    FNext, FPrev, FReplaceBtn, FReplaceAllBtn, FClose: TButton;
    FShowReplace: Boolean;
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
    procedure SetShowReplace(AValue: Boolean);
    procedure LayoutControls;
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
    // True (the default): two rows, find and replace. False: one row, find
    // only; Whole word and the match count move up into it.
    property ShowReplace: Boolean read FShowReplace write SetShowReplace;
  end;

implementation

{ TFindBar }

constructor TFindBar.Create(AOwner: TComponent);

  function MakeButton(const ACaption: string; AClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Self;
    Result.Text := ACaption;
    Result.OnClick := AClick;
  end;

  function MakeCheck(const ACaption: string): TCheckBox;
  begin
    Result := TCheckBox.Create(Self);
    Result.Parent := Self;
    Result.Text := ACaption;
  end;

begin
  inherited Create(AOwner);
  Stroke.Kind := TBrushKind.None;
  Fill.Color := TAlphaColor($FF2D2D30);
  Visible := False;
  FShowReplace := True;

  FSearch := TEdit.Create(Self);
  FSearch.Parent := Self;
  FSearch.TextPrompt := 'Find';
  FSearch.OnKeyDown := SearchKeyDown;
  FSearch.OnChangeTracking := SearchChanged;   // highlight live, per keystroke

  FNext := MakeButton('Next', DoNext);
  FPrev := MakeButton('Prev', DoPrev);
  FMatchCase := MakeCheck('Match case');
  FMatchCase.OnChange := SearchChanged;        // options change the match set

  FReplace := TEdit.Create(Self);
  FReplace.Parent := Self;
  FReplace.TextPrompt := 'Replace with';

  FReplaceBtn := MakeButton('Replace', DoReplace);
  FReplaceAllBtn := MakeButton('Replace All', DoReplaceAll);
  FWholeWord := MakeCheck('Whole word');
  FWholeWord.OnChange := SearchChanged;

  FClose := MakeButton('Close', DoClose);

  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.StyledSettings := [];
  FStatus.TextSettings.FontColor := TAlphaColors.Silver;
  LayoutControls;
end;

procedure TFindBar.LayoutControls;
begin
  FSearch.SetBounds(10, 8, 240, 28);
  FNext.SetBounds(258, 8, 66, 28);
  FPrev.SetBounds(328, 8, 66, 28);
  FMatchCase.SetBounds(404, 11, 110, 22);
  FReplace.Visible := FShowReplace;
  FReplaceBtn.Visible := FShowReplace;
  FReplaceAllBtn.Visible := FShowReplace;
  if FShowReplace then
  begin
    Height := 80;
    FReplace.SetBounds(10, 44, 240, 28);
    FReplaceBtn.SetBounds(258, 44, 66, 28);
    FReplaceAllBtn.SetBounds(328, 44, 100, 28);
    FWholeWord.SetBounds(438, 47, 110, 22);
    FClose.SetBounds(500, 8, 70, 28);
    FStatus.SetBounds(540, 46, 180, 24);
  end
  else
  begin
    Height := 44;
    FWholeWord.SetBounds(510, 11, 110, 22);
    FClose.SetBounds(616, 8, 70, 28);
    FStatus.SetBounds(696, 10, 180, 24);
  end;
end;

procedure TFindBar.SetShowReplace(AValue: Boolean);
begin
  if FShowReplace = AValue then
    Exit;
  FShowReplace := AValue;
  LayoutControls;
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
    if ssShift in Shift then
      DoPrev(Sender)
    else
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
