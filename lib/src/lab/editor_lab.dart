import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../notes/mode_detector.dart';
import '../notes/name_suggester.dart';
import '../notes/note_mode.dart';
import 'note_editors.dart';

/// A note held in memory. Step 2 replaces this with real storage.
class LabNote {
  LabNote({
    required this.id,
    required this.title,
    required this.text,
    required this.guess,
    this.awaitingFirstPaste = false,
  });

  final int id;
  String title;
  String text;
  ModeGuess guess;
  bool closed = false;
  bool titleEdited = false;

  /// Bumped when GOATPad renames the note, so the title field reloads.
  int titleVersion = 0;

  /// A new, empty note picks its mode and name from the first paste.
  bool awaitingFirstPaste;
}

/// Step 1 prototype: tabs, smart modes and inline naming, with nothing saved
/// yet. It settled the rich editor: Quill.
class EditorLab extends StatefulWidget {
  const EditorLab({super.key, required this.onToggleTheme});

  final VoidCallback onToggleTheme;

  @override
  State<EditorLab> createState() => _EditorLabState();
}

class _EditorLabState extends State<EditorLab> {
  final _detector = ModeDetector();
  final List<LabNote> _notes = [];
  int _nextId = 0;
  int? _selectedId;

  @override
  void initState() {
    super.initState();
    _add('Welcome to the editor lab', _welcome, const ModeGuess.rich());
    _add('Sample config', _sampleJson, const ModeGuess.code('json'));
    _add(
      'List notes in a folder',
      _samplePython,
      const ModeGuess.code('python'),
    );
    _selectedId = _notes.first.id;
  }

  List<LabNote> get _openNotes => _notes.where((n) => !n.closed).toList();

  LabNote? get _selected {
    for (final note in _notes) {
      if (note.id == _selectedId && !note.closed) return note;
    }
    return null;
  }

  LabNote _add(String title, String text, ModeGuess guess) {
    final note = LabNote(id: _nextId++, title: title, text: text, guess: guess);
    _notes.add(note);
    return note;
  }

  void _newNote() {
    setState(() {
      final note = _add(
        suggestName('', const ModeGuess.plain(), DateTime.now()),
        '',
        const ModeGuess.plain(),
      )..awaitingFirstPaste = true;
      _selectedId = note.id;
    });
  }

