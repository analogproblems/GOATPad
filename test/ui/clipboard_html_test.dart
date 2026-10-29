import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/ui/clipboard_html.dart';

Uint8List _utf16(String text, {required bool littleEndian, bool mark = true}) {
  final bytes = <int>[
    if (mark) ...(littleEndian ? [0xff, 0xfe] : [0xfe, 0xff]),
  ];
  for (final unit in text.codeUnits) {
    final pair = [unit & 0xff, unit >> 8];
    bytes.addAll(littleEndian ? pair : pair.reversed);
  }
  return Uint8List.fromList(bytes);
}

void main() {
  const html = '<p>Café <b>☃</b> \u{1F600}</p>';

  test('UTF-8, as Chrome and most apps write it', () {
    expect(decodeClipboardHtml(Uint8List.fromList(utf8.encode(html))), html);
  });

  test('UTF-16 with a byte order mark, as Firefox has written it', () {
    expect(decodeClipboardHtml(_utf16(html, littleEndian: true)), html);
    expect(decodeClipboardHtml(_utf16(html, littleEndian: false)), html);
  });

  test('UTF-16 without a mark, and a trailing NUL', () {
    expect(
      decodeClipboardHtml(
        _utf16('$html\u0000', littleEndian: true, mark: false),
      ),
      html,
    );
  });

  test('no clipboard HTML outside Linux and Windows', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(await readClipboardHtml(), isNull);
  });
}
