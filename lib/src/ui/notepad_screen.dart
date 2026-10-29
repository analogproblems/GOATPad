import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../notepad/notepad.dart';
import '../notes/mode_detector.dart';
import '../notes/note.dart';
import '../notes/note_mode.dart';
import 'appearance_dialog.dart';
import 'note_editors.dart';

/// The main window: notes in the sidebar, tabs, the editor and a status bar.
class NotepadScreen extends StatelessWidget {
  const NotepadScreen({super.key, required this.notepad});

  final Notepad notepad;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: notepad,
      builder: (context, _) {
        final note = notepad.selected;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyN, control: true):
                notepad.newNote,
            const SingleActivator(
              LogicalKeyboardKey.keyV,
              control: true,
              shift: true,
            ): _pasteAsNewNote,
            const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
              if (note != null) notepad.close(note);
            },
            const SingleActivator(LogicalKeyboardKey.tab, control: true):
                notepad.cycleTabs,
            const SingleActivator(
              LogicalKeyboardKey.tab,
              control: true,
              shift: true,
            ): () =>
                notepad.cycleTabs(backwards: true),
            const SingleActivator(LogicalKeyboardKey.pageDown, control: true):
                notepad.cycleTabs,
            const SingleActivator(
              LogicalKeyboardKey.pageUp,
              control: true,
            ): () =>
                notepad.cycleTabs(backwards: true),
          },
          // Holds focus when no editor does (say, at startup on a Rich
          // note), so the shortcuts work before anything is clicked.
          child: Focus(
            autofocus: true,
            child: Scaffold(
              body: Row(
                children: [
                  SizedBox(width: 240, child: _Sidebar(notepad: notepad)),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        _tabStrip(context, note),
                        const Divider(),
                        if (note == null)
                          Expanded(child: _emptyState(context))
                        else ...[
                          _titleField(context, note),
                          const Divider(),
                          Expanded(child: _editor(note)),
                          const Divider(),
                          _statusBar(context, note),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pasteAsNewNote() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    notepad.pasteAsNewNote(data?.text ?? '');
  }

  Widget _tabStrip(BuildContext context, Note? selected) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final n in notepad.openNotes)
                  _Tab(
                    title: n.displayTitle,
                    icon: modeIcon(n.guess.mode),
                    selected: n == selected,
                    onTap: () => notepad.open(n),
                    onClose: () => notepad.close(n),
                    onMenu: (position) => showNoteMenu(
                      context,
                      notepad: notepad,
                      note: n,
                      position: position,
                    ),
                  ),
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
            onPressed: _pasteAsNewNote,
          ),
        ],
      ),
    );
  }

  Widget _titleField(BuildContext context, Note note) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextFormField(
        key: ValueKey('title-${note.id}-${note.titleVersion}'),
        initialValue: note.title,
        style: Theme.of(context).textTheme.titleMedium,
        decoration: const InputDecoration(
          border: InputBorder.none,
          hintText: 'Name this note',
        ),
        onChanged: (value) => notepad.rename(note, value),
      ),
    );
  }

  Widget _editor(Note note) {
    final rich = note.guess.mode == NoteMode.rich;
    // Plain and Code share one editor, so the cursor stays put when the first
    // paste turns a Plain note into Code, or the language changes.
    final key = ValueKey('${note.id}-${rich ? 'rich' : 'text'}');
    void onChanged(String text) => notepad.editText(note, text);

    if (!rich) {
      return CodeNoteEditor(
        key: key,
        text: note.text,
        guess: note.guess,
        onChanged: onChanged,
      );
    }
    return QuillNoteEditor(key: key, markdown: note.text, onChanged: onChanged);
  }

  Widget _statusBar(BuildContext context, Note note) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final lines = note.text.isEmpty ? 0 : '\n'.allMatches(note.text).length + 1;
    final languages = {
      'json',
      ...ModeDetector.defaultLanguages,
      if (note.guess.language != null) note.guess.language!,
    }.toList()..sort();

    return Container(
      height: 34,
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          DropdownButton<NoteMode>(
            value: note.guess.mode,
            isDense: true,
            underline: const SizedBox(),
            style: small,
            items: [
              for (final mode in NoteMode.values)
                DropdownMenuItem(value: mode, child: Text(mode.label)),
            ],
            onChanged: (mode) => notepad.setMode(note, mode!),
          ),
          if (note.guess.mode == NoteMode.code) ...[
            const SizedBox(width: 16),
            DropdownButton<String>(
              value: note.guess.language,
              isDense: true,
              underline: const SizedBox(),
              style: small,
              items: [
                for (final language in languages)
                  DropdownMenuItem(
                    value: language,
                    child: Text(languageLabel(language)),
                  ),
              ],
              onChanged: (language) => notepad.setLanguage(note, language!),
            ),
          ],
          const Spacer(),
          Text(
            '$lines lines · ${note.text.length} characters',
            style: small?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('No open tabs', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Ctrl+N starts a note. Closed notes stay in the sidebar; '
            'click one to reopen it.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

IconData modeIcon(NoteMode mode) => switch (mode) {
  NoteMode.rich => Icons.article_outlined,
  NoteMode.code => Icons.code,
  NoteMode.plain => Icons.notes,
};

/// The right-click menu for a note in the sidebar or the tab strip.
Future<void> showNoteMenu(
  BuildContext context, {
  required Notepad notepad,
  required Note note,
  required Offset position,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final choice = await showMenu<_NoteAction>(
    context: context,
    position: RelativeRect.fromRect(
      position & Size.zero,
      Offset.zero & overlay.size,
    ),
    items: [
      if (note.status == NoteStatus.open)
        const PopupMenuItem(
          value: _NoteAction.close,
          height: _menuItemHeight,
          child: Text('Close tab'),
        )
      else
        const PopupMenuItem(
          value: _NoteAction.open,
          height: _menuItemHeight,
          child: Text('Open'),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: _NoteAction.trash,
        height: _menuItemHeight,
        child: Text('Move to trash'),
      ),
    ],
  );
  switch (choice) {
    case _NoteAction.open:
      notepad.open(note);
    case _NoteAction.close:
      notepad.close(note);
    case _NoteAction.trash:
      notepad.trash(note);
    case null:
      break;
  }
}

enum _NoteAction { open, close, trash }

/// Desktop-sized menu rows, rather than Material's touch-sized 48.
const _menuItemHeight = 36.0;

class _Sidebar extends StatefulWidget {
  const _Sidebar({required this.notepad});

  final Notepad notepad;

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  bool _trashExpanded = false;

  Notepad get notepad => widget.notepad;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = notepad.selected;
    final trashed = notepad.trashedNotes;
    final heading = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
      letterSpacing: 1.2,
    );

    // A Material, not a ColoredBox, so the note tiles' highlight and ink
    // splashes paint on top of the sidebar color.
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text('NOTES', style: heading),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final n in notepad.keptNotes)
                  GestureDetector(
                    onSecondaryTapUp: (details) => showNoteMenu(
                      context,
                      notepad: notepad,
                      note: n,
                      position: details.globalPosition,
                    ),
                    child: ListTile(
                      dense: true,
                      selected: n == selected,
                      leading: Icon(modeIcon(n.guess.mode), size: 16),
                      title: Text(
                        n.displayTitle,
                        overflow: TextOverflow.ellipsis,
                        style: n.status == NoteStatus.closed
                            ? TextStyle(color: theme.colorScheme.outline)
                            : null,
                      ),
                      subtitle: n.status == NoteStatus.closed
                          ? const Text('Closed')
                          : null,
                      onTap: () => notepad.open(n),
                    ),
                  ),
              ],
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
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Ctrl+N new note · Ctrl+Shift+V paste as new note · '
              'Ctrl+W close tab',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
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
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final choice = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: false,
          height: _menuItemHeight,
          child: Text('Restore'),
        ),
        PopupMenuItem(
          value: true,
          height: _menuItemHeight,
          child: Text('Delete forever…'),
        ),
      ],
    );
    if (!context.mounted || choice == null) return;
    if (!choice) {
      notepad.restore(note);
      return;
    }
    final confirmed = await _confirm(
      context,
      title: 'Delete "${note.displayTitle}" forever?',
      body: 'This can\'t be undone.',
    );
    if (confirmed) notepad.deleteForever(note);
  }

  Future<void> _confirmEmptyTrash(BuildContext context, int count) async {
    final confirmed = await _confirm(
      context,
      title: count == 1
          ? 'Delete the note in the trash forever?'
          : 'Delete all $count notes in the trash forever?',
      body: 'This can\'t be undone.',
    );
    if (confirmed) notepad.emptyTrash();
  }

  Future<bool> _confirm(
    BuildContext context, {
    required String title,
    required String body,
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
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.title,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.onClose,
    required this.onMenu,
  });

  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
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
              right: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Flexible(child: Text(title, overflow: TextOverflow.ellipsis)),
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
  }
}
