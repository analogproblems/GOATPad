import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/store/data_location.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gpad_data_location');
  });

  tearDown(() => dir.delete(recursive: true));

  test('GPAD_DATA_DIR picks the folder, and it is made', () async {
    final folder = p.join(dir.path, 'portable', 'GPad');
    final path = await notesDatabasePath(
      environment: {'GPAD_DATA_DIR': folder},
    );
    expect(path, p.join(folder, 'notes.db'));
    expect(Directory(folder).existsSync(), isTrue);
  });

  test('the notes folder is private to its owner', () async {
    final folder = p.join(dir.path, 'gpad');
    // As an older GPad left it, open to everyone.
    Directory(folder).createSync();
    await Process.run('chmod', ['755', folder]);
    await notesDatabasePath(environment: {'XDG_DATA_HOME': dir.path});
    expect(Directory(folder).statSync().mode & 0x1ff, 0x1c0);
  }, skip: Platform.isLinux ? false : 'Linux only');
}
