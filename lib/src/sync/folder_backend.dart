import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:path/path.dart' as p;

import 'move_no_replace.dart';
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

  /// Runs just before a new vault file is put in place, for tests that
  /// hold one computer's setup there.
  @visibleForTesting
  Future<void> Function()? beforePublish;

  /// How a new vault file is put in place; tests swap it to act out a
  /// drive that can't do it without replacing.
  @visibleForTesting
  bool Function(String source, String target) moveVault = moveNoReplace;

  /// The most of a file GPad reads; tests lower them.
  @visibleForTesting
  int recordLimit = SyncBackend.maxRecordBytes;
  @visibleForTesting
  int vaultLimit = SyncBackend.maxVaultBytes;

  Directory get _records => Directory(p.join(path, 'records'));
  File get _vault => File(p.join(path, vaultFileName));

  static final _random = Random.secure();

  @override
  String get description => path;

  @override
  Future<Uint8List?> readVault() => _guard(() async {
    try {
      return await _readUpTo(_vault, vaultLimit);
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
      await beforePublish?.call();
      // In one step that never replaces a vault already there, however
      // long since the check above: of two computers setting up one
      // folder, only one wins, and nobody reads half a header.
      try {
        return moveVault(temp.path, _vault.path);
      } on UnsupportedError {
        throw const SyncBackendException(
          'GPad can\'t set sync up on this drive safely: it can\'t put a '
          'file in place without risking replacing one, like FAT and exFAT '
          'drives, which many USB sticks are. Set sync up in a folder on '
          'another drive, then copy its GPad folder here and choose that.',
        );
      }
    } finally {
      try {
        await temp.delete();
      } on FileSystemException {
        // Moved into place, or never written.
      }
    }
  });

  @override
  Future<bool> replaceVault(Uint8List old, Uint8List bytes) => _guard(() async {
    final Uint8List now;
    try {
      now = await _readUpTo(_vault, vaultLimit);
    } on PathNotFoundException {
      return false;
    }
    if (!listEquals(now, old)) return false;
    await _writeAtomically(_vault, bytes);
    return true;
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
      _guard(() => _readUpTo(_fileFor(file.name), recordLimit));

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

  /// The contents of [file], unless it holds more than [limit] bytes: then
  /// throws [FileTooLarge], having read no more than that.
  static Future<Uint8List> _readUpTo(File file, int limit) async {
    final opened = await file.open();
    try {
      final bytes = BytesBuilder(copy: false);
      while (bytes.length <= limit) {
        final chunk = await opened.read(min(1 << 20, limit + 1 - bytes.length));
        if (chunk.isEmpty) return bytes.takeBytes();
        bytes.add(chunk);
      }
      throw FileTooLarge(p.basename(file.path));
    } finally {
      await opened.close();
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
