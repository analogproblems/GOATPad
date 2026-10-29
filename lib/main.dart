import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/notepad/notepad.dart';
import 'src/store/data_location.dart';
import 'src/store/instance_door.dart';
import 'src/store/note_store.dart';
import 'src/sync/sync_controller.dart';
import 'src/ui/tray.dart';
import 'src/update/installation.dart';
import 'src/update/updater.dart';

Future<void> main(List<String> args) async {
  // A new version, from its staging folder, finishing an update on Windows
  // once the old one has quit. It shows nothing and opens no notes.
  if (args case [WindowsFolderInstallation.finishArgument, ...final rest]) {
    await WindowsFolderInstallation.finish(rest);
    exit(0);
  }
  WidgetsFlutterBinding.ensureInitialized();
  String? path;
  final Notepad notepad;
  try {
    path = await notesDatabasePath();
    notepad = Notepad.load(
      await _openStore(path, afterUpdate: args.contains(updatedArgument)),
    );
  } on StoreLockedException {
    // Perhaps in the tray: bring that GPad's window back instead.
    await Tray.allowOthersToFront();
    if (await InstanceDoor.knock(File(path!).parent.path)) exit(0);
    runApp(
      const StartupProblemApp(
        title: 'GPad is already open',
        message:
            'Your notes are open in another GPad window. Switch to that '
            'window, or close it and start GPad again.',
      ),
    );
    return;
  } on Object catch (error) {
    runApp(
      StartupProblemApp(
        title: 'GPad couldn\'t open your notes',
        message: path == null ? '$error' : '$error\n\nYour notes are in $path.',
      ),
    );
    return;
  }
  final sync = SyncController(notepad);
  final tray = Tray(sync);
  final updater = Updater(store: notepad.store);
  runApp(GPadApp(notepad: notepad, sync: sync, tray: tray, updater: updater));
  await InstanceDoor.open(File(path).parent.path, onKnock: tray.showWindow);
  // After the window is up: reading the keychain can take a moment, or
  // wait for the person to unlock it.
  await Future.wait([sync.start(), tray.start(), updater.start()]);
}

/// Opens the notes at [path]. Started by an update, gives the old GPad a
/// while to quit and let go of them.
Future<NoteStore> _openStore(String path, {required bool afterUpdate}) async {
  final giveUp = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    try {
      return NoteStore.open(path);
    } on StoreLockedException {
      if (!afterUpdate || DateTime.now().isAfter(giveUp)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }
}
