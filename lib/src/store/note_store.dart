import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/folder.dart';
import '../notes/note.dart';
import '../notes/note_mode.dart';

/// Another GPad window already has the notes open.
class StoreLockedException implements Exception {
  const StoreLockedException(this.path);

  final String path;

  @override
  String toString() => 'StoreLockedException: $path is open in another GPad';
}

/// Notes, folders and settings in a local SQLite database.
///
/// Calls are synchronous: SQLite answers small reads and writes in well under
/// a millisecond, and the notepad batches keystrokes before saving.
class NoteStore {
  NoteStore._(this._db) {
    _migrate();
    _saveNote = _db.prepare(_upsertNote, persistent: true);
    _saveFolder = _db.prepare(_upsertFolder, persistent: true);
  }

  /// Opens or creates the database at [path].
  ///
  /// The file stays locked while it is open, so a second GPad window can't
  /// overwrite edits made in the first. That window gets a
  /// [StoreLockedException] instead.
  factory NoteStore.open(String path) {
    final db = sqlite3.open(path);
    try {
      // In exclusive mode SQLite keeps the lock it takes for the first write
      // until the database is closed.
      db.execute('PRAGMA locking_mode = EXCLUSIVE');
      db.execute('PRAGMA journal_mode = WAL');
      // FULL syncs the log to disk on every commit, so a save that has
      // finished survives a power cut. NORMAL would be faster but could
      // lose saves made since the last checkpoint.
      db.execute('PRAGMA synchronous = FULL');
      db.execute('BEGIN EXCLUSIVE; COMMIT;');
    } on SqliteException catch (e) {
      db.close();
      if (e.resultCode == SqlError.SQLITE_BUSY) {
        throw StoreLockedException(path);
      }
      rethrow;
    }
    try {
      return NoteStore._(db);
    } catch (_) {
      db.close();
      rethrow;
    }
  }

  /// A store that lives only in memory, for tests.
  factory NoteStore.inMemory() => NoteStore._(sqlite3.openInMemory());

  final Database _db;
  late final PreparedStatement _saveNote;
  late final PreparedStatement _saveFolder;

  /// The connection, for tests that check its settings or make it fail.
  @visibleForTesting
  Database get database => _db;

  static const schemaVersion = 2;

  void _migrate() {
    final version = _db.userVersion;
    if (version > schemaVersion) {
      throw StateError(
        'These notes were saved by a newer GPad (schema $version). '
        'Update GPad to open them.',
      );
    }
    if (version == schemaVersion) return;

    _transaction(() {
      if (version < 1) {
        _db.execute('''
          CREATE TABLE notes (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            title_edited INTEGER NOT NULL,
            body TEXT NOT NULL,
            mode TEXT NOT NULL,
            language TEXT,
            status TEXT NOT NULL,
            tab_order INTEGER NOT NULL,
            awaiting_paste INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            trashed_at INTEGER
          );
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          );
        ''');
      }
      if (version < 2) {
        _db.execute('''
          CREATE TABLE folders (
            id TEXT PRIMARY KEY,
            parent_id TEXT,
            name TEXT NOT NULL,
            expanded INTEGER NOT NULL,
            tabs_collapsed INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          );
          ALTER TABLE notes ADD COLUMN folder_id TEXT;
        ''');
      }
      _db.userVersion = schemaVersion;
    });
  }

  static const _upsertNote = '''
    INSERT INTO notes (id, title, title_edited, body, mode, language, status,
      tab_order, awaiting_paste, created_at, updated_at, trashed_at, folder_id)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET
      title = excluded.title,
      title_edited = excluded.title_edited,
      body = excluded.body,
      mode = excluded.mode,
      language = excluded.language,
      status = excluded.status,
      tab_order = excluded.tab_order,
      awaiting_paste = excluded.awaiting_paste,
      updated_at = excluded.updated_at,
      trashed_at = excluded.trashed_at,
      folder_id = excluded.folder_id
  ''';

  static const _upsertFolder = '''
    INSERT INTO folders (id, parent_id, name, expanded, tabs_collapsed,
      created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT (id) DO UPDATE SET
      parent_id = excluded.parent_id,
      name = excluded.name,
      expanded = excluded.expanded,
      tabs_collapsed = excluded.tabs_collapsed,
      updated_at = excluded.updated_at
  ''';

