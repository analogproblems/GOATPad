import 'package:flutter_quill/quill_delta.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'rich_markdown.dart';

/// Clipboard HTML longer than this is pasted as plain text, so a huge copy
/// never stalls the paste.
const maxClipboardHtmlLength = 4 << 20;

/// Tables holding more cells than this in all, counting the empty ones
/// that spanned cells leave, are pasted as plain text. Spans can make a
/// small copy expand enormously, and a table this big is easier to work
/// with as the tab-separated text spreadsheets also put on the clipboard.
const maxTableCells = 5000;

/// Markdown for HTML copied from a browser, Word, Google Docs or LibreOffice,
/// or null when the HTML holds nothing the plain text doesn't: no headings,
/// lists, quotes, emphasis, links, images or tables.
///
/// A code block on its own isn't formatting either. Code copied from an
/// editor or a web page often comes with HTML that only colors it, and it
/// should go through the plain text and become a Code note.
///
/// Only what Markdown can say is kept. Links and images keep web addresses
/// only (no `javascript:`, no local files, no addresses relative to a page
/// GPad can't know), images too small to see are dropped, and nothing is
/// ever fetched.
String? markdownFromHtml(String html) {
  if (html.length > maxClipboardHtmlLength) return null;
  final body = html_parser.parse(html).body;
  if (body == null) return null;
  final walker = _Walker()..walk(body);
  walker.flush();
  if (!walker.formatted || walker.tooBig) return null;
  final markdown = RichMarkdown.fromDelta(walker.delta);
  return markdown.trim().isEmpty ? null : markdown;
}

sealed class _Block {}

class _ListBlock extends _Block {
  _ListBlock({required this.ordered});
  final bool ordered;
}

class _ItemBlock extends _Block {
  _ItemBlock(this.type, {this.depth});
  String type;

  /// Set for Word's lists, which are paragraphs that name their level.
  final int? depth;
}

class _QuoteBlock extends _Block {}

class _HeadingBlock extends _Block {
  _HeadingBlock(this.level);
  final int level;
}

class _CodeBlock extends _Block {
  _CodeBlock(this.language);
  final String? language;
}

const _skipped = {
  'head',
  'title',
  'meta',
  'link',
  'style',
  'script',
  'noscript',
  'template',
  'iframe',
  'object',
  'embed',
  'svg',
  'canvas',
  'video',
  'audio',
  'source',
  'track',
  'select',
  'option',
  'button',
  'textarea',
  'map',
  'area',
  'dialog',
};

const _blockTags = {
  'p',
  'div',
  'section',
  'article',
  'header',
  'footer',
  'main',
  'aside',
  'nav',
  'figure',
  'figcaption',
  'address',
  'center',
  'form',
  'fieldset',
  'legend',
  'details',
  'summary',
  'dl',
  'dt',
  'dd',
  'hgroup',
  'caption',
  'tr',
  'td',
  'th',
  'thead',
  'tbody',
  'tfoot',
};

final _monospace = RegExp(
  r'mono|courier|consolas|menlo|monaco|lucida console|source code|inconsolata',
  caseSensitive: false,
);
final _webAddress = RegExp(
  r'^(https?|ftps?|mailto|tel):',
  caseSensitive: false,
);
final _wordListLevel = RegExp(r'level(\d+)', caseSensitive: false);
final _orderedBullet = RegExp(
  r'^\(?([0-9]{1,3}|[a-zA-Z]|[ivxlcdmIVXLCDM]{1,6})[.)]',
);
final _codeLanguage = RegExp(
  r'(?:^|\s)(?:language|lang|highlight-source)-([\w+#-]+)',
);

Map<String, String> _styleOf(dom.Element element) {
  final style = element.attributes['style'];
  if (style == null) return const {};
  return {
    for (final declaration in style.split(';'))
      if (declaration.indexOf(':') case final colon when colon > 0)
        declaration.substring(0, colon).trim().toLowerCase(): declaration
            .substring(colon + 1)
            .trim()
            .toLowerCase(),
  };
}

bool _hidden(Map<String, String> style) =>
    style['display'] == 'none' ||
    style['visibility'] == 'hidden' ||
    style['mso-hide'] == 'all' ||
    style['mso-list'] == 'ignore';

bool _preformatted(Map<String, String> style) =>
    (style['white-space'] ?? '').startsWith('pre') &&
    _monospace.hasMatch(style['font-family'] ?? '');

class _Walker {
  _Walker([List<Map<String, Object>>? inline]) : _inline = [...?inline];

  final delta = Delta();

