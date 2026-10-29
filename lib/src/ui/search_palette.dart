import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../notepad/notepad.dart';
import '../notes/note.dart';
import '../store/note_store.dart';
import 'icons.dart';

/// Searches every note, closed and trashed ones too, as you type. Up and
/// Down pick a result, Enter opens it, Escape closes the search.
Future<void> showSearchPalette(
  BuildContext context, {
  required Notepad notepad,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _SearchPalette(notepad: notepad),
  );
}

class _SearchPalette extends StatefulWidget {
  const _SearchPalette({required this.notepad});

  final Notepad notepad;

  @override
  State<_SearchPalette> createState() => _SearchPaletteState();
}

class _SearchPaletteState extends State<_SearchPalette> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final _pickedKey = GlobalKey();
  late List<SearchResult> _results = widget.notepad.search('');
  int _picked = 0;

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _search(String query) => setState(() {
    _results = widget.notepad.search(query);
    _picked = 0;
  });

  void _move(int step) {
    if (_results.isEmpty) return;
    setState(() => _picked = (_picked + step) % _results.length);
    // Keep the picked result in view, including after wrapping around.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final picked = _pickedKey.currentContext;
      if (picked != null) {
        Scrollable.ensureVisible(
          picked,
          alignmentPolicy: step > 0
              ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
              : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
        );
      } else if (_scroll.hasClients) {
        _scroll.jumpTo(_picked == 0 ? 0 : _scroll.position.maxScrollExtent);
      }
    });
  }

  void _open(SearchResult result) {
    final note = result.note;
    if (note.status == NoteStatus.trashed) {
      widget.notepad.restore(note);
    } else {
      widget.notepad.open(note);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Pinned near the top, so it doesn't jump as the results change.
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        margin: const EdgeInsets.fromLTRB(24, 72, 24, 24),
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 520),
        child: Material(
          elevation: 8,
          borderRadius: BorderRadius.circular(12),
          color: theme.colorScheme.surfaceContainerHigh,
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                      _move(1),
                  const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                      _move(-1),
                },
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  onChanged: _search,
                  onSubmitted: (_) {
                    if (_results.isNotEmpty) _open(_results[_picked]);
                  },
                  decoration: const InputDecoration(
                    hintText: 'Search all notes',
                    prefixIcon: Icon(Icons.search),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const Divider(),
              Flexible(child: _resultList(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resultList(BuildContext context) {
    final theme = Theme.of(context);
    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _query.text.trim().isEmpty ? 'No notes yet' : 'No notes match',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
    }
    return ListView.builder(
      key: const ValueKey('search-results'),
      controller: _scroll,
      shrinkWrap: true,
      itemCount: _results.length,
      itemBuilder: (context, i) => _ResultTile(
        key: i == _picked ? _pickedKey : null,
        notepad: widget.notepad,
        result: _results[i],
        picked: i == _picked,
        onTap: () => _open(_results[i]),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({
    super.key,
    required this.notepad,
    required this.result,
    required this.picked,
    required this.onTap,
  });

  final Notepad notepad;
  final SearchResult result;
  final bool picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final note = result.note;
    final folder = notepad.folderOf(note);
    final muted = theme.textTheme.bodySmall?.copyWith(color: scheme.outline);
    final where = [
      if (folder != null) notepad.pathOf(folder),
      switch (note.status) {
        NoteStatus.open => null,
        NoteStatus.closed => 'Closed',
        NoteStatus.trashed => 'In trash, opening restores it',
      },
    ].nonNulls.join(' · ');
    final snippet = result.snippet;

    return Ink(
      color: picked ? scheme.secondaryContainer : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  modeIcon(note.guess.mode),
                  size: 16,
                  color: scheme.outline,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      _marked(context, result.title, theme.textTheme.bodyLarge),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (snippet != null)
                      Text.rich(
                        _marked(
                          context,
                          snippet.replaceAll(RegExp(r'\s+'), ' '),
                          theme.textTheme.bodySmall,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (where.isNotEmpty) Text(where, style: muted),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [text] as spans, with the parts the search matched in bold on a tint.
  /// Color isn't the only cue: matches are bold too.
  static TextSpan _marked(BuildContext context, String text, TextStyle? style) {
    final scheme = Theme.of(context).colorScheme;
    final match = TextStyle(
      fontWeight: FontWeight.bold,
      backgroundColor: scheme.primaryContainer,
      color: scheme.onPrimaryContainer,
    );
    final spans = <TextSpan>[];
    var inMatch = false;
    for (final part in text.split(
      RegExp(
        '[${SearchHit.markStart}'
        '${SearchHit.markEnd}]',
      ),
    )) {
      if (part.isNotEmpty) {
        spans.add(TextSpan(text: part, style: inMatch ? match : null));
      }
      inMatch = !inMatch;
    }
    return TextSpan(style: style, children: spans);
  }
}
