import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/app.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/sync/keychain.dart';
import 'package:goatpad/src/sync/sync_controller.dart';
import 'package:goatpad/src/sync/vault.dart';
import 'package:goatpad/src/ui/sidebar.dart';
import 'package:path/path.dart' as p;

import '../sync/fake_drive.dart';
import '../sync/held_keychain.dart';

const _passphrase = 'purple tiger lamp river';

SyncController _controller(
  Notepad notepad, {
  Keychain? keychain,
  FakeDrive? drive,
}) => SyncController(
  notepad,
  keychain: keychain ?? MemoryKeychain(),
  kdf: KdfParams.insecureForTests,
  uploadDelay: const Duration(milliseconds: 20),
  maxWait: const Duration(milliseconds: 200),
  hostName: 'work-pc',
  googleClient: drive == null ? null : FakeDrive.ownClient,
  httpClient: drive?.client,
  openBrowser: drive?.allow,
);

Future<void> _pumpApp(
  WidgetTester tester,
  Notepad notepad,
  SyncController sync,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(GPadApp(notepad: notepad, sync: sync));
  await tester.pump(const Duration(milliseconds: 1));
}

Finder _inSidebar(String text) =>
    find.descendant(of: find.byType(Sidebar), matching: find.text(text));

Finder _field(String label) => find.widgetWithText(TextField, label);

/// Lets files, keys and isolates do their real work until [finder] shows.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(finder, findsOneWidget);
}

