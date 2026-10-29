import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:quill_native_bridge/quill_native_bridge.dart';

/// The channel GPad's Linux runner answers with the clipboard's `text/html`.
const clipboardChannel = MethodChannel('gpad/clipboard');

/// Reads the HTML that browsers, Word, Google Docs and LibreOffice put on the
/// clipboard next to the plain text, or null if there is none. Flutter's
/// own clipboard API only reads plain text.
///
/// On Linux it asks GTK through GPad's runner (`linux/runner`), and on
/// Windows it uses quill_native_bridge, which flutter_quill already
/// brings in. Anything going wrong reads as no HTML, so a paste always
/// falls back to the plain text.
Future<String?> readClipboardHtml() async {
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.linux:
        final bytes = await clipboardChannel.invokeMethod<Uint8List>('getHtml');
        return bytes == null ? null : decodeClipboardHtml(bytes);
      case TargetPlatform.windows:
        return await QuillNativeBridge().getClipboardHtml();
      default:
        return null;
    }
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Clipboard HTML on Linux is usually UTF-8, but Firefox has offered it as
/// UTF-16, with or without a byte order mark.
@visibleForTesting
String decodeClipboardHtml(Uint8List bytes) {
  String utf16(int start, {required bool littleEndian}) {
    final units = <int>[
      for (var i = start; i + 1 < bytes.length; i += 2)
        littleEndian
            ? bytes[i] | bytes[i + 1] << 8
            : bytes[i] << 8 | bytes[i + 1],
    ];
    return String.fromCharCodes(units);
  }

  final String text;
  if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xfe) {
    text = utf16(2, littleEndian: true);
  } else if (bytes.length >= 2 && bytes[0] == 0xfe && bytes[1] == 0xff) {
    text = utf16(2, littleEndian: false);
  } else if (bytes.length >= 4 && bytes[1] == 0 && bytes[3] == 0) {
    // ASCII markup in UTF-16 without a mark: every other byte is zero.
    text = utf16(0, littleEndian: true);
  } else {
    text = utf8.decode(bytes, allowMalformed: true);
  }
  return text.replaceAll('\u0000', '');
}
