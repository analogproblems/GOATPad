import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/app.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/notes/note.dart';
import 'package:goatpad/src/store/note_store.dart';

/// Starts GPad with the welcome note and three more, one closed and one in
/// the trash.
Future<Notepad> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final notepad = Notepad.load(NoteStore.inMemory());
  notepad.pasteAsNewNote('Groceries\nmilk, eggs, bread');
  notepad.close(
    notepad.pasteAsNewNote('Milk frother manual\nDescale monthly')!,
  );
  notepad.trash(notepad.pasteAsNewNote('Milkshake recipe\nIce cream')!);
  await tester.pumpWidget(GPadApp(notepad: notepad));
  await tester.pump(const Duration(milliseconds: 1));
  return notepad;
}

final _desktop = TargetPlatformVariant.only(TargetPlatform.linux);

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

Future<void> _openSearch(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _finish(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(seconds: 1));
}

Finder _inResults(Finder finder) => find.descendant(
  of: find.byKey(const ValueKey('search-results')),
  matching: finder,
);

/// The plain text of every line shown in the results, in order: each
/// result's title, then its snippet and where it is.
List<String> _titles(WidgetTester tester) => [
  for (final text in tester.widgetList<Text>(_inResults(find.byType(Text))))
    text.textSpan?.toPlainText() ?? text.data ?? '',
];

void main() {
  testWidgets('Ctrl+P searches as you type and Enter opens the pick', (
    tester,
  ) async {
    final notepad = await _pumpApp(tester);
    await _openSearch(tester);
    expect(find.text('Search all notes'), findsOneWidget);

    await tester.enterText(find.byType(EditableText).last, 'milk');
    await tester.pump();
    final titles = _titles(tester);
    expect(titles.where((t) => t.contains('Milk')), isNotEmpty);
    expect(_inResults(find.text('Closed')), findsOneWidget);
    expect(find.text('In trash, opening restores it'), findsOneWidget);
    // The match markers never show as characters.
    expect(titles.any((t) => t.contains('\u0002')), isFalse);

    // A title match ranks first.
    expect(titles.first, 'Milk frother manual');

    // Down to the next result and back up to the closed frother manual.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    // Enter, as the platform's text input reports it.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 300));
    final frother = notepad.selected!;
    expect(frother.title, 'Milk frother manual');
    expect(frother.status, NoteStatus.open);
    expect(find.text('Search all notes'), findsNothing);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('opening a trashed result restores it', (tester) async {
    final notepad = await _pumpApp(tester);
    await _openSearch(tester);
    await tester.enterText(find.byType(EditableText).last, 'shake');
    await tester.pump();

    await tester.tap(find.text('In trash, opening restores it'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(notepad.selected!.title, 'Milkshake recipe');
    expect(notepad.trashedNotes, isEmpty);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('Escape closes the search without opening anything', (
    tester,
  ) async {
    final notepad = await _pumpApp(tester);
    final before = notepad.selected;
    await _openSearch(tester);
    await tester.enterText(find.byType(EditableText).last, 'nothing like it');
    await tester.pump();
    expect(find.text('No notes match'), findsOneWidget);

    await _press(tester, LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Search all notes'), findsNothing);
    expect(notepad.selected, before);
    await _finish(tester);
  }, variant: _desktop);
}
