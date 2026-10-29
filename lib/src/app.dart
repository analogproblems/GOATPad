import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'lab/editor_lab.dart';
import 'theme.dart';

class GoatPadApp extends StatefulWidget {
  const GoatPadApp({super.key});

  @override
  State<GoatPadApp> createState() => _GoatPadAppState();
}

class _GoatPadAppState extends State<GoatPadApp> {
  ThemeMode _themeMode = ThemeMode.system;

  void _toggleTheme() {
    final platformDark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final isDark =
        _themeMode == ThemeMode.dark ||
        (_themeMode == ThemeMode.system && platformDark);
    setState(() => _themeMode = isDark ? ThemeMode.light : ThemeMode.dark);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GOATPad',
      debugShowCheckedModeBanner: false,
      theme: GoatTheme.light(),
      darkTheme: GoatTheme.dark(),
      themeMode: _themeMode,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        FlutterQuillLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en')],
      home: EditorLab(onToggleTheme: _toggleTheme),
    );
  }
}
