import 'package:flutter/material.dart';

import '../notepad/notepad.dart';
import '../notes/folder.dart';
import '../notes/note.dart';
import 'icons.dart';

/// Desktop-sized menu rows, rather than Material's touch-sized 48.
const menuItemHeight = 36.0;

PopupMenuItem<T> menuItem<T>(T value, String label) =>
    PopupMenuItem(value: value, height: menuItemHeight, child: Text(label));

/// Shows a right-click menu at [position], in global coordinates, and
/// returns what was picked.
Future<T?> showContextMenu<T>(
  BuildContext context, {
  required Offset position,
  required List<PopupMenuEntry<T>> items,
}) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}

/// The right-click menu for a note in the sidebar or the tab strip.
Future<void> showNoteMenu(
  BuildContext context, {
  required Notepad notepad,
  required Note note,
  required Offset position,
}) async {
  final choice = await showContextMenu<_NoteAction>(
    context,
    position: position,
    items: [
      if (note.status == NoteStatus.open)
        menuItem(_NoteAction.close, 'Close tab')
      else
        menuItem(_NoteAction.open, 'Open'),
      menuItem(_NoteAction.move, 'Move to folder…'),
      const PopupMenuDivider(),
      menuItem(_NoteAction.trash, 'Move to trash'),
    ],
  );
  if (!context.mounted) return;
  switch (choice) {
    case _NoteAction.open:
      notepad.open(note);
    case _NoteAction.close:
      notepad.close(note);
    case _NoteAction.move:
      await showMoveNoteDialog(context, notepad: notepad, note: note);
    case _NoteAction.trash:
      notepad.trash(note);
    case null:
      break;
  }
}

enum _NoteAction { open, close, move, trash }

/// Asks which folder to move [note] to, and moves it.
Future<void> showMoveNoteDialog(
  BuildContext context, {
  required Notepad notepad,
  required Note note,
}) async {
  final current = notepad.folderOf(note);
  Widget option(Folder? folder, String label, {int depth = 0}) {
    final here = folder == current;
    return SimpleDialogOption(
      onPressed: () => Navigator.of(context).pop((folder,)),
      padding: EdgeInsets.fromLTRB(24.0 + depth * 16, 8, 24, 8),
      child: Row(
        children: [
          Icon(
            folder == null ? Icons.notes : Icons.folder,
            size: 18,
            color: folder == null ? null : folderColor(context, folder),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          if (here) const Icon(Icons.check, size: 18),
        ],
      ),
    );
  }

  final picked = await showDialog<(Folder?,)>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text('Move "${note.displayTitle}" to'),
      children: [
        option(null, 'No folder'),
        for (final folder in notepad.folders)
          option(folder, folder.displayName, depth: notepad.depthOf(folder)),
      ],
    ),
  );
  if (picked != null) notepad.moveNote(note, picked.$1);
}

/// Asks before something that can't be undone. Returns true to go ahead.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(action),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
