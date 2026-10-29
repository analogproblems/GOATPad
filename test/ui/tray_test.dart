import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/app.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/sync/keychain.dart';
import 'package:goatpad/src/sync/sync_controller.dart';
import 'package:goatpad/src/sync/sync_record.dart';
import 'package:goatpad/src/sync/vault.dart';
import 'package:goatpad/src/ui/sidebar.dart';
import 'package:goatpad/src/ui/tray.dart';
import 'package:path/path.dart' as p;

/// The runner's side of the tray channel: what it was asked, and whether
/// it has a tray.
class _Runner {
  _Runner({this.available = true}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(
            call.arguments == null
                ? call.method
                : '${call.method} ${(call.arguments as Map)['status']}',
          );
          return switch (call.method) {
            'available' => available,
            'show' => true,
            _ => null,
          };
        });
  }

  static const channel = MethodChannel(Tray.channelName);

  final bool available;
  final calls = <String>[];

  /// How many times GPad quit for good.
  var exits = 0;

  Future<void> exit() async => exits++;

  /// The icon's menu, choosing [method].
  Future<void> choose(String method) async {
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          Tray.channelName,
          const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
          (_) => done.complete(),
        );
    await done.future;
  }

  void stop() => TestDefaultBinaryMessengerBinding
      .instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null);
}

SyncController _controller(Notepad notepad) => SyncController(
  notepad,
  keychain: MemoryKeychain(),
  kdf: KdfParams.insecureForTests,
  uploadDelay: const Duration(milliseconds: 20),
  maxWait: const Duration(milliseconds: 200),
  hostName: 'work-pc',
);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('gpad_tray'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> setUpSync(SyncController sync) async {
    final folder = p.join(dir.path, 'GPad');
    await Directory(folder).create();
    await sync.create(
      place: FolderPlace(folder),
      passphrase: 'purple tiger lamp river',
      deviceName: 'Work PC',
      remember: false,
    );
    await sync.finish();
  }

  test('the icon shows while the tray is on and sync is set up', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final runner = _Runner();
    addTearDown(runner.stop);
    final notepad = Notepad.load(NoteStore.inMemory());
    final sync = _controller(notepad);
    final tray = Tray(sync);
    addTearDown(() {
      tray.dispose();
      sync.dispose();
    });

    await tray.start();
    expect(tray.available, isTrue);
    expect(tray.keepsRunning, isFalse);
    expect(runner.calls, ['available']);

    // On, but nothing to sync yet: no icon.
    await tray.setEnabled(true);
    expect(tray.keepsRunning, isFalse);
    expect(runner.calls, ['available']);

    await setUpSync(sync);
    await pumpEventQueue();
    expect(tray.keepsRunning, isTrue);
    expect(runner.calls.first, 'available');
    expect(runner.calls[1], startsWith('show GPad: '));
    expect(runner.calls.last, 'status GPad: Synced');

    // Remembered, without the icon, until it is on again.
    await tray.setEnabled(false);
    expect(runner.calls.last, 'remove');
    expect(notepad.store.setting('tray'), isNull);
    await tray.setEnabled(true);
    expect(notepad.store.setting('tray'), 'on');
    expect(runner.calls.last, startsWith('show GPad: '));

    // Turning sync off takes the icon away; closing quits again.
    await sync.turnOff();
    await pumpEventQueue();
    expect(runner.calls.last, 'remove');
    expect(tray.keepsRunning, isFalse);
  });

  test('without a tray on this desktop, nothing changes', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final runner = _Runner(available: false);
    addTearDown(runner.stop);
    final notepad = Notepad.load(NoteStore.inMemory());
    final sync = _controller(notepad);
    final tray = Tray(sync);
    addTearDown(() {
      tray.dispose();
      sync.dispose();
    });
    await tray.start();
    await tray.setEnabled(true);
    await setUpSync(sync);
    await pumpEventQueue();
    expect(tray.available, isFalse);
    expect(tray.keepsRunning, isFalse);
    expect(runner.calls, ['available']);
  });

  Future<(Notepad, SyncController, Tray)> pumpApp(
    WidgetTester tester,
    _Runner runner, {
    bool enabled = true,
  }) async {
    final notepad = Notepad.load(NoteStore.inMemory());
    final sync = _controller(notepad);
    final tray = Tray(sync);
    addTearDown(tray.dispose);
    await tester.runAsync(() async {
      await setUpSync(sync);
      await tray.start();
      await tray.setEnabled(enabled);
    });
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      GPadApp(
        notepad: notepad,
        sync: sync,
        tray: tray,
        exitForGood: runner.exit,
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    return (notepad, sync, tray);
  }

  Future<void> finish(WidgetTester tester, SyncController sync) async {
    await tester.runAsync(sync.finish);
    sync.dispose();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('with the tray on, closing the window hides it', (tester) async {
    final runner = _Runner();
    addTearDown(runner.stop);
    final (notepad, sync, _) = await pumpApp(tester, runner);

    final note = notepad.newNote();
    notepad.editText(note, 'typed just before closing');
    final response = await tester.runAsync(
      () => tester.binding.handleRequestAppExit(),
    );
    expect(response, AppExitResponse.cancel);
    expect(runner.calls.last, 'hideWindow');
    expect(runner.exits, 0);
    // Saved now, and on its way up.
    expect(notepad.store.pendingSync(), isNotEmpty);
    await finish(tester, sync);
  });

  testWidgets('with the tray off, closing the window quits', (tester) async {
    final runner = _Runner();
    addTearDown(runner.stop);
    final (_, sync, _) = await pumpApp(tester, runner, enabled: false);
    final response = await tester.runAsync(
      () => tester.binding.handleRequestAppExit(),
    );
    expect(response, AppExitResponse.exit);
    expect(runner.calls, isNot(contains('hideWindow')));
    await finish(tester, sync);
  });

  testWidgets('Quit in the icon\'s menu uploads, then quits', (tester) async {
    final runner = _Runner();
    addTearDown(runner.stop);
    final (notepad, sync, _) = await pumpApp(tester, runner);
    notepad.editText(notepad.newNote(), 'typed, then quit from the tray');

    await tester.runAsync(() => runner.choose('quit'));
    expect(runner.exits, 1);
    expect(runner.calls.last, 'remove');
    // Uploaded before quitting.
    expect(
      notepad.store.pendingSync().where(
        (s) => !notepad.isLocalOnly(RecordKind.values.byName(s.kind), s.id),
      ),
      isEmpty,
    );
    await finish(tester, sync);
  });

  testWidgets('the setting is in the sync window', (tester) async {
    final runner = _Runner();
    addTearDown(runner.stop);
    final (notepad, sync, tray) = await pumpApp(tester, runner, enabled: false);

    await tester.tap(
      find.descendant(of: find.byType(Sidebar), matching: find.text('Synced')),
    );
    await tester.pump();
    final setting = find.text(
      'Keep syncing in the tray when the window is closed',
    );
    expect(setting, findsOneWidget);
    await tester.tap(setting);
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    expect(tray.enabled, isTrue);
    expect(runner.calls.last, startsWith('show GPad: '));
    await tester.tap(find.text('Close'));
    await tester.pump();
    await finish(tester, sync);
  });
}
