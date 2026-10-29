import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/sync/folder_backend.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gpad_folder_backend');
  });

  tearDown(() => dir.delete(recursive: true));

  test('of two computers making a vault at once, one wins', () async {
    for (var round = 0; round < 20; round++) {
      final folder = p.join(dir.path, 'GPad$round');
      final first = Uint8List.fromList('{"first": $round}'.codeUnits);
      final second = Uint8List.fromList('{"second": $round}'.codeUnits);
      final made = await Future.wait([
        FolderBackend(folder).createVault(first),
        FolderBackend(folder).createVault(second),
      ]);
      expect(made.where((m) => m), hasLength(1), reason: 'round $round');
      expect(
        await FolderBackend(folder).readVault(),
        made.first ? first : second,
      );
      // Nothing left over from the one that lost.
      expect(Directory(folder).listSync().map((e) => p.basename(e.path)), {
        'gpad-vault.json',
        'records',
      });
    }
  });

  test('a write\'s tag is for the bytes it wrote', () async {
    final folder = p.join(dir.path, 'GPad');
    final backend = FolderBackend(folder);
    final id = 'a' * 32;
    final other = File(p.join(folder, 'records', '$id.gpad'));
    // Another computer replaces the file as soon as it is in place.
    backend.afterRename = () async {
      await other.writeAsBytes([9, 9, 9, 9, 9]);
      await other.setLastModified(DateTime(2020));
    };
    final written = await backend.write(id, Uint8List.fromList([1, 2, 3]));
    final listed = (await backend.list()).single;
    expect(listed.tag, isNot(written.tag));
  });
}
