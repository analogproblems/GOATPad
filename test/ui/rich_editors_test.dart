import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/ui/clipboard_html.dart';
import 'package:goatpad/src/ui/note_editors.dart';
import 'package:goatpad/src/notes/mode_detector.dart';
import 'package:goatpad/src/notes/note_mode.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: const [
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    FlutterQuillLocalizations.delegate,
  ],
  supportedLocales: const [Locale('en')],
  home: Scaffold(body: SizedBox(width: 900, height: 700, child: child)),
);

const _withEmbeds = '''
# Photo

![x](https://example.com/x.png)

---

After the rule.
''';

void main() {
  test('Markdown with an image is detected as Rich', () {
    expect(ModeDetector().detect(_withEmbeds), const ModeGuess.rich());
  });

  testWidgets('Quill shows Markdown images and rules without throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(QuillNoteEditor(markdown: _withEmbeds, onChanged: (_) {})),
    );
    // Let the toolbar's zero-length startup timers fire.
    await tester.pump(const Duration(milliseconds: 1));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('example.com/x.png'), findsOneWidget);
    expect(find.byType(Divider), findsWidgets);
  });

  testWidgets('editing next to an image keeps it in the Markdown', (
    tester,
  ) async {
    String? saved;
    await tester.pumpWidget(
      _host(
        QuillNoteEditor(markdown: _withEmbeds, onChanged: (m) => saved = m),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));

    final controller = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    controller.document.insert(controller.document.length - 1, ' More');
    await tester.pump(const Duration(milliseconds: 1));

    expect(saved, contains('![x](https://example.com/x.png)'));
    expect(saved, contains('\n---\n'));
    expect(saved, contains('More'));
  });

  testWidgets('a table shows as a table and stays Markdown', (tester) async {
    const markdown =
        '| Key | Does |\n| --- | --- |\n| **Ctrl+N** | New note |\n';
    String? saved;
    await tester.pumpWidget(
      _host(QuillNoteEditor(markdown: markdown, onChanged: (m) => saved = m)),
    );
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.byType(Table), findsOneWidget);
    expect(find.textContaining('Ctrl+N', findRichText: true), findsOneWidget);
    expect(find.textContaining('**', findRichText: true), findsNothing);

    final controller = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    controller.document.insert(controller.document.length - 1, 'After');
    await tester.pump(const Duration(milliseconds: 1));
    expect(saved, startsWith(markdown));
  });

  testWidgets('quoting or listing a table\'s line never loses the table', (
    tester,
  ) async {
    const markdown = '| Team | Person |\n| --- | --- |\n| Core | Ana |\n';
    for (final format in <Attribute<Object?>>[
      Attribute.blockQuote,
      Attribute.ul,
      Attribute.h2,
      Attribute.codeBlock,
    ]) {
      String? saved;
      await tester.pumpWidget(
        _host(
          QuillNoteEditor(
            key: UniqueKey(),
            markdown: markdown,
            onChanged: (m) => saved = m,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      final controller = tester
          .widget<QuillEditor>(find.byType(QuillEditor))
          .controller;
      controller
        ..updateSelection(
          const TextSelection.collapsed(offset: 0),
          ChangeSource.local,
        )
        ..formatSelection(format);
      await tester.pump(const Duration(milliseconds: 1));
      expect(saved, markdown, reason: format.key);

      // Opened again, it is still a table.
      await tester.pumpWidget(
        _host(
          QuillNoteEditor(
            key: UniqueKey(),
            markdown: saved!,
            onChanged: (_) {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(Table), findsOneWidget, reason: format.key);
    }
  });

  testWidgets('table cells keep the spaces around bold, links and code', (
    tester,
  ) async {
    const markdown =
        '| Say **hello** now | See [the docs](https://example.com) or `gpad --help` here |\n'
        '| --- | --- |\n'
        '| a *b* c | ~~x~~ y |\n';
    await tester.pumpWidget(
      _host(QuillNoteEditor(markdown: markdown, onChanged: (_) {})),
    );
    await tester.pump(const Duration(milliseconds: 1));

    final cells = [
      for (final text in tester.widgetList<RichText>(
        find.descendant(
          of: find.byType(Table),
          matching: find.byType(RichText),
        ),
      ))
        text.text.toPlainText(),
    ];
    expect(cells, [
      'Say hello now',
      'See the docs or gpad --help here',
      'a b c',
      'x y',
    ]);
  });

  testWidgets('pasting formatted HTML into a Rich note keeps the formatting', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      clipboardChannel,
      (call) async => Uint8List.fromList(
        utf8.encode(
          '<p>See <b>this</b> and <a href="https://example.com">that</a></p>',
        ),
      ),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        clipboardChannel,
        null,
      ),
    );

    String? saved;
    await tester.pumpWidget(
      _host(QuillNoteEditor(markdown: 'Before\n', onChanged: (m) => saved = m)),
    );
    await tester.pump(const Duration(milliseconds: 1));
    final controller = tester
        .widget<QuillEditor>(find.byType(QuillEditor))
        .controller;
    controller.updateSelection(
      const TextSelection.collapsed(offset: 6),
      ChangeSource.local,
    );
    // What Ctrl+V runs.
    // ignore: experimental_member_use
    await controller.clipboardPaste();
    await tester.pump(const Duration(milliseconds: 1));

    expect(saved, 'BeforeSee **this** and [that](https://example.com)\n');
    // The cursor ends up after the pasted text.
    expect(controller.selection, const TextSelection.collapsed(offset: 23));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
}
