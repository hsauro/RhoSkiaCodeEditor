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
  ufMain in 'ufMain.pas' {frmMain},
  uLipsumGenerator in 'uLipsumGenerator.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
