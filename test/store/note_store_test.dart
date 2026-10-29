import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notes/folder.dart';
import 'package:goatpad/src/notes/note.dart';
import 'package:goatpad/src/notes/note_mode.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:sqlite3/sqlite3.dart';

Note _note({
  String id = 'a1',
  String text = 'SELECT 1;',
  NoteStatus status = NoteStatus.open,
  String? folderId,
}) => Note(
  id: id,
  folderId: folderId,
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
    expect(loaded.folderId, isNull);
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

  test('folders load back, nested, with what is in them', () {
    final store = NoteStore.inMemory();
    final work = Folder(
      id: 'f1',
      name: 'Work',
      expanded: false,
      tabsCollapsed: true,
      createdAt: DateTime(2026, 10, 29, 9),
      updatedAt: DateTime(2026, 10, 29, 10),
    );
    final recipes = Folder(
      id: 'f2',
      parentId: 'f1',
      name: 'Recipes',
      createdAt: DateTime(2026, 10, 29, 9),
      updatedAt: DateTime(2026, 10, 29, 9),
    );
    store.saveFolders([work, recipes]);
    store.saveNote(_note(folderId: 'f2'));

    final loaded = {for (final f in store.loadFolders()) f.id: f};
    expect(loaded['f1']!.name, 'Work');
    expect(loaded['f1']!.parentId, isNull);
    expect(loaded['f1']!.expanded, isFalse);
    expect(loaded['f1']!.tabsCollapsed, isTrue);
    expect(loaded['f1']!.updatedAt, DateTime(2026, 10, 29, 10));
    expect(loaded['f2']!.parentId, 'f1');
    expect(loaded['f2']!.expanded, isTrue);
    expect(store.loadNotes().single.folderId, 'f2');

    recipes.name = 'Cooking';
    store.saveFolder(recipes);
    store.deleteFolders(['f1']);
    expect(store.loadFolders().single.name, 'Cooking');
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

  test('notes saved before folders existed open without loss', () {
    final path = '${temp.path}/notes.db';
    // The first GPad schema, as step 2 part 1 shipped it.
    sqlite3.open(path)
      ..execute('''
        CREATE TABLE notes (
          id TEXT PRIMARY KEY, title TEXT NOT NULL,
          title_edited INTEGER NOT NULL, body TEXT NOT NULL,
          mode TEXT NOT NULL, language TEXT, status TEXT NOT NULL,
          tab_order INTEGER NOT NULL, awaiting_paste INTEGER NOT NULL,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          trashed_at INTEGER
        );
        CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO notes VALUES ('a1', 'Old note', 0, 'Kept', 'plain', NULL,
          'open', 0, 0, 0, 0, NULL);
        INSERT INTO settings VALUES ('welcomed', '1');
      ''')
      ..userVersion = 1
      ..close();

    final store = NoteStore.open(path);
    final note = store.loadNotes().single;
    expect(note.text, 'Kept');
    expect(note.folderId, isNull);
    expect(store.loadFolders(), isEmpty);
    expect(store.setting('welcomed'), '1');
    // Notes from before sync are waiting to be uploaded once it is on.
    expect(store.pendingSync().map((s) => s.id), ['a1']);
    store.close();

    final db = sqlite3.open(path);
    expect(db.userVersion, NoteStore.schemaVersion);
    db.close();
  });

  test('sync counts the changes other machines see, and only those', () {
    final store = NoteStore.inMemory();
    int seq(String id) => store.syncState(id)!.localSeq;
    final note = _note(text: 'one');
    store.saveNote(note);
    expect(seq('a1'), 1);
    store.saveNote(note);
    expect(seq('a1'), 1, reason: 'saving the same values is no change');
    store.saveNote(note..text = 'two');
    expect(seq('a1'), 2);

    final folder = Folder(
      id: 'f1',
      name: 'Work',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    store.saveFolder(folder);
    store.saveFolder(folder..expanded = false);
    store.saveFolder(folder..tabsCollapsed = true);
    expect(seq('f1'), 1, reason: 'folding stays on each machine');
    store.saveFolder(folder..name = 'Job');
    expect(seq('f1'), 2);

    store.saveSyncState('a1', kind: 'note');
    expect(store.pendingSync().map((s) => s.id), ['f1']);
    store.deleteNotes(['a1']);
    expect(seq('a1'), 3);
    expect(store.pendingSync().map((s) => s.id), containsAll(['a1', 'f1']));
    store.saveSyncState('a1', kind: 'note', upload: true);
    expect(store.syncState('a1')!.syncedSeq, -1);
    store.close();
  });

  group('search', () {
    late NoteStore store;
    setUp(() {
      store = NoteStore.inMemory();
      store.saveNotes([
        _note(id: 'menu', text: 'Espresso, croissants and a Café crème.'),
        _note(id: 'sql', text: 'SELECT price FROM menu WHERE item = "café";'),
        _note(id: 'empty', text: ''),
      ]);
      // Titles: 'Query' for all but one.
      final titled = _note(id: 'titled', text: 'Notes from the meeting')
        ..title = 'Menu ideas';
      store.saveNote(titled);
    });
    tearDown(() => store.close());

    List<String> ids(String query) => [
      for (final hit in store.search(query)) hit.noteId,
    ];

    test('finds part of a word, ignoring case and accents', () {
      expect(ids('CAFE'), unorderedEquals(['menu', 'sql']));
      expect(ids('roiss'), ['menu']);
    });

    test('needs every word, and ranks title matches first', () {
      expect(ids('menu'), ['titled', 'sql']);
      expect(ids('menu price'), ['sql']);
      expect(ids('menu nothing'), isEmpty);
    });

    test('marks the matches in the title and the text around them', () {
      final hit = store.search('ideas').single;
      expect(hit.title, 'Menu ${SearchHit.markStart}ideas${SearchHit.markEnd}');
      expect(hit.snippet, 'Notes from the meeting');

      final body = store.search('price').single;
      expect(body.snippet, contains('${SearchHit.markStart}price'));
    });

    test('short words and quotes are matched as typed', () {
      expect(ids('a'), containsAll(['menu', 'sql', 'titled']));
      expect(ids('"café";'), ['sql']);
      expect(ids('= "'), ['sql']);
      expect(ids('  '), isEmpty);
    });

    test('short words ignore case and accents too, alone or mixed', () {
      store.saveNote(_note(id: 'oil', text: 'Motor ÖL, 5 Liter'));
      expect(ids('öl'), ['oil']);
      expect(ids('Ol'), ['oil']);
      expect(ids('fe'), unorderedEquals(['menu', 'sql']));
      expect(ids('motor öl'), ['oil']);
      expect(ids('crème FE'), ['menu']);
      expect(ids('crème öl'), isEmpty);
      // An accent typed apart doesn't make a word long enough for the index.
      expect(ids('fe\u0301'), unorderedEquals(['menu', 'sql']));
      expect(ids('cre\u0300me fe\u0301'), ['menu']);
      expect(ids('\u0301'), isEmpty);
    });

    test('marks short words where they are, however they were written', () {
      store.saveNote(
        _note(id: 'trip', text: 'Ask about the cafe\u0301 au lait')
          ..title = 'İstanbul trip',
      );
      final hit = store.search('is fe au').single;
      final (start, end) = (SearchHit.markStart, SearchHit.markEnd);
      expect(hit.title, '$start\u0130s${end}tanbul trip');
      expect(
        hit.snippet,
        'Ask about the ca${start}fe\u0301$end ${start}au$end lait',
      );
    });

    test('follows edits and deletions', () {
      store.saveNote(_note(id: 'menu', text: 'Tea and scones'));
      expect(ids('croissant'), isEmpty);
      expect(ids('scones'), ['menu']);

      store.deleteNotes(['menu']);
      expect(ids('scones'), isEmpty);
    });
  });

  test('a crowd of trashed matches never hides a kept note', () {
    final store = NoteStore.inMemory();
    addTearDown(store.close);
    store.saveNotes([
      for (var i = 0; i < 60; i++)
        _note(id: 't$i', text: 'ok', status: NoteStatus.trashed)
          ..title = 'Milk $i'
          ..updatedAt = DateTime(2026, 10, 29, 12, i),
    ]);
    // Matches only in its text, and is the oldest: last but for the trash.
    store.saveNote(_note(id: 'kept', text: 'Buy milk, ok?'));

    for (final query in ['milk', 'ok']) {
      final hits = store.search(query);
      expect(hits, hasLength(50));
      expect(hits.first.noteId, 'kept', reason: query);
    }
  });

  test('upgrading from folders indexes the notes already there', () {
    final path = '${temp.path}/notes.db';
    final store = NoteStore.open(path);
    store.saveNote(_note(text: 'Remember the milk'));
    // Back to schema 2: no search index or sync records yet.
    store.database.execute('''
      DROP TRIGGER notes_fts_insert;
      DROP TRIGGER notes_fts_delete;
      DROP TRIGGER notes_fts_update;
      DROP TABLE notes_fts;
      DROP TRIGGER notes_sync_insert;
      DROP TRIGGER notes_sync_update;
      DROP TRIGGER notes_sync_delete;
      DROP TRIGGER folders_sync_insert;
      DROP TRIGGER folders_sync_update;
      DROP TRIGGER folders_sync_delete;
      DROP TABLE sync_records;
    ''');
    store.database.userVersion = 2;
    store.close();

    final upgraded = NoteStore.open(path);
    expect(upgraded.search('milk').single.noteId, 'a1');
    upgraded.close();
  });

  test('notes from a newer GPad are refused rather than changed', () {
    final path = '${temp.path}/notes.db';
    sqlite3.open(path)
      ..userVersion = NoteStore.schemaVersion + 1
      ..close();

    expect(() => NoteStore.open(path), throwsStateError);
  });
}
