import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/sync/folder_backend.dart';
import 'package:goatpad/src/sync/keychain.dart';
import 'package:goatpad/src/sync/sync_backend.dart';
import 'package:goatpad/src/sync/sync_controller.dart';
import 'package:goatpad/src/sync/sync_engine.dart' show SyncException;
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
    _Gate? gate,
    bool watch = true,
  }) {
    final controller = SyncController(
      notepad,
      keychain: keychain ?? MemoryKeychain(),
      kdf: KdfParams.insecureForTests,
      uploadDelay: const Duration(milliseconds: 20),
      maxWait: const Duration(milliseconds: 200),
      hostName: host,
      backendFor: gate == null && watch
          ? null
          : (folder) => _GatedBackend(
              FolderBackend(folder),
              gate ?? _Gate(),
              watch: watch,
            ),
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
    bool watch = true,
  }) async {
    final sync = controllerFor(notepad, keychain: keychain, watch: watch);
    final checked = await sync.checkFolder(chosen);
    expect((checked.place as FolderPlace).path, p.join(chosen, 'GPad'));
    expect(checked.vault, isNull);
    await Directory((checked.place as FolderPlace).path).create();
    final key = await sync.create(
      place: checked.place,
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
        place: checked.place,
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
        place: checked.place,
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
      place: FolderPlace(folder),
      passphrase: passphrase,
      deviceName: 'Work PC',
      remember: false,
    );

    final home = Notepad.load(NoteStore.inMemory());
    final homeSync = controllerFor(home);
    final checked = await homeSync.checkFolder(chosen);
    expect(
      await homeSync.join(
        place: checked.place,
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
    // Windows won't rename a folder something is watching.
    final sync = await setUpFirst(work, watch: false);
    final folder = (sync.config!.place as FolderPlace).path;
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
    File(
      p.join(
        (sync.config!.place as FolderPlace).path,
        FolderBackend.vaultFileName,
      ),
    ).writeAsBytesSync(other.header.encode());
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
        place: sync.config!.place,
        passphrase: passphrase,
        deviceName: 'Home',
        remember: false,
      ),
      throwsA(isA<SyncBackendException>()),
    );
  });

  test('of two computers setting up one folder at once, one wins', () async {
    final folder = p.join(chosen, 'GPad');
    await Directory(folder).create();
    final first = controllerFor(Notepad.load(NoteStore.inMemory()));
    final second = controllerFor(Notepad.load(NoteStore.inMemory()));
    Future<bool> setUp(SyncController sync) => sync
        .create(
          place: FolderPlace(folder),
          passphrase: passphrase,
          deviceName: '',
          remember: false,
        )
        .then((_) => true, onError: (Object e) => e is! SyncBackendException);
    final made = await Future.wait([setUp(first), setUp(second)]);
    expect(made.where((m) => m), hasLength(1));
    final winner = made.first ? first : second;
    final loser = made.first ? second : first;
    expect(loser.status, SyncStatus.off);
    final header = VaultHeader.decode(
      File(p.join(folder, FolderBackend.vaultFileName)).readAsBytesSync(),
    );
    expect(header.id, winner.config!.vault.id);
  });

  test('turning sync off mid-round stops the round there', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final sync = await setUpFirst(work);
    final home = Notepad.load(NoteStore.inMemory());
    final gate = _Gate();
    final homeSync = controllerFor(home, host: 'home', gate: gate);
    final checked = await homeSync.checkFolder(chosen);
    await homeSync.join(
      place: checked.place,
      vault: checked.vault!,
      passphrase: passphrase,
      deviceName: '',
      remember: false,
    );
    await settle(homeSync);

    // Home is reading a new note from work when sync is turned off there.
    work.editText(work.newNote(), 'from work');
    await settle(sync);
    gate.reads = true;
    final round = homeSync.syncNow();
    await gate.reached;
    await homeSync.turnOff();
    gate.open();
    await round;
    expect(homeSync.status, SyncStatus.off);
    expect(home.keptNotes.map((n) => n.text), isNot(contains('from work')));
  });

  test('a round cut short leaves nothing behind for the next setup', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final gate = _Gate();
    final sync = controllerFor(work, gate: gate);
    final first = p.join(chosen, 'GPad');
    await Directory(first).create();
    await sync.create(
      place: FolderPlace(first),
      passphrase: passphrase,
      deviceName: 'Work PC',
      remember: false,
    );
    await settle(sync);

    // Turned off while a note is being written, then set up again in
    // another folder before that write finishes.
    final note = work.newNote();
    work.editText(note, 'typed');
    work.flush();
    gate.writes = true;
    final round = sync.syncNow();
    await gate.reached;
    await sync.turnOff();
    final second = p.join(dir.path, 'Other', 'GPad');
    await Directory(second).create(recursive: true);
    await sync.create(
      place: FolderPlace(second),
      passphrase: 'another passphrase',
      deviceName: 'Work PC',
      remember: false,
    );
    gate.open();
    await round;
    await settle(sync);

    // The old round didn't mark the note as uploaded to the new folder.
    expect(sync.status, SyncStatus.synced);
    expect(
      Directory(p.join(second, 'records'))
          .listSync()
          .map((f) => p.basename(f.path)),
      contains('${note.id}.gpad'),
    );
  });

  test('turning sync off forgets the key and keeps the notes', () async {
    final work = Notepad.load(NoteStore.inMemory());
    final note = work.newNote();
    work.editText(note, 'stays');
    final keychain = MemoryKeychain();
    final sync = await setUpFirst(work, keychain: keychain);
    final folder = (sync.config!.place as FolderPlace).path;
    await sync.turnOff();
    expect(sync.status, SyncStatus.off);
    expect(sync.config, isNull);
    expect(keychain.secrets, isEmpty);
    expect(work.store.setting('sync'), isNull);
    expect(note.text, 'stays');

    // Back on with the same notes: nothing is counted twice.
    final checked = await sync.checkFolder(folder);
    expect((checked.place as FolderPlace).path, folder);
    await sync.join(
      place: FolderPlace(folder),
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

  group('changing the passphrase or recovery key', () {
    const newPassphrase = 'orange whale kite meadow';

    File vaultFile(SyncController sync) => File(
      p.join(
        (sync.config!.place as FolderPlace).path,
        FolderBackend.vaultFileName,
      ),
    );

    Future<SyncController> joinFrom(
      Notepad notepad, {
      Keychain? keychain,
      String? key,
    }) async {
      final sync = controllerFor(notepad, keychain: keychain, host: 'home');
      final checked = await sync.checkFolder(chosen);
      expect(
        await sync.join(
          place: checked.place,
          vault: checked.vault!,
          passphrase: key == null ? passphrase : null,
          recoveryKey: key,
          deviceName: 'Home',
          remember: false,
        ),
        isTrue,
      );
      await settle(sync);
      return sync;
    }

    test('a new passphrase reaches the other computers', () async {
      final work = Notepad.load(NoteStore.inMemory());
      final sync = await setUpFirst(work);
      final home = Notepad.load(NoteStore.inMemory());
      final homeSync = await joinFrom(home);

      expect(
        await sync.changePassphrase(
          passphrase: 'wrong passphrase',
          newPassphrase: newPassphrase,
        ),
        isFalse,
      );
      expect(
        await sync.changePassphrase(
          passphrase: passphrase,
          newPassphrase: newPassphrase,
        ),
        isTrue,
      );
      final header = VaultHeader.decode(vaultFile(sync).readAsBytesSync());
      expect(header.id, sync.config!.vault.id);
      expect(header.encode(), sync.config!.vault.encode());
      final crypto = await VaultCrypto.load();
      expect(await crypto.unlock(header, passphrase), isNull);
      (await crypto.unlock(header, newPassphrase))!.dispose();
      final saved = jsonDecode(work.store.setting('sync')!) as Map;
      expect(base64.decode(saved['vault'] as String), header.encode());

      // Home keeps the new vault file as it syncs, and notes go on syncing.
      work.editText(work.newNote(), 'after the change');
      await settle(sync);
      await homeSync.syncNow();
      expect(homeSync.status, SyncStatus.synced);
      expect(homeSync.config!.vault.encode(), header.encode());
      expect(home.openNotes.map((n) => n.text), contains('after the change'));
    });

    test('a computer that was off takes the new passphrase', () async {
      final work = Notepad.load(NoteStore.inMemory());
      // Windows won't rename a folder something is watching.
      final sync = await setUpFirst(work, watch: false);
      final dbPath = p.join(dir.path, 'home.db');
      var store = NoteStore.open(dbPath);
      var home = Notepad.load(store);
      var homeSync = await joinFrom(home, keychain: const NoKeychain());

      Future<void> stop() async {
        await homeSync.finish();
        homeSync.dispose();
        controllers.remove(homeSync);
        home.dispose();
        store.close();
      }

      Future<void> restart() async {
        store = NoteStore.open(dbPath);
        home = Notepad.load(store);
        homeSync = controllerFor(
          home,
          keychain: const NoKeychain(),
          host: 'home',
          watch: false,
        );
        await homeSync.start();
        expect(homeSync.status, SyncStatus.locked);
      }

      await stop();
      expect(
        await sync.changePassphrase(
          passphrase: passphrase,
          newPassphrase: newPassphrase,
        ),
        isTrue,
      );
      final changed = vaultFile(sync).readAsBytesSync();

      // Out of reach, the new passphrase can't be checked yet.
      await restart();
      final folder = (homeSync.config!.place as FolderPlace).path;
      await Directory(folder).rename('$folder-away');
      expect(
        await homeSync.unlock(passphrase: newPassphrase, remember: false),
        isFalse,
      );
      await Directory('$folder-away').rename(folder);
      expect(
        await homeSync.unlock(passphrase: newPassphrase, remember: false),
        isTrue,
      );
      expect(homeSync.config!.vault.encode(), changed);
      await settle(homeSync);
      expect(homeSync.status, SyncStatus.synced);

      // It was kept, so the old one stops working here too.
      await stop();
      await restart();
      expect(
        await homeSync.unlock(passphrase: passphrase, remember: false),
        isFalse,
      );
      expect(
        await homeSync.unlock(passphrase: newPassphrase, remember: false),
        isTrue,
      );
      await stop();
    });

    test('a new recovery key replaces the old one everywhere', () async {
      final work = Notepad.load(NoteStore.inMemory());
      final sync = controllerFor(work);
      final folder = p.join(chosen, 'GPad');
      await Directory(folder).create();
      final oldKey = await sync.create(
        place: FolderPlace(folder),
        passphrase: passphrase,
        deviceName: 'Work PC',
        remember: false,
      );
      await settle(sync);
      final homeSync = await joinFrom(
        Notepad.load(NoteStore.inMemory()),
        key: oldKey,
      );

      expect(await sync.newRecoveryKey(passphrase: 'wrong passphrase'), isNull);
      final newKey = await sync.newRecoveryKey(recoveryKey: oldKey);
      expect(RecoveryKey.decode(newKey!), isNotNull);
      expect(newKey, isNot(oldKey));

      await homeSync.syncNow();
      final header = homeSync.config!.vault;
      expect(header.encode(), vaultFile(sync).readAsBytesSync());
      final crypto = await VaultCrypto.load();
      expect(crypto.unlockWithRecoveryKey(header, oldKey), isNull);
      crypto.unlockWithRecoveryKey(header, newKey)!.dispose();
      (await crypto.unlock(header, passphrase))!.dispose();
    });

    test('a change made elsewhere meanwhile is kept', () async {
      final gate = _Gate();
      final work = Notepad.load(NoteStore.inMemory());
      final sync = controllerFor(work, gate: gate);
      final checked = await sync.checkFolder(chosen);
      await Directory((checked.place as FolderPlace).path).create();
      await sync.create(
        place: checked.place,
        passphrase: passphrase,
        deviceName: 'Work PC',
        remember: false,
      );
      await settle(sync);
      final homeSync = await joinFrom(Notepad.load(NoteStore.inMemory()));

      gate.beforeReplacingVault = () async {
        expect(
          await homeSync.changePassphrase(
            passphrase: passphrase,
            newPassphrase: 'changed at home',
          ),
          isTrue,
        );
      };
      await expectLater(
        sync.changePassphrase(
          passphrase: passphrase,
          newPassphrase: newPassphrase,
        ),
        throwsA(isA<SyncBackendException>()),
      );
      final crypto = await VaultCrypto.load();
      final header = VaultHeader.decode(vaultFile(sync).readAsBytesSync());
      expect(await crypto.unlock(header, newPassphrase), isNull);
      (await crypto.unlock(header, 'changed at home'))!.dispose();

      // Trying again starts from home's.
      expect(
        await sync.changePassphrase(
          passphrase: passphrase,
          newPassphrase: newPassphrase,
        ),
        isFalse,
      );
      expect(
        await sync.changePassphrase(
          passphrase: 'changed at home',
          newPassphrase: newPassphrase,
        ),
        isTrue,
      );
    });

    test(
      'a vault file this computer\'s key doesn\'t open stops sync',
      () async {
        final work = Notepad.load(NoteStore.inMemory());
        final sync = await setUpFirst(work);
        final before = sync.config!.vault.encode();
        final other = await (await VaultCrypto.load()).create(
          'another passphrase',
          kdf: KdfParams.insecureForTests,
        );
        other.vault.dispose();
        final json = jsonDecode(utf8.decode(other.header.encode())) as Map;
        json['id'] = sync.config!.vault.id;
        vaultFile(sync).writeAsStringSync(jsonEncode(json));

        await sync.syncNow();
        expect(sync.status, SyncStatus.problem);
        expect(sync.problem, contains('key doesn\'t open'));
        expect(sync.config!.vault.encode(), before);
        await expectLater(
          sync.changePassphrase(
            passphrase: passphrase,
            newPassphrase: newPassphrase,
          ),
          throwsA(isA<SyncException>()),
        );
      },
    );
  });
}

/// Holds reads or writes, once [reads] or [writes] is set, until [open].
class _Gate {
  bool reads = false;
  bool writes = false;

  /// Runs before the vault file is replaced, as another computer would.
  Future<void> Function()? beforeReplacingVault;
  final _reached = Completer<void>();
  final _open = Completer<void>();

  /// Completes when a read or write is being held.
  Future<void> get reached => _reached.future;

  void open() => _open.complete();

  Future<void> _pass(bool held) async {
    if (!held || _open.isCompleted) return;
    if (!_reached.isCompleted) _reached.complete();
    await _open.future;
  }
}

class _GatedBackend implements SyncBackend {
  _GatedBackend(this.inner, this.gate, {this.watch = true});

  final SyncBackend inner;
  final _Gate gate;
  final bool watch;

  @override
  Future<Uint8List> read(RemoteFile file) async {
    final bytes = await inner.read(file);
    await gate._pass(gate.reads);
    return bytes;
  }

  @override
  Future<RemoteFile> write(String recordId, Uint8List bytes) async {
    final written = await inner.write(recordId, bytes);
    await gate._pass(gate.writes);
    return written;
  }

  @override
  String get description => inner.description;
  @override
  Future<Uint8List?> readVault() => inner.readVault();
  @override
  Future<bool> createVault(Uint8List bytes) => inner.createVault(bytes);
  @override
  Future<bool> replaceVault(Uint8List old, Uint8List bytes) async {
    final before = gate.beforeReplacingVault;
    gate.beforeReplacingVault = null;
    await before?.call();
    return inner.replaceVault(old, bytes);
  }

  @override
  Future<List<RemoteFile>> list() => inner.list();
  @override
  Future<bool> deleteIfUnchanged(RemoteFile file) =>
      inner.deleteIfUnchanged(file);
  @override
  Stream<void>? get changes => watch ? inner.changes : null;
}
