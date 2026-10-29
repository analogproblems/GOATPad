import 'dart:async';
import 'dart:typed_data';

import 'package:goatpad/src/sync/keychain.dart';

/// Holds each write while [holding], as a keychain waiting to be unlocked
/// does, until the test lets it go on.
class HeldKeychain extends MemoryKeychain {
  bool holding = false;
  final held = <Completer<void>>[];

  @override
  Future<void> write(String name, Uint8List secret) async {
    if (holding) {
      final gate = Completer<void>();
      held.add(gate);
      await gate.future;
    }
    return super.write(name, secret);
  }
}
