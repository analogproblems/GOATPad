import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'notepad/notepad.dart';
import 'theme.dart';
import 'ui/notepad_screen.dart';

const _localizationsDelegates = [
  GlobalMaterialLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  FlutterQuillLocalizations.delegate,
];

class GPadApp extends StatefulWidget {
  const GPadApp({super.key, required this.notepad});

  final Notepad notepad;

  @override
  State<GPadApp> createState() => _GPadAppState();
}

class _GPadAppState extends State<GPadApp> {
  final _navigator = GlobalKey<NavigatorState>();

  // Typing is saved a moment after each keystroke. Save the last moment too
  // whenever the window loses focus, hides or closes.
  late final _lifecycle = AppLifecycleListener(
    onStateChange: (_) => widget.notepad.flush(),
    onExitRequested: _exitRequested,
  );

  /// Quits once everything is saved. If saving fails, asks before quitting
  /// and losing the latest changes.
  Future<AppExitResponse> _exitRequested() async {
    final notepad = widget.notepad;
    final context = _navigator.currentContext;
    if (notepad.flush() || context == null) return AppExitResponse.exit;
    final quit = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Your latest changes aren\'t saved'),
        content: Text(
          'GPad couldn\'t save them (${notepad.saveProblem}). If you quit '
          'now, they will be lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Quit anyway'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep GPad open'),
          ),
        ],
      ),
    );
    return quit == true ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  @override
  void initState() {
    super.initState();
    _lifecycle;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Appearance>(
      valueListenable: widget.notepad.appearance,
      builder: (context, appearance, _) => MaterialApp(
        title: 'GPad',
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        theme: GoatTheme.build(appearance, Brightness.light),
        darkTheme: GoatTheme.build(appearance, Brightness.dark),
        themeMode: appearance.mode,
        localizationsDelegates: _localizationsDelegates,
        supportedLocales: const [Locale('en')],
        home: NotepadScreen(notepad: widget.notepad),
      ),
    );
  }
}

/// Shown instead of the notepad when GPad can't open the notes.
class StartupProblemApp extends StatelessWidget {
  const StartupProblemApp({
    super.key,
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final appearance = const Appearance();
    return MaterialApp(
      title: 'GPad',
      debugShowCheckedModeBanner: false,
      theme: GoatTheme.build(appearance, Brightness.light),
      darkTheme: GoatTheme.build(appearance, Brightness.dark),
      localizationsDelegates: _localizationsDelegates,
      supportedLocales: const [Locale('en')],
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  SelectableText(message),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
