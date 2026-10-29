import '../notes/folder.dart';
import '../notes/note.dart';
import '../notes/note_mode.dart';

/// The fields of a note that sync carries between machines, as JSON.
///
/// Which tabs are open travels too, so a note opened at work shows as a tab
/// at home. Which tab is selected, and whether folders are expanded, stay
/// on each machine.
Map<String, Object?> noteData(Note note) => {
  'title': note.title,
  'titleEdited': note.titleEdited,
  'text': note.text,
  'mode': note.guess.mode.name,
  'language': note.guess.language,
  'status': note.status.name,
  'tabOrder': note.tabOrder,
  'awaitingPaste': note.awaitingFirstPaste,
  'folder': note.folderId,
  'createdAt': note.createdAt.millisecondsSinceEpoch,
  'updatedAt': note.updatedAt.millisecondsSinceEpoch,
  'trashedAt': note.trashedAt?.millisecondsSinceEpoch,
};

/// A note with [data], which must have come from [noteData]. Throws a
/// [FormatException] if it didn't.
Note noteFromData(String id, Map<String, Object?> data) {
  final note = Note(
    id: id,
    title: '',
    text: '',
    guess: const ModeGuess.plain(),
    createdAt: DateTime(0),
    updatedAt: DateTime(0),
  );
  applyNoteData(note, data);
  return note;
}

/// Sets [note]'s fields from [data], all or none of them.
void applyNoteData(Note note, Map<String, Object?> data) {
  final mode = _enum(NoteMode.values, data, 'mode');
  final language = _optional<String>(data, 'language');
  final guess = switch (mode) {
    NoteMode.rich => const ModeGuess.rich(),
    NoteMode.plain => const ModeGuess.plain(),
    NoteMode.code => ModeGuess.code(language ?? 'plaintext'),
  };
  final title = _required<String>(data, 'title');
  final titleEdited = _required<bool>(data, 'titleEdited');
  final text = _required<String>(data, 'text');
  final status = _enum(NoteStatus.values, data, 'status');
  final tabOrder = _required<int>(data, 'tabOrder');
  final awaitingPaste = _required<bool>(data, 'awaitingPaste');
  final folder = _optional<String>(data, 'folder');
  final createdAt = _time(data, 'createdAt');
  final updatedAt = _time(data, 'updatedAt');
  final trashedAt = _optionalTime(data, 'trashedAt');
  note
    ..title = title
    ..titleEdited = titleEdited
    ..text = text
    ..guess = guess
    ..status = status
    ..tabOrder = tabOrder
    ..awaitingFirstPaste = awaitingPaste
    ..folderId = folder
    ..createdAt = createdAt
    ..updatedAt = updatedAt
    ..trashedAt = trashedAt;
}

Map<String, Object?> folderData(Folder folder) => {
  'name': folder.name,
  'parent': folder.parentId,
  'createdAt': folder.createdAt.millisecondsSinceEpoch,
  'updatedAt': folder.updatedAt.millisecondsSinceEpoch,
};

Folder folderFromData(String id, Map<String, Object?> data) {
  final folder = Folder(
    id: id,
    name: '',
    createdAt: DateTime(0),
    updatedAt: DateTime(0),
  );
  applyFolderData(folder, data);
  return folder;
}

void applyFolderData(Folder folder, Map<String, Object?> data) {
  final name = _required<String>(data, 'name');
  final parent = _optional<String>(data, 'parent');
  final createdAt = _time(data, 'createdAt');
  final updatedAt = _time(data, 'updatedAt');
  folder
    ..name = name
    ..parentId = parent
    ..createdAt = createdAt
    ..updatedAt = updatedAt;
}

T _required<T>(Map<String, Object?> data, String key) => switch (data[key]) {
  final T value => value,
  _ => throw FormatException('$key is missing or the wrong type'),
};

T? _optional<T extends Object>(Map<String, Object?> data, String key) =>
    switch (data[key]) {
      null => null,
      final T value => value,
      _ => throw FormatException('$key is the wrong type'),
    };

E _enum<E extends Enum>(List<E> values, Map<String, Object?> data, String key) {
  final name = _required<String>(data, key);
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('Unknown $key $name');
}

DateTime _time(Map<String, Object?> data, String key) =>
    DateTime.fromMillisecondsSinceEpoch(_required<int>(data, key));

DateTime? _optionalTime(Map<String, Object?> data, String key) =>
    switch (_optional<int>(data, key)) {
      final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      null => null,
    };