  /// Set once something Markdown can format has been seen.
  var formatted = false;

  /// Set when the tables add up to more than [maxTableCells] cells. The
  /// walk stops then, and the paste falls back to the plain text.
  var tooBig = false;
  var _tableCells = 0;

  final _parts = <(Object, Map<String, dynamic>)>[];
  final _blocks = <_Block>[];
  final List<Map<String, Object>> _inline;
  var _pre = 0;
  var _depth = 0;

  void walk(dom.Node node) {
    for (final child in node.nodes) {
      if (child is dom.Text) {
        _text(child.text);
      } else if (child is dom.Element) {
        _element(child);
      }
    }
  }

  void _element(dom.Element element) {
    final tag = element.localName ?? '';
    final style = _styleOf(element);
    if (tooBig || _skipped.contains(tag) || _hidden(style)) return;
    if (_depth > 200) {
      // Pathologically deep markup keeps its text and nothing else.
      _text(element.text);
      return;
    }
    _depth++;
    try {
      switch (tag) {
        case 'br':
          flush(keepEmpty: _pre > 0);
        case 'hr':
          flush();
          _parts.add(({RichMarkdown.ruleType: 'hr'}, const {}));
          formatted = true;
          flush();
        case 'img':
          _image(element);
        case 'input':
          if (element.attributes['type']?.toLowerCase() == 'checkbox') {
            final item = _blocks.whereType<_ItemBlock>().lastOrNull;
            item?.type = element.attributes.containsKey('checked')
                ? 'checked'
                : 'unchecked';
          }
        case 'table':
          _table(element);
        case 'pre':
          _preBlock(element);
        case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
          _block(element, _HeadingBlock(int.parse(tag.substring(1))));
        case 'blockquote':
          _block(element, _QuoteBlock());
        case 'ul' || 'ol':
          _block(element, _ListBlock(ordered: tag == 'ol'));
        case 'li':
          final list = _blocks.whereType<_ListBlock>().lastOrNull;
          final checked =
              element.attributes['aria-checked'] ??
              element.attributes['data-checked'];
          _block(
            element,
            _ItemBlock(switch (checked) {
              'true' => 'checked',
              'false' => 'unchecked',
              _ => list?.ordered ?? false ? 'ordered' : 'bullet',
            }),
          );
        default:
          final wordItem = tag == 'p' ? _wordListItem(style, element) : null;
          if (_blockTags.contains(tag) && _preformatted(style)) {
            _preBlock(element);
          } else if (wordItem != null) {
            _block(element, wordItem);
          } else if (_blockTags.contains(tag)) {
            _block(element, null);
          } else {
            _inlineElement(element, tag, style);
          }
      }
    } finally {
      _depth--;
    }
  }

  void _block(dom.Element element, _Block? block) {
    flush();
    if (block != null) _blocks.add(block);
    walk(element);
    flush();
    if (block != null) _blocks.removeLast();
  }

  void _inlineElement(
    dom.Element element,
    String tag,
    Map<String, String> style,
  ) {
    final attrs = <String, Object>{
      if (tag == 'b' || tag == 'strong') 'bold': true,
      if (const {'i', 'em', 'cite', 'dfn'}.contains(tag)) 'italic': true,
      if (const {'s', 'strike', 'del'}.contains(tag)) 'strike': true,
      if (const {'code', 'kbd', 'samp', 'tt'}.contains(tag)) 'code': true,
      if (tag == 'a') 'link': ?_safeLink(element.attributes['href']),
    };
    switch (style['font-weight']) {
      case 'bold' || 'bolder' || '600' || '700' || '800' || '900':
        attrs['bold'] = true;
      case 'normal' || 'lighter' || '100' || '200' || '300' || '400' || '500':
        attrs['bold'] = false;
    }
    switch (style['font-style']) {
      case 'italic' || 'oblique':
        attrs['italic'] = true;
      case 'normal':
        attrs['italic'] = false;
    }
    final decoration =
        '${style['text-decoration'] ?? ''} ${style['text-decoration-line'] ?? ''}';
    if (decoration.contains('line-through')) attrs['strike'] = true;
    if (_monospace.hasMatch(style['font-family'] ?? '')) attrs['code'] = true;

    _inline.add(attrs);
    walk(element);
    _inline.removeLast();
  }

