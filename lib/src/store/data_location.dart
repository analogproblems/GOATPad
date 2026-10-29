import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Where GPad keeps its notes: on Linux, `$XDG_DATA_HOME/gpad` (usually
/// `~/.local/share/gpad`); on Windows, `%LOCALAPPDATA%\GPad`. Local rather
/// than roaming on Windows, so a roaming profile never copies the database
/// around; GPad's own encrypted sync is what moves notes between machines.
///
/// Set `GPAD_DATA_DIR` to use another folder instead, for a portable copy on
/// a USB stick or a throwaway folder when testing.
///
/// On Linux the folder is made private to the person, since the notes in it
/// aren't encrypted: other accounts on the computer can't look inside. On
/// Windows, the local app data folder already is.
Future<String> notesDatabasePath({Map<String, String>? environment}) async {
  final env = environment ?? Platform.environment;
  final dir = Directory(_dataDirectory(env));
  await dir.create(recursive: true);
  if (Platform.isLinux) _makePrivate(dir.path);
  return '${dir.path}${Platform.pathSeparator}notes.db';
}

/// Lets only the owner into the folder at [path]: mode 700, rwx------.
/// Does nothing where that isn't possible, as on a FAT USB stick.
void _makePrivate(String path) => using((arena) {
  _chmod(path.toNativeUtf8(allocator: arena), 0x1c0);
});

final _chmod = DynamicLibrary.process()
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, int)
    >('chmod');

String _dataDirectory(Map<String, String> env) {
  String? nonEmpty(String key) {
    final value = env[key];
    return value == null || value.isEmpty ? null : value;
  }

  final override = nonEmpty('GPAD_DATA_DIR');
  if (override != null) return override;

  if (Platform.isWindows) {
    final localAppData = nonEmpty('LOCALAPPDATA');
    if (localAppData != null) return '$localAppData\\GPad';
    return '${nonEmpty('USERPROFILE') ?? '.'}\\AppData\\Local\\GPad';
  }
  final dataHome =
      nonEmpty('XDG_DATA_HOME') ?? '${nonEmpty('HOME') ?? '.'}/.local/share';
  return '$dataHome/gpad';
}
