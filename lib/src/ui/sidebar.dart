import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../notepad/notepad.dart';
import '../notes/folder.dart';
import '../notes/note.dart';
import '../sync/sync_controller.dart';
import 'appearance_dialog.dart';
import 'icons.dart';
import 'menus.dart';
import 'search_palette.dart';
import 'sync_dialog.dart';
import 'tray.dart';

/// Folders and notes as a tree, then the trash.
///
/// Notes and folders can be dragged onto a folder to move them into it, or
/// onto the NOTES heading or the empty space below the tree to move them to
/// the top level.
class Sidebar extends StatefulWidget {
  const Sidebar({super.key, required this.notepad, this.sync, this.tray});

  final Notepad notepad;

  /// Sync, whose state shows at the bottom. Null in tests that don't need
  /// it.
  final SyncController? sync;

  /// The tray icon, whose setting is in the sync window.
  final Tray? tray;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  bool _trashExpanded = false;

  /// The folder whose name is being typed in place.
  Folder? _renaming;

  Notepad get notepad => widget.notepad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trashed = notepad.trashedNotes;
    final heading = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
      letterSpacing: 1.2,
    );

    // A Material, not a ColoredBox, so the rows' highlight and ink splashes
    // paint on top of the sidebar color.
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Text('GPad', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: 'Search notes (Ctrl+P)',
                  icon: const Icon(Icons.search, size: 18),
                  onPressed: () => showSearchPalette(context, notepad: notepad),
                ),
                IconButton(
                  tooltip: 'Appearance',
                  icon: const Icon(Icons.palette_outlined, size: 18),
                  onPressed: () => showAppearanceDialog(
                    context,
                    appearance: notepad.appearance.value,
                    onChanged: (a) => notepad.appearance.value = a,
                  ),
                ),
              ],
            ),
          ),
          _notesHeading(heading),
          Expanded(
            // Drops on the empty space below the tree go to the top level.
            child: _dropTarget(
              into: null,
              builder: (_) => ListView(children: _rows(null, 0)),
            ),
          ),
          if (trashed.isNotEmpty) ...[
            const Divider(),
            _trashHeader(context, heading, trashed.length),
            if (_trashExpanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final n in trashed) _trashTile(context, n)],
                ),
              ),
          ],
          if (widget.sync case final sync?) ...[
            const Divider(),
            _syncRow(context, sync),
          ],
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Ctrl+N new note · Ctrl+Shift+V paste as new note · '
              'Ctrl+W close tab · Ctrl+P search',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// How sync is going; a click opens the sync dialog.
  Widget _syncRow(BuildContext context, SyncController sync) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final summary = syncSummary(sync);
        final attention = switch (sync.status) {
          SyncStatus.problem ||
          SyncStatus.locked ||
          SyncStatus.signedOut => true,
          _ => sync.unreadable.isNotEmpty || sync.tooLarge.isNotEmpty,
        };
        final color = attention
            ? theme.colorScheme.error
            : theme.colorScheme.outline;
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: Icon(summary.icon, size: 18, color: color),
          title: Text(
            summary.label,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
          onTap: () => showSyncDialog(context, sync, tray: widget.tray),
        );
      },
    );
  }

  Widget _notesHeading(TextStyle? heading) {
    return _dropTarget(
      into: null,
      builder: (highlight) => Container(
        color: highlight
            ? Theme.of(context).colorScheme.primaryContainer
            : null,
        padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
        child: Row(
          children: [
            Expanded(child: Text('NOTES', style: heading)),
            IconButton(
              tooltip: 'New folder',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: () => _newFolder(null),
            ),
          ],
        ),
      ),
    );
  }

  /// Rows for what is in [parent]: its folders, each followed by what is in
  /// it if expanded, then its notes.
  List<Widget> _rows(Folder? parent, int depth) => [
    for (final folder in notepad.foldersIn(parent)) ...[
      _folderRow(folder, depth),
      if (folder.expanded) ..._rows(folder, depth + 1),
    ],
    for (final note in notepad.notesIn(parent)) _noteRow(note, depth),
  ];

  Widget _folderRow(Folder folder, int depth) {
    final renaming = folder == _renaming;
    final row = _dropTarget(
      into: folder,
      builder: (highlight) => _TreeRow(
        depth: depth,
        icon: folder.expanded ? Icons.folder_open : Icons.folder,
        iconColor: folderColor(context, folder),
        expanded: folder.expanded,
        onToggle: () => notepad.setFolderExpanded(folder, !folder.expanded),
        highlight: highlight,
        onTap: renaming
            ? null
            : () => notepad.setFolderExpanded(folder, !folder.expanded),
        onMenu: (position) => _showFolderMenu(folder, position),
        label: renaming
            ? _RenameField(
                initial: folder.name,
                onDone: (name) {
                  if (name != null) notepad.renameFolder(folder, name);
                  setState(() => _renaming = null);
                },
              )
            : Text(folder.displayName, overflow: TextOverflow.ellipsis),
      ),
    );
    if (renaming) return row;
    return _draggable(
      data: folder,
      icon: Icons.folder,
      label: folder.displayName,
      child: row,
    );
  }

  Widget _noteRow(Note note, int depth) {
    final theme = Theme.of(context);
    final closed = note.status == NoteStatus.closed;
    return _draggable(
      data: note,
      icon: modeIcon(note.guess.mode),
      label: note.displayTitle,
      // Dropping on a note puts the dragged item alongside it.
      child: _dropTarget(
        into: notepad.folderOf(note),
        builder: (highlight) => _TreeRow(
          depth: depth,
          icon: modeIcon(note.guess.mode),
          selected: note == notepad.selected,
          highlight: highlight,
          onTap: () => notepad.open(note),
          onMenu: (position) => showNoteMenu(
            context,
            notepad: notepad,
            note: note,
            position: position,
          ),
          label: Text(
            note.displayTitle,
            overflow: TextOverflow.ellipsis,
            style: closed ? TextStyle(color: theme.colorScheme.outline) : null,
          ),
          trailing: closed
              ? Text(
                  'Closed',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                )
              : null,
        ),
      ),
    );
  }

  Widget _draggable({
    required Object data,
    required IconData icon,
    required String label,
    required Widget child,
  }) {
    return Draggable<Object>(
      data: data,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _DragLabel(icon: icon, label: label),
      childWhenDragging: Opacity(opacity: 0.5, child: child),
      child: child,
    );
  }

  /// A place to drop notes and folders, which go [into] that folder, or to
  /// the top level if null. [builder] is told when a drop here would move
  /// something, to highlight it.
  ///
  /// It takes every drag, even one that wouldn't move anything (a note onto
  /// its own folder), so the drop never falls through to the top-level
  /// target behind it.
  Widget _dropTarget({
    required Folder? into,
    required Widget Function(bool highlight) builder,
  }) {
    return DragTarget<Object>(
      onAcceptWithDetails: (details) => _drop(details.data, into),
      builder: (context, candidates, _) =>
          builder(candidates.any((data) => _canDrop(data, into))),
    );
  }

  bool _canDrop(Object? data, Folder? into) => switch (data) {
    final Note note => note.folderId != into?.id,
    final Folder folder => notepad.canMoveFolder(folder, into),
    _ => false,
  };

  void _drop(Object data, Folder? into) {
    if (!_canDrop(data, into)) return;
    switch (data) {
      case final Note note:
        notepad.moveNote(note, into);
      case final Folder folder:
        notepad.moveFolder(folder, into);
    }
  }

  void _newFolder(Folder? parent) =>
      setState(() => _renaming = notepad.createFolder(parent: parent));

  Future<void> _showFolderMenu(Folder folder, Offset position) async {
    final choice = await showContextMenu<_FolderAction>(
      context,
      position: position,
      items: [
        menuItem(_FolderAction.newNote, 'New note here'),
        menuItem(_FolderAction.newFolder, 'New folder inside'),
        menuItem(_FolderAction.rename, 'Rename'),
        const PopupMenuDivider(),
        menuItem(_FolderAction.delete, 'Delete folder…'),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case _FolderAction.newNote:
        notepad.newNoteIn(folder);
      case _FolderAction.newFolder:
        _newFolder(folder);
      case _FolderAction.rename:
        setState(() => _renaming = folder);
      case _FolderAction.delete:
        await _deleteFolder(folder);
      case null:
        break;
    }
  }

  /// Deletes [folder] once the person agrees, if anything is in it. Its
  /// notes and folders are kept.
  Future<void> _deleteFolder(Folder folder) async {
    final notes = notepad.notesIn(folder).length;
    final folders = notepad.foldersIn(folder).length;
    if (notes + folders > 0) {
      final parent = notepad.parentOf(folder);
      final contents = [
        if (notes > 0) notes == 1 ? '1 note' : '$notes notes',
        if (folders > 0) folders == 1 ? '1 folder' : '$folders folders',
      ].join(' and ');
      final where = parent == null
          ? 'the top level'
          : '"${parent.displayName}"';
      final confirmed = await confirm(
        context,
        title: 'Delete the folder "${folder.displayName}"?',
        body:
            'The $contents in it will move to $where. '
            'No notes are deleted.',
        action: 'Delete folder',
      );
      if (!confirmed) return;
    }
    notepad.deleteFolder(folder);
  }

  Widget _trashHeader(BuildContext context, TextStyle? heading, int count) {
    return InkWell(
      onTap: () => setState(() => _trashExpanded = !_trashExpanded),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            Icon(
              _trashExpanded ? Icons.expand_more : Icons.chevron_right,
              size: 16,
              color: heading?.color,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'TRASH ($count)',
                style: heading,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (_trashExpanded)
              TextButton(
                onPressed: () => _confirmEmptyTrash(context, count),
                child: const Text('Empty'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _trashTile(BuildContext context, Note note) {
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    final deletesOn = notepad.deletesOn(note);
    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showTrashMenu(context, note, details.globalPosition),
      child: ListTile(
        dense: true,
        leading: Icon(modeIcon(note.guess.mode), size: 16),
        title: Text(
          note.displayTitle,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: theme.colorScheme.outline),
        ),
        subtitle: deletesOn == null
            ? null
            : Text(
                'Kept until ${localizations.formatShortMonthDay(deletesOn)}',
              ),
        trailing: IconButton(
          tooltip: 'Restore',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.restore_from_trash_outlined),
          onPressed: () => notepad.restore(note),
        ),
        onTap: () => notepad.restore(note),
      ),
    );
  }

  Future<void> _showTrashMenu(
    BuildContext context,
    Note note,
    Offset position,
  ) async {
    final choice = await showContextMenu<bool>(
      context,
      position: position,
      items: [menuItem(false, 'Restore'), menuItem(true, 'Delete forever…')],
    );
    if (!context.mounted || choice == null) return;
    if (!choice) {
      notepad.restore(note);
      return;
    }
    final confirmed = await confirm(
      context,
      title: 'Delete "${note.displayTitle}" forever?',
      body: 'This can\'t be undone.',
      action: 'Delete forever',
    );
    if (confirmed) notepad.deleteForever(note);
  }

  Future<void> _confirmEmptyTrash(BuildContext context, int count) async {
    final confirmed = await confirm(
      context,
      title: count == 1
          ? 'Delete the note in the trash forever?'
          : 'Delete all $count notes in the trash forever?',
      body: 'This can\'t be undone.',
      action: 'Delete forever',
    );
    if (confirmed) notepad.emptyTrash();
  }
}

enum _FolderAction { newNote, newFolder, rename, delete }

/// One line of the tree: an expand arrow for folders, an icon and a label.
class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.depth,
    required this.icon,
    required this.label,
    this.iconColor,
    this.expanded,
    this.onToggle,
    this.selected = false,
    this.highlight = false,
    this.onTap,
    this.onMenu,
    this.trailing,
  });

  final int depth;
  final IconData icon;
  final Color? iconColor;
  final Widget label;

  /// Null for rows that don't expand, like notes.
  final bool? expanded;
  final VoidCallback? onToggle;
  final bool selected;

  /// Something dragged over this row would move here.
  final bool highlight;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onMenu;
  final Widget? trailing;

  static const _indent = 14.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onSecondaryTapUp: onMenu == null
          ? null
          : (details) => onMenu!(details.globalPosition),
      child: Ink(
        color: highlight
            ? scheme.primaryContainer
            : selected
            ? scheme.secondaryContainer
            : null,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.only(left: 8 + depth * _indent, right: 12),
            child: SizedBox(
              height: 32,
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    child: expanded == null
                        ? null
                        : InkResponse(
                            onTap: onToggle,
                            radius: 12,
                            child: Icon(
                              expanded!
                                  ? Icons.expand_more
                                  : Icons.chevron_right,
                              size: 16,
                              color: scheme.outline,
                            ),
                          ),
                  ),
                  const SizedBox(width: 2),
                  Icon(icon, size: 16, color: iconColor ?? scheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        color: selected ? scheme.onSecondaryContainer : null,
                      ),
                      child: label,
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 8),
                    trailing!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What follows the pointer while a note or folder is dragged.
class _DragLabel extends StatelessWidget {
  const _DragLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A folder name being typed in place. Enter or clicking away keeps it;
/// Escape keeps the old name.
class _RenameField extends StatefulWidget {
  const _RenameField({required this.initial, required this.onDone});

  final String initial;

  /// Called once, with the name typed, or null if the person backed out.
  final ValueChanged<String?> onDone;

  @override
  State<_RenameField> createState() => _RenameFieldState();
}

class _RenameFieldState extends State<_RenameField> {
  late final _controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  final _focus = FocusNode();
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _finish(_controller.text);
    });
  }

  @override
  void dispose() {
    _done = true;
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _finish(String? name) {
    if (_done) return;
    _done = true;
    widget.onDone(name);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () => _finish(null),
      },
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        autofocus: true,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          border: OutlineInputBorder(),
        ),
        onSubmitted: _finish,
        onTapOutside: (_) => _focus.unfocus(),
      ),
    );
  }
}
