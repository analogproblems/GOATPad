import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/store/search_fold.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('folds case and accents', () {
    expect(
      foldForSearch('Café CRÈME, Ölwechsel, Phở'),
      'cafe creme, olwechsel, pho',
    );
    expect(foldForSearch('ΣΟΦΙΑ and Москва'), 'σοφια and москва');
    expect(foldForSearch('ß, æ and ø stay'), 'ß, æ and ø stay');
  });

  test('maps each folded character back to where it came from', () {
    final sources = <int>[];
    // İ lowercases to i plus a dot, and the e has its accent typed apart.
    expect(foldForSearch('İs café!', sources), 'is cafe!');
    expect(sources, [0, 1, 2, 3, 4, 5, 6, 8]);
  });

  test('folds letters outside the BMP as SQLite does', () {
    final sources = <int>[];
    // SQLite folds Deseret capitals and leaves the rest, like Osage, alone.
    expect(
      foldForSearch('\u{10400}x\u{104B0}', sources),
      '\u{10428}x\u{104B0}',
    );
    expect(sources, [0, 0, 2, 3, 3]);
    expect(charWidthAt('\u{10400}x', 0), 2);
    expect(charWidthAt('\u{10400}x', 2), 1);
  });

  test("treats exactly the same text as equal as SQLite's index", () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(
      'CREATE VIRTUAL TABLE t USING fts5('
      "x, tokenize = 'trigram remove_diacritics 2')",
    );
    // Every character but the surrogates, combining marks and the
    // non-characters at the end of each plane, through the second plane,
    // plus letters followed by combining marks typed apart. Each sits
    // between two letters, to make a trigram.
    final samples = [
      for (var c = 0x20; c < 0x20000; c++)
        if (!isCombiningMark(c) &&
            (c < 0xd800 || c > 0xdfff) &&
            c & 0xfffe != 0xfffe)
          String.fromCharCode(c),
      for (final letter in ['a', 'E', 'n', 'O', 'u', 'ı', 'ø', 'ß', 'ά'])
        for (var mark = 0x300; mark <= 0x36f; mark++)
          '$letter${String.fromCharCode(mark)}',
    ];
    final insert = db.prepare('INSERT INTO t (rowid, x) VALUES (?, ?)');
    final sameFold = <String, Set<int>>{};
    db.execute('BEGIN');
    for (var i = 0; i < samples.length; i++) {
      final text = 'q${samples[i]}z';
      insert.execute([i, text]);
      sameFold.putIfAbsent(foldForSearch(text), () => {}).add(i);
    }
    db.execute('COMMIT');
    insert.close();

    // Searching the index for each folded form must find exactly the
    // samples that fold to it: no fewer, and no more.
    final disagree = <String>[];
    sameFold.forEach((folded, expected) {
      final found = {
        for (final row in db.select('SELECT rowid FROM t WHERE t MATCH ?', [
          '"${folded.replaceAll('"', '""')}"',
        ]))
          row['rowid'] as int,
      };
      if (found.length != expected.length || !found.containsAll(expected)) {
        disagree.add(
          '$folded: ${expected.map((i) => samples[i])} vs '
          '${found.map((i) => samples[i])}',
        );
      }
    });
    expect(disagree, isEmpty);
  });
}
