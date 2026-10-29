import 'dart:typed_data';

/// A record file in the remote store.
class RemoteFile {
  const RemoteFile({required this.name, required this.recordId, this.tag});

  /// The id at the start of a record file's name: `<id>.gpad`, or a copy
  /// another sync tool made of it, like Dropbox's
  /// `<id> (Jason's conflicted copy).gpad` or Syncthing's
  /// `<id>.sync-conflict-….gpad`.
  static final namePattern = RegExp(r'^([0-9a-f]{32})(.*)\.gpad$');

  static String nameFor(String recordId) => '$recordId.gpad';

  final String name;
  final String recordId;

  /// Changes whenever the file does, like its size and modification time,
  /// or Drive's checksum. Null when the store can't tell.
  final String? tag;

  /// Whether this is the record's own file rather than a copy another sync
  /// tool made when two machines saved it at once.
  bool get isCanonical => name == nameFor(recordId);
}

/// Thrown when the remote store can't be reached or refuses a request.
class SyncBackendException implements Exception {
  const SyncBackendException(this.message);

  final String message;

  @override
  String toString() => 'SyncBackendException: $message';
}

/// Where synced notes are kept: a vault file and one encrypted file per
/// note or folder. GPad never sends anything else, and never anything
/// unencrypted but the vault file, which holds only encrypted keys.
abstract interface class SyncBackend {
  /// Where the notes go, for people to read, like a folder's path.
  String get description;

  /// The vault file, or null if there isn't one yet.
  Future<Uint8List?> readVault();

  /// Writes the vault file, unless there already is one. Returns false,
  /// writing nothing, if there is.
  Future<bool> createVault(Uint8List bytes);

  /// Every record file, including copies made by other sync tools.
  Future<List<RemoteFile>> list();

  Future<Uint8List> read(RemoteFile file);

  /// Writes the record's own file, replacing it whole, and returns it with
  /// its new tag.
  Future<RemoteFile> write(String recordId, Uint8List bytes);

  Future<void> delete(RemoteFile file);

  /// Completes when something in the store may have changed, so sync can
  /// look sooner than its next regular check. Null if the store can't
  /// tell.
  Stream<void>? get changes;
}
