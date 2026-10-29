import 'dart:io';

import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/notepad/notepad.dart';
import 'src/store/data_location.dart';
import 'src/store/instance_door.dart';
import 'src/store/note_store.dart';
import 'src/sync/sync_controller.dart';
import 'src/ui/tray.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String? path;
  final Notepad notepad;
  try {
    path = await notesDatabasePath();
    notepad = Notepad.load(NoteStore.open(path));
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
  runApp(GPadApp(notepad: notepad, sync: sync, tray: tray));
  await InstanceDoor.open(File(path).parent.path, onKnock: tray.showWindow);
  // After the window is up: reading the keychain can take a moment, or
  // wait for the person to unlock it.
  await Future.wait([sync.start(), tray.start()]);
}
