import 'package:flutter/material.dart';

import '../notepad/notepad.dart';
import '../notes/folder.dart';
import '../notes/note.dart';
import 'icons.dart';
import 'menus.dart';

/// Open tabs, grouped by folder. Each group starts with the folder's label,
/// which folds its tabs away or brings them back. Tabs can be dragged onto a
/// label, or onto a folder in the sidebar, to move the note there.
class TabStrip extends StatelessWidget {
  const TabStrip({
    super.key,
    required this.notepad,
    required this.onPasteAsNewNote,
  });

  final Notepad notepad;
  final VoidCallback onPasteAsNewNote;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = notepad.selected;
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final group in notepad.tabGroups) ...[
                  if (group.folder case final folder?)
                    _GroupLabel(
                      notepad: notepad,
                      folder: folder,
                      tabs: group.notes.length,
                    ),
                  for (final note in group.notes)
                    if (!group.collapsed || note == selected)
                      _Tab(
                        note: note,
                        selected: note == selected,
                        groupColor: switch (group.folder) {
                          final folder? => folderColor(context, folder),
                          null => null,
                        },
                        onTap: () => notepad.open(note),
                        onClose: () => notepad.close(note),
                        onMenu: (position) => showNoteMenu(
                          context,
                          notepad: notepad,
                          note: note,
                          position: position,
                        ),
                      ),
                ],
              ],
            ),
          ),
          IconButton(
            tooltip: 'New note (Ctrl+N)',
            icon: Icon(Icons.add, size: 18, color: scheme.onSurface),
            onPressed: notepad.newNote,
          ),
          IconButton(
            tooltip: 'Paste as new note (Ctrl+Shift+V)',
            icon: Icon(Icons.content_paste, size: 18, color: scheme.onSurface),
            onPressed: onPasteAsNewNote,
          ),
        ],
      ),
    );
  }
}

/// A folder's name at the start of its tab group. Clicking it folds the
/// group's tabs away, or brings them back.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel({
    required this.notepad,
    required this.folder,
    required this.tabs,
  });

  final Notepad notepad;
  final Folder folder;

  /// How many tabs are in the group.
  final int tabs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = folderColor(context, folder);
    final collapsed = folder.tabsCollapsed;
    final path = notepad.pathOf(folder);
    return DragTarget<Note>(
      onWillAcceptWithDetails: (details) => details.data.folderId != folder.id,
      onAcceptWithDetails: (details) => notepad.moveNote(details.data, folder),
      builder: (context, candidates, _) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 7, 2, 7),
        child: Tooltip(
          message: collapsed ? '$path. Show its tabs' : '$path. Fold its tabs',
          child: Material(
            color: color.withValues(alpha: candidates.isEmpty ? 0.18 : 0.4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
              side: BorderSide(color: color),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => notepad.setTabsCollapsed(folder, !collapsed),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 14,
                      color: theme.colorScheme.onSurface,
                    ),
                    const SizedBox(width: 2),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Text(
                        folder.displayName,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    if (collapsed) ...[
                      const SizedBox(width: 6),
                      Text('$tabs', style: theme.textTheme.labelSmall),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.note,
    required this.selected,
    required this.groupColor,
    required this.onTap,
    required this.onClose,
    required this.onMenu,
  });

  final Note note;
  final bool selected;

  /// The color of the tab's folder, or null if it isn't in one.
  final Color? groupColor;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tab = GestureDetector(
      onSecondaryTapUp: (details) => onMenu(details.globalPosition),
      // Middle-click closes, as in browsers and Sublime.
      onTertiaryTapUp: (_) => onClose(),
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 220),
          padding: const EdgeInsets.only(left: 12, right: 4),
          decoration: BoxDecoration(
            color: selected ? scheme.surfaceContainerLowest : null,
            border: Border(
              top: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 2,
              ),
              bottom: BorderSide(
                color: groupColor ?? Colors.transparent,
                width: 2,
              ),
              right: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(modeIcon(note.guess.mode), size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Flexible(
                child: Text(note.displayTitle, overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                tooltip: 'Close tab (keeps the note)',
                iconSize: 14,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
    return Draggable<Note>(
      data: note,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(6),
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(note.displayTitle),
        ),
      ),
      child: tab,
    );
  }
}
