import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/app.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/ui/sidebar.dart';
import 'package:goatpad/src/ui/tab_strip.dart';

/// Starts GPad on a fresh in-memory store with the welcome note and a
/// pasted "Shopping list", which is selected.
Future<Notepad> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final notepad = Notepad.load(NoteStore.inMemory());
  notepad.pasteAsNewNote('Shopping list\napples\npears');
  await tester.pumpWidget(GPadApp(notepad: notepad));
  await tester.pump(const Duration(milliseconds: 1));
  return notepad;
}

final _desktop = TargetPlatformVariant.only(TargetPlatform.linux);

Finder _inSidebar(String text) =>
    find.descendant(of: find.byType(Sidebar), matching: find.text(text));

/// The folder name being typed in the sidebar.
final _renameField = find.descendant(
  of: find.byType(Sidebar),
  matching: find.byType(EditableText),
);

Finder _inTabs(String text) =>
    find.descendant(of: find.byType(TabStrip), matching: find.text(text));

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  await tester.tap(finder, buttons: kSecondaryButton);
  await _settle(tester);
}

Future<void> _finish(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('a new folder is named in place', (tester) async {
    final notepad = await _pumpApp(tester);

    await tester.tap(find.byTooltip('New folder'));
    await tester.pump();
    // The name is selected, so typing replaces it.
    await tester.enterText(_renameField, 'Work');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(notepad.folders.single.name, 'Work');
    expect(_inSidebar('Work'), findsOneWidget);
    expect(_renameField, findsNothing);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('Escape keeps the old name', (tester) async {
    final notepad = await _pumpApp(tester);
    final work = notepad.createFolder(name: 'Work');
    await tester.pump();

    await _rightClick(tester, _inSidebar('Work'));
    await tester.tap(find.text('Rename'));
    await _settle(tester);
    await tester.enterText(_renameField, 'Play');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(work.name, 'Work');
    expect(_renameField, findsNothing);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('a folder\'s notes are a tab group that folds away', (
    tester,
  ) async {
    final notepad = await _pumpApp(tester);
    final work = notepad.createFolder(name: 'Work');
    await tester.pump();

    await _rightClick(tester, _inSidebar('Work'));
    await tester.tap(find.text('New note here'));
    await _settle(tester);
    final report = notepad.selected!;
    expect(report.folderId, work.id);
    expect(_inTabs('Work'), findsOneWidget);

    // Folding the group keeps the selected tab; once another tab is picked,
    // the group's tabs are hidden.
    await tester.tap(_inTabs('Work'));
    await tester.pump();
    expect(work.tabsCollapsed, isTrue);
    expect(_inTabs(report.displayTitle), findsOneWidget);
    await tester.tap(_inTabs('Shopping list'));
    await tester.pump();
    expect(_inTabs(report.displayTitle), findsNothing);
    expect(_inTabs('1'), findsOneWidget, reason: 'the label counts its tabs');

    await tester.tap(_inTabs('Work'));
    await tester.pump();
    expect(_inTabs(report.displayTitle), findsOneWidget);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('Move to folder puts a note in the folder picked', (
    tester,
  ) async {
    final notepad = await _pumpApp(tester);
    final shopping = notepad.selected!;
    final home = notepad.createFolder(name: 'Home');
    await tester.pump();

    await _rightClick(tester, _inSidebar('Shopping list'));
    await tester.tap(find.text('Move to folder…'));
    await _settle(tester);
    expect(find.text('Move "Shopping list" to'), findsOneWidget);
    await tester.tap(find.text('Home').last);
    await _settle(tester);

    expect(shopping.folderId, home.id);
    expect(_inTabs('Home'), findsOneWidget);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('notes and folders can be dragged into folders', (tester) async {
    final notepad = await _pumpApp(tester);
    final shopping = notepad.selected!;
    final home = notepad.createFolder(name: 'Home');
    final recipes = notepad.createFolder(name: 'Recipes');
    await tester.pump();

    Future<void> drag(Finder from, Finder to) async {
      final gesture = await tester.startGesture(
        tester.getCenter(from),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, 8));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(to));
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    await drag(_inSidebar('Shopping list'), _inSidebar('Home'));
    expect(shopping.folderId, home.id);

    await drag(_inSidebar('Recipes'), _inSidebar('Home'));
    expect(recipes.parentId, home.id);

    // A folder can't go inside itself.
    await drag(_inSidebar('Home'), _inSidebar('Recipes'));
    expect(home.parentId, isNull);

    // The NOTES heading is the top level.
    await drag(_inSidebar('Shopping list'), _inSidebar('NOTES'));
    expect(shopping.folderId, isNull);
    await _finish(tester);
  }, variant: _desktop);

  testWidgets('deleting a folder asks, and keeps its notes', (tester) async {
    final notepad = await _pumpApp(tester);
    final shopping = notepad.selected!;
    final home = notepad.createFolder(name: 'Home');
    notepad.moveNote(shopping, home);
    await tester.pump();

    await _rightClick(tester, _inSidebar('Home'));
    await tester.tap(find.text('Delete folder…'));
    await _settle(tester);
    expect(
      find.text(
        'The 1 note in it will move to the top level. No notes are deleted.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete folder'));
    await _settle(tester);

    expect(notepad.folders, isEmpty);
    expect(shopping.folderId, isNull);
    expect(_inSidebar('Shopping list'), findsOneWidget);
    await _finish(tester);
  }, variant: _desktop);
}
