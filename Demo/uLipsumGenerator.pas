unit uLipsumGenerator;

interface

uses
  System.SysUtils, System.Classes;

type
  TLipsumGen = class
  private
    FWordList: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    // The argument now explicitly means the number of paragraphs you want
    function GenerateParagraph(ParagraphCount: Integer): string;
  end;

implementation

constructor TLipsumGen.Create;
begin
  FWordList := TStringList.Create;
  FWordList.Add('Lorem ipsum dolor sit amet, consectetur adipiscing elit.');
  FWordList.Add('Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.');
  FWordList.Add('Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.');
  FWordList.Add('Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur.');
  FWordList.Add('Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum.');
end;

destructor TLipsumGen.Destroy;
begin
  FWordList.Free;
  inherited;
end;

function TLipsumGen.GenerateParagraph(ParagraphCount: Integer): string;
var
  p, s, w: Integer;
  LBuffer: TStringBuilder;
  LSentence: string;
  LWords: TArray<string>;
  LWord: string;
  LCurrentLineLength: Integer;
  LSentencesInThisPara: Integer;
const
  MAX_LINE_LENGTH = 80; // Hard wrap lines at 60 characters
begin
  if ParagraphCount <= 0 then Exit('');

  LBuffer := TStringBuilder.Create;
  LCurrentLineLength := 0;
  try
    // Loop explicitly for the number of paragraphs requested
    for p := 1 to ParagraphCount do
    begin

      // Randomly decide to put 3, 4, or 5 sentences in this specific paragraph
      LSentencesInThisPara := 3 + Random(6);

      // Build the sentences for the current paragraph
      for s := 1 to LSentencesInThisPara do
      begin
        LSentence := FWordList[Random(FWordList.Count)];
        LWords := LSentence.Split([' ']);

        // Process word-by-word to enforce the 60-character hard wrap limit
        for w := 0 to High(LWords) do
        begin
          LWord := LWords[w];

          if (LCurrentLineLength > 0) and (LCurrentLineLength + Length(LWord) > MAX_LINE_LENGTH) then
          begin
            LBuffer.Append(sLineBreak);
            LCurrentLineLength := 0;
          end
          else if (LCurrentLineLength > 0) then
          begin
            LBuffer.Append(' ');
            Inc(LCurrentLineLength);
          end;

          LBuffer.Append(LWord);
          LCurrentLineLength := LCurrentLineLength + Length(LWord);
        end;

        // If there is another sentence coming in this same paragraph, add a trailing space
        if s < LSentencesInThisPara then
        begin
          LBuffer.Append(' ');
          Inc(LCurrentLineLength);
        end;
      end;

      // If there is another paragraph coming, inject the double line break separating them
      if p < ParagraphCount then
      begin
        LBuffer.Append(sLineBreak + sLineBreak);
        LCurrentLineLength := 0; // Reset line length tracker for the next paragraph block
      end;
    end;

    Result := LBuffer.ToString;
  finally
    LBuffer.Free;
  end;
end;

end.

