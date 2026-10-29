import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'google_auth.dart';
import 'sync_backend.dart';

/// A file in Google Drive, with the fields GPad asks for.
class DriveFile {
  const DriveFile({
    required this.id,
    required this.name,
    required this.createdTime,
    this.headRevisionId,
    this.appProperties = const {},
    this.parents = const [],
  });

  factory DriveFile.fromJson(Map<String, Object?> json) => DriveFile(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    createdTime:
        DateTime.tryParse(json['createdTime'] as String? ?? '') ??
        DateTime.utc(0),
    headRevisionId: json['headRevisionId'] as String?,
    appProperties: {
      for (final MapEntry(:key, :value)
          in (json['appProperties'] as Map<String, Object?>? ?? {}).entries)
        if (value is String) key: value,
    },
    parents: [
      for (final parent in json['parents'] as List<Object?>? ?? const [])
        if (parent is String) parent,
    ],
  );

  final String id;
  final String name;

  /// When Drive made it, by Drive's clock, which every computer sees alike.
  final DateTime createdTime;

  /// Changes with every upload of the file's contents.
  final String? headRevisionId;

  /// Tags only GPad's sign-in client sees and can search by.
  final Map<String, String> appProperties;
  final List<String> parents;

  /// Whether this was made before [other], the same way on every computer.
  bool isOlderThan(DriveFile other) {
    final byTime = createdTime.compareTo(other.createdTime);
    return byTime != 0 ? byTime < 0 : id.compareTo(other.id) < 0;
  }

  static const fields =
      'id,name,createdTime,headRevisionId,appProperties,parents';
}

/// The few calls to the Drive API (v3) that sync needs, signed in through
/// [auth], with retries when Google asks GPad to slow down or has a
/// moment's trouble.
class DriveApi {
  DriveApi(
    this.auth, {
    http.Client? httpClient,
    this.retryDelay = const Duration(seconds: 1),
    this.tries = 5,
  }) : _http = httpClient ?? http.Client();

  /// The sign-in to use, or null when there is none: then every call
  /// throws [GoogleSignInNeeded].
  final GoogleAuth? Function() auth;
  final http.Client _http;

  /// How long to wait before the first retry; each one after waits twice
  /// as long.
  final Duration retryDelay;
  final int tries;

  static const _host = 'www.googleapis.com';
  static const folderType = 'application/vnd.google-apps.folder';
  static final _random = Random();

  /// Quotes [value] for a search query.
  static String quote(String value) =>
      "'${value.replaceAll(r'\', r'\\').replaceAll("'", r"\'")}'";

  /// Every file matching [query], a Drive search like
  /// `name = 'x' and trashed = false`.
  Future<List<DriveFile>> list(String query) async {
    final files = <DriveFile>[];
    String? pageToken;
    do {
      final response = await _send(
        'GET',
        Uri.https(_host, '/drive/v3/files', {
          'q': query,
          'spaces': 'drive',
          'pageSize': '1000',
          'fields': 'nextPageToken,files(${DriveFile.fields})',
          'pageToken': ?pageToken,
        }),
      );
      final json = _json(response);
      for (final file in json['files'] as List<Object?>? ?? const []) {
        files.add(DriveFile.fromJson(file as Map<String, Object?>));
      }
      pageToken = json['nextPageToken'] as String?;
    } while (pageToken != null);
    return files;
  }

