import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/app.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/update/installation.dart';
import 'package:goatpad/src/update/release_manifest.dart';
import 'package:goatpad/src/update/updater.dart';
import 'package:goatpad/src/version.dart';
import 'package:path/path.dart' as p;
import 'package:sodium/sodium_sumo.dart';

import '../update/fake_github.dart';

/// Takes an AppImage-style update, and notes what is asked of it.
class _Installation extends Installation {
  _Installation(this.dir);

  final Directory dir;
  final calls = <String>[];
  bool restartFails = false;

  @override
  String get kind => ReleaseManifest.appImage;

  @override
  File downloadTarget(String name) => File(p.join(dir.path, name));

  @override
  Future<void> install(File download) async =>
      calls.add('install ${download.readAsStringSync()}');

  @override
  Future<void> restartAfterExit() async {
    if (restartFails) throw const ProcessException('gpad', [], 'Access denied');
    calls.add('restart');
  }

  @override
  Future<void> finishAfterExit() async => calls.add('finish');
}

void main() {
  late SodiumSumo sodium;
  late FakeGitHub github;
  late Directory dir;
  late _Installation installation;
  late int exits;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  setUp(() async {
    github = FakeGitHub(sodium);
    dir = await Directory.systemTemp.createTemp('gpad_updates_ui');
    installation = _Installation(dir);
    exits = 0;
  });

  tearDown(() => dir.delete(recursive: true));

  Future<(Notepad, Updater)> pumpApp(
    WidgetTester tester, {
    String? release,
  }) async {
    if (release != null) {
      github.release(release, {
        ReleaseManifest.appImage: (
          'GPad-$release-x86_64.AppImage',
          Uint8List.fromList(utf8.encode('GPad $release')),
        ),
      });
    }
    final notepad = Notepad.load(NoteStore.inMemory());
    final updater = Updater(
      store: notepad.store,
      source: github.source,
      installation: installation,
      client: github.client,
      current: Version.tryParse(gpadVersion),
      sodium: () async => sodium,
    );
    addTearDown(updater.dispose);
    await tester.runAsync(updater.check);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      GPadApp(
        notepad: notepad,
        updater: updater,
        exitForGood: () async => exits++,
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    return (notepad, updater);
  }

  testWidgets('a ready update shows above the notes and restarts GPad', (
    tester,
  ) async {
    final (notepad, updater) = await pumpApp(tester, release: '9.0.0');
    expect(updater.status, UpdateStatus.ready);
    expect(
      find.text('GPad 9.0.0 is ready. It starts when you restart GPad.'),
      findsOneWidget,
    );

    notepad.editText(notepad.newNote(), 'typed just before restarting');
    await tester.tap(find.text('Restart now'));
    await tester.pump();
    expect(installation.calls, ['install GPad 9.0.0', 'restart']);
    expect(exits, 1);
    // Saved before quitting.
    expect(
      notepad.store.loadNotes().map((n) => n.text),
      contains('typed just before restarting'),
    );
    // Let the save timers left by typing run out.
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a restart that won\'t start keeps GPad open and says why', (
    tester,
  ) async {
    installation.restartFails = true;
    final (_, updater) = await pumpApp(tester, release: '9.0.0');
    await tester.tap(find.text('Restart now'));
    await tester.pump();
    expect(exits, 0);
    expect(updater.status, UpdateStatus.ready);
    expect(find.textContaining('but it wouldn\'t start'), findsOneWidget);
    expect(find.textContaining('Access denied'), findsOneWidget);

    installation.restartFails = false;
    await tester.tap(find.text('Restart now'));
    await tester.pump();
    expect(exits, 1);
  });

  testWidgets('later hides the notice', (tester) async {
    final (_, updater) = await pumpApp(tester, release: '9.0.0');
    await tester.tap(find.text('Later'));
    await tester.pump();
    expect(find.textContaining('is ready'), findsNothing);
    expect(updater.status, UpdateStatus.ready);
  });

  testWidgets('quitting finishes a ready update', (tester) async {
    await pumpApp(tester, release: '9.0.0');
    final response = await tester.runAsync(
      () => tester.binding.handleRequestAppExit(),
    );
    expect(response, AppExitResponse.exit);
    expect(installation.calls, ['install GPad 9.0.0', 'finish']);
  });

  testWidgets('quitting with nothing ready installs nothing', (tester) async {
    await pumpApp(tester, release: gpadVersion);
    await tester.runAsync(() => tester.binding.handleRequestAppExit());
    expect(installation.calls, isEmpty);
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('the updates window shows the version and the setting', (
    tester,
  ) async {
    final (_, updater) = await pumpApp(tester, release: gpadVersion);
    await tester.tap(find.byTooltip('About GPad and updates'));
    await tester.pumpAndSettle();
    expect(find.text('GPad $gpadVersion'), findsOneWidget);
    expect(find.text('GPad is up to date.'), findsOneWidget);

    expect(updater.automatic, isTrue);
    await tester.tap(find.text('Check for updates on its own'));
    await tester.pump();
    expect(updater.automatic, isFalse);

    github.requests.clear();
    // Tapped outside the test's fake time, so the check really runs.
    await tester.runAsync(() async {
      await tester.tap(find.text('Check now'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(github.requests, isNotEmpty);
    expect(find.text('GPad is up to date.'), findsOneWidget);
  });
}
