import 'dart:math';

import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_quill/markdown_quill.dart';

/// Converts Rich notes between the Markdown they are stored as and the Quill
/// Delta the rich editor works on.
///
/// Reading uses markdown_quill, taught to keep image alt text, tables and
/// level 4 to 6 headings. Writing is GPad's own: markdown_quill's writer
/// escapes nearly all punctuation (`saved as you go\.`), drops alt text and
/// tables, and can run a paragraph into the quote above it. This one escapes
/// only what would otherwise change meaning, so the Markdown underneath
/// reads like Markdown a person wrote and parses back to the same note.
abstract final class RichMarkdown {
  /// Embed type for images. The data is a map with `src`, and `alt` and
  /// `title` when the image has them.
  static const imageType = 'x-md-image';

  /// markdown_quill's embed type for a table. The data is the table's
  /// Markdown, shown as a table and kept as written.
  static const tableType = EmbeddableTable.tableType;

  /// markdown_quill's embed type for `---`.
  static const ruleType = 'divider';

  /// The line attribute markdown_quill keeps a code block's language in.
  static const codeLanguageKey = 'x-md-codeblock-lang';

  static Delta toDelta(String markdown) => _reader.convert(markdown);

  static String fromDelta(Delta delta) => _write(_lines(delta));

  /// One table cell's Markdown, from a Delta holding a single line.
  static String tableCell(Delta delta) {
    final parts = [for (final line in _lines(delta)) ...line.parts];
    return _inline(parts, tableCell: true);
  }

  static final _reader = MarkdownToDelta(
    markdownDocument: md.Document(
      encodeHtml: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      blockSyntaxes: const [EmbeddableTableSyntax()],
      inlineSyntaxes: [_ImageSyntax()],
    ),
    customElementToBlockAttribute: {
      'h4': (_) => [quill.Attribute.h4],
      'h5': (_) => [quill.Attribute.h5],
      'h6': (_) => [quill.Attribute.h6],
    },
    customElementToEmbeddable: {
      tableType: EmbeddableTable.fromMdSyntax,
      imageType: (attributes) => quill.Embeddable(imageType, {
        'src': attributes['src'] ?? '',
        if (attributes['alt'] case final alt? when alt.isNotEmpty) 'alt': alt,
        if (attributes['title'] case final title? when title.isNotEmpty)
          'title': _unescapeHtml(title),
      }),
    },
  );
}

/// The markdown package escapes HTML in image titles even with
/// `encodeHtml` off.
String _unescapeHtml(String text) => text
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

/// markdown_quill turns images into plain image embeds, which only hold the
/// address. Naming the element differently routes it to [RichMarkdown]'s own
/// embed, which keeps the alt text and title too.
class _ImageSyntax extends md.ImageSyntax {
  @override
  md.Element createNode(
    String destination,
    String? title, {
    required List<md.Node> Function() getChildren,
  }) {
    final image = super.createNode(
      destination,
      title,
      getChildren: getChildren,
    );
    return md.Element.empty(RichMarkdown.imageType)
      ..attributes.addAll(image.attributes);
  }
}

class _Part {
  _Part.text(this.text, this.attrs) : embed = null;
  _Part.embed(quill.Embeddable this.embed, this.attrs) : text = '';

  final String text;
  final quill.Embeddable? embed;
  final Map<String, dynamic> attrs;

  bool get isText => embed == null;
  bool get isCode => isText && attrs['code'] == true;
  String? get link => attrs['link'] as String?;
}

class _Line {
  _Line(this.parts, this.attrs);

  final List<_Part> parts;
  final Map<String, dynamic> attrs;

  bool get isCode => attrs['code-block'] == true;
  int? get heading => switch (attrs['header']) {
    final int level => level.clamp(1, 6),
    _ => null,
  };
  String? get list => switch (attrs['list']) {
    final String type
        when const {
          'bullet',
          'ordered',
          'checked',
          'unchecked',
        }.contains(type) =>
      type,
    _ => null,
  };
  bool get isQuote => attrs['blockquote'] == true;
  int get indent => switch (attrs['indent']) {
    final int level => level.clamp(0, 12),
    _ => 0,
  };
  bool get isBlank =>
      parts.every((part) => part.isText && part.text.trim().isEmpty);
}

