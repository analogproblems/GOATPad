import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../notes/mode_detector.dart';
import '../notes/name_suggester.dart';
import '../notes/note.dart';
import '../notes/note_mode.dart';
import '../store/note_store.dart';
import '../theme.dart';
import 'welcome_note.dart';

/// The notes and tabs on this machine, saved as they change.
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
        id: newNoteId(),
        title: 'Welcome to GPad',
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
      store.setting(_selectedKey),
      _loadAppearance(store.setting(_appearanceKey)),
    );
  }

  static const saveDelay = Duration(milliseconds: 300);
  static const retryDelay = Duration(seconds: 5);
  static const trashKeptFor = Duration(days: 30);

  static const _welcomedKey = 'welcomed';
  static const _selectedKey = 'selected_note';
  static const _appearanceKey = 'appearance';

  final NoteStore _store;
  final DateTime Function() _clock;
  final List<Note> _notes;
  final _detector = ModeDetector();
  final _unsaved = <Note>{};
  final _unsavedSettings = <String, String>{};
  final _deleted = <String>{};
  SqliteException? _saveError;
  Timer? _saveTimer;
  String? _selectedId;

  /// Theme, light or dark, and code colors. Saved whenever they change.
  final ValueNotifier<Appearance> appearance;

  /// Notes in tabs, in tab order.
  List<Note> get openNotes =>
      _notes.where((n) => n.status == NoteStatus.open).toList()
        ..sort((a, b) => a.tabOrder.compareTo(b.tabOrder));

  /// Every note that isn't in the trash, open or closed, by title.
  List<Note> get keptNotes =>
      _notes.where((n) => n.status != NoteStatus.trashed).toList()
        ..sort(_byTitle);

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
  /// paste.
  Note newNote() {
    final now = _clock();
    return _add(
      Note(
        id: newNoteId(),
        title: suggestName('', const ModeGuess.plain(), now),
        text: '',
        guess: const ModeGuess.plain(),
        createdAt: now,
        updatedAt: now,
        awaitingFirstPaste: true,
      ),
    );
  }

  /// A new note holding [text], with its mode and name picked from it.
  /// Returns null if [text] is blank.
  Note? pasteAsNewNote(String text) {
    if (text.trim().isEmpty) return null;
    final now = _clock();
    final guess = _detector.detect(text);
    return _add(
      Note(
        id: newNoteId(),
        title: suggestName(text, guess, now),
        text: text,
        guess: guess,
        createdAt: now,
        updatedAt: now,
      ),
    );
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
    final open = openNotes;
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

  /// Saves any changes that are still waiting, like typing within the last
  /// [saveDelay]. Returns false if that failed: the changes are kept, and
  /// saved by a later [flush] or the retry after [retryDelay].
  bool flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_unsaved.isNotEmpty ||
        _unsavedSettings.isNotEmpty ||
        _deleted.isNotEmpty) {
      try {
        _store.save(
          notes: _unsaved,
          settings: _unsavedSettings,
          deletedNoteIds: _deleted,
        );
      } on SqliteException catch (error) {
        _saveError = error;
        _saveTimer = Timer(retryDelay, flush);
        notifyListeners();
        return false;
      }
      _unsaved.clear();
      _unsavedSettings.clear();
      _deleted.clear();
    }
    if (_saveError != null) {
      _saveError = null;
      notifyListeners();
    }
    return true;
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
  /// one before.
  Note? _neighborOf(Note note) {
    final open = openNotes;
    final index = open.indexOf(note);
    if (index < 0) return selected;
    open.removeAt(index);
    return open.isEmpty ? null : open[index.clamp(0, open.length - 1)];
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
