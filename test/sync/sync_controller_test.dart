import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/sync/folder_backend.dart';
import 'package:goatpad/src/sync/keychain.dart';
import 'package:goatpad/src/sync/sync_backend.dart';
import 'package:goatpad/src/sync/sync_controller.dart';
import 'package:goatpad/src/sync/sync_record.dart';
import 'package:goatpad/src/sync/vault.dart';
import 'package:path/path.dart' as p;

const passphrase = 'purple tiger lamp river';

void main() {
  late Directory dir;
  late String chosen;
  final controllers = <SyncController>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gpad_sync_controller');
    chosen = p.join(dir.path, 'Dropbox');
    await Directory(chosen).create();
  });

  tearDown(() async {
    final running = [...controllers];
    controllers.clear();
    for (final c in running) {
      // Let a round still running finish before its folder goes.
      await c.finish();
      c.dispose();
    }
    await dir.delete(recursive: true);
  });

  SyncController controllerFor(
    Notepad notepad, {
    Keychain? keychain,
    String host = 'work-pc',
  }) {
    final controller = SyncController(
      notepad,
      keychain: keychain ?? MemoryKeychain(),
      kdf: KdfParams.insecureForTests,
      uploadDelay: const Duration(milliseconds: 20),
      maxWait: const Duration(milliseconds: 200),
      hostName: host,
    );
    controllers.add(controller);
    return controller;
  }

  Future<void> settle(SyncController sync) async {
    sync.notepad.flush();
    for (var i = 0; i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (sync.status != SyncStatus.syncing &&
          sync.notepad.store.pendingSync().every(
            (s) => sync.notepad.isLocalOnly(
              RecordKind.values.byName(s.kind),
              s.id,
            ),
          )) {
        return;
      }
    }
  }

  Future<SyncController> setUpFirst(
    Notepad notepad, {
    Keychain? keychain,
  }) async {
    final sync = controllerFor(notepad, keychain: keychain);
    final checked = await sync.checkFolder(chosen);
    expect(checked.path, p.join(chosen, 'GPad'));
    expect(checked.vault, isNull);
    await Directory(checked.path).create();
    final key = await sync.create(
      folder: checked.path,
      passphrase: passphrase,
      deviceName: 'Work PC',
      remember: true,
    );
    expect(RecoveryKey.decode(key), isNotNull);
    await settle(sync);
    return sync;
  }

  test('setting up, then joining from a second computer', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final note = work.newNote();
    work.editText(note, 'pasted at work');
    final keychain = MemoryKeychain();
    final sync = await setUpFirst(work, keychain: keychain);
    expect(sync.status, SyncStatus.synced);
    expect(sync.config!.deviceName, 'Work PC');
    expect(keychain.secrets.keys.single, startsWith('sync-key-'));
    expect(await sync.remembered, isTrue);

    final home = Notepad.load(NoteStore.inMemory());
    final homeSync = controllerFor(home, host: 'home');
    final checked = await homeSync.checkFolder(chosen);
    expect(checked.vault, isNotNull);
    expect(
      await homeSync.join(
        folder: checked.path,
        vault: checked.vault!,
        passphrase: 'wrong passphrase',
        deviceName: '',
        remember: false,
      ),
      isFalse,
    );
    expect(homeSync.status, SyncStatus.off);
    expect(
      await homeSync.join(
        folder: checked.path,
        vault: checked.vault!,
        passphrase: passphrase,
        deviceName: '',
        remember: false,
      ),
      isTrue,
    );
    await settle(homeSync);
    expect(homeSync.config!.deviceName, 'home');
    expect(home.openNotes.map((n) => n.text), contains('pasted at work'));
    expect(await homeSync.remembered, isFalse);

    // Typing at home reaches work a moment later.
    final there = home.openNotes.firstWhere((n) => n.text == 'pasted at work');
    home.editText(there, 'pasted at work, edited at home');
    await settle(homeSync);
    await sync.syncNow();
    expect(note.text, 'pasted at work, edited at home');
  });

  test('restarting unlocks from the keychain, or asks', () async {
    final dbPath = p.join(dir.path, 'notes.db');
    final keychain = MemoryKeychain();
    var store = NoteStore.open(dbPath);
    var notepad = Notepad.load(store);
    var sync = await setUpFirst(notepad, keychain: keychain);
    sync.dispose();
    controllers.remove(sync);
    notepad.dispose();
    store.close();

    store = NoteStore.open(dbPath);
    notepad = Notepad.load(store);
    sync = controllerFor(notepad, keychain: keychain);
    await sync.start();
    await settle(sync);
    expect(sync.status, SyncStatus.synced);
    sync.dispose();
    controllers.remove(sync);

    // No keychain, or it lost the key: sync waits for the passphrase.
    sync = controllerFor(notepad, keychain: const NoKeychain());
    await sync.start();
    expect(sync.status, SyncStatus.locked);
    expect(await sync.unlock(passphrase: 'nope', remember: false), isFalse);
    expect(sync.status, SyncStatus.locked);
    expect(await sync.unlock(passphrase: passphrase, remember: false), isTrue);
    await settle(sync);
    expect(sync.status, SyncStatus.synced);
    sync.dispose();
    controllers.remove(sync);
    notepad.dispose();
    store.close();
  });

  test('the recovery key unlocks when the passphrase is forgotten', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final sync = controllerFor(work);
    final folder = p.join(chosen, 'GPad');
    await Directory(folder).create();
    final key = await sync.create(
      folder: folder,
      passphrase: passphrase,
      deviceName: 'Work PC',
      remember: false,
    );

    final home = Notepad.load(NoteStore.inMemory());
    final homeSync = controllerFor(home);
    final checked = await homeSync.checkFolder(chosen);
    expect(
      await homeSync.join(
        folder: checked.path,
        vault: checked.vault!,
        recoveryKey: key.toLowerCase().replaceAll('-', ' '),
        deviceName: 'Home',
        remember: false,
      ),
      isTrue,
    );
  });

  test('a missing sync folder is a problem, not a mass delete', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final note = work.newNote();
    work.editText(note, 'keep me');
    final sync = await setUpFirst(work);
    final folder = sync.config!.folder;
    final away = '$folder-away';
    await Directory(folder).rename(away);

    work.editText(note, 'keep me, edited');
    await sync.syncNow();
    expect(sync.status, SyncStatus.problem);
    expect(sync.problem, contains('missing'));
    // Nothing was written where the folder was.
    expect(Directory(folder).existsSync(), isFalse);

    await Directory(away).rename(folder);
    await sync.syncNow();
    expect(sync.status, SyncStatus.synced);
    expect(sync.problem, isNull);
  });

  test('a folder holding someone else\'s notes is refused', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final sync = await setUpFirst(work);
    final other = await (await VaultCrypto.load()).create(
      'another passphrase',
      kdf: KdfParams.insecureForTests,
    );
    File(p.join(sync.config!.folder, FolderBackend.vaultFileName))
        .writeAsBytesSync(other.header.encode());
    await sync.syncNow();
    expect(sync.status, SyncStatus.problem);
    expect(sync.problem, contains('different set of GPad notes'));
  });

  test('two computers can\'t both create a vault in one folder', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final sync = await setUpFirst(work);
    final home = controllerFor(Notepad.load(NoteStore.inMemory()));
    await expectLater(
      home.create(
        folder: sync.config!.folder,
        passphrase: passphrase,
        deviceName: 'Home',
        remember: false,
      ),
      throwsA(isA<SyncBackendException>()),
    );
  });

  test('turning sync off forgets the key and keeps the notes', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final note = work.newNote();
    work.editText(note, 'stays');
    final keychain = MemoryKeychain();
    final sync = await setUpFirst(work, keychain: keychain);
    final folder = sync.config!.folder;
    await sync.turnOff();
    expect(sync.status, SyncStatus.off);
    expect(sync.config, isNull);
    expect(keychain.secrets, isEmpty);
    expect(work.store.setting('sync'), isNull);
    expect(note.text, 'stays');

    // Back on with the same notes: nothing is counted twice.
    final checked = await sync.checkFolder(folder);
    expect(checked.path, folder);
    await sync.join(
      folder: folder,
      vault: checked.vault!,
      passphrase: passphrase,
      deviceName: 'Work PC',
      remember: false,
    );
    await settle(sync);
    expect(work.keptNotes.where((n) => n.text == 'stays'), hasLength(1));
  });

  test('changes waiting when GPad quits go up first', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final sync = await setUpFirst(work);
    final note = work.newNote();
    work.editText(note, 'typed just before quitting');
    work.flush();
    await sync.finish();
    expect(
      work.store.pendingSync().where(
        (s) => !work.isLocalOnly(RecordKind.note, s.id),
      ),
      isEmpty,
    );
  });
}