/// Splits [delta] into lines. In a Delta each `\n` ends a line and carries
/// that line's block attributes (heading, list, quote, code).
List<_Line> _lines(Delta delta) {
  final lines = <_Line>[];
  var parts = <_Part>[];
  for (final op in delta.toList()) {
    if (!op.isInsert) continue;
    final attrs = op.attributes ?? const <String, dynamic>{};
    final data = op.data;
    if (data is String) {
      final chunks = data.split('\n');
      for (var i = 0; i < chunks.length; i++) {
        if (chunks[i].isNotEmpty) parts.add(_Part.text(chunks[i], attrs));
        if (i < chunks.length - 1) {
          lines.add(_Line(parts, attrs));
          parts = [];
        }
      }
    } else if (data is Map && data.length == 1) {
      parts.add(
        _Part.embed(
          quill.Embeddable(data.keys.first, data.values.first),
          attrs,
        ),
      );
    }
  }
  if (parts.isNotEmpty) lines.add(_Line(parts, const {}));
  return lines;
}

/// Blocks are separated by a blank line. Lines of one list, quote or code
/// block follow each other directly. Empty lines between paragraphs add
/// nothing, as Markdown would drop them anyway, but they do end a list or a
/// quote.
String _write(List<_Line> lines) {
  final blocks = <String>[];
  var i = 0;
  // The end of the run of lines from i that pass [test].
  int runEnd(bool Function(_Line) test) {
    var j = i + 1;
    while (j < lines.length && test(lines[j])) {
      j++;
    }
    return j;
  }

  while (i < lines.length) {
    final line = lines[i];
    if (line.isCode) {
      final end = runEnd((l) => l.isCode);
      blocks.add(_codeBlock(lines.sublist(i, end)));
      i = end;
    } else if (line.list != null) {
      final end = runEnd((l) => l.list != null && !l.isCode);
      blocks.add(_list(lines.sublist(i, end)));
      i = end;
    } else if (line.heading != null) {
      blocks.add(_heading(line));
      i++;
    } else if (line.isQuote) {
      final end = runEnd((l) => l.isQuote && l.list == null && !l.isCode);
      blocks.add(lines.sublist(i, end).map(_quoteLine).join('\n'));
      i = end;
    } else {
      if (!line.isBlank) blocks.addAll(_paragraph(line));
      i++;
    }
  }
  return blocks.isEmpty ? '' : '${blocks.join('\n\n')}\n';
}

String _quoteLine(_Line line) {
  final text = _inline(line.parts, lineStart: true, verifyAs: '> ');
  return text.isEmpty ? '>' : '> $text';
}

String _codeBlock(List<_Line> lines) {
  final language =
      lines
          .map((line) => line.attrs[RichMarkdown.codeLanguageKey])
          .whereType<String>()
          .map((name) => name.trim().split(RegExp(r'\s')).first)
          .where((name) => name.isNotEmpty && !name.contains('`'))
          .firstOrNull ??
      '';
  final body = lines
      .map(
        (line) =>
            line.parts.where((part) => part.isText).map((p) => p.text).join(),
      )
      .join('\n');
  final longest = RegExp(r'`{3,}')
      .allMatches(body)
      .fold(0, (most, match) => max(most, match[0]!.length));
  final fence = '`' * max(3, longest + 1);
  return '$fence$language\n$body\n$fence';
}

String _list(List<_Line> lines) {
  final out = <String>[];
  final counts = <int, int>{};
  final types = <int, String>{};
  // Where a nested item must start, by level. Nesting has to reach the
  // parent's text, so it follows the width of the parent's marker.
  final childPads = <int, int>{};
  for (final line in lines) {
    final level = line.indent;
    for (final map in [counts, types, childPads]) {
      map.removeWhere((key, _) => key > level);
    }
    final type = line.list!;
    if (types[level] != type) counts[level] = 0;
    types[level] = type;
    final count = counts[level] = (counts[level] ?? 0) + 1;
    final marker = switch (type) {
      'ordered' => '$count. ',
      'checked' => '- [x] ',
      'unchecked' => '- [ ] ',
      _ => '- ',
    };
    final pad = level == 0 ? 0 : childPads[level - 1] ?? 4 * level;
    final markerWidth = type == 'ordered' ? marker.length : 2;
    childPads[level] = pad + max(4, markerWidth);
    final text = _inline(line.parts, lineStart: true, verifyAs: '- ');
    out.add('${' ' * pad}$marker$text'.trimRight());
  }
  return out.join('\n');
}

