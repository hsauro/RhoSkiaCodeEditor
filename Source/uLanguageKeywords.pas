unit uLanguageKeywords;

{
  Ready-made keyword lists for the built-in TSimpleHighlighter presets, so a
  caller does not have to hand-type them:

    Editor.Highlighter.UsePython;
    Editor.Highlighter.AddKeywords(PythonKeywords);

  Each constant pairs with the like-named preset (UsePascal / UseCLike /
  UseAntimony / UsePython). These are just data -- the unit depends on neither
  the editor nor the highlighter, so the lists work with a hand-written
  TTokenizeLineProc too. Add more with AddKeywords, or start from ClearKeywords
  if you want a different set entirely.
}

interface

const
  // Object Pascal / Delphi reserved words, plus the most commonly highlighted
  // directives and predefined identifiers. The Pascal preset is case-insensitive,
  // so casing here does not matter.
  PascalKeywords: TArray<string> = [
    'and', 'array', 'as', 'asm', 'begin', 'case', 'class', 'const',
    'constructor', 'destructor', 'dispinterface', 'div', 'do', 'downto', 'else',
    'end', 'except', 'exports', 'file', 'finalization', 'finally', 'for',
    'function', 'goto', 'if', 'implementation', 'in', 'inherited',
    'initialization', 'inline', 'interface', 'is', 'label', 'library', 'mod',
    'nil', 'not', 'object', 'of', 'or', 'out', 'packed', 'procedure', 'program',
    'property', 'raise', 'record', 'repeat', 'resourcestring', 'set', 'shl',
    'shr', 'string', 'then', 'threadvar', 'to', 'try', 'type', 'unit', 'until',
    'uses', 'var', 'while', 'with', 'xor',
    // directives / predefined -- not reserved, but usually highlighted
    'private', 'protected', 'public', 'published', 'virtual', 'override',
    'abstract', 'overload', 'reintroduce', 'default', 'read', 'write', 'stored',
    'true', 'false', 'result'];

  // ISO C (C11) keywords. C++ callers can AddKeywords the extras they need.
  CKeywords: TArray<string> = [
    'auto', 'break', 'case', 'char', 'const', 'continue', 'default', 'do',
    'double', 'else', 'enum', 'extern', 'float', 'for', 'goto', 'if', 'inline',
    'int', 'long', 'register', 'restrict', 'return', 'short', 'signed',
    'sizeof', 'static', 'struct', 'switch', 'typedef', 'union', 'unsigned',
    'void', 'volatile', 'while', '_Bool', '_Complex', '_Imaginary'];

  // Antimony (SBML-oriented model description language). Starter set -- adjust
  // to taste for your dialect.
  AntimonyKeywords: TArray<string> = [
    'model', 'end', 'species', 'compartment', 'reaction', 'gene', 'formula',
    'const', 'var', 'is', 'in', 'has', 'at', 'after', 'unit', 'function',
    'substanceOnly', 'ext', 'import', 'event', 'delay', 'time', 'default'];

  // Python 3 keywords -- the `keyword.kwlist` set.
  PythonKeywords: TArray<string> = [
    'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break',
    'class', 'continue', 'def', 'del', 'elif', 'else', 'except', 'finally',
    'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'nonlocal',
    'not', 'or', 'pass', 'raise', 'return', 'try', 'while', 'with', 'yield'];

implementation

end.
