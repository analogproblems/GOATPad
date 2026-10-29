import 'dart:convert';
import 'dart:typed_data';

import '../notepad/notepad.dart';
import '../store/note_store.dart';
import 'merge.dart';
import 'record_data.dart';
import 'sync_backend.dart';
import 'sync_record.dart';
import 'vault.dart';
import 'version_vector.dart';

/// Thrown when a sync round can't finish. Nothing is lost: whatever was
/// done stays done, and the next round picks up the rest.
class SyncException implements Exception {
  const SyncException(this.message);

  final String message;

  @override
  String toString() => 'SyncException: $message';
}

/// What one round of [SyncEngine.sync] did.
class SyncReport {
  int uploaded = 0;
  int downloaded = 0;

  /// Notes changed here and on another machine at once, now kept twice.
  int conflicts = 0;

  /// Files that couldn't be opened: changed, damaged, from another vault
  /// or from a newer GPad. They are left alone.
  final unreadable = <String>[];
}

/// Brings the notes here and in the remote store in step.
///
/// Each note and folder is one encrypted file, carrying a version that
/// counts each machine's saves (see [VersionVector]). A round downloads the
/// files that changed since the last round and merges them in, then
/// uploads whatever changed here. Merging follows [mergeRecord]: what only
/// one machine changed is taken as it is, and when two machines changed a
/// note's text at once, both texts are kept.
class SyncEngine {
  SyncEngine({
    required this.backend,
    required this.vault,
    required this.notepad,
    required this.deviceId,
    required this.deviceName,
    this.clock = DateTime.now,
  });

  final SyncBackend backend;
  final Vault vault;
  final Notepad notepad;
  final String deviceId;
  final String deviceName;
  final DateTime Function() clock;

  /// Files that couldn't be opened, by name, with their tags, so they are
  /// read again only if they change.
  final _unreadable = <String, String?>{};

  NoteStore get _store => notepad.store;

  /// Whether changes made here are waiting to go up.
  bool get hasPending => _store.pendingSync().any(
    (state) =>
        state.version != null ||
        !notepad.isLocalOnly(RecordKind.values.byName(state.kind), state.id),
  );

  Future<SyncReport> sync() async {
    final report = SyncReport();
    _flush();
    final files = await backend.list();
    final byRecord = <String, List<RemoteFile>>{};
    for (final file in files) {
      byRecord.putIfAbsent(file.recordId, () => []).add(file);
    }

    final copies = <RemoteFile>[];
    for (final MapEntry(key: id, value: group) in byRecord.entries) {
      // The record's own file first, then copies other tools made of it.
      group.sort(
        (a, b) => a.isCanonical != b.isCanonical
            ? (a.isCanonical ? -1 : 1)
            : a.name.compareTo(b.name),
      );
      for (final file in group) {
        final state = _store.syncState(id);
        if (file.isCanonical &&
            file.tag != null &&
            state?.remoteTag == file.tag) {
          continue;
        }
        if (_unreadable.containsKey(file.name) &&
            _unreadable[file.name] == file.tag) {
          report.unreadable.add(file.name);
          continue;
        }
        final SyncRecord record;
        try {
          record = _open(id, await backend.read(file));
        } on FormatException {
          _unreadable[file.name] = file.tag;
          report.unreadable.add(file.name);
          continue;
        } on VaultException {
          _unreadable[file.name] = file.tag;
          report.unreadable.add(file.name);
          continue;
        }
        if (!_absorb(record, file, report)) {
          _unreadable[file.name] = file.tag;
          report.unreadable.add(file.name);
          continue;
        }
        if (!file.isCanonical) copies.add(file);
      }
    }

    // A file someone deleted from the store goes back, so its note isn't
    // lost on machines that haven't synced yet.
    final present = {
      for (final f in files)
        if (f.isCanonical) f.recordId,
    };
    for (final state in _store.syncStates().values) {
      if (state.remoteTag != null && !present.contains(state.id)) {
        _store.saveSyncState(
          state.id,
          kind: state.kind,
          upload: true,
          clearRemoteTag: true,
        );
      }
    }

    await _upload(report);
    // Copies are merged into the record's own file by now.
    for (final copy in copies) {
      await backend.delete(copy);
    }
    return report;
  }

  void _flush() {
    if (!notepad.flush()) {
      throw SyncException(
        'GPad can\'t save your notes on this computer '
        '(${notepad.saveProblem})',
      );
    }
  }

  SyncRecord _open(String id, Uint8List file) {
    final record = SyncRecord.decode(vault.open(id, file));
    if (record.id != id) {
      throw const FormatException('The record inside has another id');
    }
    // Read the data the way this GPad would write it, which also checks
    // every field.
    final data = record.data;
    return SyncRecord(
      kind: record.kind,
      id: id,
      version: record.version,
      device: record.device,
      deviceName: record.deviceName,
      savedAt: record.savedAt,
      data: data == null
          ? null
          : switch (record.kind) {
              RecordKind.note => noteData(noteFromData(id, data)),
              RecordKind.folder => folderData(folderFromData(id, data)),
            },
    );
  }

