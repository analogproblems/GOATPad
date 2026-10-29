import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notes/mode_detector.dart';
import 'package:goatpad/src/notes/note_mode.dart';

void main() {
  final detector = ModeDetector();

  group('exact formats', () {
    test('JSON object', () {
      expect(
        detector.detect('{"name": "goatpad", "tags": ["notes", 1, true]}'),
        const ModeGuess.code('json'),
      );
    });

    test('JSON array with surrounding whitespace', () {
      expect(detector.detect('\n  [1, 2, 3]\n'), const ModeGuess.code('json'));
    });

    test('broken JSON is not JSON', () {
      expect(detector.detect('{name: goatpad').language, isNot('json'));
    });

    test('XML document', () {
      expect(
        detector.detect('<?xml version="1.0"?>\n<notes><note id="1"/></notes>'),
        const ModeGuess.code('xml'),
      );
    });
  });

  group('code', () {
    test('Python', () {
      expect(
        detector.detect('''
import os

def list_notes(folder):
    """Return note files in folder."""
    return [f for f in os.listdir(folder) if f.endswith(".md")]
'''),
        const ModeGuess.code('python'),
      );
    });

    test('SQL', () {
      expect(
        detector.detect('''
SELECT id, title, updated_at
FROM notes
WHERE folder_id = 42 AND closed = 0
ORDER BY updated_at DESC
LIMIT 20;
'''),
        const ModeGuess.code('sql'),
      );
    });

    test('C#', () {
      expect(
        detector.detect('''
using System;

namespace Goat
{
    public class Note
    {
        public string Title { get; set; }
        public override string ToString() => Title;
    }
}
'''),
        const ModeGuess.code('csharp'),
      );
    });

    test('Bash', () {
      expect(
        detector.detect('''
#!/usr/bin/env bash
set -euo pipefail
for f in *.log; do
  echo "Compressing \$f"
  gzip "\$f"
done
'''),
        const ModeGuess.code('bash'),
      );
    });

    test('a short JavaScript snippet', () {
      expect(
        detector.detect(
          'const res = await fetch(url);\nconsole.log(res.status);',
        ),
        const ModeGuess.code('javascript'),
      );
    });

    test('YAML', () {
      expect(
        detector.detect('''
name: goatpad
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
'''),
        const ModeGuess.code('yaml'),
      );
    });

    test('a diff', () {
      expect(
        detector.detect('''
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -1,3 +1,3 @@
 void main() {
-  print('hello');
+  print('hello, GPad');
 }
'''),
        const ModeGuess.code('diff'),
      );
    });
  });

  group('rich', () {
    test('Markdown with headings and lists', () {
      expect(
        detector.detect('''
# Trip notes

- Book the train
- Pack the **good** charger
'''),
        const ModeGuess.rich(),
      );
    });

    test('a list under a heading line is a list, not a diff', () {
      expect(
        detector.detect('Grocery list\n- oat milk\n- crème fraîche\n- lemons'),
        const ModeGuess.rich(),
      );
      expect(
        detector.detect('Pros and cons\n+ cheap\n+ fast\n- noisy'),
        const ModeGuess.rich(),
      );
    });

    test('Markdown with a link and a quote', () {
      expect(
        detector.detect(
          '> Read this first\n\nSee [the docs](https://example.com) for more.',
        ),
        const ModeGuess.rich(),
      );
    });

    test('formatting on the clipboard means rich', () {
      expect(
        detector.detect('Plain words', clipboardHadFormatting: true),
        const ModeGuess.rich(),
      );
      expect(
        detector.detect('def f():\n    return 1', clipboardHadFormatting: true),
        const ModeGuess.rich(),
      );
      // An image copied on its own has no plain text.
      expect(
        detector.detect('', clipboardHadFormatting: true),
        const ModeGuess.rich(),
      );
    });

    test('but JSON and XML stay code whatever the clipboard says', () {
      expect(
        detector.detect('{"a": 1}', clipboardHadFormatting: true),
        const ModeGuess.code('json'),
      );
      expect(
        detector.detect('<a><b/></a>', clipboardHadFormatting: true),
        const ModeGuess.code('xml'),
      );
    });
  });

  group('plain', () {
    test('empty text', () {
      expect(detector.detect('   \n'), const ModeGuess.plain());
    });

    test('an email', () {
      expect(
        detector.detect('''
Hi Sam,

Can you select a time for the review from the options below? I think
Thursday works best, and we should order lunch for the team if it runs long.

Thanks,
Jason
'''),
        const ModeGuess.plain(),
      );
    });

    test('a short sentence', () {
      expect(
        detector.detect('Remember to call the dentist on Friday.'),
        const ModeGuess.plain(),
      );
    });

    test('a log line', () {
      expect(
        detector.detect(
          '2026-10-29 03:12:44 ERROR [sync] upload failed: 503 (retry in 30s)',
        ),
        const ModeGuess.plain(),
      );
    });

    test('a URL', () {
      expect(
        detector.detect('https://github.com/analogproblems/GOATPad/pull/1'),
        const ModeGuess.plain(),
      );
    });

    test('a list of words', () {
      expect(
        detector.detect('milk\neggs\nbread\ncoffee'),
        const ModeGuess.plain(),
      );
    });
  });

  test('huge JSON is recognized without parsing all of it', () {
    final big =
        '[${List.filled(200000, '{"id": 1, "title": "note"}').join(',')}]';
    expect(big.length, greaterThan(ModeDetector.maxExactParseLength));
    final watch = Stopwatch()..start();
    expect(detector.detect(big), const ModeGuess.code('json'));
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('huge text that merely starts with a bracket is not JSON', () {
    final big = '[draft] ${List.filled(200000, 'some words here').join(' ')}';
    expect(detector.detect(big).language, isNot('json'));
  });

  test('a huge paste is only sampled', () {
    final big = List.filled(
      20000,
      'SELECT * FROM notes WHERE id = 1;',
    ).join('\n');
    final watch = Stopwatch()..start();
    expect(detector.detect(big).mode, NoteMode.code);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });
}
