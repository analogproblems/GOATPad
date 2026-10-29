import 'dart:ui' show AppExitResponse;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/app.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/notes/note.dart';
import 'package:goatpad/src/store/note_store.dart';

/// Starts GPad on a fresh in-memory store with the welcome note and two
/// pasted notes open, "Shopping list" selected.
Future<Notepad> _pumpApp(WidgetTester tester, {NoteStore? store}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final notepad = Notepad.load(store ?? NoteStore.inMemory());
  notepad.pasteAsNewNote('Groceries for the week\nmilk, eggs, bread');
  notepad.pasteAsNewNote('Shopping list\napples\npears');
  await tester.pumpWidget(GPadApp(notepad: notepad));
  await tester.pump(const Duration(milliseconds: 1));
  return notepad;
}

/// The close buttons on the tabs, in tab order.
final _closeButtons = find.byTooltip('Close tab (keeps the note)');

/// GPad is a desktop app; flutter_test pretends to be Android otherwise.
final _desktop = TargetPlatformVariant.only(TargetPlatform.linux);

/// Drops keyboard focus so the code editor's cursor stops blinking, leaving
/// no timers running when the test ends.
Future<void> _finish(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, buttons: kSecondaryButton);
  // Let the menu finish opening.
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('shortcuts work before anything has been clicked', (
    tester,
  ) async {
    final notepad = await _pumpApp(tester);
    expect(notepad.openNotes, hasLength(3));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 100));

    expect(notepad.openNotes, hasLength(4));
    expect(notepad.selected!.awaitingFirstPaste, isTrue);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('a closed tab stays in the sidebar and reopens with a click', (
    tester,
  ) async {
    final notepad = await _pumpApp(tester);
    final shopping = notepad.selected!;
    expect(_closeButtons, findsNWidgets(3));

    await tester.tap(_closeButtons.last);
    await tester.pump(const Duration(milliseconds: 100));
    expect(shopping.status, NoteStatus.closed);
    expect(find.text('Closed'), findsOneWidget);

    await tester.tap(find.text('Shopping list'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(shopping.status, NoteStatus.open);
    expect(notepad.selected, shopping);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('a trashed note can be restored from the trash', (tester) async {
    final notepad = await _pumpApp(tester);
    final shopping = notepad.selected!;

    // Right-click the note in the sidebar (the first match; the second is
    // its tab).
    await _rightClick(tester, find.text('Shopping list').first);
    await tester.tap(find.text('Move to trash'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(shopping.status, NoteStatus.trashed);
    expect(find.text('TRASH (1)'), findsOneWidget);

    await tester.tap(find.text('TRASH (1)'));
    await tester.pump();
    expect(find.textContaining('Kept until'), findsOneWidget);
    await tester.tap(find.byTooltip('Restore'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(shopping.status, NoteStatus.open);
    expect(notepad.selected, shopping);
    expect(find.text('TRASH (1)'), findsNothing);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('emptying the trash asks first', (tester) async {
    final notepad = await _pumpApp(tester);
    final shopping = notepad.selected!;
    notepad.trash(shopping);
    await tester.pump();

    await tester.tap(find.text('TRASH (1)'));
    await tester.pump();
    await tester.tap(find.text('Empty'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete the note in the trash forever?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(notepad.trashedNotes, [shopping]);

    await tester.tap(find.text('Empty'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Delete forever'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(notepad.trashedNotes, isEmpty);
    expect(find.text('TRASH (1)'), findsNothing);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('a failing save shows a warning, and quitting asks first', (
    tester,
  ) async {
    final store = NoteStore.inMemory();
    final notepad = await _pumpApp(tester, store: store);
    final db = store.database;
    final pages = db.select('PRAGMA page_count').single.values.single;
    db.execute('PRAGMA max_page_count = $pages');

    notepad.editText(notepad.selected!, 'x' * 100000);
    notepad.flush();
    await tester.pump();
    expect(find.textContaining('GPad can\'t save your notes'), findsOneWidget);

    // Closing the window: GPad asks, and staying keeps the window open.
    final exit = tester.binding.handleRequestAppExit();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Your latest changes aren\'t saved'), findsOneWidget);
    await tester.tap(find.text('Keep GPad open'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(await exit, AppExitResponse.cancel);

    // Once there is room again, Try again saves and the warning goes.
    db.execute('PRAGMA max_page_count = 1000000');
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.textContaining('GPad can\'t save your notes'), findsNothing);
    expect(notepad.saveProblem, isNull);
    expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
    await _finish(tester);
  }, variant: _desktop);
}
