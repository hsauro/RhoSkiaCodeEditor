program SkiaCodeEditorDemo;

{
  Demo host for TSkiaCodeEditor.

  The component's own units are not listed here: they come in through ufMain's
  uses clause and are found on the project's unit search path (..\Source) --
  exactly as they would be for a consumer who has installed the package.
}

uses
  System.StartUpCopy,
  FMX.Forms,
  {$IFDEF MACOS}
  Macapi.Foundation,
  Macapi.Helpers,
  {$ENDIF}
  ufMain in 'ufMain.pas' {frmMain},
  uLipsumGenerator in 'uLipsumGenerator.pas';

{$R *.res}

begin
  {$IFDEF MACOS}
  // macOS suppresses key auto-repeat for character keys: press-and-hold shows
  // the accent picker instead of repeating. (Navigation keys have no accent
  // variants, so they already repeat.) Turn that off for this app so holding a
  // key repeats it, matching Windows. Must run before the first window becomes
  // first responder, hence here rather than in a form event.
  TNSUserDefaults.Wrap(TNSUserDefaults.OCClass.standardUserDefaults)
    .setBool(False, StrToNSStr('ApplePressAndHoldEnabled'));
  {$ENDIF}
  Application.Initialize;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
