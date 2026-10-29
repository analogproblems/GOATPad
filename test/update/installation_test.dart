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
    });

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
