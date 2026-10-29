import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Thrown when the keychain is there but refused a request, say because
/// it is locked and the person said no.
class KeychainException implements Exception {
  const KeychainException(this.message);

  final String message;

  @override
  String toString() => 'KeychainException: $message';
}

/// Where GPad keeps the sync key between runs, so it doesn't ask for the
/// passphrase each time: the system's keychain, never a plain file.
abstract interface class Keychain {
  /// The keychain on this computer: the Secret Service (GNOME Keyring or
  /// KWallet) on Linux, the Credential Manager on Windows.
  factory Keychain.system() {
    if (Platform.isLinux) return const SecretServiceKeychain();
    if (Platform.isWindows) return const CredentialManagerKeychain();
    return const NoKeychain();
  }

  /// Whether this computer has a keychain GPad can use. Without one, GPad
  /// asks for the passphrase each time it starts.
  Future<bool> available();

  Future<Uint8List?> read(String name);

  Future<void> write(String name, Uint8List secret);

  Future<void> delete(String name);
}

/// No keychain: nothing is remembered.
class NoKeychain implements Keychain {
  const NoKeychain();

  @override
  Future<bool> available() async => false;

  @override
  Future<Uint8List?> read(String name) async => null;

  @override
  Future<void> write(String name, Uint8List secret) async =>
      throw const KeychainException('There is no keychain on this computer');

  @override
  Future<void> delete(String name) async {}
}

/// A keychain in memory, for tests.
class MemoryKeychain implements Keychain {
  final secrets = <String, Uint8List>{};

  @override
  Future<bool> available() async => true;

  @override
  Future<Uint8List?> read(String name) async => secrets[name];

  @override
  Future<void> write(String name, Uint8List secret) async =>
      secrets[name] = secret;

  @override
  Future<void> delete(String name) async => secrets.remove(name);
}

/// The freedesktop Secret Service through libsecret, which GNOME, KDE and
/// most Linux desktops provide.
///
/// libsecret is loaded when it is needed rather than linked, so GPad still
/// starts on a system without it. Calls run in another isolate, since the
/// keychain may be locked and wait for the person to unlock it.
class SecretServiceKeychain implements Keychain {
  const SecretServiceKeychain();

  @override
  Future<bool> available() => Isolate.run(() {
    try {
      _Libsecret.open().lookup('availability check');
      return true;
    } on Object {
      return false;
    }
  });

  @override
  Future<Uint8List?> read(String name) => Isolate.run(() {
    final value = _Libsecret.open().lookup(name);
    return value == null ? null : base64.decode(value);
  });

  @override
  Future<void> write(String name, Uint8List secret) => Isolate.run(
    () => _Libsecret.open().store(name, 'GPad: $name', base64.encode(secret)),
  );

  @override
  Future<void> delete(String name) =>
      Isolate.run(() => _Libsecret.open().clear(name));
}

final class _SchemaAttribute extends Struct {
  external Pointer<Utf8> name;

  @Int32()
  external int type;
}

/// libsecret's SecretSchema.
final class _Schema extends Struct {
  external Pointer<Utf8> name;

  @Int32()
  external int flags;

  @Array(32)
  external Array<_SchemaAttribute> attributes;

  @Int32()
  external int reserved;

  external Pointer<Void> reserved1;
  external Pointer<Void> reserved2;
  external Pointer<Void> reserved3;
  external Pointer<Void> reserved4;
  external Pointer<Void> reserved5;
  external Pointer<Void> reserved6;
  external Pointer<Void> reserved7;
}

final class _GError extends Struct {
  @Uint32()
  external int domain;

  @Int32()
  external int code;

  external Pointer<Utf8> message;
}

typedef _HashTable = Pointer<Void>;
typedef _ErrorOut = Pointer<Pointer<_GError>>;

