import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:goatpad/src/sync/google_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _folderType = 'application/vnd.google-apps.folder';

/// A file in [FakeDrive].
class FakeFile {
  FakeFile({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.parents,
    required this.appProperties,
    required this.createdTime,
    required this.owner,
    this.content,
  });

  final String id;
  String name;
  final String mimeType;
  List<String> parents;
  Map<String, String> appProperties;
  final DateTime createdTime;

  /// Whose Drive it is in.
  final String owner;
  Uint8List? content;
  int revision = 1;
  bool trashed = false;

  bool get isFolder => mimeType == _folderType;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'createdTime': createdTime.toUtc().toIso8601String(),
    if (!isFolder) 'headRevisionId': 'rev$revision',
    'appProperties': appProperties,
    'parents': parents,
    'trashed': trashed,
  };
}

/// Google's sign-in service and the Drive API, in memory, as far as GPad
/// uses them. Computers syncing through one Drive share one of these and
/// use its [client].
///
/// Each Google account has a Drive of its own here, which only sign-ins
/// to that account see.
class FakeDrive {
  FakeDrive({this.account = 'jason@example.com'});

  /// Who signs in from now on; tests change it to sign in as someone else.
  String account;

  static const ownClient = GoogleClient(
    id: 'gpad-test.apps.googleusercontent.com',
    secret: 'GOCSPX-test',
  );

  final files = <String, FakeFile>{};

  /// Every request, as "METHOD /path".
  final requests = <String>[];

  /// The scopes the person leaves ticked when allowing GPad in.
  String grantedScope = GoogleAuth.scope;

  /// Files lists leave out, as a Drive whose search hasn't caught up yet.
  final hiddenFromLists = <String>{};

  /// At most this many files per page of a list.
  int pageSize = 1000;

  /// Runs before each request is answered, and after it changed things,
  /// for tests that have another computer act at those moments.
  Future<void> Function(http.Request request)? before;
  Future<void> Function(http.Request request)? after;

  final refreshTokens = <String>{};

  /// Whose each refresh token is, if not [account]'s.
  final _owners = <String, String>{};

  /// Whose each access token is.
  final _accessTokens = <String, String>{};
  final _codes =
      <
        String,
        ({String challenge, String redirect, String clientId, String account})
      >{};
  final _failures =
      <({String method, String path, int status, String? reason})>[];
  var _next = 0;
  var _clock = DateTime.utc(2026, 10, 29, 12);

  http.Client get client => MockClient(_handle);

  /// The next [times] requests to [path] by [method] get [status], with
  /// [reason] as Drive's error reason.
  void failNext(
    String method,
    String path,
    int status, {
    String? reason,
    int times = 1,
  }) {
    for (var i = 0; i < times; i++) {
      _failures.add((
        method: method,
        path: path,
        status: status,
        reason: reason,
      ));
    }
  }

  /// Makes every access token stop working, as an hour later.
  void expireAccessTokens() => _accessTokens.clear();

  /// Signs GPad out everywhere, as when the person removes its access.
  void revokeAll() {
    refreshTokens.clear();
    _accessTokens.clear();
  }

  /// Moves a file to the bin, with everything in it.
  void trash(String id) {
    files[id]!.trashed = true;
    for (final child in files.values.where((f) => f.parents.contains(id))) {
      trash(child.id);
    }
  }

  /// The files GPad tagged as [role], and not in the bin, in [owner]'s
  /// Drive or anyone's.
  List<FakeFile> tagged(String role, {String? owner}) => [
    for (final file in files.values)
      if (file.appProperties['gpad'] == role &&
          !file.trashed &&
          (owner == null || file.owner == owner))
        file,
  ];

  /// Acts as the browser: the person allows GPad in.
  Future<void> allow(Uri url) async {
    final params = url.queryParameters;
    if (params['code_challenge_method'] != 'S256' ||
        params['scope'] != GoogleAuth.scope ||
        params['response_type'] != 'code' ||
        params['access_type'] != 'offline') {
      throw StateError('Not how GPad should ask: $url');
    }
    final code = 'code-${_next++}';
    _codes[code] = (
      challenge: params['code_challenge']!,
      redirect: params['redirect_uri']!,
      clientId: params['client_id']!,
      account: account,
    );
    await comeBack(url, {'code': code, 'state': params['state']!});
  }

  /// Acts as the browser: the person says no.
  Future<void> deny(Uri url) => comeBack(url, {
    'error': 'access_denied',
    'state': url.queryParameters['state']!,
  });

