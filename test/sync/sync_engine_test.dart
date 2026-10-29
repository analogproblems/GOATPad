import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/notes/note.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/sync/folder_backend.dart';
import 'package:goatpad/src/sync/sync_backend.dart';
import 'package:goatpad/src/sync/sync_engine.dart';
import 'package:goatpad/src/sync/vault.dart';
import 'package:path/path.dart' as p;

/// One computer: its own notes, syncing through the shared folder.
class Machine {
  Machine(this.name, this.vault, String folder, {NoteStore? store})
    : notepad = Notepad.load(store ?? NoteStore.inMemory()) {
    backend = FolderBackend(folder);
    engine = SyncEngine(
      backend: backend,
      vault: vault,
      notepad: notepad,
      deviceId: '$name-id',
      deviceName: name,
    );
  }

  final String name;
  final Vault vault;
  final Notepad notepad;
  late final FolderBackend backend;
  late final SyncEngine engine;

  Future<SyncReport> sync() => engine.sync();

  Note? find(String title) {
    for (final note in [...notepad.keptNotes, ...notepad.trashedNotes]) {
      if (note.title == title) return note;
    }
    return null;
  }

  Note note(String title) => find(title)!;

  /// Notes other than the welcome note, by title.
  List<String> get titles => [
    for (final n in notepad.keptNotes)
      if (n.title != 'Welcome to GPad') n.title,
  ];

  Note write(String title, String text) {
    final note = notepad.newNote();
    notepad.editText(note, text);
    notepad.rename(note, title);
    return note;
  }
}