  /// Merges [remote], read from [file], into the notes here. Returns false
  /// if it can't be: it claims to be a folder but is a note here, or the
  /// other way round.
  bool _absorb(SyncRecord remote, RemoteFile file, SyncReport report) {
    _flush();
    final id = remote.id;
    final kind = remote.kind;
    final state = _store.syncState(id);
    if (state != null && state.kind != kind.name) return false;
    final local = notepad.syncData(kind, id);
    final known = _version(state?.version);
    final relation = known == null ? null : remote.version.compareTo(known);
    final tag = file.isCanonical ? file.tag : null;

    switch (relation) {
      case Descent.same:
        // Nothing new; maybe just touched by another tool.
        _store.saveSyncState(
          id,
          kind: kind.name,
          syncedSeq: state!.syncedSeq,
          remoteTag: tag,
        );
        return true;
      case Descent.older:
        // An old version came back, say restored from a backup or left by
        // another tool. Ours is newer, so put it back.
        if (file.isCanonical) {
          _store.saveSyncState(id, kind: kind.name, upload: true);
        }
        return true;
      case Descent.newer when !state!.changedHere:
        _apply(remote, MergeResult(remote.data), local, remote.version, tag);
        report.downloaded++;
        return true;
      case Descent.newer:
        // Changed there and here since the version both had.
        final merged = mergeRecord(
          kind,
          ancestor: (data: _data(state!.base)),
          local: local,
          remote: remote.data,
          localNewer: state.changedAt.isAfter(remote.savedAt),
          remoteDevice: remote.deviceName,
        );
        _apply(remote, merged, local, remote.version, tag, report: report);
        report.downloaded++;
        return true;
      case Descent.concurrent:
      case null:
        if (state?.version == null && local == null) {
          // New to this machine.
          _apply(remote, MergeResult(remote.data), local, remote.version, tag);
          report.downloaded++;
          return true;
        }
        // Saved there without knowing about our last upload, or we never
        // synced it before but have it (sync was set up again). The last
        // version that came from elsewhere is the common one, if the other
        // machine had it.
        final commonVersion = _version(state?.commonVersion);
        final hadCommon =
            commonVersion != null &&
            switch (remote.version.compareTo(commonVersion)) {
              Descent.same || Descent.newer => true,
              _ => false,
            };
        final merged = mergeRecord(
          kind,
          ancestor: hadCommon ? (data: _data(state!.common)) : null,
          local: local,
          remote: remote.data,
          localNewer: (state?.changedAt ?? DateTime(0)).isAfter(remote.savedAt),
          remoteDevice: remote.deviceName,
        );
        // Upload even if nothing changed here, so the store holds a version
        // that has seen both.
        _apply(
          remote,
          merged,
          local,
          remote.version.merge(known ?? const VersionVector()),
          tag,
          report: report,
          upload: true,
        );
        report.downloaded++;
        return true;
    }
  }

  /// Puts [merged] in place of [local], and records that the notes here
  /// now include [remote]. Unless [merged] is just [remote], sync uploads
  /// the result.
  void _apply(
    SyncRecord remote,
    MergeResult merged,
    Map<String, Object?>? local,
    VersionVector version,
    String? tag, {
    SyncReport? report,
    bool upload = false,
  }) {
    final kind = remote.kind;
    final id = remote.id;
    final copy = merged.conflictCopy;
    _store.transaction(() {
      final saved = notepad.applySynced(
        [
          if (!sameData(merged.data, local))
            SyncedChange(kind, id, merged.data),
        ],
        newNotes: [?copy],
      );
      // Rolls back what sync noted; the notes stay as they are in the
      // window and are saved when saving works again.
      if (!saved) _flush();
      // Checked after saving: putting the folder tree right may have moved
      // it since.
      final now = notepad.syncData(kind, id);
      final inStep = !upload && sameData(now, remote.data);
      final remoteData = jsonEncode(remote.data);
      _store.saveSyncState(
        id,
        kind: kind.name,
        upload: !inStep,
        version: jsonEncode(version.toJson()),
        base: remoteData,
        commonVersion: jsonEncode(remote.version.toJson()),
        common: remoteData,
        remoteTag: tag,
      );
    });
    if (copy != null) report?.conflicts++;
  }

  Future<void> _upload(SyncReport report) async {
    _flush();
    for (final state in _store.pendingSync()) {
      final kind = RecordKind.values.byName(state.kind);
      final data = notepad.syncData(kind, state.id);
      if (state.version == null) {
        // Made and deleted here before it was ever uploaded.
        if (data == null) {
          _store.deleteSyncState(state.id);
          continue;
        }
        if (notepad.isLocalOnly(kind, state.id)) continue;
      }
      final version = (_version(state.version) ?? const VersionVector()).bump(
        deviceId,
      );
      final record = SyncRecord(
        kind: kind,
        id: state.id,
        version: version,
        data: data,
        device: deviceId,
        deviceName: deviceName,
        savedAt: clock(),
      );
      final seq = state.localSeq;
      final file = await backend.write(
        state.id,
        vault.seal(state.id, record.encode()),
      );
      // If it changed while it was being written, it stays pending, and the
      // next round uploads it again.
      _store.saveSyncState(
        state.id,
        kind: state.kind,
        syncedSeq: seq,
        version: jsonEncode(version.toJson()),
        base: jsonEncode(data),
        remoteTag: file.tag,
      );
      report.uploaded++;
    }
  }

  static VersionVector? _version(String? json) =>
      json == null ? null : VersionVector.fromJson(jsonDecode(json));

  static Map<String, Object?>? _data(String? json) =>
      json == null ? null : jsonDecode(json) as Map<String, Object?>?;
}
