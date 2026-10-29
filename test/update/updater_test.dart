import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/update/installation.dart';
import 'package:goatpad/src/update/release_manifest.dart';
import 'package:goatpad/src/update/updater.dart';
import 'package:path/path.dart' as p;

import 'fake_github.dart';

import 'package:sodium/sodium_sumo.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late SodiumSumo sodium;
  late FakeGitHub github;
  late NoteStore store;
  late Directory dir;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  setUp(() async {
    github = FakeGitHub(sodium);
    store = NoteStore.inMemory();
    dir = await Directory.systemTemp.createTemp('gpad_updater');
  });

  tearDown(() async {
    store.close();
    await dir.delete(recursive: true);
  });

  Updater updater(Installation installation, {String current = '0.1.0'}) =>
      Updater(
        store: store,
        source: github.source,
        installation: installation,
        client: github.client,
        current: Version.tryParse(current),
        sodium: () async => sodium,
      );

  AppImageInstallation appImage() {
    final file = File(p.join(dir.path, 'GPad.AppImage'))
      ..writeAsStringSync('old');
    return AppImageInstallation(file.path);
  }

  Map<String, (String, Uint8List)> appImageRelease(String content) => {
    ReleaseManifest.appImage: ('GPad-0.2.0-x86_64.AppImage', _bytes(content)),
  };

  test('a build without GPad\'s key never asks', () async {
    final off = Updater(
      store: store,
      installation: const ManualInstallation(),
      client: github.client,
    );
    expect(off.source, isNull);
    expect(off.status, UpdateStatus.off);
    await off.start();
    await off.check();
    expect(github.requests, isEmpty);
    off.dispose();
  });

  test('no release yet, or none newer, is up to date', () async {
    final installation = appImage();
    final update = updater(installation);
    await update.check();
    expect(update.status, UpdateStatus.upToDate);

    github.release('0.1.0', appImageRelease('same'));
    await update.check();
    expect(update.status, UpdateStatus.upToDate);
    expect(github.requests.last, endsWith('/v0.1.0/gpad-update.json.sig'));
    expect(File(installation.path).readAsStringSync(), 'old');
    update.dispose();
  });

  test('a newer AppImage is checked and put in place', () async {
    final installation = appImage();
    github.release('0.2.0', appImageRelease('new GPad'));
    final update = updater(installation);
    final seen = <UpdateStatus>[];
    update.addListener(() => seen.add(update.status));
    await update.check();

    expect(update.status, UpdateStatus.ready);
    expect(update.newVersion, const Version(0, 2, 0));
    expect(update.showNotice, isTrue);
    expect(
      '${update.releasePage}',
      'https://github.com/$repository/releases/tag/v0.2.0',
    );
    expect(
      seen,
      containsAllInOrder([
        UpdateStatus.checking,
        UpdateStatus.downloading,
        UpdateStatus.ready,
      ]),
    );
    expect(github.requests, [
      '/$repository/releases/latest/download/gpad-update.json',
      '/$repository/releases/download/v0.2.0/gpad-update.json.sig',
      '/$repository/releases/download/v0.2.0/GPad-0.2.0-x86_64.AppImage',
    ]);
    final file = File(installation.path);
    expect(file.readAsStringSync(), 'new GPad');
    expect(file.statSync().mode & 0x1ff, 0x1ed);
    // Only the AppImage is left: the download became it.
    expect(dir.listSync().map((e) => p.basename(e.path)), ['GPad.AppImage']);

    // Ready: nothing more to fetch until the restart.
    github.requests.clear();
    await update.check();
    expect(github.requests, isEmpty);
    update.dismiss();
    expect(update.showNotice, isFalse);
    update.dispose();
  });

  test('a download that doesn\'t match its manifest is thrown away', () async {
    final installation = appImage();
    for (final (entry, problem) in [
      ({'size': 8, 'sha256': '0' * 64}, 'doesn\'t match'),
      ({'size': 3, 'sha256': '0' * 64}, 'bigger'),
      ({'size': 20, 'sha256': '0' * 64}, 'doesn\'t match'),
    ]) {
      github.release('0.2.0', appImageRelease('new GPad'));
      github.entries = {
        ReleaseManifest.appImage: {
          'name': 'GPad-0.2.0-x86_64.AppImage',
          ...entry,
        },
      };
      final update = updater(installation);
      await update.check();
      expect(update.status, UpdateStatus.failed);
      expect(update.problem, contains(problem));
      expect(update.showNotice, isFalse);
      expect(File(installation.path).readAsStringSync(), 'old');
      expect(dir.listSync(), hasLength(1), reason: 'download left behind');
      update.dispose();
    }
  });

  test('a release signed with another key is never downloaded', () async {
    final installation = appImage();
    github
      ..release('0.2.0', appImageRelease('new GPad'))
      ..badSignature = true;
    final update = updater(installation);
    await update.check();
    expect(update.status, UpdateStatus.failed);
    expect(update.problem, contains('isn\'t signed by GPad\'s key'));
    expect(github.requests, hasLength(2));
    expect(File(installation.path).readAsStringSync(), 'old');
    update.dispose();
  });

  test('a package install is only told of the new version', () async {
    github.release('0.2.0', {
      ...appImageRelease('new GPad'),
      ReleaseManifest.deb: ('gpad_0.2.0_amd64.deb', _bytes('deb')),
    });
    final update = updater(const ManualInstallation());
    await update.check();
    expect(update.status, UpdateStatus.available);
    expect(update.showNotice, isTrue);
    expect(update.newVersion, const Version(0, 2, 0));
    expect(github.requests, hasLength(2));
    update.dispose();
  });

  test(
    'a release without this installation\'s download is only told of',
    () async {
      github.release('0.2.0', {
        ReleaseManifest.windowsZip: (
          'GPad-0.2.0-windows-x64.zip',
          _bytes('zip'),
        ),
      });
      final update = updater(appImage());
      await update.check();
      expect(update.status, UpdateStatus.available);
      update.dispose();
    },
  );

  test('GitHub out of reach says so', () async {
    github
      ..release('0.2.0', appImageRelease('new GPad'))
      ..failWith = const SocketException('no network');
    final update = updater(appImage());
    await update.check();
    expect(update.status, UpdateStatus.failed);
    expect(update.problem, 'GPad can\'t reach GitHub');

    github.failWith = null;
    await update.check();
    expect(update.status, UpdateStatus.ready);
    expect(update.problem, isNull);
    update.dispose();
  });

  test('a Windows zip is unzipped beside GPad until it quits', () async {
    final archive = Archive()
      ..add(ArchiveFile.bytes('GPad/gpad.exe', _bytes('new exe')))
      ..add(ArchiveFile.bytes('GPad/data/app.so', _bytes('new app')));
    final zip = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
    github.release('0.2.0', {
      ReleaseManifest.windowsZip: ('GPad-0.2.0-windows-x64.zip', zip),
    });
    File(p.join(dir.path, 'gpad.exe')).writeAsStringSync('old exe');
    final update = updater(WindowsFolderInstallation(dir.path));
    await update.check();
    expect(update.status, UpdateStatus.ready);
    final staged = p.join(dir.path, '.gpad-update', 'GPad');
    expect(File(p.join(staged, 'gpad.exe')).readAsStringSync(), 'new exe');
    expect(
      File(p.join(staged, 'data', 'app.so')).readAsStringSync(),
      'new app',
    );
    expect(File(p.join(dir.path, 'gpad.exe')).readAsStringSync(), 'old exe');
    // The zip itself is gone.
    expect(
      dir.listSync().map((e) => p.basename(e.path)),
      unorderedEquals(['gpad.exe', '.gpad-update']),
    );
    update.dispose();
  });

  test('a release zip that won\'t unzip fails the update', () async {
    final archive = Archive()
      ..add(ArchiveFile.bytes('GPad/gpad.exe', _bytes('x' * 5000)));
    // Damaged compressed data, which unzipping trips over.
    final zip = Uint8List.fromList(ZipEncoder().encodeBytes(archive))
      ..[60] ^= 0xff
      ..[70] ^= 0xff
      ..[80] ^= 0xff;
    github.release('0.2.0', {
      ReleaseManifest.windowsZip: ('GPad-0.2.0-windows-x64.zip', zip),
    });
    final update = updater(WindowsFolderInstallation(dir.path));
    await update.check();
    expect(update.status, UpdateStatus.failed);
    expect(update.problem, startsWith('GPad couldn\'t update'));
    update.dispose();
  });

  test('checks on its own after starting, unless turned off', () async {
    github.release('0.1.0', appImageRelease('same'));
    final update = Updater(
      store: store,
      source: github.source,
      installation: appImage(),
      client: github.client,
      current: const Version(0, 1, 0),
      sodium: () async => sodium,
      firstCheckAfter: const Duration(milliseconds: 100),
      checkEvery: const Duration(milliseconds: 400),
    );
    await update.start();
    expect(github.requests, isEmpty);
    // Leeway for a slow machine: each check takes a moment.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(github.requests, hasLength(2));
    expect(update.status, UpdateStatus.upToDate);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(github.requests, hasLength(4));

    update.setAutomatic(false);
    expect(update.automatic, isFalse);
    github.requests.clear();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(github.requests, isEmpty);

    update.setAutomatic(true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(github.requests, isNotEmpty);
    update.dispose();
  });
}
