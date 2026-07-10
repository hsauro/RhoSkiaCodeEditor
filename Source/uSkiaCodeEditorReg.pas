unit uSkiaCodeEditorReg;

{
  Design-time registration for TSkiaCodeEditor.

  This unit is compiled into the DESIGN-TIME package (dclSkiaCodeEditor) only.
  Keeping Register out of the runtime package is what lets an application link
  the component without dragging in designide.
}

interface

procedure Register;

implementation

uses
  System.Classes,
  FMX.Types,
  uSkiaCodeEditor;

procedure Register;
begin
  // GroupDescendentsWith ties the component to the FireMonkey object tree, so
  // the IDE offers it on FMX forms and hides it from VCL ones. Without it the
  // component shows up on both palettes and can be dropped where it can't work.
  GroupDescendentsWith(TSkiaCodeEditor, FMX.Types.TFmxObject);
  RegisterComponents('Skia', [TSkiaCodeEditor]);
end;

end.
