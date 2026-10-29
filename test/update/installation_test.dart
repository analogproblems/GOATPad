import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/update/installation.dart';
import 'package:goatpad/src/update/release_manifest.dart';
import 'package:path/path.dart' as p;

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gpad_installation');
  });

  tearDown(() => dir.delete(recursive: true));

  void write(String relative, String text) {
    final file = File(p.join(dir.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }

  String read(String relative) =>
      File(p.join(dir.path, relative)).readAsStringSync();

  /// Every file under [dir], relative to it.
  List<String> files() => [
    for (final f in dir.listSync(recursive: true).whereType<File>())
      p.relative(f.path, from: dir.path),
  ]..sort();

  test(
    'an AppImage is found from \$APPIMAGE, and anything else is by hand',
    () {
      write('GPad.AppImage', 'gpad');
      final path = p.join(dir.path, 'GPad.AppImage');
      final found = Installation.detect(environment: {'APPIMAGE': path});
      expect(found, isA<AppImageInstallation>());
      expect((found as AppImageInstallation).path, path);
      expect(found.kind, ReleaseManifest.appImage);
      for (final env in [
        <String, String>{},
        {'APPIMAGE': 'GPad.AppImage'},
        {'APPIMAGE': p.join(dir.path, 'missing.AppImage')},
      ]) {
        expect(
          Installation.detect(environment: env),
          isA<ManualInstallation>(),
          reason: '$env',
        );
      }
      expect(const ManualInstallation().kind, isNull);
    },
    skip: Platform.isLinux ? false : 'Linux only',
  );

  group('Windows zip', () {
    File zip(Map<String, String> entries) {
      final archive = Archive();
      for (final MapEntry(:key, :value) in entries.entries) {
        archive.add(ArchiveFile.bytes(key, _bytes(value)));
      }
      return File(p.join(dir.path, 'update.zip'))
        ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    }

    test('unzips only inside its GPad folder', () async {
      final into = Directory(p.join(dir.path, 'out'));
      await unzipRelease(
        zip({'GPad/gpad.exe': 'exe', 'GPad/data/flutter_assets/a': 'a'}),
        into,
      );
      expect(read('out/GPad/gpad.exe'), 'exe');
      expect(read('out/GPad/data/flutter_assets/a'), 'a');

      for (final name in [
        '../evil.exe',
        'GPad/../../evil.exe',
        '/etc/evil',
        'C:/Windows/evil.dll',
        r'GPad\..\..\evil.exe',
        'Other/gpad.exe',
        '',
      ]) {
        await expectLater(
          unzipRelease(zip({name: 'evil'}), into),
          throwsA(isA<UpdateException>()),
          reason: name,
        );
      }
      expect(files().where((f) => f.contains('evil')), isEmpty);
    });

    test('a zip without gpad.exe isn\'t staged', () async {
      final installation = WindowsFolderInstallation(dir.path);
      await expectLater(
        installation.install(zip({'GPad/readme.txt': 'hi'})),
        throwsA(isA<UpdateException>()),
      );
    });

    test('new files replace the old, which wait aside', () async {
      write('gpad.exe', 'old exe');
      write('data/app.so', 'old app');
      write('notes I keep here.txt', 'mine');
      write('.gpad-update/GPad/gpad.exe', 'new exe');
      write('.gpad-update/GPad/data/app.so', 'new app');
      write('.gpad-update/GPad/new_plugin.dll', 'plugin');

      await WindowsFolderInstallation.finish([dir.path, 'no process']);

      expect(read('gpad.exe'), 'new exe');
      expect(read('data/app.so'), 'new app');
      expect(read('new_plugin.dll'), 'plugin');
      expect(read('notes I keep here.txt'), 'mine');
      expect(read('.gpad-old/gpad.exe'), 'old exe');
      expect(read('.gpad-old/data/app.so'), 'old app');

      // The next start tidies up, and has nothing to report.
      expect(await WindowsFolderInstallation.cleanUp(dir.path), isNull);
      expect(files(), [
        'data/app.so',
        'gpad.exe',
        'new_plugin.dll',
        'notes I keep here.txt',
      ]);
    });

    test('a failed copy puts the old version back', () async {
      write('gpad.exe', 'old exe');
      write('data/app.so', 'old app');
      write('.gpad-update/GPad/data/app.so', 'new app');
      write('.gpad-update/GPad/gpad.exe', 'new exe');
      write('.gpad-update/GPad/zz_new.dll', 'new dll');
      var copies = 0;
      await expectLater(
        WindowsFolderInstallation.replaceFiles(
          dir.path,
          Directory(p.join(dir.path, '.gpad-update', 'GPad')),
          copy: (from, to) async {
            // A failure that trying again doesn't help.
            if (++copies == 2) throw StateError('The disk is full');
            await from.copy(to);
          },
        ),
        throwsStateError,
      );
      expect(read('gpad.exe'), 'old exe');
      expect(read('data/app.so'), 'old app');
      expect(File(p.join(dir.path, 'zz_new.dll')).existsSync(), isFalse);
      // All back, so nothing is kept for the next start.
      expect(
        File(p.join(dir.path, WindowsFolderInstallation.replacingName))
            .existsSync(),
        isFalse,
      );
    });

    group('old files that won\'t go back', () {
      setUp(() => WindowsFolderInstallation.retryPause = Duration.zero);
      tearDown(
        () => WindowsFolderInstallation.retryPause = const Duration(
          milliseconds: 200,
        ),
      );

      Directory stage() {
        write('.gpad-update/GPad/data/app.so', 'new app');
        write('.gpad-update/GPad/gpad.exe', 'new exe');
        return Directory(p.join(dir.path, '.gpad-update', 'GPad'));
      }

      /// Moves as GPad does, except putting back gpad.exe while [stuck].
      var stuck = true;
      Future<void> move(File from, String to) async {
        if (stuck &&
            p.basename(to) == 'gpad.exe' &&
            from.path.contains('.gpad-old')) {
          throw const FileSystemException('In use');
        }
        await from.rename(to);
      }

      Future<void> failToUpdate() => expectLater(
        WindowsFolderInstallation.replaceFiles(
          dir.path,
          stage(),
          copy: (from, to) async {
            if (p.basename(to) == 'gpad.exe') throw StateError('Disk full');
            await from.copy(to);
          },
          move: move,
        ),
        throwsStateError,
      );

      test('are kept, and put back by the next update', () async {
        stuck = true;
        write('gpad.exe', 'old exe');
        write('data/app.so', 'old app');
        await failToUpdate();
        expect(read('data/app.so'), 'old app');
        expect(read('.gpad-old/gpad.exe'), 'old exe');

        // The next start keeps them, and says where.
        expect(
          await WindowsFolderInstallation.cleanUp(dir.path),
          contains('kept in .gpad-old'),
        );
        expect(read('.gpad-old/gpad.exe'), 'old exe');

        // Still stuck: the next update changes nothing.
        await expectLater(
          WindowsFolderInstallation.replaceFiles(dir.path, stage(), move: move),
          throwsA(isA<FileSystemException>()),
        );
        expect(read('data/app.so'), 'old app');
        expect(read('.gpad-old/gpad.exe'), 'old exe');

        // Free again: they go back, then the update goes in.
        stuck = false;
        await WindowsFolderInstallation.replaceFiles(
          dir.path,
          stage(),
          move: move,
        );
        expect(read('gpad.exe'), 'new exe');
        expect(read('data/app.so'), 'new app');
        expect(read('.gpad-old/gpad.exe'), 'old exe');
        expect(await WindowsFolderInstallation.cleanUp(dir.path), isNull);
        expect(files(), ['data/app.so', 'gpad.exe']);
      });
    });

    test('an update that won\'t start can be started again', () async {
      final installation = WindowsFolderInstallation(dir.path);
      // Unzipped files aren't runnable on Linux, as if Windows refused it.
      await installation.install(
        zip({'GPad/gpad.exe': '#!/bin/sh\necho "\$@" > "\$0.ran"\n'}),
      );
      final staged = p.join(dir.path, '.gpad-update', 'GPad', 'gpad.exe');
      await expectLater(
        installation.restartAfterExit(),
        throwsA(isA<ProcessException>()),
      );
      // Quitting tries again, and keeps why it couldn't for the next start.
      await installation.finishAfterExit();
      expect(read('.gpad-update-failed'), contains('couldn\'t start'));

      Process.runSync('chmod', ['755', staged]);
      await installation.restartAfterExit();
      final ran = File('$staged.ran');
      for (var i = 0; i < 50 && !ran.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        ran.readAsStringSync().trim(),
        '--gpad-finish-update ${dir.path} $pid --relaunch',
      );
    }, skip: Platform.isLinux ? false : 'Linux only');

    test('a failure is kept for the next start to tell', () async {
      write('gpad.exe', 'old exe');
      // Nothing staged: the update can't be finished.
      await WindowsFolderInstallation.finish([dir.path, 'no process']);
      expect(read('gpad.exe'), 'old exe');
      expect(await WindowsFolderInstallation.cleanUp(dir.path), isNotEmpty);
      expect(await WindowsFolderInstallation.cleanUp(dir.path), isNull);
    });
  });

  test('an AppImage update replaces the file and can be run', () async {
    write('GPad.AppImage', 'old');
    final installation = AppImageInstallation(
      p.join(dir.path, 'GPad.AppImage'),
    );
    final download = installation.downloadTarget('GPad-0.2.0.AppImage');
    expect(p.dirname(download.path), dir.path);
    download.writeAsStringSync('new');
    await installation.install(download);
    expect(read('GPad.AppImage'), 'new');
    expect(
      File(installation.path).statSync().mode & 0x1ff,
      0x1ed, // rwxr-xr-x
    );
    expect(files(), ['GPad.AppImage']);
  }, skip: Platform.isLinux ? false : 'Linux only');
}
