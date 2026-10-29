import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'sync_backend.dart';

/// Keeps synced notes in a folder that another tool, like Dropbox,
/// OneDrive, Nextcloud or Syncthing, copies between machines.
///
/// The folder holds `gpad-vault.json` and a `records` folder with one file
/// per note or folder. Files are written to a temporary name and renamed
/// into place, so other tools never copy half a file.
class FolderBackend implements SyncBackend {
  FolderBackend(this.path);

  /// The folder GPad uses for [chosen]: the folder itself if it already
  /// holds a vault or is called GPad, otherwise a GPad folder inside it, so
  /// choosing a whole Dropbox doesn't scatter files across it.
  static String folderFor(String chosen) {
    if (File(p.join(chosen, vaultFileName)).existsSync() ||
        p.basename(chosen).toLowerCase() == 'gpad') {
      return chosen;
    }
    return p.join(chosen, 'GPad');
  }

  static const vaultFileName = 'gpad-vault.json';

  final String path;

  /// Runs after each file is renamed into place, for tests that have
  /// another computer write there at that moment.
  @visibleForTesting
  Future<void> Function()? afterRename;

  Directory get _records => Directory(p.join(path, 'records'));
  File get _vault => File(p.join(path, vaultFileName));

  static final _random = Random.secure();

  @override
  String get description => path;

  @override
  Future<Uint8List?> readVault() => _guard(() async {
    try {
      return await _vault.readAsBytes();
    } on PathNotFoundException {
      return null;
    }
  });

  @override
  Future<bool> createVault(Uint8List bytes) => _guard(() async {
    await _records.create(recursive: true);
    final temp = _tempFor(_vault);
    try {
      await temp.writeAsBytes(bytes, flush: true);
      // Claimed by an exclusive create, which only one of two computers
      // can win, even on a shared or network drive. Then filled in by a
      // rename, so nobody reads half a header.
      try {
        await _vault.create(exclusive: true);
      } on FileSystemException {
        if (await _vault.exists()) return false;
        rethrow;
      }
      try {
        await temp.rename(_vault.path);
      } catch (_) {
        // Give the claim up, rather than leave an empty vault file that
        // nobody can join or replace.
        await _vault.delete();
        rethrow;
      }
      return true;
    } finally {
      try {
        await temp.delete();
      } on FileSystemException {
        // Renamed into place, or never written.
      }
    }
  });

  @override
  Future<List<RemoteFile>> list() => _guard(() async {
    if (!await _records.exists()) return const [];
    final files = <RemoteFile>[];
    await for (final entry in _records.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      final match = RemoteFile.namePattern.firstMatch(name);
      if (match == null) continue;
      final FileStat stat;
      try {
        stat = await entry.stat();
      } on FileSystemException {
        continue; // Gone since it was listed.
      }
      if (stat.type != FileSystemEntityType.file) continue;
      files.add(RemoteFile(name: name, recordId: match[1]!, tag: _tag(stat)));
    }
    return files;
  });

  @override
  Future<Uint8List> read(RemoteFile file) =>
      _guard(() => _fileFor(file.name).readAsBytes());

  @override
  Future<RemoteFile> write(String recordId, Uint8List bytes) =>
      _guard(() async {
        await _records.create(recursive: true);
        final name = RemoteFile.nameFor(recordId);
        return RemoteFile(
          name: name,
          recordId: recordId,
          tag: await _writeAtomically(_fileFor(name), bytes),
        );
      });

  @override
  Future<bool> deleteIfUnchanged(RemoteFile file) => _guard(() async {
    final listed = _fileFor(file.name);
    // Renamed out of the way first, so a sync tool putting a new version
    // there now makes a new file rather than one that gets deleted.
    final claimed = _tempFor(listed);
    try {
      await listed.rename(claimed.path);
    } on PathNotFoundException {
      return true;
    } on FileSystemException {
      return false; // Open in another program, say; next round, then.
    }
    if (file.tag != null && _tag(await claimed.stat()) == file.tag) {
      await claimed.delete();
      return true;
    }
    // Changed since it was read. Kept under a name of its own, which no
    // sync tool is writing to, for the next round to read.
    await claimed.rename(
      _fileFor(
        '${file.recordId} (changed while syncing '
        '${_random.nextInt(1 << 32)}).gpad',
      ).path,
    );
    return false;
  });

  @override
  Stream<void>? get changes {
    // Watching needs the folder to exist; until then, regular checks do.
    if (!_records.existsSync()) return null;
    try {
      return _records.watch().map((_) {});
    } on FileSystemException {
      return null;
    }
  }

  File _fileFor(String name) => File(p.join(_records.path, name));

  File _tempFor(File file) => File(
    p.join(
      file.parent.path,
      '.${p.basename(file.path)}.${_random.nextInt(1 << 32)}.tmp',
    ),
  );

  /// Writes [bytes] to [file] by renaming a finished temporary file into
  /// place, and returns the tag of what was written. The tag is taken
  /// before the rename, which keeps it: taken after, it could be the tag
  /// of a file another computer put there in between.
  Future<String> _writeAtomically(File file, Uint8List bytes) async {
    final temp = _tempFor(file);
    try {
      await temp.writeAsBytes(bytes, flush: true);
      final tag = _tag(await temp.stat());
      await temp.rename(file.path);
      await afterRename?.call();
      return tag;
    } catch (_) {
      try {
        await temp.delete();
      } on FileSystemException {
        // Nothing to clean up.
      }
      rethrow;
    }
  }

  static String _tag(FileStat stat) =>
      '${stat.size}:${stat.modified.microsecondsSinceEpoch}';

  static Future<T> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on FileSystemException catch (e) {
      final reason = e.osError?.message ?? e.message;
      throw SyncBackendException(
        e.path == null ? reason : '$reason (${e.path})',
      );
    }
  }
}
