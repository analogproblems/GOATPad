import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// The installer's id for GPad, its `AppId` in `windows/installer/gpad.iss`
/// (a test checks they match). It never changes.
const installerAppId = '{897E6F70-EBD0-4396-8FA0-41AD9320D1E2}';

/// Where the installer lists GPad among Windows' installed apps, under
/// HKEY_CURRENT_USER for an install for one person.
const installedAppKey =
    r'Software\Microsoft\Windows\CurrentVersion\Uninstall\'
    '${installerAppId}_is1';

/// GPad's entry among Windows' installed apps (**Settings → Apps**), as the
/// installer made it. GPad installed this way updates itself by replacing
/// its files, as the portable zip does, without the installer, so it keeps
/// the version the entry shows up to date itself.
class InstalledAppEntry {
  const InstalledAppEntry([this.key = installedAppKey]);

  /// The entry's key under HKEY_CURRENT_USER.
  final String key;

  /// The entry's text value [name], or null if there is none.
  String? read(String name) => _Registry.read(key, name);

  /// Sets the entry's text value [name]. False if Windows wouldn't.
  bool write(String name, String value) => _Registry.write(key, name, value);

  /// Has the entry show [version], if it is for GPad in [dir]. Leaves it
  /// alone if GPad there wasn't installed by the installer, like the
  /// portable zip, which an installed GPad elsewhere could share the entry
  /// with. True if the entry shows [version] now. Never throws.
  bool updateVersion(String dir, String version) {
    try {
      final location = read('InstallLocation');
      if (location == null || !_sameFolder(location, dir)) return false;
      if (read('DisplayVersion') == version) return true;
      return write('DisplayVersion', version);
    } on Object {
      // Only how GPad is listed; nothing to undo.
      return false;
    }
  }

  /// Whether Windows paths [a] and [b] are the same folder: the installer
  /// writes it with a backslash at the end.
  static bool _sameFolder(String a, String b) {
    String folder(String path) => p.windows.normalize(path).toLowerCase();
    return folder(a) == folder(b);
  }
}

/// Text values under HKEY_CURRENT_USER, from advapi32.
abstract final class _Registry {
  /// HKEY_CURRENT_USER: `(HKEY)(LONG)0x80000001`, sign extended.
  static const _currentUser = -0x7fffffff;
  static const _sz = 1; // REG_SZ
  static const _onlySz = 0x2; // RRF_RT_REG_SZ

  static final _advapi32 = DynamicLibrary.open('advapi32.dll');

  static final _getValue = _advapi32
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
          Pointer<Uint32>,
        ),
        int Function(
          int,
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
          Pointer<Uint32>,
        )
      >('RegGetValueW');

  static final _setKeyValue = _advapi32
      .lookupFunction<
        Int32 Function(
          IntPtr,
          Pointer<Utf16>,
          Pointer<Utf16>,
          Uint32,
          Pointer<Void>,
          Uint32,
        ),
        int Function(
          int,
          Pointer<Utf16>,
          Pointer<Utf16>,
          int,
          Pointer<Void>,
          int,
        )
      >('RegSetKeyValueW');

  static String? read(String key, String name) => using((arena) {
    final keyName = key.toNativeUtf16(allocator: arena);
    final valueName = name.toNativeUtf16(allocator: arena);
    final size = arena<Uint32>();
    // How big it is, then the text, which Windows ends with a zero.
    if (_getValue(
          _currentUser,
          keyName,
          valueName,
          _onlySz,
          nullptr,
          nullptr,
          size,
        ) !=
        0) {
      return null;
    }
    final text = arena<Uint16>(size.value ~/ 2 + 1);
    if (_getValue(
          _currentUser,
          keyName,
          valueName,
          _onlySz,
          nullptr,
          text.cast(),
          size,
        ) !=
        0) {
      return null;
    }
    return text.cast<Utf16>().toDartString();
  });

  static bool write(String key, String name, String value) => using((arena) {
    final text = value.toNativeUtf16(allocator: arena);
    return _setKeyValue(
          _currentUser,
          key.toNativeUtf16(allocator: arena),
          name.toNativeUtf16(allocator: arena),
          _sz,
          text.cast(),
          (value.length + 1) * 2,
        ) ==
        0;
  });
}