String _heading(_Line line) {
  final hashes = '#' * line.heading!;
  // A run of # at the end would be read as a closing sequence and dropped.
  final text = _inline(
    line.parts,
    verifyAs: '$hashes ',
  ).replaceFirstMapped(RegExp(r'(^|\s)(#+)$'), (m) => '${m[1]}\\${m[2]}');
  return text.isEmpty ? hashes : '$hashes $text';
}

/// A paragraph, split around any rule or table in it, as those can only
/// stand on their own lines.
List<String> _paragraph(_Line line) {
  final out = <String>[];
  var run = <_Part>[];
  void flush() {
    final text = _inline(run, lineStart: true);
    if (text.isNotEmpty) out.add(text);
    run = [];
  }

  for (final part in line.parts) {
    switch (part.embed?.type) {
      case RichMarkdown.ruleType:
        flush();
        out.add('---');
      case RichMarkdown.tableType:
        flush();
        final table = '${part.embed!.data}'.trim();
        if (table.isNotEmpty) out.add(table);
      default:
        run.add(part);
    }
  }
  flush();
  return out;
}

enum _Emphasis { link, strike, bold, italic }

class _Open {
  _Open(this.emphasis, this.link, this.contentStart);
  final _Emphasis emphasis;
  final String? link;
  final int contentStart;

  bool matches((_Emphasis, String?) mark) =>
      emphasis == mark.$1 && link == mark.$2;
}

/// An emphasis marker in the written line, and the part it opens before or
/// closes after.
class _Marker {
  _Marker(
    this.start,
    this.end,
    this.emphasis,
    this.part, {
    required this.opens,
  });
  final int start;
  final int end;
  final _Emphasis emphasis;
  final int part;
  final bool opens;

  String get family => emphasis == _Emphasis.strike ? '~' : '*';
}

/// The Markdown for one line's text: emphasis, links, code and images, with
/// escapes only where the text would otherwise be read as syntax.
///
/// Markdown only reads `*` and `~~` as emphasis next to the right kind of
/// character: `a**"b"**` and `**Note:**Next` stay literal asterisks. Where a
/// marker would land like that, the punctuation at the edge of the run moves
/// outside it, or the run loses that emphasis. Lines where a marker touches
/// punctuation are then parsed back as a check, and in the rare case that
/// still reads differently the line is written without emphasis. Formatting
/// can be lost that way, but never text. [verifyAs] is the line's block
/// prefix (`# `, `- `), so the check parses it the way it will be read.
String _inline(
  List<_Part> rawParts, {
  bool lineStart = false,
  bool tableCell = false,
  String verifyAs = '',
}) {
  var parts = _normalize(rawParts);
  if (parts.isEmpty) return '';

  final plain = parts.where((p) => p.isText && !p.isCode).map((p) => p.text);
  final lineText = plain.join();
  final context = _EscapeContext(
    manyTildes:
        '~'.allMatches(lineText).length > 1 ||
        parts.any((p) => p.attrs['strike'] == true),
    escapePipes: tableCell || _delimiterRow.hasMatch(lineText),
  );

  while (true) {
    final (text, markers) = _emit(parts, context, lineStart: lineStart);
    final (fix, risky) = _checkMarkers(text, markers);
    if (fix != null) {
      parts = _withoutEmphasis(
        parts,
        fix.part,
        fix.emphasis,
        atStart: fix.opens,
      );
      continue;
    }
    if (risky && !tableCell && !_readsBack('$verifyAs$text', parts)) {
      parts = [
        for (final part in parts)
          part.isText
              ? _Part.text(part.text, {
                  for (final entry in part.attrs.entries)
                    if (entry.key == 'code' || entry.key == 'link')
                      entry.key: entry.value,
                })
              : part,
      ];
      continue;
    }
    return text;
  }
}

