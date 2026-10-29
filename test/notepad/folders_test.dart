import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/notes/folder.dart';
import 'package:goatpad/src/notes/note.dart';
import 'package:goatpad/src/notes/note_mode.dart';
import 'package:goatpad/src/store/note_store.dart';

void main() {
  late NoteStore store;
  final now = DateTime(2026, 10, 29, 14, 3);

  setUp(() => store = NoteStore.inMemory());
  tearDown(() => store.close());

  Notepad load() => Notepad.load(store, clock: () => now);

  Note stored(Note note) =>
      store.loadNotes().firstWhere((n) => n.id == note.id);

  List<String?> groupNames(Notepad notepad) => [
    for (final group in notepad.tabGroups) group.folder?.name,
  ];

  test('tabs are grouped by folder, in sidebar order, loose tabs last', () {
    final notepad = load();
    final welcome = notepad.selected!;
    final work = notepad.createFolder(name: 'Work');
    final home = notepad.createFolder(name: 'Home');
    final recipes = notepad.createFolder(parent: home, name: 'Recipes');

    final soup = notepad.newNoteIn(recipes);
    final report = notepad.newNoteIn(work);
    final bills = notepad.newNoteIn(home);
    final memo = notepad.newNoteIn(work);

    expect(groupNames(notepad), ['Home', 'Recipes', 'Work', null]);
    expect(notepad.openNotes, [bills, soup, report, memo, welcome]);
    expect(notepad.pathOf(recipes), 'Home / Recipes');
    expect(notepad.folders, [home, recipes, work]);
    notepad.dispose();
  });

  test('new notes go in the same folder as the selected tab', () {
    final notepad = load();
    final work = notepad.createFolder(name: 'Work');
    final report = notepad.newNoteIn(work);
    expect(notepad.selected, report);

    expect(notepad.newNote().folderId, work.id);
    expect(notepad.pasteAsNewNote('Agenda\n- budget')!.folderId, work.id);
    expect(notepad.newNoteIn(null).folderId, isNull);
    expect(notepad.newNote().folderId, isNull);
    notepad.dispose();
  });

  test('moving a note moves its tab to the end of the new group', () {
    final notepad = load();
    final welcome = notepad.selected!;
    final work = notepad.createFolder(name: 'Work');
    final report = notepad.newNoteIn(work);
    final loose = notepad.newNoteIn(null);

    notepad.moveNote(welcome, work);
    expect(notepad.openNotes, [report, welcome, loose]);
    expect(stored(welcome).folderId, work.id);

    notepad.moveNote(welcome, null);
    expect(notepad.openNotes, [report, loose, welcome]);
    expect(stored(welcome).folderId, isNull);
    notepad.dispose();
  });

  test('moving a note into a folder shows that folder in the sidebar', () {
    final notepad = load();
    final home = notepad.createFolder(name: 'Home');
    final recipes = notepad.createFolder(parent: home, name: 'Recipes');
    notepad.setFolderExpanded(home, false);
    notepad.setFolderExpanded(recipes, false);

    notepad.moveNote(notepad.selected!, recipes);
    expect(home.expanded, isTrue);
    expect(recipes.expanded, isTrue);
    notepad.dispose();
  });

  test('deleting a folder keeps everything that was in it', () {
    final notepad = load();
    final home = notepad.createFolder(name: 'Home');
    final recipes = notepad.createFolder(parent: home, name: 'Recipes');
    final desserts = notepad.createFolder(parent: recipes, name: 'Desserts');
    final soup = notepad.newNoteIn(recipes);
    final stew = notepad.newNoteIn(recipes);
    notepad.trash(stew);

    notepad.deleteFolder(recipes);
    expect(notepad.folders, [home, desserts]);
    expect(desserts.parentId, home.id);
    expect(soup.folderId, home.id);
    expect(stew.folderId, home.id);
    notepad.dispose();

    final restarted = load();
    expect(restarted.folders.map((f) => f.name), ['Home', 'Desserts']);
    expect(restarted.notesIn(restarted.folders.first).map((n) => n.id), [
      soup.id,
    ]);
    expect(restarted.trashedNotes.single.folderId, home.id);
    restarted.dispose();
  });

  test('a folder can\'t go inside itself or a folder inside it', () {
    final notepad = load();
    final home = notepad.createFolder(name: 'Home');
    final recipes = notepad.createFolder(parent: home, name: 'Recipes');
    final work = notepad.createFolder(name: 'Work');

    expect(notepad.canMoveFolder(home, home), isFalse);
    expect(notepad.canMoveFolder(home, recipes), isFalse);
    expect(notepad.canMoveFolder(recipes, home), isFalse, reason: 'already');
    expect(notepad.canMoveFolder(home, null), isFalse, reason: 'already');
    expect(notepad.canMoveFolder(recipes, null), isTrue);

    notepad.moveFolder(home, recipes);
    expect(home.parentId, isNull);

    notepad.moveFolder(home, work);
    expect(notepad.folders, [work, home, recipes]);
    expect(notepad.pathOf(recipes), 'Work / Home / Recipes');
    notepad.dispose();
  });

  test('folders, and how they are shown, survive a restart', () {
    final notepad = load();
    final work = notepad.createFolder(name: 'New folder');
    notepad.renameFolder(work, '  Work ');
    notepad.renameFolder(work, '   ');
    final report = notepad.newNoteIn(work);
    notepad.setFolderExpanded(work, false);
    notepad.setTabsCollapsed(work, true);
    notepad.dispose();

    final restarted = load();
    final loaded = restarted.folders.single;
    expect(loaded.name, 'Work');
    expect(loaded.expanded, isFalse);
    expect(loaded.tabsCollapsed, isTrue);
    expect(restarted.notesIn(loaded).single.id, report.id);
    restarted.dispose();
  });

  test('a collapsed group hides its tabs, except the selected one', () {
    final notepad = load();
    final welcome = notepad.selected!;
    final work = notepad.createFolder(name: 'Work');
    notepad.newNoteIn(work);
    final memo = notepad.newNoteIn(work);
    notepad.open(welcome);

    notepad.setTabsCollapsed(work, true);
    expect(notepad.visibleTabs, [welcome]);
    notepad.cycleTabs();
    expect(notepad.selected, welcome, reason: 'nothing else to show');

    notepad.open(memo);
    expect(notepad.visibleTabs, [memo, welcome]);
    notepad.cycleTabs();
    expect(notepad.selected, welcome);
    expect(notepad.visibleTabs, [welcome]);

    // Closing the last visible tab falls back to the nearest hidden one.
    notepad.close(welcome);
    expect(notepad.selected, memo);
    notepad.dispose();
  });

  test('closing a tab skips over collapsed groups', () {
    final notepad = load();
    final welcome = notepad.selected!;
    final work = notepad.createFolder(name: 'Work');
    final home = notepad.createFolder(name: 'Home');
    final bills = notepad.newNoteIn(home);
    notepad.newNoteIn(work);
    notepad.setTabsCollapsed(work, true);
    notepad.open(bills);
    expect(notepad.visibleTabs, [bills, welcome]);

    notepad.close(bills);
    expect(notepad.selected, welcome);
    notepad.dispose();
  });

  test('a damaged folder tree loads with nothing lost', () {
    Folder folder(String id, String? parentId) => Folder(
      id: id,
      parentId: parentId,
      name: id,
      createdAt: now,
      updatedAt: now,
    );
    store.saveFolders([
      folder('orphan', 'missing'),
      folder('loopA', 'loopB'),
      folder('loopB', 'loopA'),
    ]);
    store.saveNote(
      Note(
        id: 'n1',
        folderId: 'gone',
        title: 'Lost',
        text: 'still here',
        guess: const ModeGuess.plain(),
        createdAt: now,
        updatedAt: now,
      ),
    );

    final notepad = load();
    expect(notepad.foldersIn(null).map((f) => f.id), contains('orphan'));
    expect(notepad.folders, hasLength(3));
    expect(notepad.notesIn(null).map((n) => n.id), contains('n1'));
    notepad.dispose();
  });
}
