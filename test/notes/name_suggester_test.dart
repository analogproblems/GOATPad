import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notes/name_suggester.dart';
import 'package:goatpad/src/notes/note_mode.dart';

void main() {
  final now = DateTime(2026, 10, 29, 14, 3);

  test('plain text uses its first non-empty line', () {
    expect(
      suggestName(
        '\n\n  Call the dentist\nFriday 9am',
        const ModeGuess.plain(),
        now,
      ),
      'Call the dentist',
    );
  });

  test('Markdown heading marks and emphasis are dropped', () {
    expect(
      suggestName('# **Trip** notes\n- train', const ModeGuess.rich(), now),
      'Trip notes',
    );
    expect(
      suggestName('- Pack the charger', const ModeGuess.rich(), now),
      'Pack the charger',
    );
  });

  test('code with a leading comment uses the comment', () {
    expect(
      suggestName(
        '// Fetch open notes\nfetch(url)',
        const ModeGuess.code('javascript'),
        now,
      ),
      'Fetch open notes',
    );
    expect(
      suggestName(
        '-- Monthly report\nSELECT 1;',
        const ModeGuess.code('sql'),
        now,
      ),
      'Monthly report',
    );
  });

  test('code without a comment gets language and time', () {
    expect(
      suggestName('{"a": 1}', const ModeGuess.code('json'), now),
      'JSON snippet 14:03',
    );
    expect(
      suggestName(
        '#!/usr/bin/env bash\nset -e',
        const ModeGuess.code('bash'),
        now,
      ),
      'Bash snippet 14:03',
    );
  });

  test('text with no words falls back to the time', () {
    expect(
      suggestName('12345 678', const ModeGuess.plain(), now),
      'Note 14:03',
    );
    expect(suggestName('', const ModeGuess.plain(), now), 'Note 14:03');
  });

  test('long lines are cut at a word boundary', () {
    final name = suggestName(
      'This is a very long first line that keeps going well past the limit',
      const ModeGuess.plain(),
      now,
    );
    expect(name.length, lessThanOrEqualTo(maxNameLength + 1));
    expect(name, endsWith('…'));
    expect(name, 'This is a very long first line that keeps going…');
  });
}
