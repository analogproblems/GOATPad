import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
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

    expect(saved, contains('![](https://example.com/x.png)'));
    expect(saved, contains('- - -'));
    expect(saved, contains('More'));
  });
}
