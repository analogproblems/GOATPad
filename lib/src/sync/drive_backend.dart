import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;

import 'drive_api.dart';
import 'sync_backend.dart';
import 'vault.dart';

/// Keeps synced notes in Google Drive, in a GPad folder that GPad makes in
/// My Drive: `gpad-vault.json` and a `records` folder with one file per
/// note or folder, as in a sync folder. GPad asks Google only for
/// `drive.file`, which shows it the files it made and nothing else.
///
/// Drive lets two files have one name, and has no way to change or delete
/// a file only if nobody else changed it first. So GPad finds its files by
/// tags it puts on them (`appProperties`, which only GPad's sign-in client
/// sees), and when two computers make a file at once, the one Drive made
/// first counts, the same on every computer:
/// - of two vaults, the older is the vault, and the computer that made the
///   other steps back;
/// - of two files for one note, the older is its own file, and the other is
///   merged into it like a sync tool's copy, then deleted.
class DriveBackend implements SyncBackend {
  DriveBackend(this.api, {required this.account, this.vaultId});

  final DriveApi api;

  /// The Google account's email address.
  final String account;

  /// The vault whose notes [list] finds. Needed for everything but
  /// [readVault] and [createVault].
  final String? vaultId;

  static const vaultFileName = 'gpad-vault.json';

  /// The `appProperties` tag that says what a file is to GPad.
  static const _role = 'gpad';

  /// The `appProperties` tag that says which vault a file belongs to.
  static const _vaultTag = 'vault';

  /// Runs just before a new vault file is made, for tests that hold one
  /// computer's setup there.
  @visibleForTesting
  Future<void> Function()? beforePublish;

  /// Each record's own file, by record id, as of the last [list].
  final _canonical = <String, String>{};

  /// Every file [list] returned, by the name it gave it.
  final _byName = <String, String>{};

  /// The records folder, as last found or made, and whether it was found
  /// since the last [list]: once a round, GPad makes sure nobody deleted it
  /// or put it in the bin.
  String? _recordsFolder;
  bool _recordsFolderChecked = false;
  ({String id, String? revision, Uint8List bytes})? _vaultCache;

  @override
  String get description => 'Google Drive ($account)';

  @override
  Stream<void>? get changes => null;

  static String _has(String key, String value) =>
      'appProperties has { key=${DriveApi.quote(key)} and '
      'value=${DriveApi.quote(value)} }';

  /// The vault: the oldest vault file, if there are several.
  Future<DriveFile?> _vault() async {
    final vaults = await api.list(
      '${_has(_role, 'vault')} and trashed = false',
    );
    return vaults.isEmpty ? null : _oldest(vaults);
  }

  static DriveFile _oldest(Iterable<DriveFile> files) =>
      files.reduce((a, b) => b.isOlderThan(a) ? b : a);

  @override
  Future<Uint8List?> readVault() async {
    final vault = await _vault();
    if (vault == null) return null;
    final cached = _vaultCache;
    if (cached != null &&
        cached.id == vault.id &&
        cached.revision != null &&
        cached.revision == vault.headRevisionId) {
      return cached.bytes;
    }
    final bytes = await api.download(vault.id);
    if (bytes == null) return null;
    _vaultCache = (id: vault.id, revision: vault.headRevisionId, bytes: bytes);
    return bytes;
  }

  @override
  Future<bool> createVault(Uint8List bytes) async {
    final id = VaultHeader.decode(bytes).id;
    if (await _vault() != null) return false;
    final tags = {_vaultTag: id};
    final folder = await api.create(
      name: 'GPad',
      appProperties: {_role: 'folder', ...tags},
    );
    var won = false;
    try {
      final records = await api.create(
        name: 'records',
        parents: [folder.id],
        appProperties: {_role: 'records', ...tags},
      );
      await beforePublish?.call();
      await api.create(
        name: vaultFileName,
        parents: [folder.id],
        appProperties: {_role: 'vault', ...tags},
        content: bytes,
        mimeType: 'application/json',
      );
      // Another computer may have made one meanwhile. Drive keeps both,
      // and the older counts. (Two of this one's, if Drive made it twice
      // after a retry, count as this one's.)
      final winner = await _vault();
      won = winner?.appProperties[_vaultTag] == id;
      if (won) {
        _recordsFolder = records.id;
        _recordsFolderChecked = true;
      }
      return won;
    } finally {
      if (!won) {
        try {
          await api.delete(folder.id);
        } on SyncBackendException {
          // An empty GPad folder left over; it holds no vault that counts.
        }
      }
    }
  }

  @override
  Future<bool> replaceVault(Uint8List old, Uint8List bytes) async {
    final now = await readVault();
    // What was just read, and which file it came from.
    final vault = _vaultCache;
    if (now == null || vault == null || !listEquals(now, old)) return false;
    final written = await api.update(vault.id, bytes);
    if (written == null) return false;
    _vaultCache = (
      id: written.id,
      revision: written.headRevisionId,
      bytes: bytes,
    );
    return true;
  }