(String, List<_Marker>) _emit(
  List<_Part> parts,
  _EscapeContext context, {
  required bool lineStart,
}) {
  var out = '';
  final open = <_Open>[];
  final markers = <_Marker>[];
  var lastPart = -1;

  void close(int from) {
    if (from >= open.length) return;
    // Spaces just inside a closing marker stop it closing, so they move out.
    final trimmed = out.replaceFirst(RegExp(r'[ \t]+$'), '');
    final spaces = trimmed.length > open.last.contentStart
        ? out.substring(trimmed.length)
        : '';
    out = out.substring(0, out.length - spaces.length);
    for (final mark in open.sublist(from).reversed) {
      final start = out.length;
      out += switch (mark.emphasis) {
        _Emphasis.link => '](${_destination(mark.link!)})',
        _Emphasis.strike => '~~',
        _Emphasis.bold => '**',
        _Emphasis.italic => '*',
      };
      if (mark.emphasis != _Emphasis.link) {
        markers.add(
          _Marker(start, out.length, mark.emphasis, lastPart, opens: false),
        );
      }
    }
    out += spaces;
    open.removeRange(from, open.length);
  }

  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    final marks = _marksOf(part);
    final kept = open.indexWhere((o) => !marks.any(o.matches));
    close(kept < 0 ? open.length : kept);
    lastPart = i;

    final next = i + 1 < parts.length ? parts[i + 1] : null;
    if (part.link != null &&
        !open.any((o) => o.emphasis == _Emphasis.link) &&
        marks.length == 1 &&
        part.isText &&
        !part.isCode &&
        next?.link != part.link) {
      final auto = _autolink(
        part.text,
        part.link!,
        before: out.isEmpty ? null : out[out.length - 1],
        after: next == null || !next.isText || next.text.isEmpty
            ? null
            : next.text[0],
      );
      if (auto != null) {
        out += auto;
        continue;
      }
    }

    final toOpen = marks.where((m) => !open.any((o) => o.matches(m))).toList()
      ..sort((a, b) {
        if (a.$1 == _Emphasis.link || b.$1 == _Emphasis.link) {
          return a.$1 == _Emphasis.link ? -1 : 1;
        }
        return _runLength(parts, i, b).compareTo(_runLength(parts, i, a));
      });
    var text = part.text;
    if (toOpen.isNotEmpty && part.isText && !part.isCode) {
      // Spaces just inside an opening marker stop it opening, so they move
      // out too.
      final spaces = RegExp(r'^[ \t]*').stringMatch(text)!;
      out += spaces;
      text = text.substring(spaces.length);
    }
    for (final mark in toOpen) {
      // `!` right before a link would make it an image.
      if (mark.$1 == _Emphasis.link && out.endsWith('!')) {
        out = '${out.substring(0, out.length - 1)}\\!';
      }
      final start = out.length;
      out += switch (mark.$1) {
        _Emphasis.link => '[',
        _Emphasis.strike => '~~',
        _Emphasis.bold => '**',
        _Emphasis.italic => '*',
      };
      open.add(_Open(mark.$1, mark.$2, out.length));
      if (mark.$1 != _Emphasis.link) {
        markers.add(_Marker(start, out.length, mark.$1, i, opens: true));
      }
    }

    final inLink = open.any((o) => o.emphasis == _Emphasis.link);
    if (part.embed case final embed?) {
      out += _embed(embed);
    } else if (part.isCode && !out.endsWith('`')) {
      out += _codeSpan(text, escapePipes: context.escapePipes);
    } else {
      // (Code right after a literal backtick can't be marked as code.)
      out += _escape(
        text,
        atLineStart: lineStart && out.isEmpty,
        inLink: inLink,
        context: context,
      );
    }
  }
  close(0);
  // Only spaces moved out of a closing marker can trail, and the line's
  // outer spaces were trimmed already.
  return (out.trimRight(), markers);
}

final _punctuation = RegExp(r'[\p{P}\p{S}]', unicode: true);
final _whitespace = RegExp(r'\s', unicode: true);

bool _isPunctuation(String? char) =>
    char != null && _punctuation.hasMatch(char);
bool _isWhitespace(String? char) => char == null || _whitespace.hasMatch(char);

