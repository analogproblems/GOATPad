import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../notes/folder.dart';
import '../notes/html_markdown.dart';
import '../notes/mode_detector.dart';
import '../notes/name_suggester.dart';
import '../notes/note.dart';
import '../notes/note_mode.dart';
import '../store/note_store.dart';
import '../sync/record_data.dart';
import '../sync/sync_record.dart';
import '../theme.dart';
import 'welcome_note.dart';

/// The notes, folders and tabs on this machine, saved as they change.
///
/// Folders double as tab groups: the tab strip shows open notes grouped by
/// the folder they are in, so moving a note to a folder moves its tab into
/// that group.
///
/// Typing is saved at most [saveDelay] after the keystroke, and everything
/// else (new notes, closing, trashing) right away. Nothing ever asks to
/// save. The app calls [flush] before it exits, to write the last few
/// keystrokes.
///
/// If a save fails, say because the disk is full, the changes stay in
/// memory, [saveProblem] says why, and GPad tries again every [retryDelay]
/// until a save works.
class Notepad extends ChangeNotifier {
  Notepad._(
    this._store,
    this._clock,
    this._notes,
    this._folders,
    this._selectedId,
    Appearance appearance,
  ) : appearance = ValueNotifier(appearance) {
    this.appearance.addListener(_saveAppearance);
  }

  /// Loads the notes in [store], deleting any that have been in the trash
  /// longer than [trashKeptFor]. The first time, adds a welcome note.
  factory Notepad.load(
    NoteStore store, {
    DateTime Function() clock = DateTime.now,
  }) {
    final now = clock();
    final notes = store.loadNotes();
    final folders = store.loadFolders();
    store.saveFolders(_breakLoops(folders));

    final expired = [
      for (final note in notes)
        if (note.status == NoteStatus.trashed &&
            now.difference(note.trashedAt ?? now) >= trashKeptFor)
          note,
    ];
    store.deleteNotes(expired.map((n) => n.id));
    notes.removeWhere(expired.contains);

    if (store.setting(_welcomedKey) == null) {
      final welcome = Note(
        id: newId(),
        title: _welcomeTitle,
        titleEdited: true,
        text: welcomeNote,
        guess: const ModeGuess.rich(),
        createdAt: now,
        updatedAt: now,
        tabOrder: _nextTabOrder(notes),
      );
      notes.add(welcome);
      store.saveNote(welcome);
      store.setSetting(_welcomedKey, '1');
      store.setSetting(_selectedKey, welcome.id);
    }

    return Notepad._(
      store,
      clock,
      notes,
      folders,
      store.setting(_selectedKey),
      _loadAppearance(store.setting(_appearanceKey)),
    );
  }

  static const saveDelay = Duration(milliseconds: 300);
  static const retryDelay = Duration(seconds: 5);
  static const trashKeptFor = Duration(days: 30);

  static const _welcomeTitle = 'Welcome to GPad';
  static const _welcomedKey = 'welcomed';
  static const _selectedKey = 'selected_note';
  static const _appearanceKey = 'appearance';

  final NoteStore _store;
  final DateTime Function() _clock;
  final List<Note> _notes;
  final List<Folder> _folders;
  final _detector = ModeDetector();
  final _unsaved = <Note>{};
  final _unsavedFolders = <Folder>{};
  final _unsavedSettings = <String, String>{};
  final _deleted = <String>{};
  final _deletedFolders = <String>{};
  SqliteException? _saveError;
  Timer? _saveTimer;
  String? _selectedId;

  /// Theme, light or dark, and code colors. Saved whenever they change.
  final ValueNotifier<Appearance> appearance;

  /// Called after each save that wrote something, so sync can upload it.
  VoidCallback? onSaved;

  /// The store, for sync's own records.
  NoteStore get store => _store;

  /// Open tabs grouped by folder: one group per folder with open notes, in
  /// sidebar order, then the tabs that aren't in a folder.
  List<TabGroup> get tabGroups {
    final open = _notes.where((n) => n.status == NoteStatus.open).toList()
      ..sort((a, b) => a.tabOrder.compareTo(b.tabOrder));
    final byId = {for (final f in _folders) f.id: f};
    final groups = <TabGroup>[];
    for (final folder in [..._walk(null), null]) {
      final notes = [
        for (final note in open)
          if (byId[note.folderId]?.id == folder?.id) note,
      ];
      if (notes.isNotEmpty) groups.add(TabGroup(folder, notes));
    }
    return groups;
  }