Future<void> _finish(WidgetTester tester, SyncController sync) async {
  await tester.runAsync(sync.finish);
  sync.dispose();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('gpad_sync_dialog'));
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('setting sync up shows the recovery key once', (tester) async {
    final notepad = Notepad.load(NoteStore.inMemory());
    final sync = _controller(notepad);
    await _pumpApp(tester, notepad, sync);

    await tester.tap(_inSidebar('Sync is off'));
    await tester.pump();
    await tester.enterText(_field('Sync folder'), dir.path);
    await tester.tap(find.text('Next'));
    await _waitFor(tester, find.text('Choose a passphrase'));
    final folder = p.join(dir.path, 'GPad');
    expect(find.text('GPad keeps your notes in $folder.'), findsOneWidget);

    await tester.enterText(_field('Passphrase'), 'too short');
    await tester.tap(find.text('Start syncing'));
    await tester.pump();
    expect(find.text('Use at least 10 characters.'), findsOneWidget);

    await tester.enterText(_field('Passphrase'), _passphrase);
    await tester.enterText(_field('Type it again'), '$_passphrase!');
    await tester.tap(find.text('Start syncing'));
    await tester.pump();
    expect(find.text('The two passphrases don\'t match.'), findsOneWidget);

    await tester.enterText(_field('Type it again'), _passphrase);
    await tester.tap(find.text('Start syncing'));
    await _waitFor(tester, find.text('Save your recovery key'));
    final key = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(RecoveryKey.decode(key.data!), isNotNull);

    // Done waits until the key is saved somewhere.
    final done = find.widgetWithText(FilledButton, 'Done');
    expect(tester.widget<FilledButton>(done).onPressed, isNull);
    await tester.tap(find.text('I\'ve saved my recovery key'));
    await tester.pump();
    await tester.tap(done);
    await tester.pump();
    expect(find.text('Save your recovery key'), findsNothing);

    await _waitFor(tester, _inSidebar('Synced'));
    expect((sync.config!.place as FolderPlace).path, folder);
    expect(File(p.join(folder, 'gpad-vault.json')).existsSync(), isTrue);
    await _finish(tester, sync);
  });

  testWidgets('locked sync asks for the passphrase', (tester) async {
    final notepad = Notepad.load(NoteStore.inMemory());
    final first = _controller(notepad);
    await tester.runAsync(() async {
      final folder = p.join(dir.path, 'GPad');
      await Directory(folder).create();
      await first.create(
        place: FolderPlace(folder),
        passphrase: _passphrase,
        deviceName: 'Work PC',
        remember: false,
      );
      await first.finish();
    });
    first.dispose();

    // As after a restart on a computer without a keychain.
    final sync = _controller(notepad, keychain: const NoKeychain());
    await tester.runAsync(sync.start);
    expect(sync.status, SyncStatus.locked);
    await _pumpApp(tester, notepad, sync);

    await tester.tap(_inSidebar('Sync paused: unlock'));
    await tester.pump();
    expect(find.text('Unlock sync'), findsOneWidget);
    await tester.enterText(_field('Passphrase'), 'not my passphrase');
    await tester.tap(find.text('Unlock'));
    await _waitFor(tester, find.textContaining('doesn\'t unlock'));

    await tester.enterText(_field('Passphrase'), _passphrase);
    await tester.tap(find.text('Unlock'));
    await _waitFor(tester, _inSidebar('Synced'));
    expect(find.text('Unlock sync'), findsNothing);
    await _finish(tester, sync);
  });

  testWidgets('changing the passphrase, then the recovery key', (tester) async {
    const newPassphrase = 'orange whale kite meadow';
    final notepad = Notepad.load(NoteStore.inMemory());
    final sync = _controller(notepad);
    final oldKey = (await tester.runAsync(() async {
      final folder = p.join(dir.path, 'GPad');
      await Directory(folder).create();
      return sync.create(
        place: FolderPlace(folder),
        passphrase: _passphrase,
        deviceName: 'Work PC',
        remember: false,
      );
    }))!;
    final crypto = (await tester.runAsync(VaultCrypto.load))!;
    await _pumpApp(tester, notepad, sync);
    await _waitFor(tester, _inSidebar('Synced'));

    await tester.tap(_inSidebar('Synced'));
    await tester.pump();
    await tester.tap(find.text('Change passphrase…'));
    await tester.pump();
    expect(find.text('Change your passphrase'), findsOneWidget);
    final change = find.widgetWithText(FilledButton, 'Change passphrase');

    await tester.enterText(_field('Current passphrase'), _passphrase);
    await tester.enterText(_field('New passphrase'), newPassphrase);
    await tester.enterText(_field('Type it again'), '$newPassphrase!');
    await tester.tap(change);
    await tester.pump();
    expect(find.text('The two passphrases don\'t match.'), findsOneWidget);

    await tester.enterText(_field('Current passphrase'), 'not my passphrase');
    await tester.enterText(_field('Type it again'), newPassphrase);
    await tester.tap(change);
    await _waitFor(tester, find.textContaining('doesn\'t unlock'));
    expect(find.text('Change your passphrase'), findsOneWidget);

    await tester.enterText(_field('Current passphrase'), _passphrase);
    await tester.tap(change);
    await _waitFor(tester, find.textContaining('Passphrase changed.'));
    final changed = sync.config!.vault;
    expect(
      await tester.runAsync(() => crypto.unlock(changed, _passphrase)),
      isNull,
    );
    (await tester.runAsync(() => crypto.unlock(changed, newPassphrase)))!
        .dispose();

    await tester.tap(find.text('New recovery key…'));
    await tester.pump();
    expect(find.text('Make a new recovery key'), findsOneWidget);
    await tester.enterText(_field('Passphrase'), newPassphrase);
    await tester.tap(find.text('Make new key'));
    await _waitFor(tester, find.text('Save your recovery key'));
    expect(
      find.text('Your old recovery key no longer opens them.'),
      findsOneWidget,
    );
    final key = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(key.data, isNot(oldKey));
    expect(crypto.unlockWithRecoveryKey(sync.config!.vault, oldKey), isNull);
    crypto.unlockWithRecoveryKey(sync.config!.vault, key.data!)!.dispose();

    await tester.tap(find.text('I\'ve saved my recovery key'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pump();
    expect(find.text('Save your recovery key'), findsNothing);
    await _finish(tester, sync);
  });

  testWidgets('pressing Enter, then the button, joins once', (tester) async {
    final first = _controller(Notepad.load(NoteStore.inMemory()));
    await tester.runAsync(() async {
      final folder = p.join(dir.path, 'GPad');
      await Directory(folder).create();
      await first.create(
        place: FolderPlace(folder),
        passphrase: _passphrase,
        deviceName: 'Work PC',
        remember: false,
      );
      await first.finish();
    });
    first.dispose();

    final notepad = Notepad.load(NoteStore.inMemory());
    final sync = _controller(notepad);
    await _pumpApp(tester, notepad, sync);
    await tester.tap(_inSidebar('Sync is off'));
    await tester.pump();
    await tester.enterText(_field('Sync folder'), dir.path);
    await tester.tap(find.text('Next'));
    await _waitFor(tester, find.text('Unlock your notes'));

    await tester.enterText(_field('Passphrase'), _passphrase);
    // The second before the dialog shows it is busy.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.tap(find.text('Unlock and sync'));
    await _waitFor(tester, _inSidebar('Synced'));
    expect(find.text('Unlock your notes'), findsNothing);
    await _finish(tester, sync);
  });

  testWidgets('setting sync up with Google Drive signs in in the browser', (
    tester,
  ) async {
    final drive = FakeDrive();
    final notepad = Notepad.load(NoteStore.inMemory());
    final sync = _controller(notepad, drive: drive);
    await _pumpApp(tester, notepad, sync);

    await tester.tap(_inSidebar('Sync is off'));
    await tester.pump();
    // Drive comes first when GPad has a Google sign-in.
    await tester.tap(find.text('Sign in with Google'));
    await _waitFor(tester, find.text('Choose a passphrase'));
    expect(
      find.text(
        'GPad keeps your notes in a GPad folder in the Google Drive of '
        'jason@example.com.',
      ),
      findsOneWidget,
    );
    await tester.enterText(_field('Passphrase'), _passphrase);
    await tester.enterText(_field('Type it again'), _passphrase);
    await tester.tap(find.text('Start syncing'));
    await _waitFor(tester, find.text('Save your recovery key'));
    await tester.tap(find.text('I\'ve saved my recovery key'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Done'));
    await tester.pump();

    await _waitFor(tester, _inSidebar('Synced'));
    expect(sync.config!.place, isA<DrivePlace>());
    expect(drive.tagged('vault'), hasLength(1));

    await tester.tap(_inSidebar('Synced'));
    await tester.pump();
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.text('jason@example.com'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pump();
    await _finish(tester, sync);
  });

  testWidgets('signed out by Google, sync asks to sign in again', (
    tester,
  ) async {
    final drive = FakeDrive();
    final notepad = Notepad.load(NoteStore.inMemory());
    final sync = _controller(notepad, drive: drive);
    await tester.runAsync(() async {
      final checked = await sync.signInToDrive();
      await sync.create(
        place: checked.place,
        passphrase: _passphrase,
        deviceName: 'Work PC',
        remember: false,
      );
      await sync.finish();
      drive.revokeAll();
      await sync.syncNow();
    });
    expect(sync.status, SyncStatus.signedOut);
    await _pumpApp(tester, notepad, sync);

    await tester.tap(_inSidebar('Sync paused: sign in'));
    await tester.pump();
    expect(find.text('Sign in to Google'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
    await _waitFor(tester, _inSidebar('Synced'));
    expect(find.text('Sign in to Google'), findsNothing);
    await _finish(tester, sync);
  });

  testWidgets('once a new sign-in is being saved, Cancel goes', (tester) async {
    final drive = FakeDrive();
    final notepad = Notepad.load(NoteStore.inMemory());
    final keychain = HeldKeychain();
    final sync = _controller(notepad, drive: drive, keychain: keychain);
    await tester.runAsync(() async {
      final checked = await sync.signInToDrive();
      await sync.create(
        place: checked.place,
        passphrase: _passphrase,
        deviceName: 'Work PC',
        remember: false,
      );
      await sync.finish();
      drive.revokeAll();
      await sync.syncNow();
    });
    expect(sync.status, SyncStatus.signedOut);
    await _pumpApp(tester, notepad, sync);

    await tester.tap(_inSidebar('Sync paused: sign in'));
    await tester.pump();
    keychain.holding = true;
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in with Google'));
    await _waitFor(tester, find.textContaining('Saving the sign-in'));
    expect(find.text('Cancel'), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Later'))
          .onPressed,
      isNull,
    );

    keychain.holding = false;
    keychain.held.single.complete();
    await _waitFor(tester, _inSidebar('Synced'));
    expect(find.text('Sign in to Google'), findsNothing);
    await _finish(tester, sync);
  });

  testWidgets('a GPad without a Google sign-in asks for your own client', (
    tester,
  ) async {
    final drive = FakeDrive();
    final notepad = Notepad.load(NoteStore.inMemory());
    final sync = SyncController(
      notepad,
      keychain: MemoryKeychain(),
      kdf: KdfParams.insecureForTests,
      hostName: 'work-pc',
      googleClient: null,
      httpClient: drive.client,
      openBrowser: drive.allow,
    );
    await _pumpApp(tester, notepad, sync);
    await tester.tap(_inSidebar('Sync is off'));
    await tester.pump();
    // A sync folder comes first, but Drive works with your own client.
    expect(_field('Sync folder'), findsOneWidget);
    await tester.tap(find.text('Google Drive'));
    await tester.pump();
    await tester.tap(find.text('Sign in with Google'));
    await tester.pump();
    expect(
      find.text('Enter your Google client\'s ID and secret.'),
      findsOneWidget,
    );
    await tester.enterText(_field('Client ID'), FakeDrive.ownClient.id);
    await tester.enterText(_field('Client secret'), FakeDrive.ownClient.secret);
    await tester.tap(find.text('Sign in with Google'));
    await _waitFor(tester, find.text('Choose a passphrase'));
    await tester.tap(find.text('Back'));
    await tester.pump();
    sync.dispose();
  });
}
