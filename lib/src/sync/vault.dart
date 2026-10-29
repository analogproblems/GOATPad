import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

/// Thrown when an encrypted file can't be opened: it was changed, damaged,
/// or encrypted with another key.
class VaultException implements Exception {
  const VaultException(this.message);

  final String message;

  @override
  String toString() => 'VaultException: $message';
}

/// How hard Argon2id works to turn a passphrase into a key.
class KdfParams {
  const KdfParams({required this.ops, required this.mem});

  /// libsodium's "moderate" setting: 3 passes over 256 MiB, under a second
  /// on a desktop.
  static const moderate = KdfParams(ops: 3, mem: 256 << 20);

  /// Fast and weak, for tests only.
  static const insecureForTests = KdfParams(ops: 1, mem: 8 << 20);

  final int ops;

  /// Bytes of memory.
  final int mem;

  // Limits for headers read from the sync folder, so a damaged or hostile
  // one can't ask for minutes of work or gigabytes of memory.
  static const _maxOps = 10;
  static const _maxMem = 1 << 30;
}

/// The vault file, `gpad-vault.json`, at the top of the sync folder. It is
/// not secret: it holds the random key that encrypts every note, itself
/// encrypted twice, once with a key made from the passphrase and once with
/// the recovery key.
class VaultHeader {
  const VaultHeader({
    required this.id,
    required this.createdAt,
    required this.kdf,
    required this.salt,
    required this.passphraseBox,
    required this.recoveryBox,
    required this.check,
  });

  factory VaultHeader.decode(List<int> bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('The vault file isn\'t JSON');
    }
    if (json is! Map<String, Object?> || json['gpad'] != 'vault') {
      throw const FormatException('Not a GPad vault file');
    }
    if (json['version'] != formatVersion) {
      throw const FormatException(
        'This vault was made by a newer GPad. Update GPad to sync with it.',
      );
    }
    final kdf = _map(json, 'kdf');
    if (kdf['alg'] != 'argon2id13') {
      throw const FormatException('Unknown key derivation');
    }
    final ops = kdf['ops'];
    final mem = kdf['mem'];
    if (ops is! int || ops < 1 || ops > KdfParams._maxOps) {
      throw const FormatException('Bad key derivation passes');
    }
    if (mem is! int || mem < (8 << 20) || mem > KdfParams._maxMem) {
      throw const FormatException('Bad key derivation memory');
    }
    final id = json['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('Bad vault id');
    }
    final salt = _bytes(kdf, 'salt');
    if (salt.length != _saltBytes) throw const FormatException('Bad salt');
    return VaultHeader(
      id: id,
      createdAt: switch (json['created']) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        _ => throw const FormatException('Bad creation time'),
      },
      kdf: KdfParams(ops: ops, mem: mem),
      salt: salt,
      passphraseBox: _box(json, 'passphrase', _keyBytes),
      recoveryBox: _box(json, 'recovery', _keyBytes),
      // An empty message.
      check: _box(json, 'check', 0),
    );
  }

  static const formatVersion = 1;

  // Sizes in libsodium's Argon2id and XChaCha20-Poly1305, checked here
  // since libsodium throws a RangeError, not a SodiumException, for others.
  // VaultCrypto makes sure they match.
  static const _saltBytes = 16;
  static const _nonceBytes = 24;
  static const _tagBytes = 16;
  static const _keyBytes = 32;

  static final _idPattern = RegExp(r'^[0-9a-f]{32}$');

  /// Random, and part of every record's authenticated data, so records
  /// can't be moved from one vault to another.
  final String id;
  final DateTime createdAt;
  final KdfParams kdf;
  final Uint8List salt;
  final SealedBox passphraseBox;
  final SealedBox recoveryBox;

  /// An empty message sealed with the note key, to tell whether a key from
  /// the keychain belongs to this vault.
  final SealedBox check;

  List<int> encode() => utf8.encode(
    const JsonEncoder.withIndent('  ').convert({
      'gpad': 'vault',
      'version': formatVersion,
      'id': id,
      'created': createdAt.millisecondsSinceEpoch,
      'kdf': {
        'alg': 'argon2id13',
        'ops': kdf.ops,
        'mem': kdf.mem,
        'salt': base64.encode(salt),
      },
      'passphrase': passphraseBox.toJson(),
      'recovery': recoveryBox.toJson(),
      'check': check.toJson(),
    }),
  );

  /// The box under [key], sealing a message of [messageBytes].
  static SealedBox _box(
    Map<String, Object?> json,
    String key,
    int messageBytes,
  ) {
    final box = SealedBox.fromJson(_map(json, key));
    if (box.nonce.length != _nonceBytes ||
        box.sealed.length != messageBytes + _tagBytes) {
      throw FormatException('Bad $key box');
    }
    return box;
  }

  static Map<String, Object?> _map(Map<String, Object?> json, String key) =>
      switch (json[key]) {
        final Map<String, Object?> map => map,
        _ => throw FormatException('Missing $key'),
      };
}