  /// Notes in tabs, in the order the tab strip shows them.
  List<Note> get openNotes => [for (final g in tabGroups) ...g.notes];

  /// The tabs the strip shows: all of them, less those in collapsed groups.
  /// The selected tab always shows.
  List<Note> get visibleTabs {
    final current = selected;
    return [
      for (final group in tabGroups)
        for (final note in group.notes)
          if (!group.collapsed || note == current) note,
    ];
  }

  /// Every note that isn't in the trash, open or closed, by title.
  List<Note> get keptNotes =>
      _notes.where((n) => n.status != NoteStatus.trashed).toList()
        ..sort(_byTitle);

  /// Every folder, in sidebar order: each folder followed by the folders
  /// inside it.
  List<Folder> get folders => _walk(null);

  /// The folders directly inside [parent], or at the top level, by name.
  List<Folder> foldersIn(Folder? parent) =>
      _folders.where((f) => parentOf(f) == parent).toList()..sort(_byName);

  /// The notes directly inside [folder], or at the top level, by title.
  /// Leaves out the trash.
  List<Note> notesIn(Folder? folder) =>
      _notes
          .where((n) => n.status != NoteStatus.trashed && folderOf(n) == folder)
          .toList()
        ..sort(_byTitle);

  /// The folder [note] is in, or null at the top level. A note whose folder
  /// is missing, say because sync hasn't brought it yet, shows at the top
  /// level but keeps its folder, and moves into it when it arrives.
  Folder? folderOf(Note note) => _folderById(note.folderId);

  /// The folder [folder] is in, or null at the top level, which is also
  /// where a folder whose parent is missing shows.
  Folder? parentOf(Folder folder) => _folderById(folder.parentId);

  /// How many folders [folder] is inside: 0 at the top level.
  int depthOf(Folder folder) => _ancestorsOf(folder).length;

  /// The folder's name with the names of the folders it is in, like
  /// "Work / Recipes".
  String pathOf(Folder folder) => [
    for (final f in _ancestorsOf(folder).reversed) f.displayName,
    folder.displayName,
  ].join(' / ');

  /// Notes in the trash, most recently trashed first.
  List<Note> get trashedNotes =>
      _notes.where((n) => n.status == NoteStatus.trashed).toList()..sort(
        (a, b) =>
            (b.trashedAt ?? b.updatedAt).compareTo(a.trashedAt ?? a.updatedAt),
      );

  /// The tab being shown, or null when no tabs are open.
  Note? get selected {
    final open = openNotes;
    for (final note in open) {
      if (note.id == _selectedId) return note;
    }
    return open.isEmpty ? null : open.first;
  }

  /// Notes whose title or text contain every word of [query], ignoring case
  /// and accents, best match first. Open and closed notes come before
  /// trashed ones. With no query, the notes edited most recently.
  List<SearchResult> search(String query) {
    if (query.trim().isEmpty) {
      final recent = keptNotes
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return [for (final note in recent.take(20)) SearchResult(note)];
    }
    // Search what was typed in the last moment too.
    flush();
    final byId = {for (final note in _notes) note.id: note};
    return [
      for (final hit in _store.search(query))
        if (byId[hit.noteId] case final note?)
          SearchResult(note, title: hit.title, snippet: hit.snippet),
    ];
  }

  /// Why the latest changes couldn't be saved, or null if everything is
  /// saved or waiting a moment to be.
  String? get saveProblem => _saveError?.message;

  /// When [note] will be deleted for good, if it is in the trash.
  DateTime? deletesOn(Note note) => note.trashedAt?.add(trashKeptFor);

  /// Shows [note], reopening its tab if it was closed.
  void open(Note note) {
    if (note.status == NoteStatus.trashed) return;
    if (note.status == NoteStatus.closed) {
      note.status = NoteStatus.open;
      note.tabOrder = _nextTabOrder(_notes);
      _saveNow(note);
    }
    _select(note);
    notifyListeners();
  }

  /// A new, empty note that names itself and picks its mode on the first
  /// paste. It goes in the same folder as the selected tab.
  Note newNote() => newNoteIn(_currentFolder);

