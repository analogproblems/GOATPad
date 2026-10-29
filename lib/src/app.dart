import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'lab/editor_lab.dart';
import 'theme.dart';

class GPadApp extends StatefulWidget {
  const GPadApp({super.key});

  @override
  State<GPadApp> createState() => _GPadAppState();
}

class _GPadAppState extends State<GPadApp> {
  // Not saved yet; step 2 stores it with the rest of the settings.
  Appearance _appearance = const Appearance();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GPad',
      debugShowCheckedModeBanner: false,
      theme: GoatTheme.build(_appearance, Brightness.light),
      darkTheme: GoatTheme.build(_appearance, Brightness.dark),
      themeMode: _appearance.mode,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en')],
      home: EditorLab(
        appearance: _appearance,
        onAppearanceChanged: (a) => setState(() => _appearance = a),
      ),
    );
  }
}
