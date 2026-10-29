import 'package:flutter/material.dart';

import '../notes/folder.dart';
import '../notes/note_mode.dart';

IconData modeIcon(NoteMode mode) => switch (mode) {
  NoteMode.rich => Icons.article_outlined,
  NoteMode.code => Icons.code,
  NoteMode.plain => Icons.notes,
};

/// A color for [folder] that stays the same from run to run, so its tab
/// group and its sidebar icon match. The group's name is always shown too,
/// so nothing depends on telling the colors apart.
Color folderColor(BuildContext context, Folder folder) {
  var hash = 0;
  for (final unit in folder.id.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final color = _okabeIto[hash % _okabeIto.length];
  // Lighter on dark themes, where the deep blue and vermillion get lost.
  return Theme.of(context).brightness == Brightness.dark
      ? Color.lerp(color, Colors.white, 0.35)!
      : color;
}

// Okabe-Ito hues, chosen to stay distinct with color blindness. Yellow is
// left out: it vanishes on light themes.
const _okabeIto = [
  Color(0xFF0072B2), // blue
  Color(0xFFE69F00), // orange
  Color(0xFF009E73), // bluish green
  Color(0xFFD55E00), // vermillion
  Color(0xFFCC79A7), // reddish purple
  Color(0xFF56B4E9), // sky blue
];