  /// Like [newNote], but in [folder], or at the top level if null.
  Note newNoteIn(Folder? folder) {
    final now = _clock();
    if (folder != null) _reveal(folder);
    return _add(
      Note(
        id: newId(),
        folderId: folder?.id,
        title: suggestName('', const ModeGuess.plain(), now),
        text: '',
        guess: const ModeGuess.plain(),
        createdAt: now,
        updatedAt: now,
        awaitingFirstPaste: true,
      ),
    );
  }

  /// A new note holding the clipboard, with its mode and name picked from
  /// it, in the same folder as the selected tab. [html] is the clipboard's
  /// HTML, if any: when it carries formatting the note is Rich and holds it
  /// as Markdown. Returns null if there is nothing to paste.
  Note? pasteAsNewNote(String text, {String? html}) {
    final (guess, body, _) = _fromClipboard(text, html);
    if (body.trim().isEmpty) return null;
    final now = _clock();
    return _add(
      Note(
        id: newId(),
        folderId: _currentFolder?.id,
        title: suggestName(body, guess, now),
        text: body,
        guess: guess,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// The first paste into [note], a new empty note, when the clipboard has
  /// HTML: if it carries formatting, the note becomes Rich and holds it as
  /// Markdown. Returns false, changing nothing, when the paste should go in
  /// as plain text instead (the editor then pastes it, and [editText] picks
  /// the mode).
  bool pasteFormatted(Note note, {required String text, required String html}) {
    if (!note.awaitingFirstPaste || note.text.trim().isNotEmpty) return false;
    final (guess, body, fromHtml) = _fromClipboard(text, html);
    if (!fromHtml) return false;
    note
      ..text = body
      ..guess = guess
      ..awaitingFirstPaste = false
      ..updatedAt = _clock();
    if (!note.titleEdited) {
      note.title = suggestName(body, guess, note.updatedAt);
      note.titleVersion++;
    }
    _saveNow(note);
    notifyListeners();
    return true;
  }

  /// The mode and text for a paste, and whether the text is the HTML's
  /// Markdown rather than the plain text.
  (ModeGuess, String, bool) _fromClipboard(String text, String? html) {
    final markdown = html == null ? null : markdownFromHtml(html);
    final guess = _detector.detect(
      text,
      clipboardHadFormatting: markdown != null,
    );
    if (guess.mode == NoteMode.rich && markdown != null) {
      return (guess, markdown, true);
    }
    return (guess, text, false);
  }

  /// Closes [note]'s tab. The note stays, marked closed.
  void close(Note note) {
    if (note.status != NoteStatus.open) return;
    final neighbor = _neighborOf(note);
    note.status = NoteStatus.closed;
    _saveNow(note);
    if (_selectedId == note.id) _select(neighbor);
    notifyListeners();
  }

  /// Selects the next tab, or the previous one with [backwards], wrapping
  /// around at either end.
  void cycleTabs({bool backwards = false}) {
    final open = visibleTabs;
    final current = selected;
    if (open.length < 2 || current == null) return;
    final step = backwards ? -1 : 1;
    final index = (open.indexOf(current) + step) % open.length;
    _select(open[index]);
    notifyListeners();
  }

  void editText(Note note, String text) {
    if (text == note.text) return;
    final wasEmpty = note.text.trim().isEmpty;
    note.text = text;
    note.updatedAt = _clock();
    if (note.awaitingFirstPaste && wasEmpty && text.trim().isNotEmpty) {
      note.awaitingFirstPaste = false;
      note.guess = _detector.detect(text);
      if (!note.titleEdited) {
        note.title = suggestName(text, note.guess, note.updatedAt);
        note.titleVersion++;
      }
      _saveNow(note);
    } else {
      _saveSoon(note);
    }
    notifyListeners();
  }

  void rename(Note note, String title) {
    if (title == note.title) return;
    note.title = title;
    note.titleEdited = true;
    note.updatedAt = _clock();
    _saveSoon(note);
    notifyListeners();
  }

  void setMode(Note note, NoteMode mode) {
    if (mode == note.guess.mode) return;
    note.awaitingFirstPaste = false;
    note.guess = switch (mode) {
      NoteMode.code => ModeGuess.code(
        note.guess.language ??
            _codeLanguageOrNull(note.text) ??
            ModeDetector.defaultLanguages.first,
      ),
      NoteMode.rich => const ModeGuess.rich(),
      NoteMode.plain => const ModeGuess.plain(),
    };
    _saveNow(note);
    notifyListeners();
  }

  void setLanguage(Note note, String language) {
    if (note.guess.mode != NoteMode.code) return;
    note.guess = ModeGuess.code(language);
    _saveNow(note);
    notifyListeners();
  }

  /// Moves [note] to the trash, where it is kept for [trashKeptFor].
  void trash(Note note) {
    if (note.status == NoteStatus.trashed) return;
    final neighbor = _neighborOf(note);
    note.status = NoteStatus.trashed;
    note.trashedAt = _clock();
    _saveNow(note);
    if (_selectedId == note.id) _select(neighbor);
    notifyListeners();
  }

  /// Takes [note] out of the trash and opens it.
  void restore(Note note) {
    if (note.status != NoteStatus.trashed) return;
    note.status = NoteStatus.open;
    note.trashedAt = null;
    note.tabOrder = _nextTabOrder(_notes);
    _saveNow(note);
    _select(note);
    notifyListeners();
  }

  /// Deletes trashed [note] for good.
  void deleteForever(Note note) {
    if (note.status != NoteStatus.trashed) return;
    _remove([note]);
  }

  /// Deletes every note in the trash for good.
  void emptyTrash() => _remove(trashedNotes);

  /// Moves [note], and its tab, into [folder], or to the top level if null.
  void moveNote(Note note, Folder? folder) {
    if (note.folderId == folder?.id) return;
    note.folderId = folder?.id;
    // Last in its new group.
    note.tabOrder = _nextTabOrder(_notes);
    _saveNow(note);
    if (folder != null) _reveal(folder);
    notifyListeners();
  }

  /// A new folder inside [parent], or at the top level if null.
  Folder createFolder({Folder? parent, String name = 'New folder'}) {
    final now = _clock();
    final folder = Folder(
      id: newId(),
      parentId: parent?.id,
      name: name,
      createdAt: now,
      updatedAt: now,
    );
    _folders.add(folder);
    if (parent != null) _reveal(parent);
    _saveFolderNow(folder);
    notifyListeners();
    return folder;
  }

  /// Renames [folder]. A blank [name] leaves it as it was.
  void renameFolder(Folder folder, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == folder.name) return;
    folder
      ..name = trimmed
      ..updatedAt = _clock();
    _saveFolderNow(folder);
    notifyListeners();
  }

  /// Whether [folder] can go into [parent]: not into itself or a folder
  /// inside it, and not where it already is.
  bool canMoveFolder(Folder folder, Folder? parent) {
    if (folder.parentId == parent?.id) return false;
    if (parent == null) return true;
    return parent != folder && !_ancestorsOf(parent).contains(folder);
  }

  /// Moves [folder], with everything in it, into [parent], or to the top
  /// level if null.
  void moveFolder(Folder folder, Folder? parent) {
    if (!canMoveFolder(folder, parent)) return;
    folder
      ..parentId = parent?.id
      ..updatedAt = _clock();
    if (parent != null) _reveal(parent);
    _saveFolderNow(folder);
    notifyListeners();
  }

  /// Removes [folder] but keeps what was in it: its notes, trashed ones too,
  /// and its folders move up to the folder it was in.
  void deleteFolder(Folder folder) {
    _removeFolder(folder);
    // One transaction, so the folder is never gone with its notes still
    // pointing at it.
    flush();
    notifyListeners();
  }

  void _removeFolder(Folder folder) {
    for (final note in _notes) {
      if (note.folderId != folder.id) continue;
      note.folderId = folder.parentId;
      _unsaved.add(note);
    }
    for (final child in _folders) {
      if (child.parentId != folder.id) continue;
      child.parentId = folder.parentId;
      _unsavedFolders.add(child);
    }
    _folders.remove(folder);
    _unsavedFolders.remove(folder);
    _deletedFolders.add(folder.id);
  }

  /// Shows or hides what is inside [folder] in the sidebar.
  void setFolderExpanded(Folder folder, bool expanded) {
    if (folder.expanded == expanded) return;
    folder.expanded = expanded;
    _unsavedFolders.add(folder);
    _scheduleSave();
    notifyListeners();
  }

  /// Folds [folder]'s tabs into its label in the tab strip, or unfolds them.
  void setTabsCollapsed(Folder folder, bool collapsed) {
    if (folder.tabsCollapsed == collapsed) return;
    folder.tabsCollapsed = collapsed;
    _unsavedFolders.add(folder);
    _scheduleSave();
    notifyListeners();
  }

  /// Saves any changes that are still waiting, like typing within the last
  /// [saveDelay]. Returns false if that failed: the changes are kept, and
  /// saved by a later [flush] or the retry after [retryDelay].
  bool flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_unsaved.isNotEmpty ||
        _unsavedFolders.isNotEmpty ||
        _unsavedSettings.isNotEmpty ||
        _deleted.isNotEmpty ||
        _deletedFolders.isNotEmpty) {
      try {
        _saveUnsaved();
      } on SqliteException catch (error) {
        _saveError = error;
        _saveTimer = Timer(retryDelay, flush);
        notifyListeners();
        return false;
      }
      _clearUnsaved();
      onSaved?.call();
    }
    if (_saveError != null) {
      _saveError = null;
      notifyListeners();
    }
    return true;
  }