/// Checks each run of touching markers the way CommonMark decides whether a
/// delimiter run can open or close emphasis. Returns a marker that would
/// not work, and whether any run touches punctuation, which is worth
/// checking against the real parser.
(_Marker?, bool) _checkMarkers(String text, List<_Marker> markers) {
  markers.sort((a, b) => a.start.compareTo(b.start));
  var risky = false;
  var i = 0;
  while (i < markers.length) {
    var j = i + 1;
    while (j < markers.length &&
        markers[j].start == markers[j - 1].end &&
        markers[j].family == markers[i].family) {
      j++;
    }
    final run = markers.sublist(i, j);
    i = j;

    final before = run.first.start > 0 ? text[run.first.start - 1] : null;
    final after = run.last.end < text.length ? text[run.last.end] : null;
    final leftFlanking =
        !_isWhitespace(after) &&
        (!_isPunctuation(after) ||
            _isWhitespace(before) ||
            _isPunctuation(before));
    final rightFlanking =
        !_isWhitespace(before) &&
        (!_isPunctuation(before) ||
            _isWhitespace(after) ||
            _isPunctuation(after));

    final opener = run.where((m) => m.opens).firstOrNull;
    final closer = run.where((m) => !m.opens).firstOrNull;
    // A run that both closes and opens is read unpredictably.
    if (opener != null && closer != null) return (opener, risky);
    if (closer != null && !rightFlanking) return (closer, risky);
    if (opener != null && !leftFlanking) return (opener, risky);

    final clean = opener != null
        ? _isWhitespace(before) && !_isPunctuation(after)
        : !_isPunctuation(before) && _isWhitespace(after);
    if (!clean) risky = true;
  }
  return (null, risky);
}

/// [parts] with [emphasis] taken off the part at [index]: just its first or
/// last character when that is punctuation, otherwise all of it.
List<_Part> _withoutEmphasis(
  List<_Part> parts,
  int index,
  _Emphasis emphasis, {
  required bool atStart,
}) {
  final part = parts[index];
  final attrs = {...part.attrs}..remove(emphasis.name);
  final List<_Part> replacement;
  final text = part.text;
  final edge = atStart
      ? text.isEmpty
            ? ''
            : text[0]
      : text.isEmpty
      ? ''
      : text[text.length - 1];
  if (part.isText && !part.isCode && text.length > 1 && _isPunctuation(edge)) {
    final rest = atStart
        ? text.substring(1)
        : text.substring(0, text.length - 1);
    replacement = atStart
        ? [_Part.text(edge, attrs), _Part.text(rest, part.attrs)]
        : [_Part.text(rest, part.attrs), _Part.text(edge, attrs)];
  } else {
    replacement = [
      part.isText ? _Part.text(text, attrs) : _Part.embed(part.embed!, attrs),
    ];
  }
  return [
    ...parts.sublist(0, index),
    ...replacement,
    ...parts.sublist(index + 1),
  ];
}

/// Whether [markdown] parses back to the same characters with the same
/// emphasis as [parts].
bool _readsBack(String markdown, List<_Part> parts) {
  List<String> styled(Iterable<(String, Map<String, dynamic>)> runs) => [
    for (final (text, attrs) in runs)
      for (final char in text.split(''))
        if (char.trim().isNotEmpty)
          '$char${attrs['bold'] == true ? 'b' : ''}'
              '${attrs['italic'] == true ? 'i' : ''}'
              '${attrs['strike'] == true ? 's' : ''}',
  ];

  final expected = styled([
    for (final part in parts)
      if (part.isText) (part.text, part.attrs),
  ]);
  final ops = RichMarkdown.toDelta(markdown).toList();
  final actual = <(String, Map<String, dynamic>)>[];
  for (final op in ops) {
    if (op.data case final String data) {
      final end = data.indexOf('\n');
      actual.add((
        end < 0 ? data : data.substring(0, end),
        op.attributes ?? {},
      ));
      if (end >= 0) break;
    }
  }
  final got = styled(actual);
  if (got.length != expected.length) return false;
  for (var i = 0; i < got.length; i++) {
    if (got[i] != expected[i]) return false;
  }
  return true;
}

