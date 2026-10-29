import 'dart:async';

import 'package:fleather/fleather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_quill/markdown_quill.dart';
import 'package:re_editor/re_editor.dart';
import 'package:parchment/codecs.dart';
import 'package:re_highlight/languages/all.dart';

import '../notes/note_mode.dart';
import '../theme.dart';

/// Which package draws Rich notes. The lab lets you flip between them on the
/// same note to compare how they feel.
enum RichEngine {
  quill('Quill'),
  fleather('Fleather');

  const RichEngine(this.label);

  final String label;
}

/// re_editor for Code and Plain notes.
class CodeNoteEditor extends StatefulWidget {
  const CodeNoteEditor({
    super.key,
    required this.text,
    required this.guess,
    required this.onChanged,
  });

  final String text;
  final ModeGuess guess;
  final ValueChanged<String> onChanged;

  @override
  State<CodeNoteEditor> createState() => _CodeNoteEditorState();
}

class _CodeNoteEditorState extends State<CodeNoteEditor> {
  late final CodeLineEditingController _controller =
      CodeLineEditingController.fromText(widget.text);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final language = widget.guess.language;
    final grammar = language == null ? null : builtinAllLanguages[language];
    final isCode = widget.guess.mode == NoteMode.code;

    return CodeEditor(
      controller: _controller,
      autofocus: true,
      wordWrap: !isCode,
      onChanged: (_) => widget.onChanged(_controller.text),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      style: CodeEditorStyle(
        fontSize: 14,
        fontHeight: 1.4,
        fontFamily: GoatTheme.monoFonts.first,
        fontFamilyFallback: GoatTheme.monoFonts,
        textColor: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerLowest,
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.25),
        cursorLineColor: scheme.surfaceContainerLow,
        chunkIndicatorColor: scheme.outline,
        codeTheme: grammar == null || !isCode
            ? null
            : CodeHighlightTheme(
                languages: {language!: CodeHighlightThemeMode(mode: grammar)},
                theme: GoatTheme.codeTheme(Theme.of(context).brightness),
              ),
      ),
      indicatorBuilder: isCode
          ? (context, editingController, chunkController, notifier) => Row(
              children: [
                DefaultCodeLineNumber(
                  controller: editingController,
                  notifier: notifier,
                  textStyle: TextStyle(
                    color: scheme.outline,
                    fontSize: 13,
                    fontFamily: GoatTheme.monoFonts.first,
                    fontFamilyFallback: GoatTheme.monoFonts,
                  ),
                ),
                DefaultCodeChunkIndicator(
                  width: 18,
                  controller: chunkController,
                  notifier: notifier,
                ),
              ],
            )
          : null,
    );
  }
}

/// fleather for Rich notes. Its document model, parchment, ships a Markdown
/// codec, so no add-on converter is needed.
class FleatherNoteEditor extends StatefulWidget {
  const FleatherNoteEditor({
    super.key,
    required this.markdown,
    required this.onChanged,
  });

  final String markdown;
  final ValueChanged<String> onChanged;

  @override
  State<FleatherNoteEditor> createState() => _FleatherNoteEditorState();
}

class _FleatherNoteEditorState extends State<FleatherNoteEditor> {
  late final FleatherController _controller = FleatherController(
    document: widget.markdown.trim().isEmpty
        ? ParchmentDocument()
        : parchmentMarkdown.decode(widget.markdown),
  );
  StreamSubscription<ParchmentChange>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = _controller.document.changes.listen(
      (_) => widget.onChanged(parchmentMarkdown.encode(_controller.document)),
    );
  }

  @override
  void dispose() {
    _changes?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: Column(
        children: [
          FleatherToolbar.basic(
            controller: _controller,
            hideBackgroundColor: true,
            hideForegroundColor: true,
            hideAlignment: true,
            hideDirection: true,
          ),
          const Divider(),
          Expanded(
            child: FleatherEditor(
              controller: _controller,
              autofocus: true,
              padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 16),
            ),
          ),
        ],
      ),
    );
  }
}

/// flutter_quill for Rich notes. Quill keeps its own Delta format, so this
/// converts to and from Markdown with markdown_quill.
class QuillNoteEditor extends StatefulWidget {
  const QuillNoteEditor({
    super.key,
    required this.markdown,
    required this.onChanged,
  });

  final String markdown;
  final ValueChanged<String> onChanged;

  @override
  State<QuillNoteEditor> createState() => _QuillNoteEditorState();
}

class _QuillNoteEditorState extends State<QuillNoteEditor> {
  static final _toDelta = MarkdownToDelta(
    markdownDocument: md.Document(
      encodeHtml: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ),
  );
  static final _toMarkdown = DeltaToMarkdown();

  late final quill.QuillController _controller = quill.QuillController(
    document: _initialDocument(),
    selection: const TextSelection.collapsed(offset: 0),
  );
  StreamSubscription<quill.DocChange>? _changes;

  quill.Document _initialDocument() {
    if (widget.markdown.trim().isEmpty) return quill.Document();
    return quill.Document.fromDelta(_toDelta.convert(widget.markdown));
  }

  @override
  void initState() {
    super.initState();
    _changes = _controller.document.changes.listen(
      (_) =>
          widget.onChanged(_toMarkdown.convert(_controller.document.toDelta())),
    );
  }

  @override
  void dispose() {
    _changes?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: Column(
        children: [
          quill.QuillSimpleToolbar(
            controller: _controller,
            config: const quill.QuillSimpleToolbarConfig(
              multiRowsDisplay: false,
              showFontFamily: false,
              showFontSize: false,
              showSubscript: false,
              showSuperscript: false,
              showBackgroundColorButton: false,
              showColorButton: false,
              showAlignmentButtons: false,
              showDirection: false,
              showSearchButton: false,
            ),
          ),
          const Divider(),
          Expanded(
            child: quill.QuillEditor.basic(
              controller: _controller,
              // Quill throws if it takes focus before its first layout.
              config: const quill.QuillEditorConfig(
                padding: EdgeInsets.symmetric(horizontal: 40, vertical: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