  /// The note or folder [id] as sync uploads it, or null if there is none.
  Map<String, Object?>? syncData(RecordKind kind, String id) => switch (kind) {
    RecordKind.note => switch (_noteById(id)) {
      final note? => noteData(note),
      null => null,
    },
    RecordKind.folder => switch (_folderById(id)) {
      final folder? => folderData(folder),
      null => null,
    },
  };

  /// Whether sync should leave [id] on this machine: the welcome note,
  /// until it is edited, so each machine doesn't collect everyone's.
  bool isLocalOnly(RecordKind kind, String id) {
    if (kind != RecordKind.note) return false;
    final note = _noteById(id);
    return note != null &&
        note.text == welcomeNote &&
        note.title == _welcomeTitle;
  }

  void _saveUnsaved() => _store.save(
    notes: _unsaved,
    folders: _unsavedFolders,
    settings: _unsavedSettings,
    deletedNoteIds: _deleted,
    deletedFolderIds: _deletedFolders,
  );

  void _clearUnsaved() {
    _unsaved.clear();
    _unsavedFolders.clear();
    _unsavedSettings.clear();
    _deleted.clear();
    _deletedFolders.clear();
  }

  /// Puts notes and folders as other machines left them: creates, updates
  /// or deletes each of [changes], and adds [newNotes] (copies kept when
  /// two machines changed a note at once) as new open notes.
  ///
  /// Saves it all, and whatever [alsoSave] writes to the store, in one
  /// transaction. If that fails, the notes go back to how they were, in
  /// the window and on disk, and the error is rethrown. Returns false,
  /// changing nothing, if earlier changes can't be saved first.
  bool applySynced(
    List<SyncedChange> changes, {
    List<Map<String, Object?>> newNotes = const [],
    void Function()? alsoSave,
  }) {
    // Then only sync's changes are unsaved below, and undoing them can't
    // touch anyone's typing.
    if (!flush()) return false;
    final undo = _undoFor(changes);
    // Folders first, so notes find the folders they are in.
    for (final change in changes) {
      if (change.kind != RecordKind.folder) continue;
      final folder = _folderById(change.id);
      final data = change.data;
      if (data == null) {
        if (folder != null) _removeFolder(folder);
      } else if (folder != null) {
        applyFolderData(folder, data);
        _unsavedFolders.add(folder);
      } else {
        final added = folderFromData(change.id, data);
        _folders.add(added);
        _unsavedFolders.add(added);
      }
    }
    for (final change in changes) {
      if (change.kind != RecordKind.note) continue;
      final note = _noteById(change.id);
      final data = change.data;
      if (data == null) {
        if (note == null) continue;
        _notes.remove(note);
        _unsaved.remove(note);
        _deleted.add(note.id);
      } else if (note != null) {
        final (text, title) = (note.text, note.title);
        applyNoteData(note, data);
        if (note.text != text) note.textVersion++;
        if (note.title != title) note.titleVersion++;
        _unsaved.add(note);
      } else {
        final added = noteFromData(change.id, data);
        _notes.add(added);
        _unsaved.add(added);
      }
    }
    for (final data in newNotes) {
      final copy = noteFromData(newId(), data)
        ..tabOrder = _nextTabOrder(_notes);
      _notes.add(copy);
      _unsaved.add(copy);
    }
    _unsavedFolders.addAll(_breakLoops(_folders));
    try {
      _store.transaction(() {
        _saveUnsaved();
        alsoSave?.call();
      });
    } catch (_) {
      undo();
      notifyListeners();
      rethrow;
    }
    _clearUnsaved();
    onSaved?.call();
    notifyListeners();
    return true;
  }

