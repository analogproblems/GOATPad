import 'package:sqlite3/sqlite3.dart';

import '../notes/note.dart';
import '../notes/note_mode.dart';

/// Another GPad window already has the notes open.
class StoreLockedException implements Exception {
  const StoreLockedException(this.path);

  final String path;

  @override
  String toString() => 'StoreLockedException: $path is open in another GPad';
}

/// Notes and settings in a local SQLite database.
///
/// Calls are synchronous: SQLite answers small reads and writes in well under
/// a millisecond, and the notepad batches keystrokes before saving.
class NoteStore {
  NoteStore._(this._db) {
    _migrate();
    _saveNote = _db.prepare(_upsertNote, persistent: true);
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
      db.execute('PRAGMA synchronous = NORMAL');
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

  static const schemaVersion = 1;

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
      _db.userVersion = schemaVersion;
    });
  }

  static const _upsertNote = '''
    INSERT INTO notes (id, title, title_edited, body, mode, language, status,
      tab_order, awaiting_paste, created_at, updated_at, trashed_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
      trashed_at = excluded.trashed_at
  ''';

  List<Note> loadNotes() => [
    for (final row in _db.select('SELECT * FROM notes'))
      Note(
        id: row['id'] as String,
        title: row['title'] as String,
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
      ]);
    }
  });

  void saveNote(Note note) => saveNotes([note]);

  void deleteNotes(Iterable<String> ids) => _transaction(() {
    for (final id in ids) {
      _db.execute('DELETE FROM notes WHERE id = ?', [id]);
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
    _db.close();
  }

  void _transaction(void Function() body) {
    _db.execute('BEGIN');
    try {
      body();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
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