  Future<void> _pasteAsNewNote() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) return;
    final guess = _detector.detect(text);
    setState(() {
      _selectedId = _add(
        suggestName(text, guess, DateTime.now()),
        text,
        guess,
      ).id;
    });
  }

  void _close(LabNote note) {
    setState(() {
      final open = _openNotes;
      final index = open.indexOf(note);
      note.closed = true;
      if (_selectedId == note.id) {
        final rest = _openNotes;
        _selectedId = rest.isEmpty
            ? null
            : rest[index.clamp(0, rest.length - 1)].id;
      }
    });
  }

  void _open(LabNote note) {
    setState(() {
      note.closed = false;
      _selectedId = note.id;
    });
  }

  void _onTextChanged(LabNote note, String text) {
    final wasEmpty = note.text.trim().isEmpty;
    note.text = text;
    if (!note.awaitingFirstPaste || !wasEmpty || text.trim().isEmpty) {
      setState(() {});
      return;
    }
    note.awaitingFirstPaste = false;
    final guess = _detector.detect(text);
    setState(() {
      note.guess = guess;
      if (!note.titleEdited) {
        note.title = suggestName(text, guess, DateTime.now());
        note.titleVersion++;
      }
    });
  }

  void _setMode(LabNote note, NoteMode mode) {
    setState(() {
      note.awaitingFirstPaste = false;
      note.guess = switch (mode) {
        NoteMode.code => ModeGuess.code(
          note.guess.language ??
              _codeGuessOrNull(note.text) ??
              ModeDetector.defaultLanguages.first,
        ),
        NoteMode.rich => const ModeGuess.rich(),
        NoteMode.plain => const ModeGuess.plain(),
      };
    });
  }

  String? _codeGuessOrNull(String text) {
    final guess = _detector.detect(text);
    return guess.mode == NoteMode.code ? guess.language : null;
  }

  @override
  Widget build(BuildContext context) {
    final note = _selected;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newNote,
        const SingleActivator(
          LogicalKeyboardKey.keyV,
          control: true,
          shift: true,
        ): _pasteAsNewNote,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): () {
          if (note != null) _close(note);
        },
      },
      child: Scaffold(
        body: Row(
          children: [
            SizedBox(width: 230, child: _sidebar(context)),
            const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  _tabStrip(context),
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
    );
  }

  Widget _sidebar(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
            child: Row(
              children: [
                Text('GOATPad', style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: 'Light or dark',
                  icon: const Icon(Icons.brightness_6_outlined, size: 18),
                  onPressed: widget.onToggleTheme,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              'NOTES',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final n in _notes)
                  ListTile(
                    dense: true,
                    selected: n.id == _selectedId && !n.closed,
                    leading: Icon(_modeIcon(n.guess.mode), size: 16),
                    title: Text(
                      n.title,
                      overflow: TextOverflow.ellipsis,
                      style: n.closed
                          ? TextStyle(color: theme.colorScheme.outline)
                          : null,
                    ),
                    subtitle: n.closed ? const Text('Closed') : null,
                    onTap: () => _open(n),
                  ),
              ],
            ),
          ),
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

  Widget _tabStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final n in _openNotes)
                  _Tab(
                    title: n.title,
                    icon: _modeIcon(n.guess.mode),
                    selected: n.id == _selectedId,
                    onTap: () => setState(() => _selectedId = n.id),
                    onClose: () => _close(n),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'New note (Ctrl+N)',
            icon: Icon(Icons.add, size: 18, color: scheme.onSurface),
            onPressed: _newNote,
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

  Widget _titleField(BuildContext context, LabNote note) {
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
        onChanged: (value) => setState(() {
          note.title = value;
          note.titleEdited = true;
        }),
      ),
    );
  }

  Widget _editor(LabNote note) {
    final key = ValueKey(
      '${note.id}-${note.guess.mode}-${note.guess.language}',
    );
    void onChanged(String text) => _onTextChanged(note, text);

    if (note.guess.mode != NoteMode.rich) {
      return CodeNoteEditor(
        key: key,
        text: note.text,
        guess: note.guess,
        onChanged: onChanged,
      );
    }
    return QuillNoteEditor(key: key, markdown: note.text, onChanged: onChanged);
  }

  Widget _statusBar(BuildContext context, LabNote note) {
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
            onChanged: (mode) => _setMode(note, mode!),
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
              onChanged: (language) =>
                  setState(() => note.guess = ModeGuess.code(language!)),
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
            'Closed notes stay in the sidebar. Click one to reopen it.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  static IconData _modeIcon(NoteMode mode) => switch (mode) {
    NoteMode.rich => Icons.article_outlined,
    NoteMode.code => Icons.code,
    NoteMode.plain => Icons.notes,
  };
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.title,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
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
    );
  }
}

const _welcome = '''
# Welcome to the editor lab

This is the **step 1 prototype**. Nothing is saved yet. Rich notes use the Quill editor, picked over Fleather here in the lab.

## Try this

- Switch this note to **Code** in the status bar to see its Markdown, then back to **Rich**
- Press Ctrl+N, then paste something: code, JSON, an email, or a Markdown list
- Watch the mode and the suggested name change, then rename the tab inline
- Close a tab with Ctrl+W, then reopen it from the sidebar

> Every note is stored as plain text. Rich notes are Markdown underneath, so switching this note to Code shows the source.
''';

const _sampleJson = '''
{
  "sync": {
    "backend": "google-drive",
    "scope": "drive.file",
    "encryption": "xchacha20-poly1305",
    "uploadDelaySeconds": 3
  },
  "theme": "warm-dark",
  "folders": ["Work", "Home", "Snippets"]
}
''';

const _samplePython = '''
# List notes in a folder
import os


def list_notes(folder: str) -> list[str]:
    """Return the note files in folder, newest first."""
    files = [f for f in os.listdir(folder) if f.endswith(".md")]
    return sorted(files, key=lambda f: os.path.getmtime(os.path.join(folder, f)), reverse=True)
''';