  String get _vaultIdOrThrow =>
      vaultId ?? (throw StateError('No vault to sync with'));

  @override
  Future<List<RemoteFile>> list() async {
    final vault = _vaultIdOrThrow;
    final found = await api.list(
      '${_has(_role, 'record')} and ${_has(_vaultTag, vault)} '
      'and trashed = false',
    );
    final byRecord = <String, List<DriveFile>>{};
    for (final file in found) {
      final match = RemoteFile.namePattern.firstMatch(file.name);
      // Renamed in Drive, say; then it's no longer GPad's file.
      if (match == null || file.name != RemoteFile.nameFor(match[1]!)) {
        continue;
      }
      byRecord.putIfAbsent(match[1]!, () => []).add(file);
    }
    _canonical.clear();
    _byName.clear();
    _recordsFolderChecked = false;
    final files = <RemoteFile>[];
    for (final MapEntry(key: recordId, value: group) in byRecord.entries) {
      group.sort((a, b) => a.isOlderThan(b) ? -1 : (b.isOlderThan(a) ? 1 : 0));
      for (final (i, file) in group.indexed) {
        // The oldest is the record's own file. Any other, made by a
        // computer that didn't see it yet, reads like a sync tool's copy.
        final name = i == 0
            ? RemoteFile.nameFor(recordId)
            : '$recordId (also in Drive as ${file.id}).gpad';
        if (i == 0) _canonical[recordId] = file.id;
        _byName[name] = file.id;
        files.add(RemoteFile(name: name, recordId: recordId, tag: _tag(file)));
      }
    }
    return files;
  }

  /// Changes with every upload, and differs between files.
  static String? _tag(DriveFile file) =>
      file.headRevisionId == null ? null : '${file.id}:${file.headRevisionId}';

  @override
  Future<Uint8List> read(RemoteFile file) async {
    final id = _byName[file.name];
    final bytes = id == null ? null : await api.download(id);
    if (bytes == null) {
      throw SyncBackendException('${file.name} is gone from Google Drive');
    }
    return bytes;
  }

  @override
  Future<RemoteFile> write(String recordId, Uint8List bytes) async {
    final vault = _vaultIdOrThrow;
    final name = RemoteFile.nameFor(recordId);
    final existing = _canonical[recordId];
    // Drive returns the file as this upload left it, so the tag is this
    // upload's, even if another computer replaces it a moment later.
    var written = existing == null ? null : await api.update(existing, bytes);
    written ??= await _create(name, vault, bytes);
    _canonical[recordId] = written.id;
    _byName[name] = written.id;
    return RemoteFile(name: name, recordId: recordId, tag: _tag(written));
  }

  /// Makes a record file in the records folder, which someone may have
  /// deleted since GPad last looked: then in a new one.
  Future<DriveFile> _create(String name, String vault, Uint8List bytes) async {
    for (var again = false; ; again = true) {
      final folder = await _recordsFolderId(vault);
      try {
        return await api.create(
          name: name,
          parents: [folder],
          appProperties: {_role: 'record', _vaultTag: vault},
          content: bytes,
        );
      } on DriveFileMissing {
        if (again) rethrow;
        _recordsFolder = null;
      }
    }
  }

  /// Where new record files go: the vault's records folder, or a new one
  /// if someone deleted it or put it in the bin.
  Future<String> _recordsFolderId(String vault) async {
    if (_recordsFolder case final known?) {
      if (_recordsFolderChecked || await api.get(known) != null) {
        _recordsFolderChecked = true;
        return known;
      }
    }
    final folders = await api.list(
      '${_has(_role, 'records')} and ${_has(_vaultTag, vault)} '
      'and trashed = false',
    );
    final String id;
    if (folders.isNotEmpty) {
      id = _oldest(folders).id;
    } else {
      final parents = (await _vault())?.parents ?? const [];
      id = (await api.create(
        name: 'records',
        parents: parents.take(1).toList(),
        appProperties: {_role: 'records', _vaultTag: vault},
      )).id;
    }
    _recordsFolderChecked = true;
    return _recordsFolder = id;
  }

  @override
  Future<bool> deleteIfUnchanged(RemoteFile file) async {
    final id = _byName[file.name];
    if (id == null || file.tag == null) return false;
    final now = await api.get(id);
    if (now == null) return true;
    // Drive can't delete only if unchanged, so there's a moment between
    // this check and the delete. Only a computer that took this file for
    // the note's own file writes to it, and that computer keeps what it
    // wrote and, next round, finds it missing from the note's own file
    // and merges it in again.
    if (_tag(now) != file.tag) return false;
    await api.delete(id);
    _byName.remove(file.name);
    return true;
  }
}