/// A nonce and the ciphertext sealed with it, in the vault file.
class SealedBox {
  const SealedBox(this.nonce, this.sealed);

  factory SealedBox.fromJson(Map<String, Object?> json) =>
      SealedBox(_bytes(json, 'nonce'), _bytes(json, 'box'));

  final Uint8List nonce;
  final Uint8List sealed;

  Map<String, String> toJson() => {
    'nonce': base64.encode(nonce),
    'box': base64.encode(sealed),
  };
}

Uint8List _bytes(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Missing $key');
  try {
    return base64.decode(value);
  } on FormatException {
    throw FormatException('Bad $key');
  }
}

/// An unlocked vault: seals and opens records with the note key.
class Vault {
  Vault._(this._sodium, this.id, this._key);

  final SodiumSumo _sodium;
  final String id;
  final SecureKey _key;

  static final _magic = Uint8List.fromList([0x47, 0x50, 0x41, 0x44, 1]);

  Aead get _aead => _sodium.crypto.aeadXChaCha20Poly1305IETF;

  /// The note key, for the keychain.
  Uint8List exportKey() => _key.extractBytes();

  /// Whether [header] holds this vault's note key, as it does after the
  /// passphrase or recovery key changed on any computer.
  bool belongsTo(VaultHeader header) {
    if (header.id != id) return false;
    try {
      _aead.decrypt(
        cipherText: header.check.sealed,
        nonce: header.check.nonce,
        key: _key,
        additionalData: VaultCrypto._boxData(id, 'check'),
      );
      return true;
    } on SodiumException {
      return false;
    }
  }

  /// [plaintext] padded, encrypted and authenticated as record [recordId]
  /// of this vault: "GPAD", a format byte, the nonce, then the ciphertext.
  Uint8List seal(String recordId, List<int> plaintext) {
    final nonce = _sodium.randombytes.buf(_aead.nonceBytes);
    final sealed = _aead.encrypt(
      message: pad(plaintext),
      nonce: nonce,
      key: _key,
      additionalData: _recordData(recordId),
    );
    return Uint8List.fromList([..._magic, ...nonce, ...sealed]);
  }

  /// The plaintext of [file], which must have been sealed by [seal] as
  /// record [recordId] of this vault.
  Uint8List open(String recordId, Uint8List file) {
    final start = _magic.length + _aead.nonceBytes;
    if (file.length < start + _aead.aBytes) {
      throw const VaultException('The file is too short');
    }
    for (var i = 0; i < _magic.length; i++) {
      if (file[i] != _magic[i]) {
        throw const VaultException('Not a GPad record this version can read');
      }
    }
    final Uint8List padded;
    try {
      padded = _aead.decrypt(
        cipherText: file.sublist(start),
        nonce: file.sublist(_magic.length, start),
        key: _key,
        additionalData: _recordData(recordId),
      );
    } on SodiumException {
      throw const VaultException(
        'The file was changed or damaged, or belongs to another vault',
      );
    }
    return unpad(padded);
  }

  Uint8List _recordData(String recordId) =>
      Uint8List.fromList([..._magic, ...utf8.encode('$id/$recordId')]);

  void dispose() => _key.dispose();

  /// [data] followed by 0x80 and zeros, up to a size that hides most of
  /// its length: at least 256 bytes, then at most about 12% more than
  /// needed (the Padmé scheme), so a note's size shows only roughly.
  static Uint8List pad(List<int> data) {
    final length = max(256, _padme(data.length + 1));
    return Uint8List(length)
      ..setAll(0, data)
      ..[data.length] = 0x80;
  }

  static Uint8List unpad(Uint8List padded) {
    var end = padded.length - 1;
    while (end >= 0 && padded[end] == 0) {
      end--;
    }
    if (end < 0 || padded[end] != 0x80) {
      throw const VaultException('Bad padding');
    }
    return padded.sublist(0, end);
  }

  // https://lbarman.ch/blog/padme/
  static int _padme(int length) {
    if (length < 2) return length;
    final e = length.bitLength - 1;
    final s = e.bitLength;
    final lastBits = e - s;
    final mask = (1 << lastBits) - 1;
    return (length + mask) & ~mask;
  }
}

/// A vault made by [VaultCrypto.create], and its recovery key, which is
/// shown once and never stored.
class NewVault {
  const NewVault(this.header, this.vault, this.recoveryKey);

  final VaultHeader header;
  final Vault vault;
  final String recoveryKey;
}

