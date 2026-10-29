import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/sync/google_auth.dart';
import 'package:goatpad/src/sync/keychain.dart';
import 'package:goatpad/src/sync/sync_backend.dart';
import 'package:goatpad/src/sync/sync_controller.dart';
import 'package:goatpad/src/sync/sync_record.dart';
import 'package:goatpad/src/sync/vault.dart';

import 'fake_drive.dart';

const passphrase = 'purple tiger lamp river';

void main() {
  late FakeDrive drive;
  final controllers = <SyncController>[];

  setUp(() => drive = FakeDrive());

  tearDown(() async {
    final all = [...controllers];
    controllers.clear();
    for (final c in all) {
      await c.finish(timeout: const Duration(seconds: 1));
      c.dispose();
    }
  });

  SyncController controllerFor(
    Notepad notepad, {
    Keychain? keychain,
    GoogleClient? googleClient = FakeDrive.ownClient,
  }) {
    final controller = SyncController(
      notepad,
      keychain: keychain ?? MemoryKeychain(),
      kdf: KdfParams.insecureForTests,
      uploadDelay: const Duration(milliseconds: 20),
      maxWait: const Duration(milliseconds: 200),
      hostName: 'work-pc',
      googleClient: googleClient,
      httpClient: drive.client,
      openBrowser: drive.allow,
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

  Notepad notepadWith(String text) {
    final notepad = Notepad.load(NoteStore.inMemory());
    notepad.editText(notepad.newNote(), text);
    return notepad;
  }

  bool has(Notepad notepad, String text) =>
      notepad.keptNotes.any((n) => n.text == text);

  Future<SyncController> setUpFirst(
    Notepad notepad, {
    Keychain? keychain,
  }) async {
    final sync = controllerFor(notepad, keychain: keychain);
    final checked = await sync.signInToDrive();
    expect(checked.vault, isNull);
    expect(checked.place.description, 'Google Drive (jason@example.com)');
    await sync.create(
      place: checked.place,
      passphrase: passphrase,
      deviceName: 'Work PC',
      remember: true,
    );
    await settle(sync);
    expect(sync.status, SyncStatus.synced);
    return sync;
  }

  Future<SyncController> join(Notepad notepad, {Keychain? keychain}) async {
    final sync = controllerFor(notepad, keychain: keychain);
    final checked = await sync.signInToDrive();
    expect(checked.vault, isNotNull);
    expect(
      await sync.join(
        place: checked.place,
        vault: checked.vault!,
        passphrase: passphrase,
        deviceName: 'Home laptop',
        remember: true,
      ),
      isTrue,
    );
    await settle(sync);
    return sync;
  }

  test('setting up with Google Drive, then joining from home', () async {
    final work = notepadWith('pasted at work');
    final keychain = MemoryKeychain();
    final sync = await setUpFirst(work, keychain: keychain);
    final vaultId = sync.config!.vault.id;
    expect(keychain.secrets.keys, {
      'sync-google-$vaultId',
      'sync-key-$vaultId',
    });
    final saved = jsonDecode(work.store.setting('sync')!) as Map;
    expect(saved['backend'], 'drive');
    expect(saved['account'], 'jason@example.com');
    expect(saved.containsKey('client'), isFalse);
    expect(drive.tagged('record'), hasLength(1));

    final home = notepadWith('typed at home');
    final homeSync = await join(home);
    expect(homeSync.status, SyncStatus.synced);
    expect(has(home, 'pasted at work'), isTrue);
    await sync.syncNow();
    expect(has(work, 'typed at home'), isTrue);

    // After a restart, the keychain has all it needs: no browser, no
    // passphrase.
    final signIns = drive.refreshTokens.length;
    sync.dispose();
    controllers.remove(sync);
    final restarted = controllerFor(work, keychain: keychain);
    await restarted.start();
    await settle(restarted);
    expect(restarted.status, SyncStatus.synced);
    expect(drive.refreshTokens, hasLength(signIns));
  });

  test(
    'signed out by Google, changes wait and go up after signing in again',
    () async {
      final work = notepadWith('first');
      final keychain = MemoryKeychain();
      final sync = await setUpFirst(work, keychain: keychain);
      final home = notepadWith('home');
      final homeSync = await join(home);

      drive.revokeAll();
      work.editText(
        work.keptNotes.firstWhere((n) => n.text == 'first'),
        'edited',
      );
      work.flush();
      await sync.syncNow();
      expect(sync.status, SyncStatus.signedOut);
      expect(sync.problem, contains('Sign in again'));
      // The dead sign-in is forgotten; the change waits.
      expect(
        keychain.secrets.keys.where((k) => k.startsWith('sync-google')),
        isEmpty,
      );
      expect(work.store.pendingSync(), isNotEmpty);

      // Further rounds don't ask Google anything.
      drive.requests.clear();
      await sync.syncNow();
      expect(drive.requests, isEmpty);
      expect(sync.status, SyncStatus.signedOut);

      await sync.signInAgain();
      await settle(sync);
      expect(sync.status, SyncStatus.synced);
      expect(
        keychain.secrets.keys.where((k) => k.startsWith('sync-google')),
        hasLength(1),
      );

      // Removing GPad's access signed home out too.
      await homeSync.syncNow();
      expect(homeSync.status, SyncStatus.signedOut);
      await homeSync.signInAgain();
      await settle(homeSync);
      await homeSync.syncNow();
      expect(has(home, 'edited'), isTrue);
    },
  );

  test('signing in again as someone else is refused', () async {
    final sync = await setUpFirst(notepadWith('mine'));
    drive.revokeAll();
    await sync.syncNow();
    expect(sync.status, SyncStatus.signedOut);

    drive.account = 'someone@example.com';
    await expectLater(
      sync.signInAgain(),
      throwsA(
        isA<GoogleAuthException>().having(
          (e) => e.message,
          'message',
          contains('Sign in as jason@example.com'),
        ),
      ),
    );
    await sync.syncNow();
    expect(sync.status, SyncStatus.signedOut);
  });

  test(
    'turning off forgets the sign-in, and other computers sync on',
    () async {
      final keychain = MemoryKeychain();
      final sync = await setUpFirst(notepadWith('work'), keychain: keychain);
      final home = notepadWith('home');
      final homeSync = await join(home);
      final tokens = {...drive.refreshTokens};

      await sync.turnOff();
      expect(sync.status, SyncStatus.off);
      expect(keychain.secrets, isEmpty);
      // Not revoked, which would sign home out too.
      expect(drive.refreshTokens, tokens);
      home.editText(home.newNote(), 'still syncing');
      await settle(homeSync);
      expect(homeSync.status, SyncStatus.synced);
    },
  );

  test('a second computer setting up the same Drive is told to join', () async {
    final first = controllerFor(notepadWith('a'));
    final second = controllerFor(notepadWith('b'));
    final places = [
      (await first.signInToDrive()).place,
      (await second.signInToDrive()).place,
    ];
    final outcomes = await Future.wait([
      for (final (i, sync) in [first, second].indexed)
        sync
            .create(
              place: places[i],
              passphrase: passphrase,
              deviceName: '',
              remember: false,
            )
            .then<Object?>((_) => null, onError: (Object e) => e),
    ]);
    expect(outcomes.where((o) => o == null), hasLength(1));
    final lost = outcomes.firstWhere((o) => o != null);
    expect(
      lost,
      isA<SyncBackendException>().having(
        (e) => e.message,
        'message',
        contains('Sign in again to join it'),
      ),
    );
    expect(drive.tagged('vault'), hasLength(1));
  });

  test(
    'a computer that missed the other\'s vault stops once it sees it',
    () async {
      final work = await setUpFirst(notepadWith('at work'));
      final workVault = drive.tagged('vault').single.id;

      // Home's Drive search hasn't caught up with work's vault yet, so home
      // makes its own and starts syncing into it.
      drive.hiddenFromLists.add(workVault);
      final home = notepadWith('at home');
      final homeSync = controllerFor(home);
      final checked = await homeSync.signInToDrive();
      expect(checked.vault, isNull);
      await homeSync.create(
        place: checked.place,
        passphrase: 'another passphrase',
        deviceName: 'Home',
        remember: false,
      );
      await settle(homeSync);
      expect(homeSync.status, SyncStatus.synced);

      // Then it shows up, older: home stops, and work never sees home's notes.
      drive.hiddenFromLists.clear();
      await homeSync.syncNow();
      expect(homeSync.status, SyncStatus.problem);
      expect(homeSync.problem, contains('different set of GPad notes'));
      await work.syncNow();
      expect(has(work.notepad, 'at home'), isFalse);
      expect(has(home, 'at home'), isTrue);
    },
  );

  test('without a keychain, GPad asks for both after a restart', () async {
    final work = notepadWith('no keychain here');
    final sync = controllerFor(work, keychain: const NoKeychain());
    final checked = await sync.signInToDrive();
    await sync.create(
      place: checked.place,
      passphrase: passphrase,
      deviceName: 'Work PC',
      remember: false,
    );
    await settle(sync);
    expect(sync.status, SyncStatus.synced);
    sync.dispose();
    controllers.remove(sync);

    final restarted = controllerFor(work, keychain: const NoKeychain());
    await restarted.start();
    expect(restarted.status, SyncStatus.locked);
    expect(
      await restarted.unlock(passphrase: passphrase, remember: false),
      isTrue,
    );
    await settle(restarted);
    expect(restarted.status, SyncStatus.signedOut);
    await restarted.signInAgain();
    await settle(restarted);
    expect(restarted.status, SyncStatus.synced);
  });

  test('a GPad without its own client uses yours, on every start', () async {
    final keychain = MemoryKeychain();
    final work = notepadWith('own client');
    final sync = controllerFor(work, keychain: keychain, googleClient: null);
    await expectLater(
      sync.signInToDrive(),
      throwsA(
        isA<GoogleAuthException>().having(
          (e) => e.message,
          'message',
          contains('no Google sign-in built in'),
        ),
      ),
    );
    final checked = await sync.signInToDrive(ownClient: FakeDrive.ownClient);
    await sync.create(
      place: checked.place,
      passphrase: passphrase,
      deviceName: 'Work PC',
      remember: true,
    );
    await settle(sync);
    final saved = jsonDecode(work.store.setting('sync')!) as Map;
    expect(saved['client'], FakeDrive.ownClient.toJson());
    sync.dispose();
    controllers.remove(sync);

    final restarted = controllerFor(
      work,
      keychain: keychain,
      googleClient: null,
    );
    await restarted.start();
    await settle(restarted);
    expect(restarted.status, SyncStatus.synced);
  });
}
