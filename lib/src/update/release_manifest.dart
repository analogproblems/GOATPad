import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

/// Thrown when GPad can't update itself: the release can't be reached,
/// isn't signed by GPad's key, or its download doesn't match.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => 'UpdateException: $message';
}

/// A version like 0.2.0, the part of `pubspec.yaml`'s before the `+`.
class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch);

  /// [text] as a version, or null if it isn't three numbers with dots.
  static Version? tryParse(String text) {
    final match = RegExp(r'^(\d{1,9})\.(\d{1,9})\.(\d{1,9})$').firstMatch(text);
    if (match == null) return null;
    return Version(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
  }

  final int major;
  final int minor;
  final int patch;

  bool operator >(Version other) => compareTo(other) > 0;

  @override
  int compareTo(Version other) => major != other.major
      ? major.compareTo(other.major)
      : minor != other.minor
      ? minor.compareTo(other.minor)
      : patch.compareTo(other.patch);

  @override
  bool operator ==(Object other) => other is Version && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// One download in a release.
class ReleaseFile {
  const ReleaseFile({
    required this.name,
    required this.size,
    required this.sha256,
  });

  /// The asset's name in the release, like `GPad-0.2.0-x86_64.AppImage`.
  final String name;
  final int size;

  /// Its SHA-256, as lowercase hex.
  final String sha256;
}

/// What a release holds, as CI wrote and signed it: `gpad-update.json`,
/// with its Ed25519 signature next to it in `gpad-update.json.sig`.
///
/// Only the signature makes it trusted. The sizes and SHA-256 sums it holds
/// then vouch for the downloads, and its version keeps an old release from
/// being passed off as new.
class ReleaseManifest {
  const ReleaseManifest({required this.version, required this.files});

  static const fileName = 'gpad-update.json';
  static const signatureName = 'gpad-update.json.sig';
  static const formatVersion = 1;

  /// The most of a manifest or signature GPad reads.
  static const maxBytes = 64 << 10;

  /// The download for each kind of installation.
  static const windowsZip = 'windows-x64-zip';
  static const appImage = 'linux-x64-appimage';
  static const deb = 'linux-x64-deb';

  final Version version;

  /// Downloads by kind, like [appImage].
  final Map<String, ReleaseFile> files;

  /// The manifest in [bytes], if [signature] (base64, as in the `.sig`
  /// file) is [publicKey]'s signature of exactly those bytes. Throws
  /// [UpdateException] if it isn't, or the manifest makes no sense.
  static ReleaseManifest verify(
    Sodium sodium,
    Uint8List bytes,
    Uint8List signature,
    Uint8List publicKey,
  ) {
    final Uint8List signed;
    try {
      signed = base64.decode(ascii.decode(signature).trim());
    } on FormatException {
      throw const UpdateException('The release\'s signature is damaged');
    }
    final sign = sodium.crypto.sign;
    if (signed.length != sign.bytes ||
        publicKey.length != sign.publicKeyBytes ||
        !sign.verifyDetached(
          message: bytes,
          signature: signed,
          publicKey: publicKey,
        )) {
      throw const UpdateException(
        'The release isn\'t signed by GPad\'s key, so GPad won\'t install it',
      );
    }
    try {
      return _decode(bytes);
    } on FormatException catch (e) {
      throw UpdateException('The release\'s manifest is wrong (${e.message})');
    }
  }

  static ReleaseManifest _decode(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, Object?> || json['gpad-update'] != formatVersion) {
      throw const FormatException('not a manifest this GPad can read');
    }
    final version = switch (json['version']) {
      final String text => Version.tryParse(text),
      _ => null,
    };
    if (version == null) throw const FormatException('no version');
    final files = json['files'];
    if (files is! Map<String, Object?>) {
      throw const FormatException('no files');
    }
    return ReleaseManifest(
      version: version,
      files: {
        for (final MapEntry(:key, :value) in files.entries)
          key: switch (value) {
            {
              'name': final String name,
              'size': final int size,
              'sha256': final String sha256,
            }
                when _name.hasMatch(name) &&
                    size > 0 &&
                    _sha256.hasMatch(sha256) =>
              ReleaseFile(name: name, size: size, sha256: sha256),
            _ => throw FormatException('bad entry for $key'),
          },
      },
    );
  }

  /// The raw Ed25519 key in [spki]: a public key's base64 line as OpenSSL
  /// writes it to a PEM file. Null if it isn't one.
  static Uint8List? publicKeyFrom(String spki) {
    final Uint8List der;
    try {
      der = base64.decode(spki.trim());
    } on FormatException {
      return null;
    }
    // How every Ed25519 SubjectPublicKeyInfo starts (RFC 8410).
    const prefix = [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70];
    // Then the key: a bit string of 33 bytes, the first one 0.
    const keyPrefix = [...prefix, 0x03, 0x21, 0x00];
    if (der.length != keyPrefix.length + 32) return null;
    for (var i = 0; i < keyPrefix.length; i++) {
      if (der[i] != keyPrefix[i]) return null;
    }
    return der.sublist(keyPrefix.length);
  }

  static final _name = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');
}
