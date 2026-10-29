import 'note_mode.dart';

/// Suggests a title for a note from its first paste. The suggestion fills an
/// editable title field and never blocks typing.
///
/// Kept behind a small function so a local AI model can replace it later.
String suggestName(String text, ModeGuess guess, DateTime now) {
  final time = '${_two(now.hour)}:${_two(now.minute)}';
  final rich = guess.mode == NoteMode.rich;
  final firstLine = text
      .split('\n')
      .map((line) => line.trim())
      .firstWhere(
        (line) =>
            line.isNotEmpty && !(rich && _markdownFurniture.hasMatch(line)),
        orElse: () => '',
      );

  if (guess.mode == NoteMode.code) {
    final comment = _commentText(firstLine);
    if (comment != null && _hasWords(comment)) return _shorten(comment);
    return '${languageLabel(guess.language ?? 'code')} snippet $time';
  }

  final title = (rich ? _markdownText(firstLine) : firstLine)
      .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
      .replaceFirst(RegExp(r'^([-*+>]|\d+\.)\s+'), '')
      .replaceAll(RegExp(r'(?<!\uE000)[*_`]'), '')
      .replaceAll('\uE000', '')
      .trim();
  if (!_hasWords(title)) return 'Note $time';
  return _shorten(title);
}

const maxNameLength = 48;

/// Lines of a Rich note that hold no words of their own: code fences, rules
/// and the divider row under a table's header.
final _markdownFurniture = RegExp(
  r'^(`{3,}|~{3,}|([-*_])( *\2){2,} *$|\|?[ :|-]*-[ :|-]*$)',
);

/// A line of Markdown as the words it shows: link and image syntax becomes
/// its text, a table row its cells, and escaped characters are kept (marked
/// with U+E000 so emphasis stripping leaves them alone).
String _markdownText(String line) {
  var text = line
      .replaceAllMapped(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'<((https?|mailto):[^>]+)>'), (m) => m[1]!)
      .replaceFirst(RegExp(r'^([-*+]|\d+[.)]) +\[[ xX]\] +'), '')
      .replaceAll('~~', '');
  if (text.startsWith('|')) {
    text = text
        .replaceAll(RegExp(r'^\||\|$'), '')
        .split(RegExp(r'(?<!\\)\|'))
        .map((cell) => cell.trim())
        .where((cell) => cell.isNotEmpty)
        .join(', ');
  }
  return text.replaceAllMapped(
    RegExp(r'\\([!-/:-@\[-`{-~])'),
    (m) => '\uE000${m[1]}',
  );
}

final _commentPrefix = RegExp(r'^(//+|#+|--|/\*+|<!--|;+|%+|rem\s)\s*');

String? _commentText(String line) {
  if (line.startsWith('#!')) return null;
  final match = _commentPrefix.firstMatch(line);
  if (match == null) return null;
  return line
      .substring(match.end)
      .replaceFirst(RegExp(r'\s*(\*/|-->)$'), '')
      .trim();
}

bool _hasWords(String text) =>
    RegExp(r'\p{L}{2,}', unicode: true).hasMatch(text);

String _shorten(String text) {
  if (text.length <= maxNameLength) return text;
  final cut = text.substring(0, maxNameLength);
  final space = cut.lastIndexOf(' ');
  return '${(space > maxNameLength ~/ 2 ? cut.substring(0, space) : cut).trimRight()}…';
}

String _two(int n) => n.toString().padLeft(2, '0');
