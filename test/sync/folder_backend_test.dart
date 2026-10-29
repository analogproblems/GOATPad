import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/sync/folder_backend.dart';
import 'package:goatpad/src/sync/move_no_replace.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gpad_folder_backend');
  });

  tearDown(() => dir.delete(recursive: true));

  for (final noReplaceMoves in [true, false]) {
    final how = noReplaceMoves ? 'moved into place' : 'filled in place';

    FolderBackend backend(String folder) =>
        FolderBackend(folder)..noReplaceMoves = noReplaceMoves;

    test('of two computers making a vault at once, one wins ($how)', () async {
      for (var round = 0; round < 20; round++) {
        final folder = p.join(dir.path, 'GPad$round');
        final first = Uint8List.fromList('{"first": $round}'.codeUnits);
        final second = Uint8List.fromList('{"second": $round}'.codeUnits);
        final made = await Future.wait([
          backend(folder).createVault(first),
          backend(folder).createVault(second),
        ]);
        expect(made.where((m) => m), hasLength(1), reason: 'round $round');
        expect(await backend(folder).readVault(), made.first ? first : second);
        // Nothing left over from the one that lost.
        expect(Directory(folder).listSync().map((e) => p.basename(e.path)), {
          'gpad-vault.json',
          'records',
        });
      }
    });

    test(
      'a setup that stalls can\'t replace a vault made meanwhile ($how)',
      () async {
        final folder = p.join(dir.path, 'GPad');
        final stalled = backend(folder);
        final held = Completer<void>();
        final resume = Completer<void>();
        stalled.beforePublish = () {
          held.complete();
          return resume.future;
        };
        final first = Uint8List.fromList('{"stalled": 1}'.codeUnits);
        final second = Uint8List.fromList('{"meanwhile": 2}'.codeUnits);
        final stalledMade = stalled.createVault(first);
        await held.future;
        expect(await backend(folder).createVault(second), isTrue);
        resume.complete();
        expect(await stalledMade, isFalse);
        expect(await backend(folder).readVault(), second);
        expect(Directory(folder).listSync().map((e) => p.basename(e.path)), {
          'gpad-vault.json',
          'records',
        });
      },
    );
  }

  test('a move that refuses to replace', () {
    final a = File(p.join(dir.path, 'a'))..writeAsStringSync('a');
    final b = p.join(dir.path, 'b');
    expect(moveNoReplace(a.path, b), isTrue);
    expect(a.existsSync(), isFalse);
    expect(File(b).readAsStringSync(), 'a');
    final c = File(p.join(dir.path, 'c'))..writeAsStringSync('c');
    expect(moveNoReplace(c.path, b), isFalse);
    expect(c.readAsStringSync(), 'c');
    expect(File(b).readAsStringSync(), 'a');
  }, skip: Platform.isLinux || Platform.isWindows ? false : 'not built here');

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
