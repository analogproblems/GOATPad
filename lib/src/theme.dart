import 'package:flutter/material.dart';
import 'package:re_highlight/styles/kimbie-dark.dart';
import 'package:re_highlight/styles/kimbie-light.dart';

/// Warm paper-and-ink palettes. Kimbie is the closest warm syntax theme that
/// ships with re_highlight, so code matches the rest of the app.
class GoatTheme {
  static const _amber = Color(0xFFC8702A);
  static const _amberDark = Color(0xFFE39A55);

  static ThemeData light() => _build(
    ColorScheme.fromSeed(
      seedColor: _amber,
      brightness: Brightness.light,
      surface: const Color(0xFFFBF6EE),
      onSurface: const Color(0xFF3B3128),
    ).copyWith(
      primary: _amber,
      surfaceContainerLowest: const Color(0xFFFFFBF5),
      surfaceContainerLow: const Color(0xFFF5EEE3),
      surfaceContainer: const Color(0xFFEFE6D8),
      surfaceContainerHigh: const Color(0xFFE8DDCC),
    ),
  );

  static ThemeData dark() => _build(
    ColorScheme.fromSeed(
      seedColor: _amberDark,
      brightness: Brightness.dark,
      surface: const Color(0xFF1F1A16),
      onSurface: const Color(0xFFEADFD1),
    ).copyWith(
      primary: _amberDark,
      surfaceContainerLowest: const Color(0xFF181410),
      surfaceContainerLow: const Color(0xFF26201B),
      surfaceContainer: const Color(0xFF2D2620),
      surfaceContainerHigh: const Color(0xFF362E27),
    ),
  );

  static ThemeData _build(ColorScheme scheme) => ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.compact,
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.5),
      space: 1,
      thickness: 1,
    ),
  );

  static Map<String, TextStyle> codeTheme(Brightness brightness) =>
      brightness == Brightness.dark ? kimbieDarkTheme : kimbieLightTheme;

  static const monoFonts = [
    'Cascadia Mono',
    'Consolas',
    'JetBrains Mono',
    'DejaVu Sans Mono',
    'Liberation Mono',
    'monospace',
  ];
}
