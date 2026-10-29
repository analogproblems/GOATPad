import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_quill/flutter_quill.dart' show QuillEditor;
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/app.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/notes/note_mode.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/ui/clipboard_html.dart';

/// GPad is a desktop app; flutter_test pretends to be Android otherwise.
final _desktop = TargetPlatformVariant.only(TargetPlatform.linux);

const _article =
    '<h1>Trip plan</h1><p>Leave <b>early</b>, see '
    '<a href="https://example.com/map">the map</a>.</p>'
    '<ul><li>Tickets</li><li>Snacks</li></ul>';
const _articleText = 'Trip plan\nLeave early, see the map.\nTickets\nSnacks';
const _articleMarkdown = '''
# Trip plan

Leave **early**, see [the map](https://example.com/map).

- Tickets
- Snacks
''';

/// Puts [text], and [html] if given, on the pretend clipboard.
void _clipboard(WidgetTester tester, String text, {String? html}) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    return switch (call.method) {
      'Clipboard.getData' => {'text': text},
      'Clipboard.hasStrings' => {'value': true},
      _ => null,
    };
  });
  messenger.setMockMethodCallHandler(
    clipboardChannel,
    (call) async => html == null ? null : Uint8List.fromList(utf8.encode(html)),
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(clipboardChannel, null);
  });
}

Future<Notepad> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final notepad = Notepad.load(NoteStore.inMemory());
  await tester.pumpWidget(GPadApp(notepad: notepad));
  await tester.pump(const Duration(milliseconds: 1));
  return notepad;
}

Future<void> _press(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _finish(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('Ctrl+Shift+V makes a Rich note from a formatted page', (
    tester,
  ) async {
    _clipboard(tester, _articleText, html: _article);
    final notepad = await _pumpApp(tester);

    await _press(tester, LogicalKeyboardKey.keyV, shift: true);

    final note = notepad.selected!;
    expect(note.guess, const ModeGuess.rich());
    expect(note.text, _articleMarkdown);
    expect(note.title, 'Trip plan');
    expect(find.byType(QuillEditor), findsOneWidget);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('the first paste into a new note keeps its formatting', (
    tester,
  ) async {
    _clipboard(tester, _articleText, html: _article);
    final notepad = await _pumpApp(tester);

    await _press(tester, LogicalKeyboardKey.keyN);
    final note = notepad.selected!;
    expect(note.awaitingFirstPaste, isTrue);
    await _press(tester, LogicalKeyboardKey.keyV);

    expect(note.guess, const ModeGuess.rich());
    expect(note.text, _articleMarkdown);
    expect(note.title, 'Trip plan');
    expect(find.byType(QuillEditor), findsOneWidget);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('code copied with colors only still becomes a Code note', (
    tester,
  ) async {
    const code = 'def greet(name):\n    return f"Hi {name}"\n';
    _clipboard(
      tester,
      code,
      html:
          '<div style="font-family: monospace; white-space: pre;">'
          '<div><span style="color: #569cd6;">def</span> greet(name):</div>'
          '<div>    <span style="color: #c586c0;">return</span> '
          'f"Hi {name}"</div></div>',
    );
    final notepad = await _pumpApp(tester);

    await _press(tester, LogicalKeyboardKey.keyN);
    final note = notepad.selected!;
    await _press(tester, LogicalKeyboardKey.keyV);

    expect(note.text, code);
    expect(note.guess, const ModeGuess.code('python'));
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('without HTML a paste is plain text as before', (tester) async {
    _clipboard(tester, 'Call the dentist\nFriday 9am');
    final notepad = await _pumpApp(tester);

    await _press(tester, LogicalKeyboardKey.keyN);
    final note = notepad.selected!;
    await _press(tester, LogicalKeyboardKey.keyV);

    expect(note.text, 'Call the dentist\nFriday 9am');
    expect(note.guess, const ModeGuess.plain());
    await _finish(tester);
  }, variant: _desktop);
}
