import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/update/release_manifest.dart';
import 'package:goatpad/src/version.dart';
import 'package:sodium/sodium_sumo.dart';

/// Made with OpenSSL, as CI makes them:
///   openssl genpkey -algorithm ed25519 -out key.pem
///   openssl pkey -in key.pem -pubout   (its middle line)
///   openssl pkeyutl -sign -inkey key.pem -rawin -in gpad-update.json | base64
const _openSslKey =
    'MCowBQYDK2VwAyEArjhiceO4b++tAp7C7BDedcexrgWBrQ4YYzaqMxXVqH8=';
const _openSslManifest =
    '{"gpad-update":1,"version":"0.2.0","files":{"linux-x64-appimage":'
    '{"name":"GPad-0.2.0-x86_64.AppImage","size":3,"sha256":'
    '"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}}}';
const _openSslSignature =
    'XLXc+LPgAPzdjtxIffZA9VI48ACsdy5trq+CHW4KJDz/YmeZZsW41x4z2ksPtW+1zS68NOC+'
    'h1ONyJbW97CtBg==';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  group('versions', () {
    test('compare by number, not by text', () {
      final v = Version.tryParse;
      expect(v('0.10.0')! > v('0.9.9')!, isTrue);
      expect(v('1.0.0')! > v('0.99.99')!, isTrue);
      expect(v('0.2.1')! > v('0.2.0')!, isTrue);
      expect(v('0.2.0')! > v('0.2.0')!, isFalse);
      expect(v('0.2.0'), v('0.2.0'));
      for (final bad in [
        '',
        '1',
        '1.2',
        '1.2.3.4',
        'v1.2.3',
        '1.2.3+4',
        '1.2.x',
      ]) {
        expect(v(bad), isNull, reason: bad);
      }
    });

    test('this GPad\'s is the one in pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final match = RegExp(
        r'^version: *([0-9.]+)\+',
        multiLine: true,
      ).firstMatch(pubspec);
      expect(gpadVersion, match![1]);
      expect(Version.tryParse(gpadVersion), isNotNull);
    });
  });

  group('signed manifests', () {
    final key = ReleaseManifest.publicKeyFrom(_openSslKey)!;

    test('OpenSSL\'s signatures check out', () {
      final manifest = ReleaseManifest.verify(
        sodium,
        _bytes(_openSslManifest),
        _bytes('$_openSslSignature\n'),
        key,
      );
      expect(manifest.version, const Version(0, 2, 0));
      final file = manifest.files[ReleaseManifest.appImage]!;
      expect(file.name, 'GPad-0.2.0-x86_64.AppImage');
      expect(file.size, 3);
    });

    test('a changed byte, another key or a damaged signature is refused', () {
      final changed = _bytes(_openSslManifest.replaceFirst('0.2.0', '0.2.1'));
      final other = sodium.crypto.sign.keyPair();
      for (final (bytes, signature, publicKey) in [
        (changed, _bytes(_openSslSignature), key),
        (_bytes(_openSslManifest), _bytes(_openSslSignature), other.publicKey),
        (_bytes(_openSslManifest), _bytes('not base64!'), key),
        (_bytes(_openSslManifest), _bytes(base64.encode([1, 2, 3])), key),
      ]) {
        expect(
          () => ReleaseManifest.verify(sodium, bytes, signature, publicKey),
          throwsA(isA<UpdateException>()),
        );
      }
    });

    test('a signed manifest must still make sense', () {
      final keys = sodium.crypto.sign.keyPair();
      Uint8List sign(Uint8List bytes) => _bytes(
        base64.encode(
          sodium.crypto.sign.detached(
            message: bytes,
            secretKey: keys.secretKey,
          ),
        ),
      );
      String file({String name = 'GPad.zip', Object size = 3, String? sha}) =>
          jsonEncode({
            'gpad-update': 1,
            'version': '0.2.0',
            'files': {
              'windows-x64-zip': {
                'name': name,
                'size': size,
                'sha256': sha ?? 'a' * 64,
              },
            },
          });
      expect(
        ReleaseManifest.verify(
          sodium,
          _bytes(file()),
          sign(_bytes(file())),
          keys.publicKey,
        ).files.keys,
        ['windows-x64-zip'],
      );
      for (final bad in [
        file(name: '../gpad.exe'),
        file(name: 'dir/GPad.zip'),
        file(size: 0),
        file(size: '3'),
        file(sha: 'A' * 64),
        file(sha: 'a' * 63),
        '{"gpad-update":2,"version":"0.2.0","files":{}}',
        '{"gpad-update":1,"version":"v0.2.0","files":{}}',
        '{"gpad-update":1,"version":"0.2.0"}',
        '[]',
        'not JSON',
      ]) {
        final bytes = _bytes(bad);
        expect(
          () => ReleaseManifest.verify(
            sodium,
            bytes,
            sign(bytes),
            keys.publicKey,
          ),
          throwsA(isA<UpdateException>()),
          reason: bad,
        );
      }
    });

    test('only an Ed25519 public key is taken', () {
      expect(ReleaseManifest.publicKeyFrom(_openSslKey), hasLength(32));
      // An X25519 key, which is for encrypting, not signing.
      expect(
        ReleaseManifest.publicKeyFrom(
          'MCowBQYDK2VuAyEArjhiceO4b++tAp7C7BDedcexrgWBrQ4YYzaqMxXVqH8=',
        ),
        isNull,
      );
      expect(ReleaseManifest.publicKeyFrom(''), isNull);
      expect(ReleaseManifest.publicKeyFrom('not base64!'), isNull);
    });
  });
}
