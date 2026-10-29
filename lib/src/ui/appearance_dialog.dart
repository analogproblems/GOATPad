import 'package:flutter/material.dart';

import '../theme.dart';

/// Theme, light or dark, and code colors. Changes apply as you pick them.
Future<void> showAppearanceDialog(
  BuildContext context, {
  required Appearance appearance,
  required ValueChanged<Appearance> onChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _AppearanceDialog(initial: appearance, onChanged: onChanged),
  );
}

class _AppearanceDialog extends StatefulWidget {
  const _AppearanceDialog({required this.initial, required this.onChanged});

  final Appearance initial;
  final ValueChanged<Appearance> onChanged;

  @override
  State<_AppearanceDialog> createState() => _AppearanceDialogState();
}

class _AppearanceDialogState extends State<_AppearanceDialog> {
  late Appearance _appearance = widget.initial;

  void _set(Appearance appearance) {
    setState(() => _appearance = appearance);
    widget.onChanged(appearance);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.outline,
      letterSpacing: 1.2,
    );

    return AlertDialog(
      title: const Text('Appearance'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('THEME', style: heading),
              RadioGroup<ThemeFamily>(
                groupValue: _appearance.family,
                onChanged: (f) => _set(_appearance.copyWith(family: f)),
                child: Column(
                  children: [
                    for (final family in ThemeFamily.values)
                      RadioListTile<ThemeFamily>(
                        dense: true,
                        value: family,
                        title: Text(family.label),
                        subtitle: Text(family.description),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text('LIGHT OR DARK', style: heading),
              const SizedBox(height: 8),
              SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: ThemeMode.system, label: Text('System')),
                  ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                  ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
                ],
                selected: {_appearance.mode},
                onSelectionChanged: (s) =>
                    _set(_appearance.copyWith(mode: s.first)),
              ),
              const SizedBox(height: 16),
              Text('CODE COLORS', style: heading),
              RadioGroup<CodeColors>(
                groupValue: _appearance.codeColors,
                onChanged: (c) => _set(_appearance.copyWith(codeColors: c)),
                child: Column(
                  children: [
                    for (final colors in CodeColors.values)
                      RadioListTile<CodeColors>(
                        dense: true,
                        value: colors,
                        title: Text(colors.label),
                        subtitle: Text(colors.description),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
