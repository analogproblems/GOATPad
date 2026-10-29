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

  /// Runs after a copy is claimed for deleting, for tests that stop GPad
  /// at that moment.
  @visibleForTesting
  Future<void> Function()? afterClaim;

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
    if (await _vault.exists()) return false;
    final temp = _tempFor(_vault);
    try {
      await temp.writeAsBytes(bytes, flush: true);
      // Only the computer holding the setup lock publishes, so two setting
      // up one folder at once can't both win. The header goes in whole, by
      // a rename onto a name nothing is at, so it is never seen half
      // written and never replaces another.
      if (!await _lockSetup()) return false;
      try {
        if (await _vault.exists()) return false;
        await temp.rename(_vault.path);
        return true;
      } finally {
        await _unlockSetup();
      }
    } finally {
      try {
        await temp.delete();
      } on FileSystemException {
        // Renamed into place, or never written.
      }
    }
  });

  /// Held while a computer sets this folder up. Left behind if GPad
  /// stopped mid-setup, which is why an old one can be taken over.
  File get _setupLock => File(p.join(path, '.gpad-setup.lock'));

  /// How old a setup lock must be before it counts as left behind. Setting
  /// up holds it for moments; the margin is for clocks that disagree
  /// between computers and a file server.
  static const staleLock = Duration(minutes: 10);

  Future<bool> _lockSetup() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await _setupLock.create(exclusive: true);
        return true;
      } on FileSystemException {
        // Someone holds it, or held it and stopped.
      }
      final FileStat lock;
      try {
        lock = await _setupLock.stat();
      } on FileSystemException {
        continue;
      }
      if (lock.type == FileSystemEntityType.notFound) continue; // Let go of.
      if (DateTime.now().difference(lock.modified) < staleLock) return false;
      // Left behind. Renaming it away is something only one computer can
      // do; whoever does tries for the lock again.
      final taken = _tempFor(_setupLock);
      try {
        await _setupLock.rename(taken.path);
      } on FileSystemException {
        continue;
      }
      if (DateTime.now().difference((await taken.stat()).modified) <
          staleLock) {
        // A new lock took the old one's place just now; give it back.
        try {
          await taken.rename(_setupLock.path);
        } on FileSystemException {
          // Its owner finishes all the same.
        }
        return false;
      }
      try {
        await taken.delete();
      } on FileSystemException {
        // A stray hidden file at worst.
      }
    }
    return false;
  }

  Future<void> _unlockSetup() async {
    // Windows can refuse while another computer looks at the lock, so try
    // a few times; one left behind goes stale.
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await _setupLock.delete();
        return;
      } on PathNotFoundException {
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  }

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
    // there now makes a new file rather than one that gets deleted. The
    // new name is still a copy's, so if GPad stops here, or the copy had
    // changed since it was read, the next round reads it like any other.
    final claimed = _fileFor(
      '${file.recordId} (claimed by GPad ${_random.nextInt(1 << 32)}).gpad',
    );
    try {
      await listed.rename(claimed.path);
    } on PathNotFoundException {
      return true;
    } on FileSystemException {
      return false; // Open in another program, say; next round, then.
    }
    await afterClaim?.call();
    if (file.tag == null || _tag(await claimed.stat()) != file.tag) {
      return false;
    }
    await claimed.delete();
    return true;
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
