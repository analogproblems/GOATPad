import 'dart:math';

import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notepad/welcome_note.dart';
import 'package:goatpad/src/notes/rich_markdown.dart';

/// Markdown read into Quill and written back out.
String roundTrip(String markdown) =>
    RichMarkdown.fromDelta(RichMarkdown.toDelta(markdown));

Delta paragraph(String text) => Delta()
  ..insert(text)
  ..insert('\n');

/// The text of [delta] if it is a single plain paragraph, else its JSON, so a
/// failing comparison shows what came back.
Object plainText(Delta delta) {
  final ops = delta.toList();
  final plain = ops.every((op) => op.data is String && op.attributes == null);
  if (!plain) return delta.toJson();
  final text = ops.map((op) => op.data as String).join();
  return text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
}

/// Each character that isn't a space, with the formatting on it. Spaces
/// at the edge of a run may lose their formatting on the way through, which
/// changes nothing visible.
List<(String, Set<String>)> styledCharacters(Delta delta) => [
  for (final op in delta.toList())
    for (final char
        in op.data is String ? (op.data as String).split('') : ['${op.data}'])
      if (char.trim().isNotEmpty) (char, {...?op.attributes?.keys}),
];

void main() {
  group('round trip', () {
    test('the welcome note comes back exactly as written', () {
      expect(roundTrip(welcomeNote), welcomeNote);
    });

    test('Markdown in GPad\'s own style comes back unchanged', () {
      const markdown = '''
# Title

Text with **bold**, *italic*, ~~struck~~, `code` and a [link](https://example.com).

## Lists

- one
- two
    - nested
        1. deep
- three
1. first
2. second
- [ ] to do
- [x] done

> A quote
> on two lines

After the quote.

```dart
var x = 1;

print(x);
```

#### Level four

##### Level five

###### Level six

---

| Name | Count |
| --- | --- |
| a \\| b | 1 |

![A cat on a mat](https://example.com/cat.png "The cat")

Visit https://example.com or mail someone@example.com today.
''';
      expect(roundTrip(markdown), markdown);
    });

    test('a paragraph after a quote stays out of the quote', () {
      final delta = Delta()
        ..insert('Quoted')
        ..insert('\n', {'blockquote': true})
        ..insert('Not quoted')
        ..insert('\n');
      final markdown = RichMarkdown.fromDelta(delta);
      expect(markdown, '> Quoted\n\nNot quoted\n');
      expect(RichMarkdown.toDelta(markdown).toJson(), delta.toJson());
    });

    test('headings, code and tables are followed by a blank line', () {
      final delta = Delta()
        ..insert('Title')
        ..insert('\n', {'header': 1})
        ..insert('code')
        ..insert('\n', {'code-block': true})
        ..insert('After')
        ..insert('\n');
      expect(
        RichMarkdown.fromDelta(delta),
        '# Title\n\n```\ncode\n```\n\nAfter\n',
      );
    });

    test('an empty line ends a list', () {
      final delta = Delta()
        ..insert('a')
        ..insert('\n', {'list': 'bullet'})
        ..insert('\n')
        ..insert('b')
        ..insert('\n', {'list': 'bullet'});
      expect(RichMarkdown.fromDelta(delta), '- a\n\n- b\n');
    });

    test('ordered lists count, and nesting clears wide markers', () {
      final delta = Delta();
      for (var i = 1; i <= 10; i++) {
        delta
          ..insert('item $i')
          ..insert('\n', {'list': 'ordered'});
      }
      delta
        ..insert('nested')
        ..insert('\n', {'list': 'bullet', 'indent': 1});
      final markdown = RichMarkdown.fromDelta(delta);
      expect(markdown, contains('9. item 9\n10. item 10\n    - nested'));
      expect(RichMarkdown.toDelta(markdown).toJson(), delta.toJson());
    });

    test('a code block keeps its language and any fences inside it', () {
      final delta = Delta()
        ..insert('```')
        ..insert('\n', {'code-block': true, RichMarkdown.codeLanguageKey: 'md'})
        ..insert('inner')
        ..insert('\n', {'code-block': true})
        ..insert('```')
        ..insert('\n', {'code-block': true});
      final markdown = RichMarkdown.fromDelta(delta);
      expect(markdown, '````md\n```\ninner\n```\n````\n');
      expect(RichMarkdown.fromDelta(RichMarkdown.toDelta(markdown)), markdown);
    });
  });

  group('escaping', () {
    const untouched = [
      'Everything is saved as you go.',
      'Press Ctrl+N, then Ctrl+Shift+V.',
      'snake_case and file_name_here',
      'C# and F# and #hashtag',
      'x < y > z',
      '2 * 3 = 6',
      'Price: \$5 & up (or more)! 100%',
      'a - b + c',
      '~/projects and C:\\Users\\me',
      '"Quotes", \'apostrophes\' and {braces}',
      'She said: brackets] are fine alone',
    ];
    for (final text in untouched) {
      test('leaves "$text" alone', () {
        expect(RichMarkdown.fromDelta(paragraph(text)), '$text\n');
      });
    }

    const escaped = {
      '# Not a heading': r'\# Not a heading',
      '> Not a quote': r'\> Not a quote',
      '- Not a list': r'\- Not a list',
      '+ Not a list': r'\+ Not a list',
      '1. Not a list': r'1\. Not a list',
      '2026) Not a list': r'2026\) Not a list',
      '---': r'\---',
      '===': r'\===',
      '- - -': r'\- - -',
      '**Not bold**': r'\*\*Not bold\*\*',
      '_Not italic_': r'\_Not italic\_',
      '~~Not struck~~': r'\~\~Not struck\~\~',
      '`Not code`': r'\`Not code\`',
      '[Not a link](page.html)': r'\[Not a link](page.html)',
      '<b>Not HTML</b>': r'\<b>Not HTML\</b>',
      '&amp; is not an ampersand': r'\&amp; is not an ampersand',
      r'Ends in a backslash \': r'Ends in a backslash \\',
      r'Not an escape: \*': r'Not an escape: \\\*',
    };
    for (final MapEntry(key: text, value: markdown) in escaped.entries) {
      test('escapes "$text"', () {
        expect(RichMarkdown.fromDelta(paragraph(text)), '$markdown\n');
        expect(plainText(RichMarkdown.toDelta('$markdown\n')), text);
      });
    }

    test('any mix of punctuation reads back as the same plain text', () {
      // Fixed seed, so a failure always shows the same input.
      final random = Random(4);
      const alphabet = r'ab1 *_`[]()<>#&;~\|!-+=.:/@';
      for (var n = 0; n < 3000; n++) {
        final text = String.fromCharCodes([
          for (var i = random.nextInt(14) + 1; i > 0; i--)
            alphabet.codeUnitAt(random.nextInt(alphabet.length)),
        ]).trim();
        if (text.isEmpty) continue;
        for (final (attrs, expected) in [
          (null, text),
          ({'blockquote': true}, null),
          ({'list': 'bullet'}, null),
          ({'header': 2}, null),
        ]) {
          final delta = Delta()
            ..insert(text)
            ..insert('\n', attrs);
          final markdown = RichMarkdown.fromDelta(delta);
          final back = RichMarkdown.toDelta(markdown);
          if (expected != null) {
            expect(plainText(back), text, reason: 'Markdown: $markdown');
          } else {
            expect(
              back.toJson(),
              delta.toJson(),
              reason: 'Markdown: $markdown',
            );
          }
        }
      }
    });
    test('random formatting reads back on the same characters', () {
      final random = Random(7);
      const alphabet = r'ab1 *_`[]<>#&;~\|!-.:';
      const styles = [
        <String, dynamic>{},
        {'bold': true},
        {'italic': true},
        {'strike': true},
        {'code': true},
        {'bold': true, 'italic': true},
        {'link': 'https://example.com/x'},
      ];
      for (var n = 0; n < 2000; n++) {
        final delta = Delta();
        for (var p = random.nextInt(4) + 1; p > 0; p--) {
          final text = String.fromCharCodes([
            for (var i = random.nextInt(6) + 1; i > 0; i--)
              alphabet.codeUnitAt(random.nextInt(alphabet.length)),
          ]);
          final style = styles[random.nextInt(styles.length)];
          delta.insert(text, style.isEmpty ? null : style);
        }
        delta.insert('\n');
        final markdown = RichMarkdown.fromDelta(delta);
        final reason = 'Delta: ${delta.toJson()}\nMarkdown: $markdown';
        final before = styledCharacters(delta);
        final after = styledCharacters(RichMarkdown.toDelta(markdown));
        // The text always survives. Formatting can be lost where Markdown
        // has no way to say it, but never gained.
        expect(after.map((c) => c.$1), before.map((c) => c.$1), reason: reason);
        for (var i = 0; i < before.length; i++) {
          expect(before[i].$2.containsAll(after[i].$2), isTrue, reason: reason);
        }
      }
    });
  });

  group('inline formatting', () {
    void expectRoundTrip(Delta delta, String markdown) {
      expect(RichMarkdown.fromDelta(delta), '$markdown\n');
      expect(RichMarkdown.toDelta('$markdown\n').toJson(), delta.toJson());
    }

    test('spaces move outside emphasis so it still parses', () {
      final delta = Delta()
        ..insert('Some ')
        ..insert('bold ', {'bold': true})
        ..insert('text')
        ..insert('\n');
      expect(RichMarkdown.fromDelta(delta), 'Some **bold** text\n');
    });

    test('bold next to punctuation', () {
      Delta bold(String before, String text, String after) => Delta()
        ..insert(before)
        ..insert(text, {'bold': true})
        ..insert(after)
        ..insert('\n');
      expectRoundTrip(bold('', 'Note:', ' Read this.'), '**Note:** Read this.');
      expectRoundTrip(bold('(', 'see', ')'), '(**see**)');
      expectRoundTrip(bold('"', 'quoted', '"'), '"**quoted**"');
      // Markdown can't close bold between ":" and a letter, or open it
      // between a letter and a quote mark, so that punctuation moves out.
      expect(
        RichMarkdown.fromDelta(bold('', 'Note:', 'Next')),
        '**Note**:Next\n',
      );
      expect(RichMarkdown.fromDelta(bold('a', '"q"', '')), 'a"**q"**\n');
    });

    test('overlapping bold and italic', () {
      final delta = Delta()
        ..insert('one ', {'bold': true})
        ..insert('two', {'bold': true, 'italic': true})
        ..insert(' three', {'italic': true})
        ..insert('\n');
      final markdown = RichMarkdown.fromDelta(delta);
      expect(markdown, '**one *two*** *three*\n');
      // Only the space between the two runs loses its italics.
      expect(
        RichMarkdown.toDelta(markdown).toJson(),
        (Delta()
              ..insert('one ', {'bold': true})
              ..insert('two', {'bold': true, 'italic': true})
              ..insert(' ')
              ..insert('three', {'italic': true})
              ..insert('\n'))
            .toJson(),
      );
    });

    test('emphasis inside a word', () {
      expectRoundTrip(
        Delta()
          ..insert('un')
          ..insert('believ', {'bold': true})
          ..insert('able')
          ..insert('\n'),
        'un**believ**able',
      );
    });

    test('a link around bold text', () {
      expectRoundTrip(
        Delta()
          ..insert('see ')
          ..insert('the ', {'link': 'https://example.com'})
          ..insert('docs', {'link': 'https://example.com', 'bold': true})
          ..insert('\n'),
        'see [the **docs**](https://example.com)',
      );
    });

    test('a link address with spaces or brackets', () {
      final delta = Delta()
        ..insert('file', {'link': 'file:///my notes/a (1.txt'})
        ..insert('\n');
      final markdown = RichMarkdown.fromDelta(delta);
      expect(markdown, '[file](<file:///my notes/a (1.txt>)\n');
      // Reading it back encodes the spaces, which still opens the same file.
      expect(
        RichMarkdown.toDelta(markdown).toJson(),
        (Delta()
              ..insert('file', {'link': 'file:///my%20notes/a%20(1.txt'})
              ..insert('\n'))
            .toJson(),
      );
    });

    test('code holding backticks', () {
      expectRoundTrip(
        Delta()
          ..insert('a ` tick', {'code': true})
          ..insert(' and ')
          ..insert('`edge`', {'code': true})
          ..insert('\n'),
        '``a ` tick`` and `` `edge` ``',
      );
    });

    test('bold code', () {
      expectRoundTrip(
        Delta()
          ..insert('run ')
          ..insert('make', {'bold': true, 'code': true})
          ..insert('\n'),
        'run **`make`**',
      );
    });

    test('an address that is its own link text stays bare', () {
      expectRoundTrip(
        Delta()
          ..insert('Go to ')
          ..insert('https://example.com/a_b', {
            'link': 'https://example.com/a_b',
          })
          ..insert(' now')
          ..insert('\n'),
        'Go to https://example.com/a_b now',
      );
    });

    test('an address next to other text goes in angle brackets', () {
      expectRoundTrip(
        Delta()
          ..insert('(')
          ..insert('https://example.com.', {'link': 'https://example.com.'})
          ..insert(')')
          ..insert('\n'),
        '(<https://example.com.>)',
      );
    });

    test('an image keeps its alt text and title', () {
      expectRoundTrip(
        Delta()
          ..insert('Look: ')
          ..insert({
            RichMarkdown.imageType: {
              'src': 'https://example.com/cat.png',
              'alt': 'A [cat]',
              'title': 'Say "hi"',
            },
          })
          ..insert('\n'),
        r'Look: ![A \[cat\]](https://example.com/cat.png "Say \"hi\"")',
      );
    });

    test('a linked image', () {
      final delta = Delta()
        ..insert(
          {
            RichMarkdown.imageType: {'src': 'https://example.com/a.png'},
          },
          {'link': 'https://example.com'},
        )
        ..insert('\n');
      expect(
        RichMarkdown.fromDelta(delta),
        '[![](https://example.com/a.png)](https://example.com)\n',
      );
    });

    test('formatting Markdown has no syntax for is dropped quietly', () {
      final delta = Delta()
        ..insert('under', {'underline': true, 'color': '#ff0000'})
        ..insert('\n', {'align': 'center'});
      expect(RichMarkdown.fromDelta(delta), 'under\n');
    });

    test('an embed Markdown cannot show keeps its address', () {
      final delta = Delta()
        ..insert({'video': 'https://example.com/v.mp4'})
        ..insert({'formula': 'x^2'})
        ..insert('\n');
      expect(RichMarkdown.fromDelta(delta), '<https://example.com/v.mp4>\n');
    });

    test('an old plain image embed', () {
      final delta = Delta()
        ..insert({'image': 'https://example.com/a.png'})
        ..insert('\n');
      expect(RichMarkdown.fromDelta(delta), '![](https://example.com/a.png)\n');
    });
  });

  test('a table cell escapes its pipes', () {
    expect(
      RichMarkdown.tableCell(
        Delta()
          ..insert('a | b ')
          ..insert('c|d', {'code': true})
          ..insert('\n'),
      ),
      r'a \| b `c\|d`',
    );
  });

  test('an empty note is empty Markdown', () {
    expect(RichMarkdown.fromDelta(Delta()..insert('\n')), '');
    expect(RichMarkdown.fromDelta(Delta()), '');
  });
}