  List<Note> loadNotes() => [
    for (final row in _db.select('SELECT * FROM notes'))
      Note(
        id: row['id'] as String,
        title: row['title'] as String,
        folderId: row['folder_id'] as String?,
        titleEdited: row['title_edited'] == 1,
        text: row['body'] as String,
        guess: _guess(row['mode'] as String, row['language'] as String?),
        status: NoteStatus.values.byName(row['status'] as String),
        tabOrder: row['tab_order'] as int,
        awaitingFirstPaste: row['awaiting_paste'] == 1,
        createdAt: _time(row['created_at'] as int),
        updatedAt: _time(row['updated_at'] as int),
        trashedAt: switch (row['trashed_at']) {
          final int ms => _time(ms),
          _ => null,
        },
      ),
  ];

  /// Inserts or updates [notes] in one transaction.
  void saveNotes(Iterable<Note> notes) => _transaction(() {
    for (final note in notes) {
      _saveNote.execute([
        note.id,
        note.title,
        note.titleEdited ? 1 : 0,
        note.text,
        note.guess.mode.name,
        note.guess.language,
        note.status.name,
        note.tabOrder,
        note.awaitingFirstPaste ? 1 : 0,
        note.createdAt.millisecondsSinceEpoch,
        note.updatedAt.millisecondsSinceEpoch,
        note.trashedAt?.millisecondsSinceEpoch,
        note.folderId,
      ]);
    }
  });

  void saveNote(Note note) => saveNotes([note]);

  /// Saves [notes], [folders] and [settings] and deletes the notes and
  /// folders with the given ids, in one transaction: either all of it is
  /// saved or, if this throws, none of it.
  void save({
    Iterable<Note> notes = const [],
    Iterable<Folder> folders = const [],
    Map<String, String> settings = const {},
    Iterable<String> deletedNoteIds = const [],
    Iterable<String> deletedFolderIds = const [],
  }) => _transaction(() {
    saveNotes(notes);
    saveFolders(folders);
    settings.forEach(setSetting);
    deleteNotes(deletedNoteIds);
    deleteFolders(deletedFolderIds);
  });

  void deleteNotes(Iterable<String> ids) => _transaction(() {
    for (final id in ids) {
      _db.execute('DELETE FROM notes WHERE id = ?', [id]);
    }
  });

  List<Folder> loadFolders() => [
    for (final row in _db.select('SELECT * FROM folders'))
      Folder(
        id: row['id'] as String,
        parentId: row['parent_id'] as String?,
        name: row['name'] as String,
        expanded: row['expanded'] == 1,
        tabsCollapsed: row['tabs_collapsed'] == 1,
        createdAt: _time(row['created_at'] as int),
        updatedAt: _time(row['updated_at'] as int),
      ),
  ];

  /// Inserts or updates [folders] in one transaction.
  void saveFolders(Iterable<Folder> folders) => _transaction(() {
    for (final folder in folders) {
      _saveFolder.execute([
        folder.id,
        folder.parentId,
        folder.name,
        folder.expanded ? 1 : 0,
        folder.tabsCollapsed ? 1 : 0,
        folder.createdAt.millisecondsSinceEpoch,
        folder.updatedAt.millisecondsSinceEpoch,
      ]);
    }
  });

  void saveFolder(Folder folder) => saveFolders([folder]);

  void deleteFolders(Iterable<String> ids) => _transaction(() {
    for (final id in ids) {
      _db.execute('DELETE FROM folders WHERE id = ?', [id]);
    }
  });

  String? setting(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setSetting(String key, String value) => _db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?) '
    'ON CONFLICT (key) DO UPDATE SET value = excluded.value',
    [key, value],
  );

  void close() {
    _saveNote.close();
    _saveFolder.close();
    _db.close();
  }

  void _transaction(void Function() body) {
    // Inside another transaction, which commits or rolls back for both.
    if (!_db.autocommit) return body();
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      // SQLite rolls back by itself after some errors, like a full disk.
      if (!_db.autocommit) _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static DateTime _time(int ms) => DateTime.fromMillisecondsSinceEpoch(ms);

  static ModeGuess _guess(String mode, String? language) =>
      switch (NoteMode.values.byName(mode)) {
        NoteMode.rich => const ModeGuess.rich(),
        NoteMode.plain => const ModeGuess.plain(),
        NoteMode.code => ModeGuess.code(language ?? 'plaintext'),
      };
}
