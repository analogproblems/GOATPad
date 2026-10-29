import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
      _guard(() => _fileFor(file.name).readAsBytes());

  @override
  Future<RemoteFile> write(String recordId, Uint8List bytes) =>
      _guard(() async {
        await _records.create(recursive: true);
        final name = RemoteFile.nameFor(recordId);
        final file = _fileFor(name);
        await _writeAtomically(file, bytes);
        return RemoteFile(
          name: name,
          recordId: recordId,
          tag: _tag(await file.stat()),
        );
      });

  @override
  Future<void> delete(RemoteFile file) => _guard(() async {
    try {
      await _fileFor(file.name).delete();
    } on PathNotFoundException {
      // Already gone.
    }
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

  Future<void> _writeAtomically(File file, Uint8List bytes) async {
    final temp = File(
      p.join(
        file.parent.path,
        '.${p.basename(file.path)}.${_random.nextInt(1 << 32)}.tmp',
      ),
    );
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
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
