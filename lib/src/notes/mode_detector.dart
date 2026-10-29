import 'dart:convert';

import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

import 'note_mode.dart';

/// Picks a [NoteMode] for text pasted into a new note.
///
/// The order matters: exact formats (JSON, XML) win, then formatting on the
/// clipboard, then Markdown signs, then highlight.js-style language
/// detection, and plain text when nothing is confident.
class ModeDetector {
  ModeDetector({this.languages = defaultLanguages}) {
    for (final name in {...languages, 'markdown'}) {
      final mode = builtinAllLanguages[name];
      if (mode != null) _highlight.registerLanguage(name, mode);
    }
  }

  /// Languages tried by auto-detection. A short list of common ones keeps
  /// detection fast and stops obscure grammars from claiming plain prose.
  static const defaultLanguages = [
    'bash',
    'c',
    'cpp',
    'csharp',
    'css',
    'dart',
    'diff',
    'dockerfile',
    'go',
    'ini',
    'java',
    'javascript',
    'kotlin',
    'php',
    'powershell',
    'python',
    'ruby',
    'rust',
    'sql',
    'swift',
    'typescript',
    'xml',
    'yaml',
  ];

  /// Only this many characters are scanned, so huge pastes stay instant.
  static const sampleLength = 8000;

  /// Exact JSON parsing reads the whole text, so above this length only the
  /// opening of the text is checked.
  static const maxExactParseLength = 1 << 20;

  /// Below this highlight.js relevance a code guess is treated as noise.
  /// Short snippets score low, so this stays small and [_readsLikeProse]
  /// does the work of keeping sentences out of Code mode.
  static const minCodeRelevance = 3;

  final List<String> languages;
  final Highlight _highlight = Highlight();

  /// [clipboardHadFormatting] is set when the clipboard also held HTML with
  /// headings, lists, emphasis, links, images or tables (see
  /// `markdownFromHtml`).
  ModeGuess detect(String text, {bool clipboardHadFormatting = false}) {
    final trimmed = text.trim();
    final sample = trimmed.length > sampleLength
        ? trimmed.substring(0, sampleLength)
        : trimmed;

    if (trimmed.isNotEmpty) {
      if (_isJson(trimmed)) return const ModeGuess.code('json');
      if (_isXml(trimmed, sample)) return const ModeGuess.code('xml');
    }
    if (clipboardHadFormatting) return const ModeGuess.rich();
    if (trimmed.isEmpty) return const ModeGuess.plain();

    final markdownSigns = _markdownSigns(sample);
    if (markdownSigns >= 2) return const ModeGuess.rich();

    final auto = _highlight.highlightAuto(sample, [...languages, 'markdown']);
    final language = auto.language;
    if (language != null &&
        language != 'markdown' &&
        auto.relevance >= minCodeRelevance &&
        !_readsLikeProse(sample)) {
      return ModeGuess.code(language);
    }

    if (markdownSigns == 1 && language == 'markdown') {
      return const ModeGuess.rich();
    }
    return const ModeGuess.plain();
  }

  static final _jsonOpening = RegExp(
    r'^[\[{]\s*("|[\[{\]}]|-?\d|true\b|false\b|null\b)',
  );

  static bool _isJson(String text) {
    final first = text[0];
    if (first != '{' && first != '[') return false;
    if (text.length > maxExactParseLength) {
      return _jsonOpening.hasMatch(text.substring(0, 64)) &&
          (text.endsWith('}') || text.endsWith(']'));
    }
    try {
      jsonDecode(text);
      return true;
    } on FormatException {
      return false;
    }
  }

  static final _xmlOpening = RegExp(r'^<[A-Za-z!]');

  /// Only the opening, the last character and the [sample] are looked at, so
  /// this stays cheap on huge pastes.
  static bool _isXml(String text, String sample) =>
      text.startsWith('<?xml') ||
      (_xmlOpening.hasMatch(text) &&
          text.endsWith('>') &&
          sample.contains('</'));

  static final _markdownPatterns = [
    RegExp(r'^#{1,6} \S', multiLine: true), // heading
    RegExp(r'^\s*([-*+]|\d+\.) \S', multiLine: true), // list item
    RegExp(r'^```', multiLine: true), // fenced code
    RegExp(r'\[[^\]\n]+\]\([^)\s]+\)'), // link
    RegExp(r'(\*\*|__)\S[^\n]*?\S\1'), // bold
    RegExp(r'^> \S', multiLine: true), // block quote
    RegExp(r'^\s*[-*] \[[ xX]\] ', multiLine: true), // task list
  ];

  /// How many different kinds of Markdown syntax appear.
  static int _markdownSigns(String text) =>
      _markdownPatterns.where((p) => p.hasMatch(text)).length;

  static final _word = RegExp(r"[A-Za-z][A-Za-z']*");
  static final _codeSymbols = RegExp(r'[{}();=<>\[\]$|&]');

  /// Prose has many words per symbol. Code is dense with brackets and
  /// operators. This stops a SQL or Ruby keyword in a sentence from turning
  /// an email into code.
  static bool _readsLikeProse(String text) {
    final words = _word.allMatches(text).length;
    if (words < 8) return false;
    final symbols = _codeSymbols.allMatches(text).length;
    final sentenceEnds = RegExp(r'[a-z][.!?](\s|$)').allMatches(text).length;
    return symbols * 12 < words && sentenceEnds > 0;
  }
}
