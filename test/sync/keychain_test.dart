import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/sync/keychain.dart';

/// Runs against the real keychain: on Windows always, and on Linux when
/// GPAD_TEST_KEYCHAIN is set and a Secret Service is running (CI starts
/// gnome-keyring for it).
void main() {
  final real =
      Platform.isWindows ||
      (Platform.isLinux && Platform.environment['GPAD_TEST_KEYCHAIN'] == '1');

  test('the system keychain keeps a secret', () async {
    final keychain = Keychain.system();
    expect(await keychain.available(), isTrue);
    final name = 'test-${DateTime.now().microsecondsSinceEpoch}';
    final secret = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));
    expect(await keychain.read(name), isNull);
    await keychain.write(name, secret);
    expect(await keychain.read(name), secret);
    await keychain.write(name, Uint8List.fromList([1, 2, 3]));
    expect(await keychain.read(name), [1, 2, 3]);
    await keychain.delete(name);
    expect(await keychain.read(name), isNull);
    await keychain.delete(name);
  }, skip: real ? false : 'needs a real keychain');

  test(
    'with no Secret Service running, there is no keychain',
    () async {
      expect(await const SecretServiceKeychain().available(), isFalse);
    },
    skip:
        Platform.isLinux &&
            Platform.environment['DBUS_SESSION_BUS_ADDRESS'] == null
        ? false
        : 'a session bus is running',
  );
}
