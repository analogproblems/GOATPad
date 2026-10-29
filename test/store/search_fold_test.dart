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

  test("treats exactly the same characters as equal as SQLite's index", () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(
      'CREATE VIRTUAL TABLE t USING fts5('
      "x, tokenize = 'trigram remove_diacritics 2')",
    );
    // Every character outside the surrogates, combining marks and the two
    // non-characters at the very end, each between two letters.
    final characters = [
      for (var c = 0x20; c < 0xfffe; c++)
        if (!isCombiningMark(c) && (c < 0xd800 || c > 0xdfff)) c,
    ];
    final insert = db.prepare('INSERT INTO t (rowid, x) VALUES (?, ?)');
    final sameFold = <String, Set<int>>{};
    db.execute('BEGIN');
    for (final c in characters) {
      final text = 'q${String.fromCharCode(c)}z';
      insert.execute([c, text]);
      sameFold.putIfAbsent(foldForSearch(text), () => {}).add(c);
    }
    db.execute('COMMIT');
    insert.close();

    // Searching the index for each folded form must find exactly the
    // characters that fold to it: no fewer, and no more.
    final disagree = <String>[];
    sameFold.forEach((folded, expected) {
      final found = {
        for (final row in db.select('SELECT rowid FROM t WHERE t MATCH ?', [
          '"${folded.replaceAll('"', '""')}"',
        ]))
          row['rowid'] as int,
      };
      if (found.length != expected.length || !found.containsAll(expected)) {
        disagree.add('$folded: $expected vs $found');
      }
    });
    expect(disagree, isEmpty);
  });
}
