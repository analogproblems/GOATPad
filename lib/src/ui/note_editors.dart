import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:markdown/markdown.dart' as md;
import 'package:markdown_quill/markdown_quill.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';

import '../notes/note_mode.dart';
import '../theme.dart';

/// Takes keyboard focus once the editor has been laid out, so a new or
/// newly shown note is ready to type or paste into. (Quill throws if it takes
/// focus before its first layout, which rules out plain `autofocus`.)
void _focusAfterLayout(State state, FocusNode node) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (state.mounted) node.requestFocus();
  });
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
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusAfterLayout(this, _focusNode);
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
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
      focusNode: _focusNode,
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
                theme: Theme.of(context).extension<CodeTheme>()!.styles,
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

/// flutter_quill for Rich notes. Quill keeps its own Delta format, so this
/// converts to and from Markdown with markdown_quill. Picked over Fleather in
/// the step 1 editor lab.
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
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  quill.Document _initialDocument() {
    if (widget.markdown.trim().isEmpty) return quill.Document();
    return quill.Document.fromDelta(_toDelta.convert(widget.markdown));
  }

  @override
  void initState() {
    super.initState();
    _focusAfterLayout(this, _focusNode);
    _changes = _controller.document.changes.listen(
      (_) =>
          widget.onChanged(_toMarkdown.convert(_controller.document.toDelta())),
    );
  }

  @override
  void dispose() {
    _changes?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
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
              // Kept across rebuilds, which happen on every keystroke.
              focusNode: _focusNode,
              scrollController: _scrollController,
              config: const quill.QuillEditorConfig(
                padding: EdgeInsets.symmetric(horizontal: 40, vertical: 16),
                unknownEmbedBuilder: _EmbedPlaceholderBuilder(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows embeds from Markdown (images, rules) without loading anything.
///
/// Quill throws for any embed type it has no builder for, and markdown_quill
/// turns `![alt](url)` and `---` into embeds. Remote images are shown as
/// their address instead of being fetched, so pasting Markdown never makes a
/// network request on its own. The embed itself stays in the document, so it
/// round-trips back to Markdown unchanged.
class _EmbedPlaceholderBuilder extends quill.EmbedBuilder {
  const _EmbedPlaceholderBuilder();

  /// markdown_quill's embed type for `---`; the package doesn't export it.
  static const _markdownQuillRuleType = 'divider';

  @override
  String get key => 'gpad-placeholder';

  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    final embed = embedContext.node.value;
    if (embed.type == _markdownQuillRuleType) {
      return const Divider(height: 24);
    }

    final scheme = Theme.of(context).colorScheme;
    final isImage = embed.type == quill.BlockEmbed.imageType;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(
            isImage ? Icons.image_outlined : Icons.extension_outlined,
            size: 16,
            color: scheme.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isImage ? '${embed.data}' : '${embed.type}: ${embed.data}',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}
