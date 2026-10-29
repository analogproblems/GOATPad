import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/sync/vault.dart';

void main() {
  late VaultCrypto crypto;
  late NewVault made;

  setUpAll(() async {
    crypto = await VaultCrypto.load();
    made = await crypto.create(
      'correct horse battery',
      kdf: KdfParams.insecureForTests,
    );
  });

  VaultHeader reread(VaultHeader header) => VaultHeader.decode(header.encode());

  test('the passphrase unlocks the vault, and a wrong one does not', () async {
    final header = reread(made.header);
    final vault = await crypto.unlock(header, 'correct horse battery');
    expect(vault, isNotNull);
    expect(vault!.id, made.header.id);
    expect(vault.exportKey(), made.vault.exportKey());
    expect(await crypto.unlock(header, 'correct horse batterY'), isNull);
    expect(await crypto.unlock(header, ''), isNull);
  });

  test('the recovery key unlocks the vault, however it is typed', () {
    final header = reread(made.header);
    final key = made.recoveryKey;
    expect(
      key,
      matches(RegExp(r'^([0-9A-HJKMNP-TV-Z]{4}-){7}[0-9A-HJKMNP-TV-Z]{4}$')),
    );
    for (final typed in [
      key,
      key.toLowerCase(),
      key.replaceAll('-', ' '),
      key.replaceAll('-', ''),
      key.replaceAll('1', 'l').replaceAll('0', 'o'),
    ]) {
      expect(
        crypto.unlockWithRecoveryKey(header, typed)?.exportKey(),
        made.vault.exportKey(),
        reason: typed,
      );
    }
    final wrong = key.replaceRange(0, 1, key[0] == 'A' ? 'B' : 'A');
    expect(crypto.unlockWithRecoveryKey(header, wrong), isNull);
    expect(crypto.unlockWithRecoveryKey(header, 'too short'), isNull);
  });

  test('a key from the keychain must belong to the vault', () async {
    final header = reread(made.header);
    expect(crypto.fromKey(header, made.vault.exportKey()), isNotNull);
    final other = await crypto.create(
      'another',
      kdf: KdfParams.insecureForTests,
    );
    expect(crypto.fromKey(header, other.vault.exportKey()), isNull);
    expect(crypto.fromKey(header, Uint8List(3)), isNull);
  });

  test(
    'records open only as the record and vault they were sealed for',
    () async {
      final id = 'a' * 32;
      final sealed = made.vault.seal(id, utf8.encode('{"hello":"world"}'));
      expect(utf8.decode(made.vault.open(id, sealed)), '{"hello":"world"}');
      expect(
        () => made.vault.open('b' * 32, sealed),
        throwsA(isA<VaultException>()),
      );
      final other = await crypto.create(
        'another',
        kdf: KdfParams.insecureForTests,
      );
      expect(
        () => other.vault.open(id, sealed),
        throwsA(isA<VaultException>()),
      );

      for (final at in [0, 5, 20, sealed.length - 1]) {
        final tampered = Uint8List.fromList(sealed)..[at] ^= 1;
        expect(
          () => made.vault.open(id, tampered),
          throwsA(isA<VaultException>()),
          reason: 'byte $at',
        );
      }
      expect(
        () => made.vault.open(id, sealed.sublist(0, 30)),
        throwsA(isA<VaultException>()),
      );
    },
  );

  test('padding hides most of a record\'s length', () {
    expect(Vault.pad([]).length, 256);
    expect(Vault.pad(List.filled(255, 1)).length, 256);
    for (final length in [256, 1000, 5000, 70000, 1 << 20]) {
      final padded = Vault.pad(List.filled(length, 7));
      expect(padded.length, greaterThan(length));
      expect(padded.length, lessThanOrEqualTo(length * 1.13 + 1));
      expect(Vault.unpad(padded), List.filled(length, 7));
    }
    // Lengths near each other pad to the same size.
    expect(
      Vault.pad(List.filled(4000, 1)).length,
      Vault.pad(List.filled(4090, 1)).length,
    );
    expect(() => Vault.unpad(Uint8List(300)), throwsA(isA<VaultException>()));
  });

  test('the vault file holds no keys in the clear and refuses bad values', () {
    final text = utf8.decode(made.header.encode());
    expect(text, isNot(contains(base64.encode(made.vault.exportKey()))));
    final json = jsonDecode(text) as Map<String, Object?>;
    expect(json['gpad'], 'vault');
    expect((json['kdf'] as Map)['alg'], 'argon2id13');

    Map<String, Object?> edited(void Function(Map<String, Object?>) edit) =>
        (jsonDecode(text) as Map<String, Object?>)..also(edit);
    for (final bad in [
      edited((j) => j['version'] = 2),
      edited((j) => (j['kdf'] as Map)['mem'] = 64 << 30),
      edited((j) => (j['kdf'] as Map)['ops'] = 0),
      edited((j) => (j['kdf'] as Map)['alg'] = 'pbkdf2'),
      edited((j) => j['id'] = '../escape'),
      edited((j) => j.remove('recovery')),
    ]) {
      expect(
        () => VaultHeader.decode(utf8.encode(jsonEncode(bad))),
        throwsFormatException,
        reason: jsonEncode(bad),
      );
    }
    expect(
      () => VaultHeader.decode(utf8.encode('nope')),
      throwsFormatException,
    );
  });

  test('a recovery key round-trips through its text form', () {
    final bytes = Uint8List.fromList(List.generate(20, (i) => i * 13));
    expect(RecoveryKey.decode(RecoveryKey.encode(bytes)), bytes);
    expect(
      RecoveryKey.decode(RecoveryKey.encode(Uint8List(20))),
      Uint8List(20),
    );
  });
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}
