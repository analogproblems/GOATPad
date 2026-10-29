import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

import '../notes/folder.dart';
import '../notes/note.dart';
import '../notes/note_mode.dart';
import 'search_fold.dart';

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
    _db.createFunction(
      functionName: 'gpad_fold',
      argumentCount: const AllowedArgumentCount(1),
      deterministic: true,
      function: (args) => switch (args[0]) {
        final String text => foldForSearch(text),
        final other => other,
      },
    );
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

  static const schemaVersion = 3;

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
      if (version < 3) {
        // A full-text index over titles and text, kept in step with notes by
        // triggers. Trigrams match any part of a word, in any language and
        // in code, ignoring case and accents. It reads the text from notes
        // by rowid, which stays put because notes are only ever upserted.
        // (VACUUM could renumber rowids; rebuild the index after one.)
        _db.execute('''
          CREATE VIRTUAL TABLE notes_fts USING fts5(
            title, body,
            content = 'notes', content_rowid = 'rowid',
            tokenize = 'trigram remove_diacritics 2'
          );
          CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN
            INSERT INTO notes_fts (rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
          END;
          CREATE TRIGGER notes_fts_delete AFTER DELETE ON notes BEGIN
            INSERT INTO notes_fts (notes_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
          END;
          CREATE TRIGGER notes_fts_update AFTER UPDATE OF title, body ON notes
          WHEN old.title IS NOT new.title OR old.body IS NOT new.body BEGIN
            INSERT INTO notes_fts (notes_fts, rowid, title, body)
            VALUES ('delete', old.rowid, old.title, old.body);
            INSERT INTO notes_fts (rowid, title, body)
            VALUES (new.rowid, new.title, new.body);
          END;
          INSERT INTO notes_fts (notes_fts) VALUES ('rebuild');
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

  /// Notes whose title or text contain every word of [query], best match
  /// first: kept notes before trashed ones, then notes whose title matches,
  /// then the rest. Matching ignores case and accents.
  List<SearchHit> search(String query, {int limit = 50}) {
    final words = query.trim().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.isEmpty) return const [];
    // Trigrams need three characters, counted once case and accents are
    // folded: `fe` plus a combining accent is only two. Shorter words are
    // looked for in a plain scan, which is fine at notepad sizes. It folds
    // the same way as the index, so both kinds of word match alike.
    final folded = [
      for (final w in words)
        if (foldForSearch(w) case final f when f.isNotEmpty) f,
    ];
    if (folded.isEmpty) return const [];
    final indexed = [
      for (final f in folded)
        if (f.runes.length >= 3) '"${f.replaceAll('"', '""')}"',
    ];
    final short = [
      for (final f in folded)
        if (f.runes.length < 3) f,
    ];
    final scan = [
      for (final _ in short)
        'instr(gpad_fold(n.title || char(10) || n.body), ?) > 0',
    ];
    // Trashed notes go last before the limit is applied, so a crowd of them
    // can't push a kept note out of the results.
    final trashedLast = "n.status = '${NoteStatus.trashed.name}'";

    if (indexed.isEmpty) {
      final titleMatches = [
        for (final _ in short) 'instr(gpad_fold(n.title), ?) > 0',
      ].join(' OR ');
      final rows = _db.select(
        'SELECT n.id, n.title, n.body FROM notes n '
        'WHERE ${scan.join(' AND ')} '
        'ORDER BY $trashedLast, NOT ($titleMatches), n.updated_at DESC '
        'LIMIT ?',
        [...short, ...short, limit],
      );
      return [
        for (final row in rows)
          SearchHit(
            row['id'] as String,
            title: _mark(row['title'] as String, short),
            snippet: _snippet(row['body'] as String, short),
          ),
      ];
    }

    // Notes whose title matches come first, then by BM25. Its own column
    // weights aren't enough: BM25 gives nothing to words found in half the
    // notes or more, which in a small notepad is most words.
    final rows = _db.select(
      'SELECT n.id, '
      "highlight(notes_fts, 0, char(2), char(3)) AS marked_title, "
      "snippet(notes_fts, 1, char(2), char(3), '…', 64) AS snippet "
      'FROM notes_fts JOIN notes n ON n.rowid = notes_fts.rowid '
      'WHERE notes_fts MATCH ? ${[for (final c in scan) 'AND $c '].join()}'
      'ORDER BY $trashedLast, instr(marked_title, char(2)) = 0, '
      'bm25(notes_fts) LIMIT ?',
      [indexed.join(' AND '), ...short, limit],
    );
    return [
      for (final row in rows)
        SearchHit(
          row['id'] as String,
          title: row['marked_title'] as String,
          snippet: switch (row['snippet']) {
            final String snippet when snippet.isNotEmpty => snippet,
            _ => null,
          },
        ),
    ];
  }

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

  /// [text] with the first place each of [words] appears marked. The words
  /// are folded with [foldForSearch], and so is [text] to find them, but
  /// the marks go around the text as it was written, accents and all.
  static String _mark(String text, List<String> words) {
    final sources = <int>[];
    final folded = foldForSearch(text, sources);
    final ranges = <(int, int)>[];
    for (final word in words) {
      final at = folded.indexOf(word);
      if (at < 0) continue;
      final last = sources[at + word.length - 1];
      var end = last + charWidthAt(text, last);
      // Keep accents typed as separate marks with their letter.
      while (end < text.length && isCombiningMark(text.codeUnitAt(end))) {
        end++;
      }
      ranges.add((sources[at], end));
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));

    final marked = StringBuffer();
    var done = 0;
    for (var i = 0; i < ranges.length; i++) {
      var (start, end) = ranges[i];
      // Overlapping matches share one mark.
      while (i + 1 < ranges.length && ranges[i + 1].$1 <= end) {
        end = max(end, ranges[++i].$2);
      }
      marked
        ..write(text.substring(done, start))
        ..write(SearchHit.markStart)
        ..write(text.substring(start, end))
        ..write(SearchHit.markEnd);
      done = end;
    }
    return (marked..write(text.substring(done))).toString();
  }

  /// About 60 characters of [body] around the first of [words] it holds,
  /// marked like FTS5's snippet().
  static String? _snippet(String body, List<String> words) {
    if (body.isEmpty) return null;
    final sources = <int>[];
    final folded = foldForSearch(body, sources);
    int? first;
    for (final word in words) {
      final at = folded.indexOf(word);
      if (at >= 0 && (first == null || sources[at] < first)) {
        first = sources[at];
      }
    }
    return _mark(_cut(body, first ?? 0), words);
  }

  static String _cut(String text, int at) {
    final start = (at - 20).clamp(0, text.length);
    final end = (at + 40).clamp(0, text.length);
    return '${start > 0 ? '…' : ''}${text.substring(start, end)}'
        '${end < text.length ? '…' : ''}';
  }

  static ModeGuess _guess(String mode, String? language) =>
      switch (NoteMode.values.byName(mode)) {
        NoteMode.rich => const ModeGuess.rich(),
        NoteMode.plain => const ModeGuess.plain(),
        NoteMode.code => ModeGuess.code(language ?? 'plaintext'),
      };
}

/// A note that matches a search. Matching text in [title] and [snippet] sits
/// between [markStart] and [markEnd].
class SearchHit {
  const SearchHit(this.noteId, {required this.title, this.snippet});

  static const markStart = '\u0002';
  static const markEnd = '\u0003';

  final String noteId;
  final String title;

  /// Text around the best match in the note's text, or its start when only
  /// the title matched. Null for an empty note.
  final String? snippet;
}