class _Libsecret {
  _Libsecret._(DynamicLibrary secret, DynamicLibrary glib)
    : _store = secret
          .lookupFunction<
            Int32 Function(
              Pointer<_Schema>,
              _HashTable,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Void>,
              _ErrorOut,
            ),
            int Function(
              Pointer<_Schema>,
              _HashTable,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Void>,
              _ErrorOut,
            )
          >('secret_password_storev_sync'),
      _lookup = secret
          .lookupFunction<
            Pointer<Utf8> Function(
              Pointer<_Schema>,
              _HashTable,
              Pointer<Void>,
              _ErrorOut,
            ),
            Pointer<Utf8> Function(
              Pointer<_Schema>,
              _HashTable,
              Pointer<Void>,
              _ErrorOut,
            )
          >('secret_password_lookupv_sync'),
      _clear = secret
          .lookupFunction<
            Int32 Function(
              Pointer<_Schema>,
              _HashTable,
              Pointer<Void>,
              _ErrorOut,
            ),
            int Function(Pointer<_Schema>, _HashTable, Pointer<Void>, _ErrorOut)
          >('secret_password_clearv_sync'),
      _free = secret
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('secret_password_free'),
      _newTable = glib
          .lookupFunction<
            _HashTable Function(Pointer<Void>, Pointer<Void>),
            _HashTable Function(Pointer<Void>, Pointer<Void>)
          >('g_hash_table_new'),
      _insert = glib
          .lookupFunction<
            Int32 Function(_HashTable, Pointer<Void>, Pointer<Void>),
            int Function(_HashTable, Pointer<Void>, Pointer<Void>)
          >('g_hash_table_insert'),
      _unref = glib
          .lookupFunction<Void Function(_HashTable), void Function(_HashTable)>(
            'g_hash_table_unref',
          ),
      _freeError = glib
          .lookupFunction<
            Void Function(Pointer<_GError>),
            void Function(Pointer<_GError>)
          >('g_error_free'),
      _strHash = glib.lookup<Void>('g_str_hash'),
      _strEqual = glib.lookup<Void>('g_str_equal');

  /// Throws if libsecret isn't installed.
  factory _Libsecret.open() => _Libsecret._(
    DynamicLibrary.open('libsecret-1.so.0'),
    DynamicLibrary.open('libglib-2.0.so.0'),
  );

  final int Function(
    Pointer<_Schema>,
    _HashTable,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Void>,
    _ErrorOut,
  )
  _store;
  final Pointer<Utf8> Function(
    Pointer<_Schema>,
    _HashTable,
    Pointer<Void>,
    _ErrorOut,
  )
  _lookup;
  final int Function(Pointer<_Schema>, _HashTable, Pointer<Void>, _ErrorOut)
  _clear;
  final void Function(Pointer<Utf8>) _free;
  final _HashTable Function(Pointer<Void>, Pointer<Void>) _newTable;
  final int Function(_HashTable, Pointer<Void>, Pointer<Void>) _insert;
  final void Function(_HashTable) _unref;
  final void Function(Pointer<_GError>) _freeError;
  final Pointer<Void> _strHash;
  final Pointer<Void> _strEqual;

  String? lookup(String name) => _call(name, (schema, table, error) {
    final value = _lookup(schema, table, nullptr, error);
    if (value == nullptr) return null;
    try {
      return value.toDartString();
    } finally {
      _free(value);
    }
  });

  void store(String name, String label, String secret) =>
      _call(name, (schema, table, error) {
        using((arena) {
          _store(
            schema,
            table,
            nullptr, // The default collection, usually the login keyring.
            label.toNativeUtf8(allocator: arena),
            secret.toNativeUtf8(allocator: arena),
            nullptr,
            error,
          );
        });
      });

  void clear(String name) => _call(
    name,
    (schema, table, error) => _clear(schema, table, nullptr, error),
  );

  /// Calls [body] with GPad's schema and the attributes for item [name],
  /// and turns a GError into a [KeychainException].
  T _call<T>(
    String name,
    T Function(Pointer<_Schema>, _HashTable, _ErrorOut) body,
  ) => using((arena) {
    final schema = arena<_Schema>();
    schema.ref
      ..name = 'io.github.analogproblems.GPad'.toNativeUtf8(allocator: arena)
      ..flags = 0;
    schema.ref.attributes[0]
      ..name = 'item'.toNativeUtf8(allocator: arena)
      ..type = 0; // SECRET_SCHEMA_ATTRIBUTE_STRING
    final table = _newTable(_strHash, _strEqual);
    try {
      _insert(
        table,
        'item'.toNativeUtf8(allocator: arena).cast(),
        name.toNativeUtf8(allocator: arena).cast(),
      );
      final error = arena<Pointer<_GError>>()..value = nullptr;
      final result = body(schema, table, error);
      if (error.value != nullptr) {
        final message = error.value.ref.message.toDartString();
        _freeError(error.value);
        throw KeychainException(message);
      }
      return result;
    } finally {
      _unref(table);
    }
  });
}