/// Keeps only what Markdown can say, merges neighbors that look the same, and
/// trims the line's outer spaces, which Markdown would drop (and four of
/// which at the start would make a code block).
List<_Part> _normalize(List<_Part> parts) {
  const kept = ['bold', 'italic', 'strike', 'code', 'link'];
  final out = <_Part>[];
  for (final part in parts) {
    final attrs = <String, dynamic>{
      for (final key in kept)
        if (part.attrs[key] case final value?
            when value != false && (key != 'link' || '$value'.isNotEmpty))
          key: key == 'link' ? '$value' : true,
    };
    if (!part.isText) {
      final link = attrs['link'];
      out.add(_Part.embed(part.embed!, {'link': ?link}));
      continue;
    }
    if (part.text.isEmpty) continue;
    if (part.text.trim().isEmpty && attrs['code'] != true) {
      attrs.removeWhere((key, _) => key != 'link');
    }
    final previous = out.lastOrNull;
    if (previous != null && previous.isText) {
      final bothCode = previous.isCode && attrs['code'] == true;
      if (bothCode && previous.link == attrs['link']) {
        // One code span, carrying only the emphasis both pieces share.
        out.last = _Part.text(previous.text + part.text, {
          for (final entry in previous.attrs.entries)
            if (attrs[entry.key] == entry.value) entry.key: entry.value,
        });
        continue;
      }
      if (_sameAttrs(previous.attrs, attrs)) {
        out.last = _Part.text(previous.text + part.text, attrs);
        continue;
      }
    }
    out.add(_Part.text(part.text, attrs));
  }

  while (out.isNotEmpty && out.first.isText && !out.first.isCode) {
    final text = out.first.text.trimLeft();
    if (text.isNotEmpty) {
      out.first = _Part.text(text, out.first.attrs);
      break;
    }
    out.removeAt(0);
  }
  while (out.isNotEmpty && out.last.isText && !out.last.isCode) {
    final text = out.last.text.trimRight();
    if (text.isNotEmpty) {
      out.last = _Part.text(text, out.last.attrs);
      break;
    }
    out.removeLast();
  }
  return out;
}

