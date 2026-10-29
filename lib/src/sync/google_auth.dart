import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:http/http.dart' as http;

import 'sync_backend.dart';

/// A Google Cloud OAuth client of the "Desktop app" type, which GPad signs
/// in to Google as.
///
/// Google treats a desktop app's secret as public, since anything shipped
/// in an app can be dug out of it. Sign-in is protected instead by PKCE
/// and by Google sending the browser back only to this computer.
class GoogleClient {
  const GoogleClient({required this.id, required this.secret});

  factory GoogleClient.fromJson(Map<String, Object?> json) =>
      GoogleClient(id: json['id'] as String, secret: json['secret'] as String);

  /// GPad's own client, which release builds get from CI secrets, or null
  /// in a build without it.
  static GoogleClient? get builtIn => _builtInId.isEmpty
      ? null
      : const GoogleClient(id: _builtInId, secret: _builtInSecret);

  static const _builtInId = String.fromEnvironment('GPAD_GOOGLE_CLIENT_ID');
  static const _builtInSecret = String.fromEnvironment(
    'GPAD_GOOGLE_CLIENT_SECRET',
  );

  final String id;
  final String secret;

  Map<String, Object?> toJson() => {'id': id, 'secret': secret};

  @override
  bool operator ==(Object other) =>
      other is GoogleClient && other.id == id && other.secret == secret;

  @override
  int get hashCode => Object.hash(id, secret);
}

/// Thrown when signing in to Google fails, or is cancelled.
class GoogleAuthException extends SyncBackendException {
  const GoogleAuthException(super.message);
}

/// Thrown when Google no longer takes GPad's sign-in: it was revoked or
/// expired, or there never was one on this computer. Signing in again
/// puts it right.
class GoogleSignInNeeded extends SyncBackendException {
  const GoogleSignInNeeded([
    super.message = 'Google signed GPad out. Sign in again to keep syncing.',
  ]);
}

