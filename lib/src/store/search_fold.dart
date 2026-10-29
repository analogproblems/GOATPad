/// [text] the way search compares it: case folded, with accents taken off
/// Latin letters, so `Café`, `CAFE` and `café` all read `cafe`. This
/// matches what SQLite's trigram tokenizer does with `remove_diacritics 2`
/// (a test checks it letter by letter), so words found through the index
/// and words found by scanning agree.
///
/// If [sources] is given, it gets, for each code unit of the result, the
/// index in [text] of the code unit it came from, to map a match back.
String foldForSearch(String text, [List<int>? sources]) {
  final out = <int>[];
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      out.add(unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit);
      sources?.add(i);
      continue;
    }
    // Lowercasing can add a combining mark: İ becomes i and a dot.
    for (final lower in String.fromCharCode(unit).toLowerCase().codeUnits) {
      var folded = switch (lower) {
        >= 0xc0 && <= 0x24f => _latin.codeUnitAt(lower - 0xc0),
        >= 0x1e00 && <= 0x1eff => _latinAdditional.codeUnitAt(lower - 0x1e00),
        _ => lower,
      };
      folded = _caseFolds[folded] ?? folded;
      if (isCombiningMark(folded)) continue;
      out.add(folded);
      sources?.add(i);
    }
  }
  return String.fromCharCodes(out);
}

/// Where Unicode case folding, which SQLite uses, differs from Dart's
/// lowercasing: letters with two lower case forms, like the Greek final
/// sigma and the long s, and a few newer capitals Dart doesn't lowercase.
const _caseFolds = {
  0x00b5: 0x03bc, // µ micro sign: μ
  0x017f: 0x0073, // ſ long s: s
  0x03c2: 0x03c3, // ς final sigma: σ
  0x03d0: 0x03b2, // ϐ: β
  0x03d1: 0x03b8, // ϑ: θ
  0x03d5: 0x03c6, // ϕ: φ
  0x03d6: 0x03c0, // ϖ: π
  0x03f0: 0x03ba, // ϰ: κ
  0x03f1: 0x03c1, // ϱ: ρ
  0x03f5: 0x03b5, // ϵ: ε
  0x0524: 0x0525, // Ԥ: ԥ
  0x0526: 0x0527, // Ԧ: ԧ
  0x10c7: 0x2d27, // Ⴧ: ⴧ
  0x10cd: 0x2d2d, // Ⴭ: ⴭ
  0x1fbe: 0x03b9, // ι prosgegrammeni: ι
  0x2c70: 0x0252, // Ɒ: ɒ
  0x2c7e: 0x023f, // Ȿ: ȿ
  0x2c7f: 0x0240, // Ɀ: ɀ
  0x2ceb: 0x2cec, // Ⳬ: ⳬ
  0x2ced: 0x2cee, // Ⳮ: ⳮ
  0x2cf2: 0x2cf3, // Ⳳ: ⳳ
  0xa660: 0xa661, // Ꙡ: ꙡ
  0xa78d: 0x0265, // Ɥ: ɥ
  0xa790: 0xa791, // Ꞑ: ꞑ
  0xa792: 0xa793, // Ꞓ: ꞓ
  0xa7a0: 0xa7a1, // Ꞡ: ꞡ
  0xa7a2: 0xa7a3, // Ꞣ: ꞣ
  0xa7a4: 0xa7a5, // Ꞥ: ꞥ
  0xa7a6: 0xa7a7, // Ꞧ: ꞧ
  0xa7a8: 0xa7a9, // Ꞩ: ꞩ
  0xa7aa: 0x0266, // Ɦ: ɦ
};

/// Whether [unit] is one of the accents that combine with the letter before
/// it, as in text typed on a Mac: `e` followed by U+0301 for `é`.
bool isCombiningMark(int unit) => unit >= 0x300 && unit <= 0x36f;

// Generated from the Unicode decompositions: each letter that is a base
// letter plus accents becomes that base letter, in lower case, except ten
// rare letters SQLite leaves alone (Ǡ, Ǣ, Ǯ, Ǽ, Ǿ and their lower cases).
// A test checks every entry against SQLite. The first table covers U+00C0
// to U+024F, the second U+1E00 to U+1EFF.
const _latin =
    'aaaaaaæceeeeiiiiðnooooo×øuuuuyþßaaaaaaæceeeeiiiiðn'
    'ooooo÷øuuuuyþyaaaaaaccccccccddđđeeeeeeeeeegggggggg'
    'hhħħiiiiiiiiiıĳĳjjkkĸllllllŀŀłłnnnnnnŉŋŋooooooœœrr'
    'rrrrssssssssttttŧŧuuuuuuuuuuuuwwyyyzzzzzzſƀɓƃƃƅƅɔƈ'
    'ƈɖɗƌƌƍǝəɛƒƒɠɣƕɩɨƙƙƚƛɯɲƞɵooƣƣƥƥʀƨƨʃƪƫƭƭʈuuʊʋƴƴƶƶʒƹƹ'
    'ƺƻƽƽƾƿǀǁǂǃǆǆǆǉǉǉǌǌǌaaiioouuuuuuuuuuǝaaǡǡǣǣǥǥggkkoo'
    'ooǯǯjǳǳǳggƕƿnnaaǽǽǿǿaaaaeeeeiiiioooorrrruuuussttȝȝ'
    'hhƞȡȣȣȥȥaaeeooooooooyyȴȵȶȷȸȹⱥȼȼƚⱦȿɀɂɂƀʉʌɇɇɉɉɋɋɍɍɏɏ';
const _latinAdditional =
    'aabbbbbbccddddddddddeeeeeeeeeeffgghhhhhhhhhhiiiikk'
    'kkkkllllllllmmmmmmnnnnnnnnoooooooopppprrrrrrrrssss'
    'ssssssttttttttuuuuuuuuuuvvvvwwwwwwwwwwxxxxyyzzzzzz'
    'htwyẚſẜẝßẟaaaaaaaaaaaaaaaaaaaaaaaaeeeeeeeeeeeeeeee'
    'iiiioooooooooooooooooooooooouuuuuuuuuuuuuuyyyyyyyy'
    'ỻỻỽỽỿỿ';
