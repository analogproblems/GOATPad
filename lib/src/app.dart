import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ServicesBinding;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'notepad/notepad.dart';
import 'sync/sync_controller.dart';
import 'theme.dart';
import 'ui/notepad_screen.dart';
import 'ui/tray.dart';

const _localizationsDelegates = [
  GlobalMaterialLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  FlutterQuillLocalizations.delegate,
];

class GPadApp extends StatefulWidget {
  const GPadApp({
    super.key,
    required this.notepad,
    this.sync,
    this.tray,
    this.exitForGood = _exitForGood,
  });

  final Notepad notepad;
  final SyncController? sync;
  final Tray? tray;

  /// Quits without asking, once Quit in the tray icon's menu has saved and
  /// uploaded everything. Tests replace it.
  final Future<void> Function() exitForGood;

  static Future<void> _exitForGood() =>
      ServicesBinding.instance.exitApplication(AppExitType.required);

  @override
  State<GPadApp> createState() => _GPadAppState();
}

class _GPadAppState extends State<GPadApp> {
  final _navigator = GlobalKey<NavigatorState>();

  // Typing is saved a moment after each keystroke. Save the last moment too
  // whenever the window loses focus, hides or closes.
  // Coming back to the window is a good moment to look for changes made
  // on other computers.
  late final _lifecycle = AppLifecycleListener(
    onStateChange: (_) => widget.notepad.flush(),
    onResume: () => widget.sync?.syncNow(),
    onExitRequested: _exitRequested,
  );

  /// Quits once everything is saved, and uploaded if sync is on (giving up
  /// after a few seconds; it goes up next time). If saving fails, asks
  /// before quitting and losing the latest changes.
  ///
  /// With the tray on, closing the window only hides it: GPad goes on
  /// saving and syncing, and quits from the tray icon's menu.
  Future<AppExitResponse> _exitRequested() async {
    final tray = widget.tray;
    if (tray != null && await tray.readyToKeepRunning()) {
      // What is typed so far goes up now, not only once GPad quits.
      widget.notepad.flush();
      widget.sync?.syncNow();
      await tray.hideWindow();
      return AppExitResponse.cancel;
    }
    return await _mayQuit() ? AppExitResponse.exit : AppExitResponse.cancel;
  }

  /// Quit, chosen in the tray icon's menu (once, if chosen twice).
  Future<void> _quitFromTray() async {
    if (_quitting) return;
    _quitting = true;
    try {
      if (!widget.notepad.flush()) {
        // Ask in the window, which may be hidden.
        await widget.tray?.showWindow();
      }
      if (!await _mayQuit()) return;
      await widget.tray?.remove();
      await widget.exitForGood();
    } finally {
      _quitting = false;
    }
  }

  bool _quitting = false;

  /// Saves and uploads what is waiting, and returns whether GPad may quit:
  /// when everything is saved, or the person says to quit anyway.
  Future<bool> _mayQuit() async {
    final notepad = widget.notepad;
    final context = _navigator.currentContext;
    if (notepad.flush()) {
      await widget.sync?.finish();
      return true;
    }
    if (context == null) return true;
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
          // The default: Enter keeps GPad open, and so does Escape.
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep GPad open'),
          ),
        ],
      ),
    );
    return quit == true;
  }

  @override
  void initState() {
    super.initState();
    _lifecycle;
    widget.tray?.onQuit = _quitFromTray;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    if (widget.tray?.onQuit == _quitFromTray) widget.tray?.onQuit = null;
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
        home: NotepadScreen(
          notepad: widget.notepad,
          sync: widget.sync,
          tray: widget.tray,
        ),
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
