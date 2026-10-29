/// How a note is shown and edited. The text underneath is always plain text:
/// Markdown for [rich], source code for [code], anything for [plain].
enum NoteMode {
  rich('Rich'),
  code('Code'),
  plain('Plain');

  const NoteMode(this.label);

  final String label;
}

/// The mode GPad picked for some text, plus the language for [NoteMode.code].
class ModeGuess {
  const ModeGuess(this.mode, [this.language]);

  const ModeGuess.rich() : this(NoteMode.rich);
  const ModeGuess.plain() : this(NoteMode.plain);
  const ModeGuess.code(String language) : this(NoteMode.code, language);

  final NoteMode mode;

  /// A re_highlight language id such as `json` or `python`. Null unless
  /// [mode] is [NoteMode.code].
  final String? language;

  @override
  bool operator ==(Object other) =>
      other is ModeGuess && other.mode == mode && other.language == language;

  @override
  int get hashCode => Object.hash(mode, language);

  @override
  String toString() =>
      language == null ? mode.label : '${mode.label} ($language)';
}

const _languageLabels = {
  'bash': 'Bash',
  'c': 'C',
  'cpp': 'C++',
  'csharp': 'C#',
  'css': 'CSS',
  'dart': 'Dart',
  'diff': 'Diff',
  'dockerfile': 'Dockerfile',
  'go': 'Go',
  'ini': 'INI',
  'java': 'Java',
  'javascript': 'JavaScript',
  'json': 'JSON',
  'kotlin': 'Kotlin',
  'markdown': 'Markdown',
  'php': 'PHP',
  'powershell': 'PowerShell',
  'python': 'Python',
  'ruby': 'Ruby',
  'rust': 'Rust',
  'scss': 'SCSS',
  'shell': 'Shell',
  'sql': 'SQL',
  'swift': 'Swift',
  'typescript': 'TypeScript',
  'xml': 'XML',
  'yaml': 'YAML',
};

/// A display name for a re_highlight language id.
String languageLabel(String language) =>
    _languageLabels[language] ??
    (language.isEmpty
        ? language
        : language[0].toUpperCase() + language.substring(1));