  /// Word writes lists as paragraphs styled `mso-list: l0 level2 lfo1`, with
  /// the bullet or number as text in a span it marks to be ignored.
  _ItemBlock? _wordListItem(Map<String, String> style, dom.Element element) {
    final list = style['mso-list'];
    if (list == null || list == 'ignore') return null;
    final level = int.tryParse(_wordListLevel.firstMatch(list)?[1] ?? '') ?? 1;
    final marker = element
        .querySelectorAll('span')
        .where((span) => _styleOf(span)['mso-list'] == 'ignore')
        .firstOrNull
        ?.text
        .trim();
    final ordered = marker != null && _orderedBullet.hasMatch(marker);
    return _ItemBlock(ordered ? 'ordered' : 'bullet', depth: level - 1);
  }

  void _preBlock(dom.Element element) {
    flush();
    final classes = [
      element.attributes['class'],
      element.parent?.attributes['class'],
      for (final code in element.querySelectorAll('code'))
        code.attributes['class'],
    ].whereType<String>().join(' ');
    final language =
        element.attributes['data-lang'] ??
        _codeLanguage.firstMatch(classes)?[1];
    _blocks.add(_CodeBlock(language?.toLowerCase()));
    _pre++;
    walk(element);
    flush();
    _pre--;
    _blocks.removeLast();
  }

  void _image(dom.Element element) {
    if (_pre > 0) return;
    final src = element.attributes['src']?.trim() ?? '';
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(src)) return;
    final style = _styleOf(element);
    bool tiny(String? size) {
      final pixels = double.tryParse((size ?? '').replaceAll('px', ''));
      return pixels != null && pixels <= 2;
    }

