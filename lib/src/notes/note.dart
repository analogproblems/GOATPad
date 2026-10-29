import 'dart:math';

import 'note_mode.dart';

/// Where a note is. Closing a tab never deletes: the note becomes [closed]
/// and stays in the sidebar. Only [trashed] notes are ever deleted, 30 days
/// after they were trashed.
enum NoteStatus { open, closed, trashed }

class Note {
  Note({
    required this.id,
    required this.title,
    required this.text,
    required this.guess,
    required this.createdAt,
    required this.updatedAt,
    this.folderId,
    this.titleEdited = false,
    this.status = NoteStatus.open,
    this.tabOrder = 0,
    this.trashedAt,
    this.awaitingFirstPaste = false,
  });

  final String id;
  String title;

  /// [title], or "Untitled" if it has been cleared.
  String get displayTitle => title.trim().isEmpty ? 'Untitled' : title;

  /// The folder the note is in, or null at the top level.
  String? folderId;

  /// The person typed this title, so GPad stops suggesting names.
  bool titleEdited;

  String text;
  ModeGuess guess;
  NoteStatus status;

  /// Position in the tab strip while [status] is [NoteStatus.open].
  int tabOrder;

  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? trashedAt;

  /// A new, empty note picks its mode and name from the first paste.
  bool awaitingFirstPaste;

  /// Bumped when GPad renames the note, so the title field reloads. Not
  /// stored.
  int titleVersion = 0;
}

final _random = Random.secure();

/// A random 128-bit id in hex, for notes and folders. Random rather than
/// counted, so ids made on two machines never clash once sync arrives.
String newId() => [
  for (var i = 0; i < 16; i++)
    _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();