  /// Puts back what [applySynced] can change for [changes]: which notes and
  /// folders there are, the changed notes' fields, every note's folder
  /// (deleting a folder moves its notes up) and every folder's fields.
  VoidCallback _undoFor(List<SyncedChange> changes) {
    final notes = [..._notes];
    final folders = [..._folders];
    final noteFields = <Note, Map<String, Object?>>{};
    for (final change in changes) {
      if (change.kind != RecordKind.note) continue;
      final note = _noteById(change.id);
      if (note != null) noteFields[note] = noteData(note);
    }
    final noteFolders = {for (final note in notes) note: note.folderId};
    final folderFields = {
      for (final folder in folders) folder: folderData(folder),
    };
    return () {
      _notes
        ..clear()
        ..addAll(notes);
      _folders
        ..clear()
        ..addAll(folders);
      for (final MapEntry(key: note, value: data) in noteFields.entries) {
        final (text, title) = (note.text, note.title);
        applyNoteData(note, data);
        if (note.text != text) note.textVersion++;
        if (note.title != title) note.titleVersion++;
      }
      for (final MapEntry(key: note, value: folderId) in noteFolders.entries) {
        note.folderId = folderId;
      }
      for (final MapEntry(key: folder, value: data) in folderFields.entries) {
        applyFolderData(folder, data);
      }
      _clearUnsaved();
    };
  }