    // Tracking pixels in emails.
    if (tiny(element.attributes['width']) ||
        tiny(element.attributes['height']) ||
        tiny(style['width']) ||
        tiny(style['height'])) {
      return;
    }
    final alt = element.attributes['alt']?.trim() ?? '';
    final title = element.attributes['title']?.trim() ?? '';
    final link = _currentInline()['link'];
    _parts.add((
      {
        RichMarkdown.imageType: {
          'src': src,
          if (alt.isNotEmpty) 'alt': alt,
          if (title.isNotEmpty) 'title': title,
        },
      },
      {'link': ?link},
    ));
    formatted = true;
  }

  /// A table of short cells becomes a Markdown table. One used for layout,
  /// as emails do, with paragraphs, lists or other tables in its cells, is
  /// read as the blocks it holds.
  void _table(dom.Element table) {
    flush();
    // A caption names the table or its units, so it comes first either way.
    for (final caption in table.children.where(
      (c) => c.localName == 'caption',
    )) {
      _block(caption, null);
    }
    final rows = <List<dom.Element>>[];
    void addRows(dom.Element parent) {
      for (final child in parent.children) {
        switch (child.localName) {
          case 'tr':
            rows.add([
              for (final cell in child.children)
                if (cell.localName == 'td' || cell.localName == 'th') cell,
            ]);
          case 'thead' || 'tbody' || 'tfoot':
            addRows(child);
        }
      }
    }

    addRows(table);
    final grid = table.querySelector('table') == null ? _grid(rows) : null;
    if (tooBig) return;
    if (grid == null) {
      for (final row in rows) {
        for (final cell in row) {
          _block(cell, null);
        }
      }
      return;
    }

    final columns = grid
        .map((row) => row.length)
        .reduce((a, b) => a > b ? a : b);
    String line(List<String> cells) =>
        '| ${[...cells, for (var i = cells.length; i < columns; i++) ''].join(' | ')} |';
    final markdown = [
      line(grid.first),
      line(List.filled(columns, '---')),
      for (final row in grid.skip(1)) line(row),
    ].join('\n');
    _parts.add(({RichMarkdown.tableType: markdown}, const {}));
    formatted = true;
    flush();
  }

  /// Each cell as Markdown, or null if any cell holds more than a line of
  /// text, or there are fewer than two columns. A cell spanning several
  /// columns or rows keeps its text in the first and leaves the others
  /// empty, so every other cell stays in its column.
  List<List<String>>? _grid(List<List<dom.Element>> rows) {
    if (rows.isEmpty) return null;
    int span(dom.Element cell, String name) =>
        (int.tryParse(cell.attributes[name] ?? '') ?? 1).clamp(1, 50);
    final grid = <List<String>>[];
    // For each column a cell from a row above still covers, how many more
    // rows it covers.
    final covered = <int, int>{};
    var cells = 0;
    for (final row in rows) {
      final out = <String>[];
      // Leaves the next columns empty while cells above cover them.
      void skipCovered() {
        while ((covered[out.length] ?? 0) > 0) {
          covered[out.length] = covered[out.length]! - 1;
          out.add('');
        }
      }

      for (final cell in row) {
        skipCovered();
        final walker = _Walker(_inline)..walk(cell);
        walker.flush();
        final ops = walker.delta.toList();
        final lines = ops.fold(
          0,
          (n, op) => op.data is String
              ? n + '\n'.allMatches(op.data as String).length
              : n,
        );
        final blocky = ops.any(
          (op) =>
              op.data is! String ||
              ((op.data as String).contains('\n') &&
                  (op.attributes?.isNotEmpty ?? false)),
        );
        if (blocky || lines > 1) return null;
        final (columns, down) = (span(cell, 'colspan'), span(cell, 'rowspan'));
        for (var i = 0; i < columns; i++) {
          if (down > 1) covered[out.length] = down - 1;
          out.add(i == 0 ? RichMarkdown.tableCell(walker.delta) : '');
        }
        // Checked as cells are added, before any padding to a rectangle.
        if (_tableCells + cells + out.length > maxTableCells) {
          tooBig = true;
          return null;
        }
      }
      // Columns after the row's last cell still covered from above.
      final last = covered.entries
          .where((e) => e.value > 0)
          .fold(-1, (most, e) => e.key > most ? e.key : most);
      while (out.length <= last) {
        if ((covered[out.length] ?? 0) > 0) {
          covered[out.length] = covered[out.length]! - 1;
        }
        out.add('');
      }
      cells += out.length;
      grid.add(out);
    }
    final columns = grid
        .map((row) => row.length)
        .fold(0, (a, b) => a > b ? a : b);
    if (columns < 2) return null;
    if ((_tableCells += grid.length * columns) > maxTableCells) {
      tooBig = true;
      return null;
    }
    return grid;
  }

  Map<String, Object> _currentInline() {
    final attrs = <String, Object>{};
    for (final layer in _inline) {
      for (final MapEntry(:key, :value) in layer.entries) {
        if (value == false) {
          attrs.remove(key);
        } else {
          attrs[key] = value;
        }
      }
    }
    return attrs;
  }

  void _text(String text) {
    if (_pre > 0) {
      final lines = text
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].isNotEmpty) _parts.add((lines[i], const {}));
        if (i < lines.length - 1) flush(keepEmpty: true);
      }
      return;
    }

    var collapsed = text.replaceAll(RegExp('[ \t\n\r\f\u00a0]+'), ' ');
    final last = _parts.lastOrNull?.$1;
    final atSpace = last == null || (last is String && last.endsWith(' '));
    if (atSpace && collapsed.startsWith(' ')) {
      collapsed = collapsed.substring(1);
    }
    if (collapsed.isEmpty) return;

    final attrs = _currentInline();
    _parts.add((collapsed, attrs));
    if (collapsed.trim().isNotEmpty && attrs.isNotEmpty) formatted = true;
  }

  /// Ends the line, giving it the attributes of the block it is in.
  void flush({bool keepEmpty = false}) {
    while (_pre == 0 && _parts.isNotEmpty && _parts.last.$1 is String) {
      final (text as String, attrs) = _parts.last;
      final trimmed = text.trimRight();
      if (trimmed.isNotEmpty) {
        _parts.last = (trimmed, attrs);
        break;
      }
      _parts.removeLast();
    }
    if (_parts.isEmpty && !keepEmpty) return;

    final lineAttrs = _lineAttrs();
    for (final (data, attrs) in _parts) {
      delta.insert(data, attrs.isEmpty ? null : attrs);
    }
    delta.insert('\n', lineAttrs.isEmpty ? null : lineAttrs);
    if (_parts.isNotEmpty &&
        !lineAttrs.containsKey('code-block') &&
        lineAttrs.isNotEmpty) {
      formatted = true;
    }
    _parts.clear();
  }

  Map<String, dynamic> _lineAttrs() {
    for (final block in _blocks.reversed) {
      switch (block) {
        case _CodeBlock(:final language):
          return {'code-block': true, RichMarkdown.codeLanguageKey: ?language};
        case _HeadingBlock(:final level):
          return {'header': level};
        case _ItemBlock(:final type, :final depth):
          final level = depth ?? _blocks.whereType<_ListBlock>().length - 1;
          return {'list': type, if (level > 0) 'indent': level.clamp(0, 8)};
        case _QuoteBlock():
          return {'blockquote': true};
        case _ListBlock():
          continue;
      }
    }
    return {};
  }
}

String? _safeLink(String? href) {
  final link = href?.trim();
  if (link == null || !_webAddress.hasMatch(link)) return null;
  return link;
}
