/// Makes two SVG strings comparable: one space between tokens, every number
/// rounded to three decimals. Hex colours and the generated ids (pa1b, sm1, pg2)
/// are kept as written so their digits are not rounded.
String normalizeSvg(String svg) {
  final token = RegExp(
    r'#[0-9a-fA-F]+|\b(?:pa|sm|pg)\d+[a-z]?|-?(?:\d+\.?\d*|\.\d+)',
  );
  final rounded = svg.replaceAllMapped(token, (m) {
    final t = m.group(0)!;
    final c = t.codeUnitAt(0);
    final isNumber = c == 0x2d || c == 0x2e || (c >= 0x30 && c <= 0x39);
    if (!isNumber) return t;
    var s = double.parse(t).toStringAsFixed(3);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s == '-0' ? '0' : s;
  });
  return rounded.replaceAll(RegExp(r'\s+'), ' ').trim();
}