bool _sameAttrs(Map<String, dynamic> a, Map<String, dynamic> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

List<(_Emphasis, String?)> _marksOf(_Part part) => [
  if (part.link case final link?) (_Emphasis.link, link),
  if (part.isText) ...[
    if (part.attrs['strike'] == true) (_Emphasis.strike, null),
    if (part.attrs['bold'] == true) (_Emphasis.bold, null),
    if (part.attrs['italic'] == true) (_Emphasis.italic, null),
  ],
];

/// How many characters the mark runs on from [start], so the longest-running
/// marks open first and the fewest need closing and reopening.
int _runLength(List<_Part> parts, int start, (_Emphasis, String?) mark) {
  var length = 0;
  for (var i = start; i < parts.length; i++) {
    if (!_marksOf(parts[i]).contains(mark)) break;
    length += parts[i].isText ? parts[i].text.length : 1;
  }
  return length;
}

final _bareUrl = RegExp(r'^(https?://|www\.)[^\s<>*~`\\\[\]()]+$');
final _email = RegExp(r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$');
final _endsBare = RegExp(r'[A-Za-z0-9/]$');

/// A link whose text is its own address, written as the address itself the
/// way it was likely typed, or in angle brackets where a bare address would
/// run into its neighbors. Null when it needs the full `[text](url)` form.
String? _autolink(
  String text,
  String href, {
  required String? before,
  required String? after,
}) {
  final isUrl =
      href == text ||
      (text.startsWith('www.') && href == 'http://$text') ||
      (text.startsWith('www.') && href == 'https://$text');
  final isEmail = href == 'mailto:$text' && _email.hasMatch(text);
  if (!isUrl && !isEmail) return null;

  final spaced =
      (before == null || _isSpace(before)) &&
      (after == null || _isSpace(after));
  final bare = isEmail ? _email.hasMatch(text) : _bareUrl.hasMatch(text);
  if (spaced && bare && _endsBare.hasMatch(text)) return text;
  if (text.contains(RegExp(r'[\s<>]'))) return null;
  if (isEmail || RegExp(r'^[A-Za-z][A-Za-z0-9+.-]{1,31}:').hasMatch(text)) {
    return '<$text>';
  }
  return null;
}

String _destination(String url) {
  var depth = 0;
  var balanced = true;
  for (final char in url.split('')) {
    if (char == '(') depth++;
    if (char == ')' && --depth < 0) balanced = false;
  }
  if (url.contains(RegExp(r'[\s<>]')) || !balanced || depth != 0) {
    return '<${url.replaceAll('<', '%3C').replaceAll('>', '%3E')}>';
  }
  return url;
}

String _embed(quill.Embeddable embed) {
  final data = embed.data;
  switch (embed.type) {
    case RichMarkdown.imageType when data is Map:
      final src = '${data['src'] ?? ''}';
      final alt = '${data['alt'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ');
      final title = '${data['title'] ?? ''}';
      final titlePart = title.isEmpty
          ? ''
          : ' "${title.replaceAll('"', r'\"')}"';
      final altText = _escape(
        alt,
        atLineStart: false,
        inLink: true,
        context: const _EscapeContext(),
      );
      return '![$altText](${_destination(src)}$titlePart)';
    case quill.BlockEmbed.imageType when data is String:
      return '![](${_destination(data)})';
    default:
      // A video or anything else Markdown has no syntax for keeps its
      // address, so nothing pasted is lost without a trace.
      if (data is String && RegExp(r'^https?://\S+$').hasMatch(data)) {
        return '<$data>';
      }
      return '';
  }
}

String _codeSpan(String text, {required bool escapePipes}) {
  final longest = RegExp(r'`+')
      .allMatches(text)
      .fold(0, (most, match) => max(most, match[0]!.length));
  final fence = '`' * (longest + 1);
  final pad =
      text.startsWith('`') ||
          text.endsWith('`') ||
          (text.startsWith(' ') && text.endsWith(' ') && text.trim().isNotEmpty)
      ? ' '
      : '';
  final body = escapePipes ? text.replaceAll('|', r'\|') : text;
  return '$fence$pad$body$pad$fence';
}

class _EscapeContext {
  const _EscapeContext({this.manyTildes = false, this.escapePipes = false});

  /// Two tildes on a line can strike out the text between them.
  final bool manyTildes;

  /// Inside a table cell, or on a line that would read as a table's divider.
  final bool escapePipes;
}

final _delimiterRow = RegExp(
  r'^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)+\|?[ \t]*$',
);
final _entity = RegExp(
  r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});',
);
final _thematicBreak = RegExp(r'^([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final _setextUnderline = RegExp(r'^(=+|-+)[ \t]*$');
final _orderedMarker = RegExp(r'^(\d{1,9})[.)]([ \t]|$)');
final _listMarker = RegExp(r'^[-+*]([ \t]|$)');
final _tagStart = RegExp(r'[A-Za-z/!?]');
final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
const _asciiPunctuation = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

bool _isSpace(String? char) =>
    char != null && (char == ' ' || char == '\t' || char == '\u00a0');

/// Escapes only the characters that would be read as Markdown here. Plain
/// prose, `snake_case`, `C#`, `x < y` and `2 * 3` stay as they are.
String _escape(
  String text, {
  required bool atLineStart,
  required bool inLink,
  required _EscapeContext context,
}) {
  final escapeAt = <int>{};
  if (atLineStart) {
    if (text.startsWith('#') ||
        text.startsWith('>') ||
        _listMarker.hasMatch(text) ||
        _thematicBreak.hasMatch(text) ||
        _setextUnderline.hasMatch(text)) {
      escapeAt.add(0);
    } else if (_orderedMarker.firstMatch(text) case final match?) {
      escapeAt.add(match[1]!.length);
    }
  }

  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    final before = i > 0 ? text[i - 1] : null;
    final after = i + 1 < text.length ? text[i + 1] : null;
    final escape =
        escapeAt.contains(i) ||
        switch (char) {
          r'\' => after == null || _asciiPunctuation.contains(after),
          '`' || '[' => true,
          ']' => inLink,
          '*' => !(_isSpace(before) && _isSpace(after)),
          '_' =>
            !(before != null &&
                after != null &&
                _wordChar.hasMatch(before) &&
                _wordChar.hasMatch(after)),
          '<' => after != null && _tagStart.hasMatch(after),
          '&' => _entity.matchAsPrefix(text, i) != null,
          '~' => context.manyTildes,
          '|' => context.escapePipes,
          _ => false,
        };
    if (escape) out.write(r'\');
    out.write(char);
  }
  return out.toString();
}
