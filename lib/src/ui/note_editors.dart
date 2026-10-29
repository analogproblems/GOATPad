import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_quill/quill_delta.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/languages/all.dart';

import '../notes/html_markdown.dart';
import '../notes/note_mode.dart';
import '../notes/rich_markdown.dart';
import '../theme.dart';
import 'clipboard_html.dart';

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
    this.onPaste,
  });

  final String text;
  final ModeGuess guess;
  final ValueChanged<String> onChanged;

  /// Runs first on a paste. If it returns true it has handled the paste
  /// itself, as when the first paste into a new note turns it Rich.
  final Future<bool> Function()? onPaste;

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

  Future<void> _paste() async {
    if (await widget.onPaste?.call() ?? false) return;
    if (mounted) _controller.paste();
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
      shortcutOverrideActions: widget.onPaste == null
          ? null
          : {
              CodeShortcutPasteIntent: CallbackAction<CodeShortcutPasteIntent>(
                onInvoke: (_) => _paste(),
              ),
            },
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
/// converts to and from Markdown with [RichMarkdown]. Picked over Fleather in
/// the step 1 editor lab.
///
/// Pasting HTML with formatting (from a browser, Word or Google Docs) goes
/// through Markdown on the way in, so what shows is exactly what is saved:
/// headings, lists, emphasis, links, images and tables, and not the fonts,
/// colors and sizes Markdown can't keep.
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
  late final quill.QuillController _controller = quill.QuillController(
    document: _initialDocument(),
    selection: const TextSelection.collapsed(offset: 0),
    // flutter_quill marks its clipboard hooks experimental. Its version is
    // locked in pubspec.lock, and the paste tests would catch a change.
    config: quill.QuillControllerConfig(
      // ignore: experimental_member_use
      clipboardConfig: quill.QuillClipboardConfig(
        // GPad reads and converts clipboard HTML itself, below.
        // ignore: experimental_member_use
        enableExternalRichPaste: false,
        // ignore: experimental_member_use
        onClipboardPaste: _pasteHtml,
      ),
    ),
  );
  StreamSubscription<quill.DocChange>? _changes;
  final _focusNode = FocusNode();
  final _scrollController = ScrollController();

  quill.Document _initialDocument() {
    if (widget.markdown.trim().isEmpty) return quill.Document();
    return quill.Document.fromDelta(RichMarkdown.toDelta(widget.markdown));
  }

  /// Pastes the clipboard's HTML, if it has formatting, as the Markdown it
  /// converts to. Returns false to let Quill paste the plain text.
  Future<bool> _pasteHtml() async {
    final html = await readClipboardHtml();
    final markdown = html == null ? null : markdownFromHtml(html);
    if (markdown == null || !mounted) return false;

    final ops = RichMarkdown.toDelta(markdown).toList();
    // Without its final line break a pasted phrase joins the line it lands
    // in, instead of splitting it.
    if (ops.lastOrNull case Operation(data: final String last, attributes: null)
        when last.endsWith('\n')) {
      ops.removeLast();
      if (last.length > 1) {
        ops.add(Operation.insert(last.substring(0, last.length - 1)));
      }
    }
    final delta = Delta();
    for (final op in ops) {
      delta.push(op);
    }
    // Delta.length counts operations, not characters.
    final length = ops.fold(0, (sum, op) => sum + (op.length ?? 0));
    final selection = _controller.selection;
    _controller
      ..replaceText(
        selection.start,
        selection.end - selection.start,
        delta,
        null,
      )
      // Set here rather than through replaceText, which counts a pasted
      // Delta as one character when it moves the cursor.
      ..updateSelection(
        TextSelection.collapsed(offset: selection.start + length),
        quill.ChangeSource.local,
      );
    return true;
  }

  @override
  void initState() {
    super.initState();
    _focusAfterLayout(this, _focusNode);
    _changes = _controller.document.changes.listen(
      (_) => widget.onChanged(
        RichMarkdown.fromDelta(_controller.document.toDelta()),
      ),
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

/// Shows embeds from Markdown (images, rules, tables) without loading
/// anything.
///
/// Quill throws for any embed type it has no builder for. Images are shown
/// as their alt text and address instead of being fetched, so pasting never
/// makes a network request on its own. Tables show as tables, read-only:
/// switching the note to Plain or Code edits their Markdown. Every embed
/// stays in the document, so it goes back to Markdown unchanged.
class _EmbedPlaceholderBuilder extends quill.EmbedBuilder {
  const _EmbedPlaceholderBuilder();

  @override
  String get key => 'gpad-placeholder';

  @override
  Widget build(BuildContext context, quill.EmbedContext embedContext) {
    final embed = embedContext.node.value;
    final data = embed.data;
    switch (embed.type) {
      case RichMarkdown.ruleType:
        return const Divider(height: 24);
      case RichMarkdown.tableType:
        return _MarkdownTable(markdown: '$data');
      case RichMarkdown.imageType when data is Map:
        final alt = '${data['alt'] ?? ''}';
        final src = '${data['src'] ?? ''}';
        return _placeholder(
          context,
          Icons.image_outlined,
          alt.isEmpty ? src : '$alt · $src',
        );
      case quill.BlockEmbed.imageType:
        return _placeholder(context, Icons.image_outlined, '$data');
      default:
        return _placeholder(
          context,
          Icons.extension_outlined,
          '${embed.type}: $data',
        );
    }
  }

  Widget _placeholder(BuildContext context, IconData icon, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

/// A Markdown table, drawn as a table with its cells' emphasis and code.
class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({required this.markdown});

  final String markdown;

  static final _unescapedPipe = RegExp(r'(?<!\\)\|');

  static List<String> _cells(String line) {
    var row = line.trim();
    if (row.startsWith('|')) row = row.substring(1);
    if (row.endsWith('|') && !row.endsWith(r'\|')) {
      row = row.substring(0, row.length - 1);
    }
    return row.split(_unescapedPipe).map((cell) => cell.trim()).toList();
  }

  TextSpan _cell(String markdown, TextStyle base, ColorScheme scheme) {
    if (markdown.isEmpty) return const TextSpan(text: '');
    return TextSpan(
      children: [
        for (final op in RichMarkdown.toDelta(markdown).toList())
          if (op.data case final String text)
            TextSpan(
              text: text.replaceAll('\n', ' ').trimRight(),
              style: base.copyWith(
                fontWeight: op.attributes?['bold'] == true
                    ? FontWeight.bold
                    : null,
                fontStyle: op.attributes?['italic'] == true
                    ? FontStyle.italic
                    : null,
                decoration: op.attributes?['strike'] == true
                    ? TextDecoration.lineThrough
                    : null,
                fontFamily: op.attributes?['code'] == true
                    ? GoatTheme.monoFonts.first
                    : null,
                fontFamilyFallback: op.attributes?['code'] == true
                    ? GoatTheme.monoFonts
                    : null,
                color: op.attributes?['link'] != null ? scheme.primary : null,
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = markdown
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final rows = [
      for (var i = 0; i < lines.length; i++)
        if (i != 1) _cells(lines[i]),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    final columns = rows.map((row) => row.length).reduce(max);
    final base = theme.textTheme.bodyMedium ?? const TextStyle();

    return Tooltip(
      message: 'Switch this note to Plain to edit the table',
      waitDuration: const Duration(seconds: 1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            border: TableBorder.all(color: scheme.outlineVariant),
            defaultColumnWidth: const IntrinsicColumnWidth(),
            children: [
              for (final (index, row) in rows.indexed)
                TableRow(
                  decoration: index == 0
                      ? BoxDecoration(color: scheme.surfaceContainer)
                      : null,
                  children: [
                    for (var c = 0; c < columns; c++)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        child: Text.rich(
                          _cell(
                            c < row.length ? row[c] : '',
                            index == 0
                                ? base.copyWith(fontWeight: FontWeight.bold)
                                : base,
                            scheme,
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
