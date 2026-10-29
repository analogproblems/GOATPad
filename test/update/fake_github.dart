import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:goatpad/src/update/release_manifest.dart';
import 'package:goatpad/src/update/updater.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const repository = 'analogproblems/GOATPad';

/// GitHub's releases, as far as GPad's updates use them: the newest
/// release, signed with [keys], served to [client].
class FakeGitHub {
  FakeGitHub(this.sodium) : keys = sodium.crypto.sign.keyPair();

  final SodiumSumo sodium;
  final KeyPair keys;

  /// The files of the newest release, by name, and its version.
  final files = <String, Uint8List>{};
  String? version;

  /// The manifest's own entries, if they should differ from [files].
  Map<String, Object?>? entries;

  /// Signs with another key instead.
  bool badSignature = false;
  final requests = <String>[];
  Object? failWith;

  UpdateSource get source =>
      UpdateSource(repository: repository, publicKey: keys.publicKey);

  void release(String version, Map<String, (String, Uint8List)> downloads) {
    this.version = version;
    files.clear();
    final listed = <String, Object?>{};
    for (final MapEntry(key: kind, value: (name, bytes)) in downloads.entries) {
      files[name] = bytes;
      listed[kind] = {
        'name': name,
        'size': bytes.length,
        'sha256': '${sha256.convert(bytes)}',
      };
    }
    entries = listed;
  }

  Uint8List get _manifest => Uint8List.fromList(
    utf8.encode(
      jsonEncode({'gpad-update': 1, 'version': version, 'files': entries}),
    ),
  );

  Uint8List get _signature {
    final key = badSignature
        ? sodium.crypto.sign.keyPair().secretKey
        : keys.secretKey;
    return Uint8List.fromList(
      utf8.encode(
        base64.encode(
          sodium.crypto.sign.detached(message: _manifest, secretKey: key),
        ),
      ),
    );
  }

  late final client = MockClient((request) async {
    requests.add(request.url.path);
    if (failWith case final error?) throw error;
    final path = request.url.path;
    final base = '/$repository/releases';
    final version = this.version;
    if (version == null) return http.Response('Not Found', 404);
    final Uint8List? body;
    if (path == '$base/latest/download/${ReleaseManifest.fileName}') {
      body = _manifest;
    } else if (path.startsWith('$base/download/v$version/')) {
      final name = path.substring('$base/download/v$version/'.length);
      body = name == ReleaseManifest.signatureName ? _signature : files[name];
    } else {
      body = null;
    }
    return body == null
        ? http.Response('Not Found', 404)
        : http.Response.bytes(body, 200);
  });
}