  @override
  void dispose() {
    flush();
    _saveTimer?.cancel();
    appearance
      ..removeListener(_saveAppearance)
      ..dispose();
    super.dispose();
  }

  Note _add(Note note) {
    note.tabOrder = _nextTabOrder(_notes);
    _notes.add(note);
    _saveNow(note);
    _select(note);
    notifyListeners();
    return note;
  }

  void _remove(List<Note> notes) {
    if (notes.isEmpty) return;
    _unsaved.removeAll(notes);
    _deleted.addAll(notes.map((n) => n.id));
    _notes.removeWhere(notes.contains);
    flush();
    notifyListeners();
  }

  /// The tab to show if [note]'s tab goes away: the one after it, else the
  /// one before, preferring tabs that aren't folded away.
  Note? _neighborOf(Note note) {
    for (final tabs in [visibleTabs, openNotes]) {
      final index = tabs.indexOf(note);
      if (index < 0) continue;
      tabs.removeAt(index);
      if (tabs.isNotEmpty) return tabs[index.clamp(0, tabs.length - 1)];
    }
    return note == selected ? null : selected;
  }

  Folder? get _currentFolder {
    final note = selected;
    return note == null ? null : folderOf(note);
  }

  Note? _noteById(String id) {
    for (final note in _notes) {
      if (note.id == id) return note;
    }
    return null;
  }

