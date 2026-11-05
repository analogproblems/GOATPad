import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/update/installation.dart';
import 'package:goatpad/src/update/installed_app.dart';
import 'package:goatpad/src/version.dart';
import 'package:path/path.dart' as p;

/// An entry kept in memory, for checking what GPad does with one.
class _FakeEntry extends InstalledAppEntry {
  _FakeEntry(this.values);

  final Map<String, String> values;
  var writes = 0;

  @override
  String? read(String name) => values[name];

  @override
  bool write(String name, String value) {
    writes++;
    values[name] = value;
    return true;
  }
}

void main() {
  test('the installer and GPad name the same entry', () {
    final script = File('windows/installer/gpad.iss').readAsStringSync();
    final appId = RegExp(r'^AppId=\{(\{[0-9A-F-]+\})$', multiLine: true);
    expect(appId.firstMatch(script)?[1], installerAppId);
    expect(
      installedAppKey,
      endsWith(
        r'\Uninstall\'
        '${installerAppId}_is1',
      ),
    );
  });

  group('the version an installed GPad shows', () {
    test('follows an update', () {
      final entry = _FakeEntry({
        'InstallLocation': r'C:\Users\Jo\AppData\Local\Programs\GPad\',
        'DisplayVersion': '0.1.0',
      });
      expect(
        entry.updateVersion(
          r'c:\users\jo\appdata\local\programs\gpad',
          '0.2.0',
        ),
        isTrue,
      );
      expect(entry.values['DisplayVersion'], '0.2.0');

      // Already right: nothing to write.
      expect(
        entry.updateVersion(
          r'C:\Users\Jo\AppData\Local\Programs\GPad',
          '0.2.0',
        ),
        isTrue,
      );
      expect(entry.writes, 1);
    });

    test('is left alone for a GPad the installer didn\'t put there', () {
      final installed = _FakeEntry({
        'InstallLocation': r'C:\Users\Jo\AppData\Local\Programs\GPad\',
        'DisplayVersion': '0.1.0',
      });
      // The portable zip, while an installed GPad is elsewhere.
      expect(installed.updateVersion(r'D:\GPad', '0.2.0'), isFalse);
      // No installed GPad at all.
      final none = _FakeEntry({});
      expect(none.updateVersion(r'D:\GPad', '0.2.0'), isFalse);
      expect(installed.writes + none.writes, 0);
      expect(installed.values['DisplayVersion'], '0.1.0');
    });

    test('changes only once an update is in place', () async {
      final dir = await Directory.systemTemp.createTemp('gpad_installed');
      addTearDown(() => dir.delete(recursive: true));
      void write(String relative, String text) {
        final file = File(p.join(dir.path, relative));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(text);
      }

      final entry = _FakeEntry({
        'InstallLocation': '${dir.path}${Platform.pathSeparator}',
        'DisplayVersion': '0.0.1',
      });
      write('gpad.exe', 'old exe');
      // Nothing staged: the update fails, and the old version stays.
      await WindowsFolderInstallation.finish([
        dir.path,
        'no process',
      ], installedApp: entry);
      expect(entry.values['DisplayVersion'], '0.0.1');

      write('.gpad-update/GPad/gpad.exe', 'new exe');
      await WindowsFolderInstallation.finish([
        dir.path,
        'no process',
      ], installedApp: entry);
      expect(entry.values['DisplayVersion'], gpadVersion);
    });
  });

  test('the version is read and written in the registry', () async {
    final key = 'Software\\GPad tests\\${Random().nextInt(1 << 32)}';
    addTearDown(() => Process.run('reg', ['delete', 'HKCU\\$key', '/f']));
    final entry = InstalledAppEntry(key);
    expect(entry.read('InstallLocation'), isNull);
    expect(entry.write('InstallLocation', r'C:\Programs\GPad – ü\'), isTrue);
    expect(entry.write('DisplayVersion', '0.1.0'), isTrue);
    expect(entry.read('InstallLocation'), r'C:\Programs\GPad – ü\');

    expect(entry.updateVersion(r'C:\Programs\GPad – ü', '0.2.0'), isTrue);
    expect(entry.read('DisplayVersion'), '0.2.0');
    expect(entry.updateVersion(r'C:\Programs\Other', '0.3.0'), isFalse);
    expect(entry.read('DisplayVersion'), '0.2.0');
  }, skip: Platform.isWindows ? false : 'Windows only');
}
