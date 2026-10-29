import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/app.dart';
import 'package:goatpad/src/code_colors.dart';
import 'package:re_editor/re_editor.dart';

Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(const GPadApp());
  // Let the Quill toolbar's zero-length startup timers fire.
  await tester.pump(const Duration(milliseconds: 1));
}

/// Opens Appearance, picks Slate, Dark and colorblind-safe code colors, and
/// closes the dialog.
Future<void> _switchToSlateDarkColorblindSafe(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Appearance'));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('Slate'));
  await tester.pump();
  await tester.tap(find.text('Dark'));
  await tester.pump();
  await tester.tap(find.text('Colorblind-safe'));
  await tester.pump();
  await tester.tap(find.text('Done'));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('changing appearance keeps a Code note and recolors it', (
    tester,
  ) async {
    await _pumpApp(tester);
    await tester.tap(find.text('Sample config').last);
    await tester.pump(const Duration(milliseconds: 100));

    final before = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final controller = before.controller!;
    controller.text = '{"edited": true}';
    controller.selection = const CodeLineSelection.collapsed(
      index: 0,
      offset: 5,
    );
    await tester.pump();
    expect(find.textContaining('16 characters'), findsOneWidget);

    await _switchToSlateDarkColorblindSafe(tester);

    final after = tester.widget<CodeEditor>(find.byType(CodeEditor));
    // Same editor state, so the text, selection and undo history survive.
    expect(identical(after.controller, controller), isTrue);
    expect(controller.text, '{"edited": true}');
    expect(
      controller.selection,
      const CodeLineSelection.collapsed(index: 0, offset: 5),
    );
    expect(find.textContaining('16 characters'), findsOneWidget);

    // The open editor picked up the new theme and code colors.
    final context = tester.element(find.byType(CodeEditor));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(
      after.style!.codeTheme!.theme,
      colorblindSafeCodeColors(Brightness.dark),
    );
    expect(after.style!.backgroundColor, const Color(0xFF0F1318));
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing appearance keeps a Rich note and its edits', (
    tester,
  ) async {
    await _pumpApp(tester);

    final editor = tester.widget<quill.QuillEditor>(
      find.byType(quill.QuillEditor),
    );
    final controller = editor.controller;
    controller.replaceText(
      0,
      0,
      'Kept. ',
      const TextSelection.collapsed(offset: 6),
    );
    await tester.pump();

    await _switchToSlateDarkColorblindSafe(tester);

    final after = tester.widget<quill.QuillEditor>(
      find.byType(quill.QuillEditor),
    );
    expect(identical(after.controller, controller), isTrue);
    expect(controller.document.toPlainText(), startsWith('Kept. Welcome'));
    expect(controller.selection, const TextSelection.collapsed(offset: 6));
    expect(
      Theme.of(tester.element(find.byType(quill.QuillEditor))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });
}
