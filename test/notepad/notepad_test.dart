import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/notes/note.dart';
import 'package:goatpad/src/notes/note_mode.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/theme.dart';

void main() {
  late NoteStore store;
  late DateTime now;

  setUp(() {
    store = NoteStore.inMemory();
    now = DateTime(2026, 10, 29, 14, 3);
  });
  tearDown(() => store.close());

  Notepad load() => Notepad.load(store, clock: () => now);

  String? storedText(String id) {
    for (final note in store.loadNotes()) {
      if (note.id == id) return note.text;
    }
    return null;
  }

  test('the first run opens a welcome note, once', () {
    final notepad = load();
    final welcome = notepad.selected!;
    expect(welcome.title, 'Welcome to GPad');
    expect(welcome.guess, const ModeGuess.rich());
    expect(notepad.openNotes, [welcome]);
    notepad.dispose();

    final again = load();
    expect(again.keptNotes, hasLength(1));
    again.dispose();
  });

  test('a new note picks its mode and name from the first paste', () {
    final notepad = load();
    final note = notepad.newNote();
    expect(notepad.selected, note);

    notepad.editText(
      note,
      '-- Monthly totals\nSELECT month, SUM(total) '
      'FROM orders GROUP BY month;',
    );

    expect(note.guess, const ModeGuess.code('sql'));
    expect(note.title, 'Monthly totals');
    // Picking a mode is saved straight away.
    expect(
      store.loadNotes().firstWhere((n) => n.id == note.id).guess.mode,
      NoteMode.code,
    );
    notepad.dispose();
  });

  test('a name typed before pasting is kept', () {
    final notepad = load();
    final note = notepad.newNote();
    notepad.rename(note, 'Standup notes');
    notepad.editText(note, '# Today\n\n- ship the store\n- write tests');

    expect(note.title, 'Standup notes');
    expect(note.guess, const ModeGuess.rich());
    notepad.dispose();
  });

  test('typing is saved a moment later without asking', () {
    fakeAsync((async) {
      final notepad = load();
      final note = notepad.selected!;

      notepad.editText(note, 'first');
      expect(storedText(note.id), isNot('first'));
      async.elapse(Notepad.saveDelay);
      expect(storedText(note.id), 'first');
      notepad.dispose();
    });
  });

  test('steady typing is still saved every few hundred milliseconds', () {
    fakeAsync((async) {
      final notepad = load();
      final note = notepad.selected!;
      const keystroke = Duration(milliseconds: 100);

      for (final text in ['a', 'ab', 'abc', 'abcd']) {
        notepad.editText(note, text);
        async.elapse(keystroke);
      }
      // Four keystrokes 100 ms apart: the first save came 300 ms after 'a',
      // while still typing.
      expect(storedText(note.id), 'abc');
      notepad.dispose();
    });
  });

  test('flush saves typing that is still waiting', () {
    fakeAsync((async) {
      final notepad = load();
      final note = notepad.selected!;
      notepad.editText(note, 'closing now');
      notepad.flush();
      expect(storedText(note.id), 'closing now');
      notepad.dispose();
    });
  });

  test('when saving fails, the changes are kept, GPad says so and retries', () {
    fakeAsync((async) {
      final notepad = load();
      final note = notepad.selected!;
      final before = storedText(note.id);
      var changes = 0;
      notepad.addListener(() => changes++);

      // Fill the "disk": the database may not grow any more.
      final db = store.database;
      final pages = db.select('PRAGMA page_count').single.values.single;
      db.execute('PRAGMA max_page_count = $pages');
      final big = 'x' * 100000;
      notepad.editText(note, big);
      async.elapse(Notepad.saveDelay);

      expect(notepad.saveProblem, contains('full'));
      expect(changes, greaterThan(1), reason: 'the screen hears about it');
      expect(storedText(note.id), before);
      expect(note.text, big);
      expect(notepad.flush(), isFalse);

      // Space frees up; the next retry saves without another keystroke.
      db.execute('PRAGMA max_page_count = 1000000');
      async.elapse(Notepad.retryDelay);
      expect(notepad.saveProblem, isNull);
      expect(storedText(note.id), big);
      notepad.dispose();
    });
  });

  test('tabs, the selected tab and closed notes come back on restart', () {
    final notepad = load();
    final welcome = notepad.selected!;
    final json = notepad.pasteAsNewNote('{"a": 1}')!;
    final python = notepad.pasteAsNewNote('import os\nprint(os.getcwd())')!;
    notepad.close(welcome);
    notepad.open(json);
    notepad.dispose();

    final restarted = load();
    expect(restarted.openNotes.map((n) => n.id), [json.id, python.id]);
    expect(restarted.selected!.id, json.id);
    final closed = restarted.keptNotes.firstWhere((n) => n.id == welcome.id);
    expect(closed.status, NoteStatus.closed);
    restarted.dispose();
  });

  test('closing the shown tab shows the next one, else the previous', () {
    final notepad = load();
    final a = notepad.selected!;
    final b = notepad.pasteAsNewNote('b')!;
    final c = notepad.pasteAsNewNote('c')!;

    notepad.open(b);
    notepad.close(b);
    expect(notepad.selected, c);
    notepad.close(c);
    expect(notepad.selected, a);
    notepad.close(a);
    expect(notepad.selected, isNull);
    notepad.dispose();
  });

  test('reopening a closed note puts it at the end of the tabs', () {
    final notepad = load();
    final a = notepad.selected!;
    final b = notepad.pasteAsNewNote('b')!;
    notepad.close(a);
    notepad.open(a);
    expect(notepad.openNotes, [b, a]);
    notepad.dispose();
  });

  test('Ctrl+Tab order wraps around', () {
    final notepad = load();
    final a = notepad.selected!;
    final b = notepad.pasteAsNewNote('b')!;
    expect(notepad.selected, b);
    notepad.cycleTabs();
    expect(notepad.selected, a);
    notepad.cycleTabs(backwards: true);
    expect(notepad.selected, b);
    notepad.dispose();
  });

  test('trashed notes leave the tabs and can be restored', () {
    final notepad = load();
    final a = notepad.selected!;
    final b = notepad.pasteAsNewNote('b')!;

    notepad.trash(b);
    expect(notepad.openNotes, [a]);
    expect(notepad.keptNotes, [a]);
    expect(notepad.trashedNotes, [b]);
    expect(notepad.deletesOn(b), now.add(const Duration(days: 30)));

    notepad.restore(b);
    expect(notepad.selected, b);
    expect(notepad.trashedNotes, isEmpty);
    expect(b.trashedAt, isNull);
    notepad.dispose();
  });

  test('the trash keeps notes for 30 days', () {
    final notepad = load();
    final old = notepad.pasteAsNewNote('old')!;
    notepad.trash(old);
    now = now.add(const Duration(days: 1));
    final recent = notepad.pasteAsNewNote('recent')!;
    notepad.trash(recent);
    notepad.dispose();

    now = now.add(const Duration(days: 29));
    final later = load();
    expect(later.trashedNotes.map((n) => n.id), [recent.id]);
    expect(storedText(old.id), isNull);
    later.dispose();
  });

  test('deleting forever and emptying the trash remove notes for good', () {
    final notepad = load();
    final a = notepad.pasteAsNewNote('a')!;
    final b = notepad.pasteAsNewNote('b')!;
    final c = notepad.pasteAsNewNote('c')!;

    notepad.deleteForever(a);
    expect(storedText(a.id), 'a', reason: 'only trashed notes can be deleted');

    for (final note in [a, b, c]) {
      notepad.trash(note);
    }
    notepad.deleteForever(a);
    expect(storedText(a.id), isNull);
    notepad.emptyTrash();
    expect(storedText(b.id), isNull);
    expect(storedText(c.id), isNull);
    notepad.dispose();
  });

  test('search finds open, closed and trashed notes, trashed last', () {
    final notepad = load();
    final open = notepad.pasteAsNewNote('Groceries: milk, eggs')!;
    final closed = notepad.pasteAsNewNote('Milk frother manual')!;
    final trashed = notepad.pasteAsNewNote('Milkshake recipe')!;
    notepad.close(closed);
    notepad.trash(trashed);

    final found = [for (final r in notepad.search('milk')) r.note];
    expect(found, hasLength(3));
    expect(found.toSet(), {open, closed, trashed});
    expect(found.last, trashed);
    notepad.dispose();
  });

  test('search sees typing that has not been saved yet', () {
    fakeAsync((async) {
      final notepad = load();
      final note = notepad.selected!;
      notepad.editText(note, 'a brand new thought');
      expect(notepad.search('thought').single.note, note);
      notepad.dispose();
    });
  });

  test('an empty search lists the most recently edited notes', () {
    final notepad = load();
    final welcome = notepad.selected!;
    now = now.add(const Duration(minutes: 1));
    final later = notepad.pasteAsNewNote('later')!;
    notepad.trash(notepad.pasteAsNewNote('gone')!);

    expect([for (final r in notepad.search(' ')) r.note], [later, welcome]);
    notepad.dispose();
  });

  test('appearance is remembered', () {
    final notepad = load();
    notepad.appearance.value = const Appearance(
      family: ThemeFamily.slate,
      mode: ThemeMode.dark,
      codeColors: CodeColors.colorblindSafe,
    );
    notepad.dispose();

    final restarted = load();
    expect(
      restarted.appearance.value,
      const Appearance(
        family: ThemeFamily.slate,
        mode: ThemeMode.dark,
        codeColors: CodeColors.colorblindSafe,
      ),
    );
    restarted.dispose();
  });

  test('an unreadable saved appearance falls back to the default', () {
    store.setSetting('appearance', '{not json');
    final notepad = load();
    expect(notepad.appearance.value, const Appearance());
    notepad.dispose();
  });
}
