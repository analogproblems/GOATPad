import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notes/note.dart';
import 'package:goatpad/src/notes/note_mode.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:sqlite3/sqlite3.dart';

Note _note({
  String id = 'a1',
  String text = 'SELECT 1;',
  NoteStatus status = NoteStatus.open,
}) => Note(
  id: id,
  title: 'Query',
  titleEdited: true,
  text: text,
  guess: const ModeGuess.code('sql'),
  status: status,
  tabOrder: 3,
  awaitingFirstPaste: true,
  createdAt: DateTime(2026, 10, 29, 9),
  updatedAt: DateTime(2026, 10, 29, 10),
  trashedAt: status == NoteStatus.trashed ? DateTime(2026, 10, 29, 11) : null,
);

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('gpad_store_'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('a saved note loads back with every field', () {
    final store = NoteStore.inMemory();
    store.saveNote(_note(status: NoteStatus.trashed));

    final loaded = store.loadNotes().single;
    expect(loaded.id, 'a1');
    expect(loaded.title, 'Query');
    expect(loaded.titleEdited, isTrue);
    expect(loaded.text, 'SELECT 1;');
    expect(loaded.guess, const ModeGuess.code('sql'));
    expect(loaded.status, NoteStatus.trashed);
    expect(loaded.tabOrder, 3);
    expect(loaded.awaitingFirstPaste, isTrue);
    expect(loaded.createdAt, DateTime(2026, 10, 29, 9));
    expect(loaded.updatedAt, DateTime(2026, 10, 29, 10));
    expect(loaded.trashedAt, DateTime(2026, 10, 29, 11));
    store.close();
  });

  test('saving again updates the note instead of adding one', () {
    final store = NoteStore.inMemory();
    final note = _note();
    store.saveNote(note);
    note.text = 'SELECT 2;';
    store.saveNote(note);

    expect(store.loadNotes().single.text, 'SELECT 2;');
    store.close();
  });

  test('deleted notes are gone', () {
    final store = NoteStore.inMemory();
    store.saveNotes([_note(id: 'a'), _note(id: 'b'), _note(id: 'c')]);
    store.deleteNotes(['a', 'c']);

    expect(store.loadNotes().map((n) => n.id), ['b']);
    store.close();
  });

  test('save writes notes, settings and deletions together or not at all', () {
    final store = NoteStore.inMemory();
    store.saveNotes([_note(id: 'a'), _note(id: 'b')]);

    final db = store.database;
    final pages = db.select('PRAGMA page_count').single.values.single;
    db.execute('PRAGMA max_page_count = $pages');
    expect(
      () => store.save(
        notes: [_note(id: 'a', text: 'x' * 100000)],
        settings: {'theme': 'slate'},
        deletedNoteIds: ['b'],
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(store.loadNotes().map((n) => n.text), ['SELECT 1;', 'SELECT 1;']);
    expect(store.setting('theme'), isNull);

    db.execute('PRAGMA max_page_count = 1000000');
    store.save(
      notes: [_note(id: 'a', text: 'x' * 100000)],
      settings: {'theme': 'slate'},
      deletedNoteIds: ['b'],
    );
    expect(store.loadNotes().single.text, hasLength(100000));
    expect(store.setting('theme'), 'slate');
    store.close();
  });

  test('settings are stored and overwritten', () {
    final store = NoteStore.inMemory();
    expect(store.setting('theme'), isNull);
    store.setSetting('theme', 'warm');
    store.setSetting('theme', 'slate');
    expect(store.setting('theme'), 'slate');
    store.close();
  });

  test('notes survive closing and reopening the file', () {
    final path = '${temp.path}/notes.db';
    final first = NoteStore.open(path);
    first.saveNote(_note());
    first.close();

    final second = NoteStore.open(path);
    expect(second.loadNotes().single.text, 'SELECT 1;');
    second.close();
  });

  test('a finished save is synced to disk, so it survives a power cut', () {
    final store = NoteStore.open('${temp.path}/notes.db');
    final db = store.database;
    expect(db.select('PRAGMA journal_mode').single.values.single, 'wal');
    // 2 is FULL: the log is synced on every commit.
    expect(db.select('PRAGMA synchronous').single.values.single, 2);
    store.close();
  });

  test('a second GPad on the same notes is turned away until the first '
      'closes', () {
    final path = '${temp.path}/notes.db';
    final first = NoteStore.open(path);
    expect(() => NoteStore.open(path), throwsA(isA<StoreLockedException>()));

    first.close();
    NoteStore.open(path).close();
  });

  test('notes from a newer GPad are refused rather than changed', () {
    final path = '${temp.path}/notes.db';
    sqlite3.open(path)
      ..userVersion = NoteStore.schemaVersion + 1
      ..close();

    expect(() => NoteStore.open(path), throwsStateError);
  });
}
