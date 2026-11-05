import 'package:collection/collection.dart';

import 'record_data.dart';
import 'sync_record.dart';

const _equality = DeepCollectionEquality();

bool sameData(Object? a, Object? b) => _equality.equals(a, b);

/// A record as it was at the last version both machines had, before
/// either changed it. [data] is null if it had been deleted.
typedef Ancestor = ({Map<String, Object?>? data});

/// What to keep after a record changed on two machines.
class MergeResult {
  const MergeResult(this.data, {this.conflictCopy});

  /// The merged record, or null if it stays deleted.
  final Map<String, Object?>? data;

  /// When both machines changed a note's text, the other machine's note,
  /// to save as a new note next to this one.
  final Map<String, Object?>? conflictCopy;
}

/// Merges a record changed here ([local]) and on another machine
/// ([remote]) since [ancestor], or with no known common version if
/// [ancestor] is null. Null data means deleted.
///
/// Fields only one side changed take that side's value. When both changed
/// a note's text, nothing is picked: this machine's text stays, and the
/// other's becomes a new note named "… (conflict from [remoteDevice])".
/// For any other field both changed, the side changed last wins
/// ([localNewer]). A record deleted on one machine but changed on the other
/// comes back, so a delete never loses an edit.
MergeResult mergeRecord(
  RecordKind kind, {
  required Ancestor? ancestor,
  required Map<String, Object?>? local,
  required Map<String, Object?>? remote,
  required bool localNewer,
  required String remoteDevice,
}) {
  if (sameData(local, remote)) return MergeResult(local);
  bool changed(Map<String, Object?>? side) =>
      ancestor == null || !sameData(side, ancestor.data);
  if (!changed(local)) return MergeResult(remote);
  if (!changed(remote)) return MergeResult(local);
  if (local == null) return MergeResult(remote);
  if (remote == null) return MergeResult(local);

  final base = ancestor?.data;
  final merge = _FieldMerge(base, local, remote, localNewer);
  return switch (kind) {
    RecordKind.note => _mergeNote(merge, remoteDevice),
    RecordKind.folder => MergeResult(merge.all()),
  };
}

MergeResult _mergeNote(_FieldMerge merge, String remoteDevice) {
  final local = merge.local;
  final remote = merge.remote;
  final merged = merge.all();

  // Status and when the note was trashed go together.
  final statusFrom = merge.sideOf('status');
  merged['trashedAt'] = statusFrom['trashedAt'];

  final textConflict = merge.conflicts('text');
  if (!textConflict) return MergeResult(merged);

  // Keep the text that is here, which may be in front of someone, with
  // what goes with it, and save the other machine's as a new note. Fields
  // a newer GPad added may describe the text, so they stay with it too.
  for (final key in [
    'text',
    'title',
    'titleEdited',
    'mode',
    'language',
    for (final key in merged.keys)
      if (!noteFieldNames.contains(key)) key,
  ]) {
    if (local.containsKey(key)) {
      merged[key] = local[key];
    } else {
      merged.remove(key);
    }
  }
  final title = switch (remote['title']) {
    final String t when t.trim().isNotEmpty => t,
    _ => 'Untitled',
  };
  return MergeResult(
    merged,
    conflictCopy: {
      ...remote,
      'title': '$title (conflict from $remoteDevice)',
      'titleEdited': true,
      'status': 'open',
      'trashedAt': null,
      'awaitingPaste': false,
      'folder': merged['folder'],
    },
  );
}

class _FieldMerge {
  _FieldMerge(this.base, this.local, this.remote, this.localNewer);

  final Map<String, Object?>? base;
  final Map<String, Object?> local;
  final Map<String, Object?> remote;
  final bool localNewer;

  /// Whether both sides changed [key] to different values.
  bool conflicts(String key) {
    final l = _value(local, key);
    final r = _value(remote, key);
    if (sameData(l, r)) return false;
    final base = this.base;
    if (base == null) return true;
    final b = _value(base, key);
    return !sameData(l, b) && !sameData(r, b);
  }

  /// The side whose value of [key] to keep. A field one side doesn't have
  /// differs from one it has, even as null, so a field a newer GPad removed
  /// stays removed.
  Map<String, Object?> sideOf(String key) {
    final l = _value(local, key);
    final r = _value(remote, key);
    if (sameData(l, r)) return local;
    final base = this.base;
    if (base != null) {
      final b = _value(base, key);
      if (sameData(l, b)) return remote;
      if (sameData(r, b)) return local;
    }
    return localNewer ? local : remote;
  }

  Map<String, Object?> all() => {
    for (final key in {...local.keys, ...remote.keys})
      if (sideOf(key) case final side when side.containsKey(key))
        key: switch (key) {
          'createdAt' => _min(local[key], remote[key]),
          'updatedAt' => _max(local[key], remote[key]),
          _ => side[key],
        },
  };

  /// [key]'s value in [data], or [_absent] if [data] has no [key].
  static Object? _value(Map<String, Object?> data, String key) =>
      data.containsKey(key) ? data[key] : _absent;

  static const _absent = _Absent();

  static Object? _min(Object? a, Object? b) =>
      a is int && b is int ? (a < b ? a : b) : a ?? b;

  static Object? _max(Object? a, Object? b) =>
      a is int && b is int ? (a > b ? a : b) : a ?? b;
}

/// Stands for a field a record doesn't have, which is not the same as one
/// it has as null.
class _Absent {
  const _Absent();
}
