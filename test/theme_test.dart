import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/code_colors.dart';
import 'package:goatpad/src/theme.dart';

/// WCAG 2 contrast ratio between two opaque colors.
double contrast(Color a, Color b) {
  double luminance(Color c) {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(c.r) +
        0.7152 * channel(c.g) +
        0.0722 * channel(c.b);
  }

  final la = luminance(a), lb = luminance(b);
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    for (final family in ThemeFamily.values) {
      test('colorblind-safe code colors meet 4.5:1 on ${family.label} '
          '${brightness.name}', () {
        final background = GoatTheme.editorBackground(family, brightness);
        colorblindSafeCodeColors(brightness).forEach((token, style) {
          final color = style.color;
          if (color == null) return;
          expect(
            contrast(color, background),
            greaterThanOrEqualTo(4.5),
            reason: '$token on $background',
          );
        });
      });
    }
  }

  test('every family builds in light and dark, with code colors attached', () {
    for (final family in ThemeFamily.values) {
      for (final colors in CodeColors.values) {
        for (final brightness in Brightness.values) {
          final theme = GoatTheme.build(
            Appearance(family: family, codeColors: colors),
            brightness,
          );
          expect(theme.brightness, brightness);
          expect(theme.extension<CodeTheme>()!.styles, isNotEmpty);
        }
      }
    }
  });
}
