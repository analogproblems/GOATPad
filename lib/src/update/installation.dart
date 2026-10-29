import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'release_manifest.dart';

/// How this copy of GPad was installed, which decides how it updates.
abstract class Installation {
  const Installation();

  /// Finds out from where GPad runs: an AppImage says so in `$APPIMAGE`,
  /// and the Windows zip is wherever `gpad.exe` is, if GPad may write
  /// there. Anything else, like the .deb, updates by hand.
  static Installation detect({
    Map<String, String>? environment,
    String? executable,
  }) {
    final env = environment ?? Platform.environment;
    if (Platform.isLinux) {
      final appImage = env['APPIMAGE'];
      if (appImage != null &&
          p.isAbsolute(appImage) &&
          File(appImage).existsSync() &&
          _mayWrite(p.dirname(appImage))) {
        return AppImageInstallation(appImage);
      }
      return const ManualInstallation();
    }
    if (Platform.isWindows) {
      final dir = p.dirname(executable ?? Platform.resolvedExecutable);
      if (_mayWrite(dir)) return WindowsFolderInstallation(dir);
    }
    return const ManualInstallation();
  }

  /// The download in a release that updates this installation, or null
  /// if it updates by hand.
  String? get kind;

  /// Where to download [name] to, before [install] takes it.
  File downloadTarget(String name);

  /// Puts [download], checked already, in place to run from the next
  /// start.
  Future<void> install(File download);

  /// Starts the new GPad once this one has quit, for restarting now.
  Future<void> restartAfterExit();

  /// Finishes an installed update as GPad quits, for an installation that
  /// can't while GPad runs.
  Future<void> finishAfterExit();