/// The Windows Credential Manager, which keeps secrets for the signed-in
/// user, encrypted with their Windows password.
class CredentialManagerKeychain implements Keychain {
  const CredentialManagerKeychain();

  static const _generic = 1; // CRED_TYPE_GENERIC
  static const _localMachine = 2; // CRED_PERSIST_LOCAL_MACHINE

  static String _target(String name) => 'GPad/$name';

  @override
  Future<bool> available() async {
    try {
      _Advapi.open();
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<Uint8List?> read(String name) async {
    final api = _Advapi.open();
    return using((arena) {
      final out = arena<Pointer<_Credential>>();
      final found = api.read(
        _target(name).toNativeUtf16(allocator: arena),
        _generic,
        0,
        out,
      );
      if (found == 0) return null;
      try {
        final cred = out.value.ref;
        return Uint8List.fromList(cred.blob.asTypedList(cred.blobSize));
      } finally {
        api.free(out.value.cast());
      }
    });
  }

  @override
  Future<void> write(String name, Uint8List secret) async {
    final api = _Advapi.open();
    using((arena) {
      final blob = arena<Uint8>(secret.length)
        ..asTypedList(secret.length).setAll(0, secret);
      final cred = arena<_Credential>();
      cred.ref
        ..flags = 0
        ..type = _generic
        ..target = _target(name).toNativeUtf16(allocator: arena)
        ..comment = nullptr
        ..blobSize = secret.length
        ..blob = blob
        ..persist = _localMachine
        ..attributeCount = 0
        ..attributes = nullptr
        ..alias = nullptr
        ..userName = 'GPad'.toNativeUtf16(allocator: arena);
      if (api.write(cred, 0) == 0) {
        throw const KeychainException(
          'Windows wouldn\'t save it in the Credential Manager',
        );
      }
    });
  }

  @override
  Future<void> delete(String name) async {
    final api = _Advapi.open();
    using((arena) {
      api.delete(_target(name).toNativeUtf16(allocator: arena), _generic, 0);
    });
  }
}

final class _FileTime extends Struct {
  @Uint32()
  external int low;

  @Uint32()
  external int high;
}

/// CREDENTIALW.
final class _Credential extends Struct {
  @Uint32()
  external int flags;

  @Uint32()
  external int type;

  external Pointer<Utf16> target;
  external Pointer<Utf16> comment;
  external _FileTime lastWritten;

  @Uint32()
  external int blobSize;

  external Pointer<Uint8> blob;

  @Uint32()
  external int persist;

  @Uint32()
  external int attributeCount;

  external Pointer<Void> attributes;
  external Pointer<Utf16> alias;
  external Pointer<Utf16> userName;
}

class _Advapi {
  _Advapi._(DynamicLibrary lib)
    : write = lib
          .lookupFunction<
            Int32 Function(Pointer<_Credential>, Uint32),
            int Function(Pointer<_Credential>, int)
          >('CredWriteW'),
      read = lib
          .lookupFunction<
            Int32 Function(
              Pointer<Utf16>,
              Uint32,
              Uint32,
              Pointer<Pointer<_Credential>>,
            ),
            int Function(
              Pointer<Utf16>,
              int,
              int,
              Pointer<Pointer<_Credential>>,
            )
          >('CredReadW'),
      delete = lib
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Uint32, Uint32),
            int Function(Pointer<Utf16>, int, int)
          >('CredDeleteW'),
      free = lib
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('CredFree');

  factory _Advapi.open() => _Advapi._(DynamicLibrary.open('advapi32.dll'));

  final int Function(Pointer<_Credential>, int) write;
  final int Function(Pointer<Utf16>, int, int, Pointer<Pointer<_Credential>>)
  read;
  final int Function(Pointer<Utf16>, int, int) delete;
  final void Function(Pointer<Void>) free;
}
