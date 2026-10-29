import 'dart:convert';

import 'version_vector.dart';

enum RecordKind { note, folder }

/// One note or folder as it is stored, encrypted, in the sync folder or on
/// Google Drive: one file per record.
class SyncRecord {
  const SyncRecord({
    required this.kind,
    required this.id,
    required this.version,
    required this.data,
    required this.device,
    required this.deviceName,
    required this.savedAt,
  });

  /// Reads a record from the JSON inside a decrypted file.
  factory SyncRecord.decode(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('A record must be JSON');
    }
    if (json is! Map<String, Object?> || json['gpad'] != formatVersion) {
      throw const FormatException('Not a GPad record this version can read');
    }
    final kind = switch (json['kind']) {
      'note' => RecordKind.note,
      'folder' => RecordKind.folder,
      final other => throw FormatException('Unknown record kind $other'),
    };
    final data = json['data'];
    if (data != null && data is! Map<String, Object?>) {
      throw const FormatException('Record data must be a map');
    }
    return SyncRecord(
      kind: kind,
      id: _string(json, 'id'),
      version: VersionVector.fromJson(json['version']),
      data: data as Map<String, Object?>?,
      device: _string(json, 'device'),
      deviceName: _string(json, 'deviceName'),
      savedAt: switch (json['savedAt']) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        _ => throw const FormatException('savedAt must be a time'),
      },
    );
  }

  static const formatVersion = 1;

  final RecordKind kind;
  final String id;
  final VersionVector version;

  /// The note's or folder's fields, or null once it has been deleted for
  /// good. A deleted record stays, so every machine learns of the delete.
  final Map<String, Object?>? data;

  bool get deleted => data == null;

  /// The machine that saved this version, by id and by the name its owner
  /// gave it.
  final String device;
  final String deviceName;
  final DateTime savedAt;

  List<int> encode() => utf8.encode(
    jsonEncode({
      'gpad': formatVersion,
      'kind': kind.name,
      'id': id,
      'version': version.toJson(),
      'device': device,
      'deviceName': deviceName,
      'savedAt': savedAt.millisecondsSinceEpoch,
      'data': data,
    }),
  );

  static String _string(Map<String, Object?> json, String key) =>
      switch (json[key]) {
        final String value => value,
        _ => throw FormatException('$key must be text'),
      };
}
