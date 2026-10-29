import 'dart:convert';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart' show SqliteException;

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

/// Thrown by a round that [SyncEngine.cancel] stopped.
class SyncCancelled implements Exception {
  const SyncCancelled();
}

/// What one round of [SyncEngine.sync] did.
class SyncReport {
  int uploaded = 0;
  int downloaded = 0;

  /// Notes changed here and on another machine at once, now kept twice.
  int conflicts = 0;

  /// Files that couldn't be opened: changed, damaged, too large, from
  /// another vault or from a newer GPad. They are left alone.
  final unreadable = <String>[];

  /// Notes too large to sync, by id: encrypted, they would be bigger than
  /// other computers read. Changes to them wait here until they are
  /// smaller.
  final tooLarge = <String>[];
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

  /// Notes found too large to upload, with how far they had been changed
  /// here and which version they were, so they are encrypted again only
  /// once either changes.
  final _tooLarge = <String, (int, String?)>{};

  bool _cancelled = false;

  NoteStore get _store => notepad.store;

  /// Stops a round under way at its next step, which throws
  /// [SyncCancelled]: once the file it is reading or writing is done, it
  /// doesn't use the key or touch the notes or what sync knows. For
  /// turning sync off, or setting it up again, mid-round.
  void cancel() => _cancelled = true;

  /// Waits for [io], then stops if the round was cancelled meanwhile.
  Future<T> _step<T>(Future<T> io) async {
    final result = await io;
    if (_cancelled) throw const SyncCancelled();
    return result;
  }

  /// Whether changes made here are waiting to go up.
  bool get hasPending => _store.pendingSync().any(
    (state) =>
        state.version != null ||
        !notepad.isLocalOnly(RecordKind.values.byName(state.kind), state.id),
  );

  Future<SyncReport> sync() async {
    if (_cancelled) throw const SyncCancelled();
    final report = SyncReport();
    _flush();
    final files = await _step(backend.list());
    final byRecord = <String, List<RemoteFile>>{};
    for (final file in files) {
      byRecord.putIfAbsent(file.recordId, () => []).add(file);
    }

    final copies = <RemoteFile>[];
    // Records whose own file can't be read. Changes here wait rather than
    // replace a version this GPad can't see, say from a newer GPad.
    final blocked = <String>{};
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
        void unreadable() {
          _unreadable[file.name] = file.tag;
          report.unreadable.add(file.name);
          if (file.isCanonical) blocked.add(id);
        }

        if (_unreadable.containsKey(file.name) &&
            _unreadable[file.name] == file.tag) {
          unreadable();
          continue;
        }
        final SyncRecord record;
        try {
          record = _open(id, await _step(backend.read(file)));
        } on FormatException {
          unreadable();
          continue;
        } on VaultException {
          unreadable();
          continue;
        } on FileTooLarge {
          unreadable();
          continue;
        }
        if (!_absorb(record, file, report)) {
          unreadable();
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

    await _upload(report, blocked);
    // Copies are merged into the record's own file by now, unless one
    // changed since it was read; then it is read again next time. Copies
    // of a record that couldn't be uploaded stay for other computers.
    for (final copy in copies) {
      if (blocked.contains(copy.recordId)) continue;
      await _step(backend.deleteIfUnchanged(copy));
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
    // A copy is deleted once merged, and may hold a version the record's
    // own file doesn't, say when a computer missed that file and made
    // another. So what came from a copy goes up to the record's own file
    // first, or other computers would never see it.
    final fromCopy = !file.isCanonical;

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
        _apply(
          remote,
          MergeResult(remote.data),
          local,
          remote.version,
          tag,
          upload: fromCopy,
        );
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
        _apply(
          remote,
          merged,
          local,
          remote.version,
          tag,
          report: report,
          upload: fromCopy,
        );
        report.downloaded++;
        return true;
      case Descent.concurrent:
      case null:
        if (state?.version == null && local == null) {
          // New to this machine. (From a copy only if the record's own file
          // couldn't be read, and then the copy stays.)
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
    final bool saved;
    try {
      saved = notepad.applySynced(
        [
          if (!sameData(merged.data, local))
            SyncedChange(kind, id, merged.data),
        ],
        newNotes: [?copy],
        // Saved with the notes, so a failure undoes both and the next round
        // merges again from the start.
        alsoSave: () {
          // Checked after the change: putting the folder tree right may
          // have moved it since.
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
        },
      );
    } on SqliteException catch (e) {
      throw SyncException(
        'GPad can\'t save synced notes on this computer (${e.message})',
      );
    }
    if (!saved) _flush();
    if (copy != null) report?.conflicts++;
  }

  /// Uploads what changed here, except records in [blocked], and adds to
  /// it records that can't go up, so their copies stay.
  Future<void> _upload(SyncReport report, Set<String> blocked) async {
    _flush();
    for (final state in _store.pendingSync()) {
      if (blocked.contains(state.id)) continue;
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
      final seen = (seq, state.version);
      if (_tooLarge[state.id] == seen) {
        report.tooLarge.add(state.id);
        blocked.add(state.id);
        continue;
      }
      final sealed = vault.seal(state.id, record.encode());
      // Other computers would refuse it, so it doesn't go up. The file
      // already there stays as it is, and so do copies other tools made of
      // it, which may hold changes merged here that only they carry.
      if (sealed.length > backend.recordLimit) {
        _tooLarge[state.id] = seen;
        report.tooLarge.add(state.id);
        blocked.add(state.id);
        continue;
      }
      _tooLarge.remove(state.id);
      final file = await _step(backend.write(state.id, sealed));
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