  static bool _mayWrite(String dir) {
    final probe = File(
      p.join(dir, '.gpad-write-check-${Random().nextInt(1 << 32)}'),
    );
    try {
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}

/// Installed by a package manager, like the .deb, or somewhere GPad can't
/// write: GPad says a new version is out and links to it.
class ManualInstallation extends Installation {
  const ManualInstallation();

  @override
  String? get kind => null;

  @override
  File downloadTarget(String name) => throw UnsupportedError('Manual');

  @override
  Future<void> install(File download) => throw UnsupportedError('Manual');

  @override
  Future<void> restartAfterExit() async {}

  @override
  Future<void> finishAfterExit() async {}
}

/// An AppImage. The new one replaces the file as soon as it is checked,
/// which Linux allows while the old one runs.
class AppImageInstallation extends Installation {
  const AppImageInstallation(this.path);

  final String path;

  @override
  String get kind => ReleaseManifest.appImage;

  /// Next to the AppImage, so it is renamed over it in one step.
  @override
  File downloadTarget(String name) => File(
    p.join(p.dirname(path), '.$name.${Random().nextInt(1 << 32)}.download'),
  );

  @override
  Future<void> install(File download) async {
    final made = await Process.run('chmod', ['755', download.path]);
    if (made.exitCode != 0) {
      throw const UpdateException('GPad couldn\'t make the update runnable');
    }
    await download.rename(path);
  }

  @override
  Future<void> restartAfterExit() async {
    await Process.start(path, const [
      updatedArgument,
    ], mode: ProcessStartMode.detached);
  }

  @override
  Future<void> finishAfterExit() async {}
}

/// Tells a GPad started by an update to wait for the old one to quit,
/// rather than finding the notes open and showing that window.
const updatedArgument = '--gpad-updated';

/// The Windows zip, unzipped to a folder GPad may write to.
///
/// Windows won't replace the files of a program while it runs, so the new
/// version is unzipped into a folder inside, `.gpad-update`. As GPad quits,
/// it starts the new `gpad.exe` from there with [finishArgument], which
/// waits for the old GPad to be gone, moves the old files aside, copies the
/// new ones in, and puts the old ones back if that fails.
class WindowsFolderInstallation extends Installation {
  WindowsFolderInstallation(this.dir);

  /// Where `gpad.exe` is.
  final String dir;

  static const stagingName = '.gpad-update';
  static const oldName = '.gpad-old';
  static const failureName = '.gpad-update-failed';

  /// Asks the new `gpad.exe` to finish installing: followed by the folder,
  /// the old GPad's process id and, to start GPad again after,
  /// [relaunchArgument]. Every later version must keep taking these.
  static const finishArgument = '--gpad-finish-update';
  static const relaunchArgument = '--relaunch';

  /// What a release's zip holds: the folder that is put in place.
  static const _zipFolder = 'GPad';

  Directory get _staging => Directory(p.join(dir, stagingName));
  Directory get _staged => Directory(p.join(_staging.path, _zipFolder));
  bool _isStaged = false;

  @override
  String get kind => ReleaseManifest.windowsZip;

  @override
  File downloadTarget(String name) =>
      File(p.join(dir, '$stagingName.${Random().nextInt(1 << 32)}.zip'));

  /// Unzips [download] into the staging folder. Refuses a zip with files
  /// outside its GPad folder, or without `gpad.exe`.
  @override
  Future<void> install(File download) async {
    try {
      if (_staging.existsSync()) await _staging.delete(recursive: true);
      await unzipRelease(download, _staging);
      if (!File(p.join(_staged.path, 'gpad.exe')).existsSync()) {
        throw const UpdateException('The update has no gpad.exe');
      }
      _isStaged = true;
    } on FileSystemException catch (e) {
      throw UpdateException('GPad couldn\'t unzip the update (${e.message})');
    } finally {
      try {
        await download.delete();
      } on FileSystemException {
        // Gone already.
      }
    }
  }

  @override
  Future<void> restartAfterExit() => _finishAfterExit(relaunch: true);

  @override
  Future<void> finishAfterExit() => _finishAfterExit(relaunch: false);

  Future<void> _finishAfterExit({required bool relaunch}) async {
    if (!_isStaged) return;
    _isStaged = false;
    await Process.start(p.join(_staged.path, 'gpad.exe'), [
      finishArgument,
      dir,
      '$pid',
      if (relaunch) relaunchArgument,
    ], mode: ProcessStartMode.detached);
  }

  /// Deletes what an earlier update left: the old files, and the staging
  /// folder, which the new GPad ran from. Returns why the last update
  /// failed, if it did.
  static Future<String?> cleanUp(String dir) async {
    for (final name in [oldName, stagingName]) {
      try {
        await Directory(p.join(dir, name)).delete(recursive: true);
      } on FileSystemException {
        // None, or still in use; next start, then.
      }
    }
    final failure = File(p.join(dir, failureName));
    try {
      final reason = await failure.readAsString();
      await failure.delete();
      return reason;
    } on FileSystemException {
      return null;
    }
  }

  /// Run by the new `gpad.exe` from the staging folder, with the arguments
  /// [finishArgument] lists: puts its files in place of the old GPad's.
  static Future<void> finish(List<String> arguments) async {
    if (arguments case [final dir, final pidText, ...final rest]) {
      final oldPid = int.tryParse(pidText);
      if (oldPid != null) _waitForExit(oldPid);
      try {
        await replaceFiles(
          dir,
          Directory(p.join(dir, stagingName, _zipFolder)),
        );
      } on Object catch (e) {
        try {
          await File(p.join(dir, failureName)).writeAsString('$e');
        } on FileSystemException {
          // Nowhere to say so.
        }
      }
      if (rest.contains(relaunchArgument)) {
        await Process.start(p.join(dir, 'gpad.exe'), const [
          updatedArgument,
        ], mode: ProcessStartMode.detached);
      }
    }
  }

  /// Copies every file in [staged] into [dir], moving the file each
  /// replaces into the old files folder first. If any step fails, takes
  /// the copies away and puts the old files back, and throws.
  @visibleForTesting
  static Future<void> replaceFiles(
    String dir,
    Directory staged, {
    Future<void> Function(File from, String to)? copy,
  }) async {
    final old = Directory(p.join(dir, oldName));
    if (old.existsSync()) await old.delete(recursive: true);
    final copyFile = copy ?? (from, to) => from.copy(to);
    final moved = <String>[];
    final copied = <String>[];
    try {
      final files = staged
          .listSync(recursive: true, followLinks: false)
          .whereType<File>();
      for (final file in files) {
        final relative = p.relative(file.path, from: staged.path);
        final target = File(p.join(dir, relative));
        if (target.existsSync()) {
          final aside = p.join(old.path, relative);
          await Directory(p.dirname(aside)).create(recursive: true);
          await _retry(() => target.rename(aside));
          moved.add(relative);
        }
        await target.parent.create(recursive: true);
        await _retry(() => copyFile(file, target.path));
        copied.add(relative);
      }
    } on Object {
      for (final relative in copied) {
        try {
          await File(p.join(dir, relative)).delete();
        } on FileSystemException {
          // Left over; the old file going back replaces it below.
        }
      }
      for (final relative in moved) {
        try {
          await File(p.join(old.path, relative)).rename(p.join(dir, relative));
        } on FileSystemException {
          // Still in the old files folder, at least.
        }
      }
      rethrow;
    }
  }

  /// Runs [step], trying again for a moment if it fails, as when a virus
  /// scanner has a new file open.
  static Future<void> _retry(Future<Object?> Function() step) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await step();
        return;
      } on FileSystemException {
        if (attempt == 6) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 100 << attempt));
      }
    }
  }

  /// Waits up to a minute for process [id] to end.
  static void _waitForExit(int id) {
    if (!Platform.isWindows) return;
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final open = kernel32
        .lookupFunction<
          Pointer<Void> Function(Uint32, Int32, Uint32),
          Pointer<Void> Function(int, int, int)
        >('OpenProcess');
    final wait = kernel32
        .lookupFunction<
          Uint32 Function(Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int)
        >('WaitForSingleObject');
    final close = kernel32
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('CloseHandle');
    const synchronize = 0x00100000;
    final process = open(synchronize, 0, id);
    // Gone already.
    if (process == nullptr) return;
    try {
      // Nothing else to do meanwhile: this GPad shows no window.
      wait(process, 60000);
    } finally {
      close(process);
    }
  }
}

/// Unzips the release zip [zip] into [into]. Refuses names that would land
/// outside the zip's GPad folder, like `../x` or `C:\x`.
@visibleForTesting
Future<void> unzipRelease(File zip, Directory into) async {
  final input = InputFileStream(zip.path);
  try {
    final archive = ZipDecoder().decodeStream(input);
    for (final entry in archive) {
      final name = entry.name.replaceAll(r'\', '/');
      final parts = p.posix.split(name);
      if (entry.isSymbolicLink ||
          parts.isEmpty ||
          p.posix.isAbsolute(name) ||
          name.contains(':') ||
          parts.contains('..') ||
          parts.first != 'GPad') {
        throw UpdateException('The update holds a file it shouldn\'t: $name');
      }
      final target = p.joinAll([into.path, ...parts]);
      if (entry.isFile) {
        await Directory(p.dirname(target)).create(recursive: true);
        final output = OutputFileStream(target);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
      } else {
        await Directory(target).create(recursive: true);
      }
    }
  } finally {
    await input.close();
  }
}