  Folder? _folderById(String? id) {
    if (id == null) return null;
    for (final folder in _folders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  /// The folders [folder] is in, innermost first.
  List<Folder> _ancestorsOf(Folder folder) {
    final ancestors = <Folder>[];
    for (
      var parent = _folderById(folder.parentId);
      parent != null;
      parent = _folderById(parent.parentId)
    ) {
      ancestors.add(parent);
    }
    return ancestors;
  }

  /// [parent]'s folders, each followed by the folders inside it.
  List<Folder> _walk(Folder? parent) => [
    for (final folder in foldersIn(parent)) ...[folder, ..._walk(folder)],
  ];

  /// Expands [folder] and the folders it is in, so the sidebar shows what is
  /// inside it.
  void _reveal(Folder folder) {
    for (final f in [folder, ..._ancestorsOf(folder)]) {
      if (f.expanded) continue;
      f.expanded = true;
      _unsavedFolders.add(f);
      _scheduleSave();
    }
  }

  void _select(Note? note) {
    if (note?.id == _selectedId) return;
    _selectedId = note?.id;
    // Not worth a disk write of its own; it goes with the next save.
    _unsavedSettings[_selectedKey] = note?.id ?? '';
    _scheduleSave();
  }

  void _saveSoon(Note note) {
    _unsaved.add(note);
    _scheduleSave();
  }

  // Saves soon, but at most saveDelay after the first unsaved change, so
  // steady typing is still saved every few hundred milliseconds. While saves
  // are failing, this waits for the next retry instead.
  void _scheduleSave() => _saveTimer ??= Timer(saveDelay, flush);

  void _saveNow(Note note) {
    _unsaved.add(note);
    flush();
  }

  void _saveFolderNow(Folder folder) {
    _unsavedFolders.add(folder);
    flush();
  }

  void _saveAppearance() {
    _unsavedSettings[_appearanceKey] = jsonEncode(appearance.value.toJson());
    flush();
  }

  String? _codeLanguageOrNull(String text) {
    final guess = _detector.detect(text);
    return guess.mode == NoteMode.code ? guess.language : null;
  }

  static int _nextTabOrder(List<Note> notes) {
    var last = -1;
    for (final note in notes) {
      if (note.status == NoteStatus.open && note.tabOrder > last) {
        last = note.tabOrder;
      }
    }
    return last + 1;
  }

  /// Breaks loops of folders inside each other, which two machines moving
  /// folders into each other at once can make, and returns the folders it
  /// moved. The folder with the lowest id in each loop moves to the top
  /// level, so every machine breaks a loop the same way. The sidebar would
  /// otherwise never stop drawing.
  static List<Folder> _breakLoops(List<Folder> folders) {
    final byId = {for (final f in folders) f.id: f};
    final moved = <Folder>[];
    for (final folder in folders) {
      final path = <String>[];
      String? id = folder.id;
      while (id != null && byId.containsKey(id) && !path.contains(id)) {
        path.add(id);
        id = byId[id]!.parentId;
      }
      // Reached the top level or a folder that isn't here.
      if (id == null || !byId.containsKey(id)) continue;
      final loop = path.sublist(path.indexOf(id));
      final lowest = byId[loop.reduce((a, b) => a.compareTo(b) < 0 ? a : b)]!;
      lowest.parentId = null;
      moved.add(lowest);
    }
    return moved;
  }

  static int _byName(Folder a, Folder b) {
    final byName = a.displayName.toLowerCase().compareTo(
      b.displayName.toLowerCase(),
    );
    return byName != 0 ? byName : a.createdAt.compareTo(b.createdAt);
  }

  static int _byTitle(Note a, Note b) {
    final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
    return byTitle != 0 ? byTitle : a.createdAt.compareTo(b.createdAt);
  }

  static Appearance _loadAppearance(String? saved) {
    if (saved == null) return const Appearance();
    try {
      final json = jsonDecode(saved);
      if (json is Map<String, Object?>) return Appearance.fromJson(json);
    } on FormatException {
      // Fall through to the default.
    }
    return const Appearance();
  }
}

/// A note or folder as another machine left it, for [Notepad.applySynced].
class SyncedChange {
  const SyncedChange(this.kind, this.id, this.data);

  final RecordKind kind;
  final String id;

  /// Its fields, as [noteData] or [folderData] gives them, or null if it
  /// was deleted.
  final Map<String, Object?>? data;
}

/// Open tabs that share a folder, or that aren't in one.
class TabGroup {
  const TabGroup(this.folder, this.notes);

  /// Null for the tabs that aren't in a folder.
  final Folder? folder;

  /// In tab order.
  final List<Note> notes;

  /// Whether the strip folds these tabs into the folder's label.
  bool get collapsed => folder?.tabsCollapsed ?? false;
}

/// A note found by [Notepad.search].
class SearchResult {
  SearchResult(this.note, {String? title, this.snippet})
    : title = title == null || title.trim().isEmpty ? note.displayTitle : title;

  final Note note;

  /// The title, with matches between [SearchHit.markStart] and
  /// [SearchHit.markEnd].
  final String title;

  /// Text around the match, marked the same way, if there is any.
  final String? snippet;
}