  /// Sends the browser back to GPad's sign-in server with [params]. Uses
  /// a plain socket, which works in widget tests too.
  static Future<void> comeBack(Uri url, Map<String, String> params) async {
    final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
    final path = Uri(path: '/', queryParameters: params);
    final socket = await Socket.connect(redirect.host, redirect.port);
    socket.write(
      'GET $path HTTP/1.1\r\nHost: ${redirect.authority}\r\n'
      'Connection: close\r\n\r\n',
    );
    await socket.flush();
    await socket.drain<void>();
    socket.destroy();
  }

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    await before?.call(request);
    final failure = _failures.indexWhere(
      (f) => f.method == request.method && path.startsWith(f.path),
    );
    if (failure != -1) {
      final f = _failures.removeAt(failure);
      return _error(f.status, f.reason ?? 'backendError');
    }
    final response = request.url.host == 'oauth2.googleapis.com'
        ? _token(request)
        : _drive(request);
    await after?.call(request);
    return response;
  }

  http.Response _token(http.Request request) {
    final form = request.bodyFields;
    if (form['client_id'] != ownClient.id ||
        form['client_secret'] != ownClient.secret) {
      return _json(401, {'error': 'invalid_client'});
    }
    switch (form['grant_type']) {
      case 'authorization_code':
        final code = _codes.remove(form['code']);
        final verifier = form['code_verifier'] ?? '';
        final challenge = base64Url
            .encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', '');
        if (code == null ||
            code.redirect != form['redirect_uri'] ||
            code.clientId != form['client_id'] ||
            code.challenge != challenge) {
          return _json(400, {'error': 'invalid_grant'});
        }
        final refresh = 'refresh-${_next++}';
        refreshTokens.add(refresh);
        _owners[refresh] = code.account;
        return _json(200, {
          ..._newAccess(code.account),
          'refresh_token': refresh,
          'scope': grantedScope,
        });
      case 'refresh_token':
        final refresh = form['refresh_token'];
        if (!refreshTokens.contains(refresh)) {
          return _json(400, {'error': 'invalid_grant'});
        }
        return _json(200, {
          ..._newAccess(_owners[refresh] ?? account),
          'scope': grantedScope,
        });
    }
    return _json(400, {'error': 'unsupported_grant_type'});
  }

  Map<String, Object?> _newAccess(String owner) {
    final access = 'access-${_next++}';
    _accessTokens[access] = owner;
    return {'access_token': access, 'expires_in': 3599, 'token_type': 'Bearer'};
  }

  http.Response _drive(http.Request request) {
    final auth = request.headers['Authorization'] ?? '';
    final owner = auth.startsWith('Bearer ')
        ? _accessTokens[auth.substring(7)]
        : null;
    if (owner == null) return _error(401, 'authError');
    final path = request.url.path;
    final query = request.url.queryParameters;
    final method = request.method;
    if (path == '/drive/v3/about' && method == 'GET') {
      return _json(200, {
        'user': {'emailAddress': owner},
      });
    }
    if (path == '/drive/v3/files' && method == 'GET') {
      return _list(query, owner);
    }
    if (path == '/drive/v3/files' && method == 'POST') {
      return _create(
        jsonDecode(request.body) as Map<String, Object?>,
        null,
        owner,
      );
    }
    if (path == '/upload/drive/v3/files' && method == 'POST') {
      if (query['uploadType'] != 'multipart') return _error(400, 'badRequest');
      final (metadata, content) = _multipart(request);
      return _create(metadata, content, owner);
    }
    final upload = RegExp(r'^/upload/drive/v3/files/([^/]+)$').firstMatch(path);
    if (upload != null && method == 'PATCH') {
      final file = files[upload[1]];
      if (file == null || file.owner != owner) return _notFound(upload[1]!);
      file
        ..content = request.bodyBytes
        ..revision += 1;
      return _json(200, file.toJson());
    }
    final one = RegExp(r'^/drive/v3/files/([^/]+)$').firstMatch(path);
    if (one != null) {
      final file = files[one[1]];
      if (file == null || file.owner != owner) return _notFound(one[1]!);
      switch (method) {
        case 'GET' when query['alt'] == 'media':
          return http.Response.bytes(file.content ?? Uint8List(0), 200);
        case 'GET':
          return _json(200, file.toJson());
        case 'DELETE':
          _delete(file.id);
          return http.Response('', 204);
      }
    }
    return _error(400, 'badRequest');
  }

  http.Response _list(Map<String, String> query, String owner) {
    final q = query['q'] ?? '';
    final matching = [
      for (final file in files.values.toList().reversed)
        if (file.owner == owner &&
            !hiddenFromLists.contains(file.id) &&
            _matches(file, q))
          file,
    ];
    final size = [
      int.parse(query['pageSize'] ?? '100'),
      pageSize,
    ].reduce((a, b) => a < b ? a : b);
    final start = int.parse(query['pageToken'] ?? '0');
    final page = matching.skip(start).take(size).toList();
    final more = start + size < matching.length;
    return _json(200, {
      'files': [for (final f in page) f.toJson()],
      if (more) 'nextPageToken': '${start + size}',
    });
  }

  http.Response _create(
    Map<String, Object?> metadata,
    Uint8List? content,
    String owner,
  ) {
    final parents = [
      for (final p in metadata['parents'] as List<Object?>? ?? const [])
        p as String,
    ];
    for (final parent in parents) {
      if (files[parent] case final folder?
          when folder.isFolder && folder.owner == owner) {
        continue;
      }
      return _notFound(parent);
    }
    _clock = _clock.add(const Duration(milliseconds: 1));
    final file = FakeFile(
      id: 'file${_next++}',
      name: metadata['name'] as String,
      mimeType: metadata['mimeType'] as String? ?? 'application/octet-stream',
      parents: parents.isEmpty ? ['root'] : parents,
      appProperties: {
        for (final MapEntry(:key, :value)
            in (metadata['appProperties'] as Map<String, Object?>? ?? {})
                .entries)
          key: value as String,
      },
      createdTime: _clock,
      owner: owner,
      content: content,
    );
    // In a folder in the bin, it's in the bin too.
    file.trashed = parents.any((p) => files[p]!.trashed);
    files[file.id] = file;
    return _json(200, file.toJson());
  }

  void _delete(String id) {
    files.remove(id);
    for (final child in [
      for (final f in files.values)
        if (f.parents.contains(id)) f.id,
    ]) {
      _delete(child);
    }
  }

  static (Map<String, Object?>, Uint8List) _multipart(http.Request request) {
    final type = request.headers['Content-Type'] ?? '';
    final boundary = RegExp(r'boundary=(\S+)').firstMatch(type)![1]!;
    // Latin-1 maps bytes to characters one to one, so the contents survive.
    final body = latin1.decode(request.bodyBytes);
    final parts = body.split('--$boundary');
    Map<String, Object?>? metadata;
    Uint8List? content;
    for (final part in parts) {
      final split = part.indexOf('\r\n\r\n');
      if (split == -1) continue;
      final headers = part.substring(0, split);
      var data = part.substring(split + 4);
      if (data.endsWith('\r\n')) data = data.substring(0, data.length - 2);
      if (headers.contains('application/json') && metadata == null) {
        metadata = jsonDecode(
          utf8.decode(latin1.encode(data)),
        ) as Map<String, Object?>;
      } else {
        content = Uint8List.fromList(latin1.encode(data));
      }
    }
    return (metadata!, content!);
  }

  static bool _matches(FakeFile file, String q) =>
      _clauses(q).every((clause) => _clause(file, clause));

  /// Splits a query at its top-level ands.
  static List<String> _clauses(String q) {
    final clauses = <String>[];
    var depth = 0;
    var quoted = false;
    var start = 0;
    for (var i = 0; i < q.length; i++) {
      final c = q[i];
      if (quoted) {
        if (c == r'\') {
          i++;
        } else if (c == "'") {
          quoted = false;
        }
      } else if (c == "'") {
        quoted = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
      } else if (depth == 0 && q.startsWith(' and ', i)) {
        clauses.add(q.substring(start, i));
        start = i + 5;
        i += 4;
      }
    }
    clauses.add(q.substring(start));
    return [
      for (final c in clauses)
        if (c.trim().isNotEmpty) c.trim(),
    ];
  }

  static const _string = r"'((?:[^'\\]|\\.)*)'";

  static String _unquote(String s) =>
      s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);

  static bool _clause(FakeFile file, String clause) {
    if (clause == 'trashed = false') return !file.trashed;
    if (RegExp('^appProperties has \\{ key=$_string and value=$_string \\}\$')
            .firstMatch(clause)
        case final m?) {
      return file.appProperties[_unquote(m[1]!)] == _unquote(m[2]!);
    }
    if (RegExp('^$_string in parents\$').firstMatch(clause) case final m?) {
      return file.parents.contains(_unquote(m[1]!));
    }
    if (RegExp('^name = $_string\$').firstMatch(clause) case final m?) {
      return file.name == _unquote(m[1]!);
    }
    throw UnsupportedError('FakeDrive can\'t search for "$clause"');
  }

  static http.Response _notFound(String id) =>
      _error(404, 'notFound', message: 'File not found: $id.');

  static http.Response _error(int status, String reason, {String? message}) =>
      _json(status, {
        'error': {
          'code': status,
          'message': message ?? reason,
          'errors': [
            {'reason': reason, 'message': message ?? reason},
          ],
        },
      });

  static http.Response _json(int status, Object json) => http.Response(
    jsonEncode(json),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}
