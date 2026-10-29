import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Moves the file at [source] to [target] in one step that fails, rather
/// than replacing it, if something is at [target] already. Dart's rename
/// always replaces, so this asks the system directly: a hard link on
/// Linux, MoveFileEx without MOVEFILE_REPLACE_EXISTING on Windows.
///
/// Returns false, leaving [source] where it is, if [target] was taken.
/// Throws [UnsupportedError] where the system or the filesystem can't do
/// it, like a FAT USB stick, which has no hard links.
bool moveNoReplace(String source, String target) {
  if (Platform.isLinux) return _linkThenUnlink(source, target);
  if (Platform.isWindows) return _moveFileEx(source, target);
  throw UnsupportedError('No move that refuses to replace here');
}

bool _linkThenUnlink(String source, String target) {
  final linked = using(
    (arena) => _Libc.instance.link(
      source.toNativeUtf8(allocator: arena),
      target.toNativeUtf8(allocator: arena),
    ),
  );
  if (linked != 0) {
    // Taken, unless linking itself is what failed.
    if (File(target).existsSync()) return false;
    throw UnsupportedError('Hard links aren\'t possible at $target');
  }
  File(source).deleteSync();
  return true;
}

bool _moveFileEx(String source, String target) {
  const writeThrough = 0x8;
  final moved = using(
    (arena) => _Kernel32.instance.moveFileEx(
      source.toNativeUtf16(allocator: arena),
      target.toNativeUtf16(allocator: arena),
      writeThrough,
    ),
  );
  if (moved != 0) return true;
  if (File(target).existsSync()) return false;
  throw FileSystemException('Can\'t move the file into place', target);
}

final class _Libc {
  _Libc._(DynamicLibrary libc)
    : link = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<Utf8>, Pointer<Utf8>)
          >('link');

  static final instance = _Libc._(DynamicLibrary.process());

  final int Function(Pointer<Utf8> source, Pointer<Utf8> target) link;
}

final class _Kernel32 {
  _Kernel32._(DynamicLibrary kernel32)
    : moveFileEx = kernel32
          .lookupFunction<
            Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
            int Function(Pointer<Utf16>, Pointer<Utf16>, int)
          >('MoveFileExW');

  static final instance = _Kernel32._(DynamicLibrary.open('kernel32.dll'));

  final int Function(Pointer<Utf16> source, Pointer<Utf16> target, int flags)
  moveFileEx;
}
