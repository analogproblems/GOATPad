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

const _passphrase = 'purple tiger lamp river';

SyncController _controller(Notepad notepad, {Keychain? keychain}) =>
    SyncController(
      notepad,
      keychain: keychain ?? MemoryKeychain(),
      kdf: KdfParams.insecureForTests,
      uploadDelay: const Duration(milliseconds: 20),
      maxWait: const Duration(milliseconds: 200),
      hostName: 'work-pc',
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
    expect(sync.config!.folder, folder);
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
        folder: folder,
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
}
