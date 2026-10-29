import 'dart:io';

/// Where GPad keeps its notes: on Linux, `$XDG_DATA_HOME/gpad` (usually
/// `~/.local/share/gpad`); on Windows, `%LOCALAPPDATA%\GPad`. Local rather
/// than roaming on Windows, so a roaming profile never copies the database
/// around; GPad's own encrypted sync is what moves notes between machines.
///
/// Set `GPAD_DATA_DIR` to use another folder instead, for a portable copy on
/// a USB stick or a throwaway folder when testing.
Future<String> notesDatabasePath({Map<String, String>? environment}) async {
  final env = environment ?? Platform.environment;
  final dir = Directory(_dataDirectory(env));
  await dir.create(recursive: true);
  return '${dir.path}${Platform.pathSeparator}notes.db';
}

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
