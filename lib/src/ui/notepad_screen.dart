import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../notepad/notepad.dart';
import '../notes/mode_detector.dart';
import '../notes/note.dart';
import '../notes/note_mode.dart';
import 'clipboard_html.dart';
import 'note_editors.dart';
import 'search_palette.dart';
import 'sidebar.dart';
import 'tab_strip.dart';

/// The main window: folders and notes in the sidebar, tabs, the editor and a
/// status bar.
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
            const SingleActivator(LogicalKeyboardKey.keyP, control: true): () =>
                showSearchPalette(context, notepad: notepad),
            const SingleActivator(
              LogicalKeyboardKey.keyF,
              control: true,
              shift: true,
            ): () =>
                showSearchPalette(context, notepad: notepad),
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
                  SizedBox(width: 240, child: Sidebar(notepad: notepad)),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        if (notepad.saveProblem case final problem?)
                          _saveProblemBanner(context, problem),
                        TabStrip(
                          notepad: notepad,
                          onPasteAsNewNote: _pasteAsNewNote,
                        ),
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
    final html = await readClipboardHtml();
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    notepad.pasteAsNewNote(data?.text ?? '', html: html);
  }

  /// The first paste into a new note keeps the clipboard's formatting, if
  /// it has any, by making the note Rich. Returns false to paste plain text.
  Future<bool> _pasteFirst(Note note) async {
    final html = await readClipboardHtml();
    if (html == null) return false;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return notepad.pasteFormatted(note, text: data?.text ?? '', html: html);
  }

  /// Stays up while saves are failing, so nobody stops typing believing
  /// their notes are safe.
  Widget _saveProblemBanner(BuildContext context, String problem) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(Icons.warning_amber, size: 18, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'GPad can\'t save your notes ($problem). Your latest changes '
                'are only in this window until it can. It keeps trying every '
                'few seconds.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(
              onPressed: notepad.flush,
              child: const Text('Try again'),
            ),
          ],
        ),
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
        onPaste: note.awaitingFirstPaste ? () => _pasteFirst(note) : null,
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