void main() {
  late VaultCrypto crypto;
  late NewVault made;
  late Directory dir;
  late String folder;
  late Machine work;
  late Machine home;

  setUpAll(() async {
    crypto = await VaultCrypto.load();
    made = await crypto.create('passphrase', kdf: KdfParams.insecureForTests);
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gpad_sync_test');
    folder = p.join(dir.path, 'GPad');
    await FolderBackend(folder)
        .createVault(Uint8List.fromList(made.header.encode()));
    work = Machine('Work PC', made.vault, folder);
    home = Machine(
      'Home laptop',
      crypto.fromKey(made.header, made.vault.exportKey())!,
      folder,
    );
  });

  tearDown(() => dir.delete(recursive: true));

  List<String> recordFiles() => [
    for (final f in Directory(p.join(folder, 'records')).listSync())
      p.basename(f.path),
  ]..sort();

  test('a note written at work turns up at home, tab and all', () async {
    final note = work.write('SQL', 'select * from orders');
    var report = await work.sync();
    expect(report.uploaded, 1);

    report = await home.sync();
    expect(report.downloaded, 1);
    final there = home.note('SQL');
    expect(there.id, note.id);
    expect(there.text, 'select * from orders');
    expect(there.status, NoteStatus.open);
    expect(home.notepad.openNotes, contains(there));

    // Nothing more to do on either side.
    expect((await home.sync()).uploaded, 0);
    report = await work.sync();
    expect((report.uploaded, report.downloaded), (0, 0));
  });

  test('files hold nothing readable, and the welcome note stays put', () async {
    work.write('Secret plans', 'launch on tuesday');
    await work.sync();
    final files = recordFiles();
    expect(files, hasLength(1));
    final bytes = File(p.join(folder, 'records', files.single))
        .readAsBytesSync();
    final asText = String.fromCharCodes(bytes);
    expect(asText, isNot(contains('Secret')));
    expect(asText, isNot(contains('tuesday')));

    // The welcome note syncs once it is edited.
    final welcome = work.note('Welcome to GPad');
    work.notepad.editText(welcome, '${welcome.text}\nMy own line');
    await work.sync();
    expect(recordFiles(), hasLength(2));
    await home.sync();
    expect(
      home.notepad.keptNotes.where((n) => n.title == 'Welcome to GPad'),
      hasLength(2),
    );
  });

  test('edits flow both ways and editors reload', () async {
    final note = work.write('List', 'eggs');
    await work.sync();
    await home.sync();
    home.notepad.editText(home.note('List'), 'eggs\nmilk');
    await home.sync();

    final version = note.textVersion;
    await work.sync();
    expect(note.text, 'eggs\nmilk');
    expect(note.textVersion, greaterThan(version));
  });

  test('a note changed on both machines is kept twice', () async {
    work.write('Plan', 'v1');
    await work.sync();
    await home.sync();
    work.notepad.editText(work.note('Plan'), 'work edit');
    home.notepad.editText(home.note('Plan'), 'home edit');
    await work.sync();

    final report = await home.sync();
    expect(report.conflicts, 1);
    // Home keeps its own text in place; work's is next to it.
    expect(home.note('Plan').text, 'home edit');
    final copy = home.note('Plan (conflict from Work PC)');
    expect(copy.text, 'work edit');
    expect(copy.status, NoteStatus.open);

    await work.sync();
    expect(work.note('Plan').text, 'home edit');
    expect(work.note('Plan (conflict from Work PC)').text, 'work edit');
    expect(work.titles..sort(), ['Plan', 'Plan (conflict from Work PC)']);
    // And then everything is settled.
    expect((await home.sync()).conflicts, 0);
    expect((await work.sync()).conflicts, 0);
  });

  test('different changes to one note merge without a copy', () async {
    work.write('Notes', 'start');
    await work.sync();
    await home.sync();
    work.notepad.close(work.note('Notes'));
    home.notepad.editText(home.note('Notes'), 'start, and more');
    await home.sync();
    final report = await work.sync();
    expect(report.conflicts, 0);
    final merged = work.note('Notes');
    expect(
      (merged.text, merged.status),
      ('start, and more', NoteStatus.closed),
    );
    await home.sync();
    expect(home.note('Notes').status, NoteStatus.closed);
  });

  test('two machines saving at once, as Dropbox sees it', () async {
    work.write('Doc', 'base');
    await work.sync();
    await home.sync();
    final id = work.note('Doc').id;
    final own = File(p.join(folder, 'records', '$id.gpad'));
    final before = own.readAsBytesSync();

    // Home saves first; then work saves over the same base, and the sync
    // tool keeps work's file and makes a copy of home's.
    home.notepad.editText(home.note('Doc'), 'home');
    await home.sync();
    final homeFile = own.readAsBytesSync();
    own.writeAsBytesSync(before);
    work.notepad.editText(work.note('Doc'), 'work');
    await work.sync();
    File(p.join(folder, 'records', "$id (Home laptop's conflicted copy).gpad"))
        .writeAsBytesSync(homeFile);

    final report = await work.sync();
    expect(report.conflicts, 1);
    expect(work.note('Doc').text, 'work');
    expect(work.note('Doc (conflict from Home laptop)').text, 'home');
    // The copy has been merged in and removed.
    expect(recordFiles().where((f) => f.contains('conflicted')), isEmpty);

    await home.sync();
    expect(home.note('Doc').text, 'work');
    expect(home.note('Doc (conflict from Home laptop)').text, 'home');
  });

  test('a file overwritten by another machine is not lost', () async {
    work.write('Shared', 'base');
    await work.sync();
    await home.sync();
    final id = work.note('Shared').id;
    final own = File(p.join(folder, 'records', '$id.gpad'));
    final before = own.readAsBytesSync();

    work.notepad.editText(work.note('Shared'), 'work');
    await work.sync();
    // A sync tool that keeps the last file written puts home's in place of
    // work's.
    own.writeAsBytesSync(before);
    home.notepad.editText(home.note('Shared'), 'home');
    await home.sync();

    final report = await work.sync();
    expect(report.conflicts, 1);
    expect(work.note('Shared').text, 'work');
    expect(work.note('Shared (conflict from Home laptop)').text, 'home');
  });

  test('deleting for good reaches every machine', () async {
    work.write('Old', 'bye');
    await work.sync();
    await home.sync();
    final note = work.note('Old');
    work.notepad.trash(note);
    await work.sync();
    await home.sync();
    expect(home.note('Old').status, NoteStatus.trashed);

    work.notepad.deleteForever(note);
    await work.sync();
    await home.sync();
    expect(home.find('Old'), isNull);
    // The deleted record stays, so a machine that syncs later still learns.
    expect(recordFiles(), hasLength(1));
  });

  test('an edit wins over a delete made at the same time', () async {
    work.write('Keep me', 'v1');
    await work.sync();
    await home.sync();
    work.notepad.trash(work.note('Keep me'));
    await work.sync();
    await home.sync();

    work.notepad.deleteForever(work.note('Keep me'));
    home.notepad.restore(home.note('Keep me'));
    home.notepad.editText(home.note('Keep me'), 'v2');
    await work.sync();
    await home.sync();
    expect(home.note('Keep me').text, 'v2');
    await work.sync();
    expect(work.note('Keep me').text, 'v2');
    expect(work.note('Keep me').status, NoteStatus.open);
  });

  test('folders sync, and deleting one keeps what was in it', () async {
    final recipes = work.notepad.createFolder(name: 'Recipes');
    final soups = work.notepad.createFolder(parent: recipes, name: 'Soups');
    final note = work.write('Leek soup', 'leeks');
    work.notepad.moveNote(note, soups);
    await work.sync();
    await home.sync();

    final there = home.note('Leek soup');
    expect(
      home.notepad.pathOf(home.notepad.folderOf(there)!),
      'Recipes / Soups',
    );
    // Whether a folder is expanded stays on each machine.
    work.notepad.setFolderExpanded(recipes, false);
    expect((await work.sync()).uploaded, 0);

    work.notepad.deleteFolder(soups);
    await work.sync();
    await home.sync();
    expect(home.notepad.folderOf(there)?.name, 'Recipes');
    expect(home.notepad.folders.map((f) => f.name), ['Recipes']);
  });

  test('a note put in a folder deleted elsewhere moves up', () async {
    final folderA = work.notepad.createFolder(name: 'A');
    await work.sync();
    await home.sync();
    work.notepad.deleteFolder(folderA);
    final there = home.write('New in A', 'x');
    home.notepad.moveNote(there, home.notepad.folders.single);
    await work.sync();
    await home.sync();
    expect(home.notepad.folders, isEmpty);
    expect(home.notepad.folderOf(there), isNull);
    await work.sync();
    expect(work.notepad.folderOf(work.note('New in A')), isNull);
  });

  test('folders moved into each other at once end up apart', () async {
    final a = work.notepad.createFolder(name: 'A');
    final b = work.notepad.createFolder(name: 'B');
    await work.sync();
    await home.sync();
    work.notepad.moveFolder(a, b);
    final homeB = home.notepad.folders.firstWhere((f) => f.name == 'B');
    final homeA = home.notepad.folders.firstWhere((f) => f.name == 'A');
    home.notepad.moveFolder(homeB, homeA);
    await work.sync();
    await home.sync();
    await work.sync();
    await home.sync();
    for (final machine in [work, home]) {
      // No folder is inside itself, so the sidebar can draw them.
      expect(machine.notepad.folders, hasLength(2), reason: machine.name);
    }
  });

  test('damaged files are reported and left alone', () async {
    work.write('Fine', 'ok');
    work.write('Damaged', 'soon');
    await work.sync();
    await home.sync();
    final id = work.note('Damaged').id;
    final file = File(p.join(folder, 'records', '$id.gpad'));
    final bytes = file.readAsBytesSync()..[40] ^= 1;
    file.writeAsBytesSync(bytes);
    // A file someone put there by hand.
    File(p.join(folder, 'records', '${'f' * 32}.gpad')).writeAsStringSync('hi');

    final report = await home.sync();
    expect(report.unreadable, hasLength(2));
    expect(home.note('Damaged').text, 'soon');
    expect(recordFiles(), hasLength(3));
    // Not read again until it changes.
    expect((await home.sync()).unreadable, hasLength(2));
  });

  test('an old version put back is replaced by the latest', () async {
    work.write('Draft', 'one');
    await work.sync();
    final id = work.note('Draft').id;
    final file = File(p.join(folder, 'records', '$id.gpad'));
    final old = file.readAsBytesSync();
    work.notepad.editText(work.note('Draft'), 'two');
    await work.sync();
    await home.sync();

    file.writeAsBytesSync(old);
    await home.sync();
    expect(home.note('Draft').text, 'two');
    final fresh = Machine('Third', made.vault, folder);
    await fresh.sync();
    expect(fresh.note('Draft').text, 'two');
  });

  test('a record file deleted by hand is put back', () async {
    work.write('Precious', 'data');
    await work.sync();
    for (final f in Directory(p.join(folder, 'records')).listSync()) {
      f.deleteSync();
    }
    expect((await work.sync()).uploaded, 1);
    await home.sync();
    expect(home.note('Precious').text, 'data');
  });

  test('changes made before quitting upload next time', () async {
    final dbPath = p.join(dir.path, 'notes.db');
    var store = NoteStore.open(dbPath);
    var machine = Machine('Work PC', made.vault, folder, store: store);
    machine.write('Late', 'typed just before closing');
    machine.notepad.flush();
    store.close();

    store = NoteStore.open(dbPath);
    machine = Machine('Work PC', made.vault, folder, store: store);
    expect((await machine.sync()).uploaded, 1);
    store.close();
    await home.sync();
    expect(home.note('Late').text, 'typed just before closing');
  });

  test('changes made while uploading go up in the next round', () async {
    final note = work.write('Busy', 'one');
    final slow = _SlowBackend(work.backend, () {
      work.notepad.editText(note, 'two');
    });
    final engine = SyncEngine(
      backend: slow,
      vault: made.vault,
      notepad: work.notepad,
      deviceId: 'Work PC-id',
      deviceName: 'Work PC',
    );
    await engine.sync();
    expect((await engine.sync()).uploaded, 1);
    await home.sync();
    expect(home.note('Busy').text, 'two');
  });

  test('joining with notes of your own keeps both sets', () async {
    work.write('From work', 'w');
    await work.sync();
    home.write('From home', 'h');
    await home.sync();
    await work.sync();
    expect(work.titles..sort(), ['From home', 'From work']);
    expect(home.titles..sort(), ['From home', 'From work']);
  });
}

/// Runs [during] while the first file is being written.
class _SlowBackend implements SyncBackend {
  _SlowBackend(this.inner, this.during);

  final SyncBackend inner;
  void Function()? during;

  @override
  Future<RemoteFile> write(String recordId, Uint8List bytes) async {
    final written = await inner.write(recordId, bytes);
    during?.call();
    during = null;
    return written;
  }

  @override
  String get description => inner.description;
  @override
  Future<Uint8List?> readVault() => inner.readVault();
  @override
  Future<bool> createVault(Uint8List bytes) => inner.createVault(bytes);
  @override
  Future<List<RemoteFile>> list() => inner.list();
  @override
  Future<Uint8List> read(RemoteFile file) => inner.read(file);
  @override
  Future<void> delete(RemoteFile file) => inner.delete(file);
  @override
  Stream<void>? get changes => inner.changes;
}