/// Makes and unlocks vaults, with libsodium: Argon2id turns the passphrase
/// into a key, and XChaCha20-Poly1305 encrypts.
class VaultCrypto {
  VaultCrypto(this._sodium)
    : assert(
        _sodium.crypto.pwhash.saltBytes == VaultHeader._saltBytes &&
            _sodium.crypto.aeadXChaCha20Poly1305IETF.nonceBytes ==
                VaultHeader._nonceBytes &&
            _sodium.crypto.aeadXChaCha20Poly1305IETF.aBytes ==
                VaultHeader._tagBytes &&
            _sodium.crypto.aeadXChaCha20Poly1305IETF.keyBytes ==
                VaultHeader._keyBytes,
        'libsodium sizes changed',
      );

  static Future<VaultCrypto> load() async =>
      VaultCrypto(await SodiumSumoInit.init());

  final SodiumSumo _sodium;

  Aead get _aead => _sodium.crypto.aeadXChaCha20Poly1305IETF;

  /// A new vault with a random note key, locked with [passphrase] and with
  /// a new recovery key.
  Future<NewVault> create(
    String passphrase, {
    KdfParams kdf = KdfParams.moderate,
    DateTime? now,
  }) async {
    final id = _hex(_sodium.randombytes.buf(16));
    final salt = _sodium.randombytes.buf(_sodium.crypto.pwhash.saltBytes);
    final noteKey = _aead.keygen();
    final recovery = _sodium.randombytes.buf(RecoveryKey.bytes);

    final passphraseKey = await _derive(passphrase, salt, kdf);
    final recoveryKey = _recoveryWrapKey(id, recovery);
    try {
      final header = VaultHeader(
        id: id,
        createdAt: now ?? DateTime.now(),
        kdf: kdf,
        salt: salt,
        passphraseBox: _wrap(noteKey, passphraseKey, id, 'passphrase'),
        recoveryBox: _wrap(noteKey, recoveryKey, id, 'recovery'),
        check: _sealCheck(noteKey, id),
      );
      return NewVault(
        header,
        Vault._(_sodium, id, noteKey),
        RecoveryKey.encode(recovery),
      );
    } finally {
      passphraseKey.dispose();
      recoveryKey.dispose();
    }
  }

  /// [header] locked with [passphrase] instead, with a new salt. The note
  /// key stays, so notes need no encrypting again, and so does the
  /// recovery key.
  Future<VaultHeader> changePassphrase(
    VaultHeader header,
    Vault vault,
    String passphrase, {
    KdfParams kdf = KdfParams.moderate,
  }) async {
    if (!vault.belongsTo(header)) {
      throw ArgumentError('That vault\'s key isn\'t in this header');
    }
    final salt = _sodium.randombytes.buf(_sodium.crypto.pwhash.saltBytes);
    final key = await _derive(passphrase, salt, kdf);
    try {
      return VaultHeader(
        id: header.id,
        createdAt: header.createdAt,
        kdf: kdf,
        salt: salt,
        passphraseBox: _wrap(vault._key, key, header.id, 'passphrase'),
        recoveryBox: header.recoveryBox,
        check: header.check,
      );
    } finally {
      key.dispose();
    }
  }

  /// [header] with a new recovery key, which is returned to show once. The
  /// old one stops opening the vault file; the passphrase stays.
  ({VaultHeader header, String recoveryKey}) newRecoveryKey(
    VaultHeader header,
    Vault vault,
  ) {
    if (!vault.belongsTo(header)) {
      throw ArgumentError('That vault\'s key isn\'t in this header');
    }
    final recovery = _sodium.randombytes.buf(RecoveryKey.bytes);
    final key = _recoveryWrapKey(header.id, recovery);
    try {
      return (
        header: VaultHeader(
          id: header.id,
          createdAt: header.createdAt,
          kdf: header.kdf,
          salt: header.salt,
          passphraseBox: header.passphraseBox,
          recoveryBox: _wrap(vault._key, key, header.id, 'recovery'),
          check: header.check,
        ),
        recoveryKey: RecoveryKey.encode(recovery),
      );
    } finally {
      key.dispose();
    }
  }

  /// The vault, if [passphrase] is the one it was locked with.
  Future<Vault?> unlock(VaultHeader header, String passphrase) async {
    final key = await _derive(passphrase, header.salt, header.kdf);
    try {
      return _unwrap(header, header.passphraseBox, key, 'passphrase');
    } finally {
      key.dispose();
    }
  }

  /// The vault, if [recoveryKey] is the one made with it. Typos in the
  /// recovery key return null too.
  Vault? unlockWithRecoveryKey(VaultHeader header, String recoveryKey) {
    final bytes = RecoveryKey.decode(recoveryKey);
    if (bytes == null) return null;
    final key = _recoveryWrapKey(header.id, bytes);
    try {
      return _unwrap(header, header.recoveryBox, key, 'recovery');
    } finally {
      key.dispose();
    }
  }