  /// Makes a file holding [content], or a folder if [content] is null.
  /// Drive puts a new file in place whole, with its contents.
  Future<DriveFile> create({
    required String name,
    List<String> parents = const [],
    Map<String, String> appProperties = const {},
    Uint8List? content,
    String mimeType = 'application/octet-stream',
  }) async {
    final metadata = jsonEncode({
      'name': name,
      'mimeType': content == null ? folderType : mimeType,
      if (parents.isNotEmpty) 'parents': parents,
      if (appProperties.isNotEmpty) 'appProperties': appProperties,
    });
    if (content == null) {
      return DriveFile.fromJson(
        _json(
          await _send(
            'POST',
            Uri.https(_host, '/drive/v3/files', {'fields': DriveFile.fields}),
            headers: {'Content-Type': 'application/json; charset=UTF-8'},
            body: utf8.encode(metadata),
          ),
        ),
      );
    }
    // The metadata and the contents in one request.
    final boundary =
        'gpad-${_random.nextInt(1 << 32)}-${_random.nextInt(1 << 32)}';
    final body = BytesBuilder(copy: false)
      ..add(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$metadata\r\n'
          '--$boundary\r\n'
          'Content-Type: $mimeType\r\n\r\n',
        ),
      )
      ..add(content)
      ..add(utf8.encode('\r\n--$boundary--\r\n'));
    return DriveFile.fromJson(
      _json(
        await _send(
          'POST',
          Uri.https(_host, '/upload/drive/v3/files', {
            'uploadType': 'multipart',
            'fields': DriveFile.fields,
          }),
          headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
          body: body.takeBytes(),
        ),
      ),
    );
  }

  /// Replaces the contents of file [id], returning it as it is with them,
  /// or null if there's no such file.
  Future<DriveFile?> update(String id, Uint8List content) async {
    final response = await _send(
      'PATCH',
      Uri.https(_host, '/upload/drive/v3/files/$id', {
        'uploadType': 'media',
        'fields': DriveFile.fields,
      }),
      headers: {'Content-Type': 'application/octet-stream'},
      body: content,
      allowMissing: true,
    );
    if (response == null) return null;
    return DriveFile.fromJson(_json(response));
  }

  /// The contents of file [id], or null if there's no such file.
  Future<Uint8List?> download(String id) async {
    final response = await _send(
      'GET',
      Uri.https(_host, '/drive/v3/files/$id', {'alt': 'media'}),
      allowMissing: true,
    );
    return response?.bodyBytes;
  }

  /// File [id] as it is now, or null if it's gone or in the bin.
  Future<DriveFile?> get(String id) async {
    final response = await _send(
      'GET',
      Uri.https(_host, '/drive/v3/files/$id', {
        'fields': '${DriveFile.fields},trashed',
      }),
      allowMissing: true,
    );
    if (response == null) return null;
    final json = _json(response);
    if (json['trashed'] == true) return null;
    return DriveFile.fromJson(json);
  }

  /// Deletes file [id] for good, and everything in it if it's a folder.
  Future<void> delete(String id) => _send(
    'DELETE',
    Uri.https(_host, '/drive/v3/files/$id'),
    allowMissing: true,
  );

  /// The signed-in account's email address.
  Future<String> account() async {
    final json = _json(
      (await _send(
        'GET',
        Uri.https(_host, '/drive/v3/about', {'fields': 'user(emailAddress)'}),
      ))!,
    );
    final user = json['user'];
    if (user is Map<String, Object?> && user['emailAddress'] is String) {
      return user['emailAddress'] as String;
    }
    throw const SyncBackendException(
      'Google didn\'t say which account this is',
    );
  }

  /// Sends a request, retrying while Google asks GPad to slow down or has
  /// trouble, and getting a new access token if the old one was refused.
  /// Returns null for a missing file if [allowMissing].
  Future<http.Response?> _send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Uint8List? body,
    bool allowMissing = false,
  }) async {
    var refreshed = false;
    for (var attempt = 1; ; attempt++) {
      final auth = this.auth();
      if (auth == null) throw const GoogleSignInNeeded();
      final token = await auth.accessToken();
      final request = http.Request(method, url)
        ..headers.addAll(headers)
        ..headers['Authorization'] = 'Bearer $token';
      if (body != null) request.bodyBytes = body;
      final http.Response response;
      try {
        response = await _http
            .send(request)
            .then(http.Response.fromStream)
            .timeout(const Duration(seconds: 60));
      } on Object catch (e) {
        if (e is! TimeoutException &&
            e is! SocketException &&
            e is! http.ClientException) {
          rethrow;
        }
        if (attempt >= tries) {
          throw SyncBackendException(
            e is TimeoutException
                ? 'Google Drive didn\'t answer in time'
                : 'Can\'t reach Google Drive',
          );
        }
        await _wait(attempt);
        continue;
      }
      final status = response.statusCode;
      if (status >= 200 && status < 300) return response;
      if (status == 404 && allowMissing) return null;
      final reason = _reason(response);
      if (status == 401) {
        // Expired early, or revoked: a new one, then, once.
        auth.refused(token);
        if (!refreshed) {
          refreshed = true;
          continue;
        }
        throw const GoogleSignInNeeded();
      }
      final slowDown =
          status == 429 ||
          status >= 500 ||
          (status == 403 &&
              (reason == 'rateLimitExceeded' ||
                  reason == 'userRateLimitExceeded'));
      if (slowDown && attempt < tries) {
        await _wait(attempt);
        continue;
      }
      throw switch ((status, reason)) {
        (403, 'storageQuotaExceeded') => const SyncBackendException(
          'Your Google Drive is full',
        ),
        (403, 'insufficientPermissions' || 'insufficientFilePermissions') =>
          const GoogleSignInNeeded(
            'GPad isn\'t allowed into your Google Drive any more. Sign in '
            'again and leave the Drive box ticked.',
          ),
        _ => SyncBackendException(
          'Google Drive refused a request (${_message(response) ?? status})',
        ),
      };
    }
  }

  Future<void> _wait(int attempt) => Future.delayed(
    retryDelay * pow(2, attempt - 1) * (0.5 + _random.nextDouble()),
  );

  static Map<String, Object?> _json(http.Response? response) {
    try {
      final json = jsonDecode(utf8.decode(response!.bodyBytes));
      if (json is Map<String, Object?>) return json;
    } on FormatException {
      // Below.
    }
    throw const SyncBackendException(
      'Google Drive sent an answer GPad can\'t read',
    );
  }

  static Map<String, Object?>? _error(http.Response response) {
    try {
      final json = jsonDecode(response.body);
      if (json case {'error': final Map<String, Object?> error}) return error;
    } on FormatException {
      // Not JSON.
    }
    return null;
  }

  static String? _reason(http.Response response) {
    if (_error(response) case {
      'errors': [{'reason': final String reason}, ...],
    }) {
      return reason;
    }
    return null;
  }

  static String? _message(http.Response response) =>
      _error(response)?['message'] as String?;
}
