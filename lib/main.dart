import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/notepad/notepad.dart';
import 'src/store/data_location.dart';
import 'src/store/note_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final path = await notesDatabasePath();
  final Notepad notepad;
  try {
    notepad = Notepad.load(NoteStore.open(path));
  } on StoreLockedException {
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
        message: '$error\n\nYour notes are in $path.',
      ),
    );
    return;
  }
  runApp(GPadApp(notepad: notepad));
}