/// GPad's sign-in to one Google account: a refresh token, which lasts and
/// is kept in the keychain, and the access tokens it gets for an hour at a
/// time.
///
/// GPad never revokes a sign-in, only forgets it: revoking one removes
/// GPad's access to the account altogether, which would sign out every
/// other computer syncing with it too.
class GoogleAuth {
  GoogleAuth(
    this.client,
    this.refreshToken, {
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : _http = httpClient ?? http.Client(),
       _clock = clock ?? DateTime.now;

  /// The only permission GPad asks for: the files it makes in Drive, and
  /// nothing else there.
  static const scope = 'https://www.googleapis.com/auth/drive.file';

  static final authEndpoint = Uri.https(
    'accounts.google.com',
    '/o/oauth2/v2/auth',
  );
  static final tokenEndpoint = Uri.https('oauth2.googleapis.com', '/token');

  final GoogleClient client;
  final String refreshToken;
  final http.Client _http;
  final DateTime Function() _clock;

  String? _access;
  DateTime? _expires;
  Future<String>? _refreshing;

  static final _random = Random.secure();

  /// Reads a sign-in that [secret] saved in the keychain, or null if it
  /// isn't one.
  static GoogleAuth? fromSecret(
    GoogleClient client,
    Uint8List secret, {
    http.Client? httpClient,
  }) {
    try {
      if (jsonDecode(utf8.decode(secret))
          case {'client': final String id, 'refreshToken': final String token}
          when id == client.id) {
        return GoogleAuth(client, token, httpClient: httpClient);
      }
    } on FormatException {
      // Not one of GPad's.
    }
    return null;
  }

  /// What the keychain keeps: the refresh token, and which client it
  /// belongs to.
  Uint8List toSecret() => utf8.encode(
    jsonEncode({'client': client.id, 'refreshToken': refreshToken}),
  );

  /// Signs in to Google in the browser. [open] shows Google's page, which
  /// asks the person to allow GPad into their Drive, then sends the browser
  /// back to a server GPad runs on this computer until then.
  ///
  /// Fails if the person refuses, or leaves the Drive permission unticked,
  /// or [cancel] completes first.
  static Future<GoogleAuth> signIn(
    GoogleClient client, {
    required Future<void> Function(Uri url) open,
    Future<void>? cancel,
    http.Client? httpClient,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://127.0.0.1:${server.port}';
      final verifier = _randomString(32);
      final state = _randomString(16);
      final challenge = _unpadded(
        base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes),
      );
      final code = _waitForCode(server, state)
        // Fails once the server closes, if GPad stopped waiting first.
        ..ignore();
      await open(
        authEndpoint.replace(
          queryParameters: {
            'client_id': client.id,
            'redirect_uri': redirect,
            'response_type': 'code',
            'scope': scope,
            'code_challenge': challenge,
            'code_challenge_method': 'S256',
            'state': state,
            // A refresh token, every time, so GPad stays signed in.
            'access_type': 'offline',
            'prompt': 'consent',
          },
        ),
      );
      final String authorized;
      try {
        authorized = await Future.any([
          code,
          if (cancel != null)
            cancel.then<String>(
              (_) => throw const GoogleAuthException('Sign-in was cancelled.'),
            ),
        ]).timeout(timeout);
      } on TimeoutException {
        throw const GoogleAuthException(
          'Sign-in took too long, so GPad stopped waiting. Try again.',
        );
      }
      final http = httpClient ?? _defaultClient();
      final tokens = await _post(http, tokenEndpoint, {
        'grant_type': 'authorization_code',
        'code': authorized,
        'client_id': client.id,
        'client_secret': client.secret,
        'redirect_uri': redirect,
        'code_verifier': verifier,
      });
      final granted = (tokens['scope'] as String? ?? '').split(' ');
      if (!granted.contains(scope)) {
        throw const GoogleAuthException(
          'GPad needs permission to see and change the files it makes in '
          'your Google Drive. Sign in again and leave that box ticked.',
        );
      }
      final refresh = tokens['refresh_token'];
      if (refresh is! String || refresh.isEmpty) {
        throw const GoogleAuthException(
          'Google didn\'t give GPad a lasting sign-in. Try again.',
        );
      }
      return GoogleAuth(client, refresh, httpClient: http).._take(tokens);
    } finally {
      await server.close(force: true);
    }
  }

  /// An access token good for at least another minute.
  Future<String> accessToken() {
    final access = _access;
    final expires = _expires;
    if (access != null &&
        expires != null &&
        _clock().isBefore(expires.subtract(const Duration(minutes: 1)))) {
      return Future.value(access);
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  /// Forgets [token] after Google refused it, so the next request gets a
  /// new one.
  void refused(String token) {
    if (_access == token) _access = null;
  }

  Future<String> _refresh() async {
    final tokens = await _post(_http, tokenEndpoint, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': client.id,
      'client_secret': client.secret,
    });
    return _take(tokens);
  }

  String _take(Map<String, Object?> tokens) {
    final access = tokens['access_token'];
    final expiresIn = tokens['expires_in'];
    if (access is! String || expiresIn is! int) {
      throw const SyncBackendException('Google sent a sign-in GPad can\'t use');
    }
    _access = access;
    _expires = _clock().add(Duration(seconds: expiresIn));
    return access;
  }

  static http.Client _defaultClient() => http.Client();

  /// Waits for Google to send the browser back with a code, and tells the
  /// person in the browser how it went.
  static Future<String> _waitForCode(HttpServer server, String state) async {
    await for (final request in server) {
      final params = request.uri.queryParameters;
      // Anything else, like the browser asking for an icon, isn't Google
      // coming back from this sign-in.
      if (request.method != 'GET' ||
          request.uri.path != '/' ||
          params['state'] != state) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      final error = params['error'];
      final code = params['code'];
      final ok = error == null && code != null && code.isNotEmpty;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..headers.set('Cache-Control', 'no-store')
        ..write(
          ok
              // Not "signed in" yet: GPad still has to swap the code.
              ? _page(
                  'Back to GPad',
                  'You can close this tab. GPad says there whether signing '
                      'in worked.',
                )
              : _page(
                  'GPad isn\'t signed in',
                  'You can close this tab and try again in GPad.',
                ),
        );
      await request.response.close();
      if (ok) return code;
      throw GoogleAuthException(
        error == 'access_denied'
            ? 'Google sign-in was cancelled, so GPad can\'t sync through '
                  'Drive.'
            : 'Google sign-in didn\'t work (${error ?? 'no code'}).',
      );
    }
    throw const GoogleAuthException('Sign-in was cancelled.');
  }

  static String _page(String title, String text) =>
      '<!doctype html><meta charset="utf-8"><title>GPad</title>'
      '<body style="font-family: sans-serif; margin: 4em auto; '
      'max-width: 32em"><h1>$title</h1><p>$text</p></body>';

  /// Posts a form to Google's sign-in service and returns its answer.
  static Future<Map<String, Object?>> _post(
    http.Client client,
    Uri url,
    Map<String, String> form,
  ) async {
    final http.Response response;
    try {
      response = await client
          .post(url, body: form)
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const SyncBackendException('Google didn\'t answer in time');
    } on SocketException catch (e) {
      throw SyncBackendException('Can\'t reach Google (${e.message})');
    } on http.ClientException catch (e) {
      throw SyncBackendException('Can\'t reach Google (${e.message})');
    }
    Object? json;
    try {
      json = jsonDecode(response.body);
    } on FormatException {
      json = null;
    }
    final body = json is Map<String, Object?>
        ? json
        : const <String, Object?>{};
    if (response.statusCode == 200) return body;
    switch (body['error']) {
      case 'invalid_grant':
        throw const GoogleSignInNeeded();
      case 'invalid_client' || 'unauthorized_client':
        throw const GoogleAuthException(
          'Google doesn\'t accept GPad\'s sign-in client. If you entered '
          'your own, check its ID and secret.',
        );
    }
    if (response.statusCode >= 500) {
      throw SyncBackendException(
        'Google\'s sign-in service is having trouble '
        '(${response.statusCode}). GPad will try again.',
      );
    }
    throw GoogleAuthException(
      'Google refused GPad\'s sign-in '
      '(${body['error_description'] ?? body['error'] ?? response.statusCode}).',
    );
  }

  static String _randomString(int bytes) => _unpadded(
    base64Url.encode([for (var i = 0; i < bytes; i++) _random.nextInt(256)]),
  );

  static String _unpadded(String base64) => base64.replaceAll('=', '');
}