  /// The vault, if [noteKey] (say, from the keychain) is its key.
  Vault? fromKey(VaultHeader header, Uint8List noteKey) {
    if (noteKey.length != _aead.keyBytes) return null;
    final key = SecureKey.fromList(_sodium, noteKey);
    try {
      _aead.decrypt(
        cipherText: header.check.sealed,
        nonce: header.check.nonce,
        key: key,
        additionalData: _boxData(header.id, 'check'),
      );
    } on SodiumException {
      key.dispose();
      return null;
    }
    return Vault._(_sodium, header.id, key);
  }

  // Argon2id needs a second or so; doing it in another isolate keeps the
  // window responsive.
  Future<SecureKey> _derive(String passphrase, Uint8List salt, KdfParams kdf) =>
      Isolate.run(() async {
        final sodium = await SodiumSumoInit.init();
        final key = sodium.crypto.pwhash.callStr(
          outLen: sodium.crypto.aeadXChaCha20Poly1305IETF.keyBytes,
          password: passphrase,
          salt: salt,
          opsLimit: kdf.ops,
          memLimit: kdf.mem,
          alg: CryptoPwhashAlgorithm.argon2id13,
        );
        try {
          return key.extractBytes();
        } finally {
          key.dispose();
        }
      }).then((bytes) => SecureKey.fromList(_sodium, bytes));

  SecureKey _recoveryWrapKey(String vaultId, Uint8List recovery) {
    final key = SecureKey.fromList(_sodium, recovery);
    try {
      return SecureKey.fromList(
        _sodium,
        _sodium.crypto.genericHash(
          message: Uint8List.fromList(utf8.encode('gpad recovery $vaultId')),
          outLen: _aead.keyBytes,
          key: key,
        ),
      );
    } finally {
      key.dispose();
    }
  }

  SealedBox _wrap(SecureKey noteKey, SecureKey wrapKey, String id, String use) {
    final nonce = _sodium.randombytes.buf(_aead.nonceBytes);
    return SealedBox(
      nonce,
      _aead.encrypt(
        message: noteKey.extractBytes(),
        nonce: nonce,
        key: wrapKey,
        additionalData: _boxData(id, use),
      ),
    );
  }

  Vault? _unwrap(VaultHeader header, SealedBox box, SecureKey key, String use) {
    final Uint8List noteKey;
    try {
      noteKey = _aead.decrypt(
        cipherText: box.sealed,
        nonce: box.nonce,
        key: key,
        additionalData: _boxData(header.id, use),
      );
    } on SodiumException {
      return null;
    }
    return fromKey(header, noteKey);
  }

  SealedBox _sealCheck(SecureKey noteKey, String id) {
    final nonce = _sodium.randombytes.buf(_aead.nonceBytes);
    return SealedBox(
      nonce,
      _aead.encrypt(
        message: Uint8List(0),
        nonce: nonce,
        key: noteKey,
        additionalData: _boxData(id, 'check'),
      ),
    );
  }

  static Uint8List _boxData(String vaultId, String use) =>
      Uint8List.fromList(utf8.encode('gpad vault $vaultId $use'));

  static String _hex(List<int> bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
}

/// The recovery key: 160 random bits written as 32 letters and digits in
/// groups of four, like `7KQ2-M9XA-…`. Crockford's base32, so it has no
/// I, L, O or U, and reading one of those as 1 or 0 is forgiven.
abstract final class RecoveryKey {
  static const bytes = 20;
  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static String encode(List<int> key) {
    assert(key.length == bytes);
    var bits = BigInt.zero;
    for (final byte in key) {
      bits = (bits << 8) | BigInt.from(byte);
    }
    final chars = <String>[];
    for (var i = 0; i < bytes * 8 ~/ 5; i++) {
      chars.add(_alphabet[(bits & BigInt.from(31)).toInt()]);
      bits >>= 5;
    }
    final text = chars.reversed.join();
    return [for (var i = 0; i < text.length; i += 4) text.substring(i, i + 4)]
        .join('-');
  }

  /// The key's bytes, or null if [text] isn't 32 base32 characters once
  /// spaces and dashes are taken out.
  static Uint8List? decode(String text) {
    final clean = text
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll(RegExp('[IL]'), '1')
        .replaceAll('O', '0');
    if (clean.length != bytes * 8 ~/ 5) return null;
    var bits = BigInt.zero;
    for (final char in clean.split('')) {
      final value = _alphabet.indexOf(char);
      if (value < 0) return null;
      bits = (bits << 5) | BigInt.from(value);
    }
    final out = Uint8List(bytes);
    for (var i = bytes - 1; i >= 0; i--) {
      out[i] = (bits & BigInt.from(255)).toInt();
      bits >>= 8;
    }
    return out;
  }
}
