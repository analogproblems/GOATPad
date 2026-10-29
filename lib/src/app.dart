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
  // Typing is saved a moment after each keystroke. Save the last moment too
  // whenever the window loses focus, hides or closes.
  late final _lifecycle = AppLifecycleListener(
    onStateChange: (_) => widget.notepad.flush(),
    onExitRequested: () async {
      widget.notepad.flush();
      return AppExitResponse.exit;
    },
  );

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
