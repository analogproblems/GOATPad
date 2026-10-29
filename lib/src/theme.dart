import 'package:flutter/material.dart';
import 'package:re_highlight/styles/a11y-dark.dart';
import 'package:re_highlight/styles/a11y-light.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:re_highlight/styles/kimbie-dark.dart';
import 'package:re_highlight/styles/kimbie-light.dart';
import 'package:re_highlight/styles/vs.dart';
import 'package:re_highlight/styles/vs2015.dart';

import 'code_colors.dart';

/// The look of the app chrome and editors. Each family has a light and a dark
/// version; [ThemeMode] picks between them.
enum ThemeFamily {
  warm('Warm', 'Paper and ink, amber accent'),
  classic('Classic', 'Plain white or black, like a traditional editor'),
  slate('Slate', 'Cool blue-grey, modern and neutral');

  const ThemeFamily(this.label, this.description);

  final String label;
  final String description;
}

/// Colors for syntax highlighting in Code notes, chosen separately from the
/// app theme.
enum CodeColors {
  matchTheme('Match theme', 'Syntax colors that suit the app theme'),
  colorblindSafe(
    'Colorblind-safe',
    'Okabe-Ito hues, bold keywords and italic comments',
  ),
  highContrast('High contrast', 'The a11y scheme, with strong contrast');

  const CodeColors(this.label, this.description);

  final String label;
  final String description;
}

/// What the person picked in the Appearance dialog.
class Appearance {
  const Appearance({
    this.family = ThemeFamily.warm,
    this.mode = ThemeMode.system,
    this.codeColors = CodeColors.matchTheme,
  });

  final ThemeFamily family;
  final ThemeMode mode;
  final CodeColors codeColors;

  Appearance copyWith({
    ThemeFamily? family,
    ThemeMode? mode,
    CodeColors? codeColors,
  }) => Appearance(
    family: family ?? this.family,
    mode: mode ?? this.mode,
    codeColors: codeColors ?? this.codeColors,
  );

  Map<String, String> toJson() => {
    'family': family.name,
    'mode': mode.name,
    'codeColors': codeColors.name,
  };

  /// Reads what [toJson] wrote. Anything missing or unknown, say from a newer
  /// GPad, falls back to the default.
  factory Appearance.fromJson(Map<String, Object?> json) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      return fallback;
    }

    const defaults = Appearance();
    return Appearance(
      family: pick(ThemeFamily.values, json['family'], defaults.family),
      mode: pick(ThemeMode.values, json['mode'], defaults.mode),
      codeColors: pick(
        CodeColors.values,
        json['codeColors'],
        defaults.codeColors,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Appearance &&
      other.family == family &&
      other.mode == mode &&
      other.codeColors == codeColors;

  @override
  int get hashCode => Object.hash(family, mode, codeColors);
}

/// Syntax colors for the code editor, carried on the [ThemeData].
class CodeTheme extends ThemeExtension<CodeTheme> {
  const CodeTheme(this.styles);

  final Map<String, TextStyle> styles;

  @override
  CodeTheme copyWith({Map<String, TextStyle>? styles}) =>
      CodeTheme(styles ?? this.styles);

  @override
  CodeTheme lerp(CodeTheme? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

class _Palette {
  const _Palette({
    required this.accent,
    required this.surface,
    required this.text,
    required this.lowest,
    required this.low,
    required this.container,
    required this.high,
  });

  final Color accent;
  final Color surface;
  final Color text;
  final Color lowest;
  final Color low;
  final Color container;
  final Color high;
}

const _palettes = {
  (ThemeFamily.warm, Brightness.light): _Palette(
    accent: Color(0xFFC8702A),
    surface: Color(0xFFFBF6EE),
    text: Color(0xFF3B3128),
    lowest: Color(0xFFFFFBF5),
    low: Color(0xFFF5EEE3),
    container: Color(0xFFEFE6D8),
    high: Color(0xFFE8DDCC),
  ),
  (ThemeFamily.warm, Brightness.dark): _Palette(
    accent: Color(0xFFE39A55),
    surface: Color(0xFF1F1A16),
    text: Color(0xFFEADFD1),
    lowest: Color(0xFF181410),
    low: Color(0xFF26201B),
    container: Color(0xFF2D2620),
    high: Color(0xFF362E27),
  ),
  (ThemeFamily.classic, Brightness.light): _Palette(
    accent: Color(0xFF0066B8),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF1F1F1F),
    lowest: Color(0xFFFFFFFF),
    low: Color(0xFFF3F3F3),
    container: Color(0xFFECECEC),
    high: Color(0xFFE0E0E0),
  ),
  (ThemeFamily.classic, Brightness.dark): _Palette(
    accent: Color(0xFF3794FF),
    surface: Color(0xFF1E1E1E),
    text: Color(0xFFD4D4D4),
    lowest: Color(0xFF1E1E1E),
    low: Color(0xFF252526),
    container: Color(0xFF2D2D2D),
    high: Color(0xFF383838),
  ),
  (ThemeFamily.slate, Brightness.light): _Palette(
    accent: Color(0xFF4F5BD5),
    surface: Color(0xFFF6F8FA),
    text: Color(0xFF1F2328),
    lowest: Color(0xFFFFFFFF),
    low: Color(0xFFF0F3F6),
    container: Color(0xFFEAEEF2),
    high: Color(0xFFDDE3E9),
  ),
  (ThemeFamily.slate, Brightness.dark): _Palette(
    accent: Color(0xFF8B96FF),
    surface: Color(0xFF15191F),
    text: Color(0xFFD6DCE4),
    lowest: Color(0xFF0F1318),
    low: Color(0xFF1B2028),
    container: Color(0xFF222833),
    high: Color(0xFF2A313D),
  ),
};

class GoatTheme {
  static ThemeData build(Appearance appearance, Brightness brightness) {
    final p = _palettes[(appearance.family, brightness)]!;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: p.accent,
          brightness: brightness,
          surface: p.surface,
          onSurface: p.text,
        ).copyWith(
          primary: p.accent,
          surfaceContainerLowest: p.lowest,
          surfaceContainerLow: p.low,
          surfaceContainer: p.container,
          surfaceContainerHigh: p.high,
        );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.compact,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        space: 1,
        thickness: 1,
      ),
      extensions: [
        CodeTheme(
          codeStyles(appearance.family, appearance.codeColors, brightness),
        ),
      ],
    );
  }

  /// The editor background for a family, which code colors must contrast with.
  static Color editorBackground(ThemeFamily family, Brightness brightness) =>
      _palettes[(family, brightness)]!.lowest;

  static Map<String, TextStyle> codeStyles(
    ThemeFamily family,
    CodeColors colors,
    Brightness brightness,
  ) {
    final dark = brightness == Brightness.dark;
    return switch (colors) {
      CodeColors.colorblindSafe => colorblindSafeCodeColors(brightness),
      CodeColors.highContrast => dark ? a11YDarkTheme : a11YLightTheme,
      CodeColors.matchTheme => switch (family) {
        ThemeFamily.warm => dark ? kimbieDarkTheme : kimbieLightTheme,
        ThemeFamily.classic => dark ? vs2015Theme : vsTheme,
        ThemeFamily.slate => dark ? githubDarkTheme : githubTheme,
      },
    };
  }

  static const monoFonts = [
    'Cascadia Mono',
    'Consolas',
    'JetBrains Mono',
    'DejaVu Sans Mono',
    'Liberation Mono',
    'monospace',
  ];
}
