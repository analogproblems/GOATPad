import 'package:flutter/material.dart';

/// Syntax colors that stay distinguishable with the common kinds of color
/// blindness. Hues follow the Okabe-Ito palette (blue, bluish green, orange,
/// vermillion, reddish purple), which avoids red/green pairs, darkened or
/// lightened so every color keeps at least 4.5:1 contrast with the editor
/// background. Keywords are bold and comments italic, so the main token kinds
/// differ by more than color alone.
Map<String, TextStyle> colorblindSafeCodeColors(Brightness brightness) =>
    brightness == Brightness.dark ? _dark : _light;

Map<String, TextStyle> _scheme({
  required Color text,
  required Color blue,
  required Color green,
  required Color orange,
  required Color vermillion,
  required Color purple,
  required Color muted,
}) {
  final keyword = TextStyle(color: blue, fontWeight: FontWeight.bold);
  final name = TextStyle(color: blue);
  final string = TextStyle(color: green);
  final number = TextStyle(color: orange);
  final title = TextStyle(color: vermillion);
  final type = TextStyle(color: purple);
  final comment = TextStyle(color: muted, fontStyle: FontStyle.italic);
  final meta = TextStyle(color: muted);

  return {
    'root': TextStyle(color: text),
    'keyword': keyword,
    'selector-tag': keyword,
    'meta-keyword': keyword,
    'built_in': type,
    'type': type,
    'title.class_': type,
    'title.class_.inherited__': type,
    'class': type,
    'title': title,
    'title.function_': title,
    'section': title.copyWith(fontWeight: FontWeight.bold),
    'deletion': title,
    'string': string,
    'regexp': string,
    'addition': string,
    'meta-string': string,
    'number': number,
    'literal': number,
    'symbol': number,
    'bullet': number,
    'link': number.copyWith(decoration: TextDecoration.underline),
    'attr': name,
    'attribute': name,
    'variable': name,
    'variable.language_': keyword,
    'template-variable': name,
    'name': name,
    'tag': name,
    'property': name,
    'params': name,
    'selector-id': name,
    'selector-class': name,
    'selector-attr': name,
    'selector-pseudo': name,
    'comment': comment,
    'quote': comment,
    'doctag': comment.copyWith(fontWeight: FontWeight.bold),
    'meta': meta,
    'subst': TextStyle(color: text),
    'emphasis': const TextStyle(fontStyle: FontStyle.italic),
    'strong': const TextStyle(fontWeight: FontWeight.bold),
  };
}

final _light = _scheme(
  text: const Color(0xFF1F1F1F),
  blue: const Color(0xFF0060A0),
  green: const Color(0xFF00704F),
  orange: const Color(0xFF8A5A00),
  vermillion: const Color(0xFFB03E00),
  purple: const Color(0xFF9C3F78),
  muted: const Color(0xFF5F6B73),
);

final _dark = _scheme(
  text: const Color(0xFFE6E6E6),
  blue: const Color(0xFF56B4E9),
  green: const Color(0xFF3CC39A),
  orange: const Color(0xFFE69F00),
  vermillion: const Color(0xFFF08A4B),
  purple: const Color(0xFFD98CB8),
  muted: const Color(0xFF9AA5AD),
);
