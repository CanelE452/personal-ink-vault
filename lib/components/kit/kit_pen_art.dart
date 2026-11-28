// The drawings are strings assembled the way the preview assembles them, so `+`
// chains are kept to stay line-for-line comparable with it.
// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sbn/tool_id.dart';

/// The seven pens of the pen window, in the order of the preview (`PEN_NAME`).
enum KitPenKind {
  fountain('fountain', '펜(가는 촉)'),
  calligraphy('calli', '만년필(넓은 촉)'),
  finePen('pen', '가는 펜'),
  pencil('pencil', '연필'),
  brush('brush', '붓'),
  highlighterChisel('hlchisel', '납작 형광펜'),
  highlighterRound('hlround', '둥근 형광펜');

  new(this.previewId, this.label);

  /// The `kind` string of the preview.
  final String previewId;

  /// The preview's `PEN_NAME`.
  final String label;

  /// The engine tool this pen writes with, null for pens the engine lacks.
  /// The two highlighters are one tool; their nib tells them apart.
  ToolId? get toolId => switch (this) {
    fountain => ToolId.fountainPen,
    calligraphy => ToolId.calligraphyPen,
    finePen => ToolId.ballpointPen,
    pencil => ToolId.pencil,
    brush => ToolId.brush,
    highlighterChisel || highlighterRound => ToolId.highlighter,
  };

  bool get inEngine => toolId != null;

  bool get isHighlighter =>
      this == highlighterChisel || this == highlighterRound;
}

/// Line type of the fine pen's sample (preview `o.dash`).
enum KitPenDash { solid, dash, dot, thin }

// ---- number and colour helpers that behave like the preview's JavaScript ----

/// JavaScript's number-to-string: no ".0" on whole numbers.
String _n(num v) {
  final d = v.toDouble();
  if (d == d.roundToDouble() && d.abs() < 1e15) return d.toInt().toString();
  return d.toString();
}

/// JavaScript's `toFixed`.
String _fx(num v, int digits) =>
    (v == 0 ? 0.0 : v.toDouble()).toStringAsFixed(digits);

/// JavaScript's `+x.toFixed(2)`: two decimals, trailing zeros dropped.
String _op(double v) {
  var s = _fx(v, 2);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

String _hex(Color c) {
  int ch(double v) => (v * 255).round();
  final rgb = (ch(c.r) << 16) | (ch(c.g) << 8) | ch(c.b);
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}

List<int> _rgb(String h) {
  final n = int.parse(h.substring(1), radix: 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

/// [h] moved [p] of the way towards [t] (preview `mix`, rounding like Math.round).
String _mix(String h, String t, double p) {
  final a = _rgb(h);
  final b = _rgb(t);
  final out = StringBuffer('#');
  for (var i = 0; i < 3; i++) {
    final x = (a[i] + (b[i] - a[i]) * p + 0.5).floor();
    out.write((x < 16 ? '0' : '') + x.toRadixString(16));
  }
  return out.toString();
}

String _lit(String h, double p) => _mix(h, '#ffffff', p);
String _drk(String h, double p) => _mix(h, '#000000', p);

String _cyl(String id, String c) =>
    '<linearGradient id="$id" x1="0" x2="1">'
    '<stop offset="0" stop-color="${_drk(c, .17)}"/>'
    '<stop offset=".2" stop-color="${_lit(c, .08)}"/>'
    '<stop offset=".42" stop-color="${_lit(c, .3)}"/>'
    '<stop offset=".7" stop-color="$c"/>'
    '<stop offset="1" stop-color="${_drk(c, .27)}"/></linearGradient>';

String _facet(String id, String c) =>
    '<linearGradient id="$id" x1="0" x2="1">'
    '<stop offset="0" stop-color="${_drk(c, .22)}"/>'
    '<stop offset=".2" stop-color="${_drk(c, .12)}"/>'
    '<stop offset=".2" stop-color="${_lit(c, .1)}"/>'
    '<stop offset=".5" stop-color="${_lit(c, .24)}"/>'
    '<stop offset=".8" stop-color="$c"/>'
    '<stop offset=".8" stop-color="${_drk(c, .2)}"/>'
    '<stop offset="1" stop-color="${_drk(c, .32)}"/></linearGradient>';

// ---- pen drawing ----

/// A pen drawn on a 48 x 200 sheet (preview `penArt`). [selected] runs the ink
/// down the whole body, [ruler] adds the straight-line ticks, [nibRight] picks
/// the high side of the chisel highlighter's nib (preview switch `NIB_RIGHT`:
/// the right side high, as in photo 0082, decided on 2026-11-19).
String kitPenArtSvg(
  KitPenKind kind,
  Color ink, {
  bool selected = false,
  bool ruler = false,
  bool nibRight = true,
}) {
  final c = _hex(ink);
  String id(String s) => 'pa1$s';
  String u(String s) => 'url(#${id(s)})';

  final defs =
      _cyl(id('b'), '#f6f6f8') +
      _cyl(id('i'), c) +
      _cyl(id('g'), '#55585e') +
      _cyl(id('d'), '#3c3e43') +
      _cyl(id('k'), '#222428') +
      _cyl(id('m'), '#dfe2e6') +
      _cyl(id('w'), '#ecd8b8') +
      _facet(id('p'), c) +
      '<linearGradient id="${id('h')}" x1="0" y1="0" x2="0" y2="1">'
          '<stop offset="0" stop-color="$c"/>'
          '<stop offset=".42" stop-color="${_mix(c, '#9a9ca2', .55)}"/>'
          '<stop offset=".8" stop-color="#f3f3f5"/>'
          '<stop offset="1" stop-color="#ffffff"/></linearGradient>'
          '<linearGradient id="${id('s')}" x1="0" x2="1">'
          '<stop offset="0" stop-color="#000" stop-opacity=".16"/>'
          '<stop offset=".34" stop-color="#fff" stop-opacity=".3"/>'
          '<stop offset=".7" stop-color="#000" stop-opacity="0"/>'
          '<stop offset="1" stop-color="#000" stop-opacity=".2"/></linearGradient>'
          '<linearGradient id="${id('f')}" x1="0" y1="0" x2="0" y2="1">'
          '<stop offset=".56" stop-color="#fff"/>'
          '<stop offset=".74" stop-color="#fff" stop-opacity="0"/></linearGradient>'
          '<mask id="${id('x')}" maskUnits="userSpaceOnUse" x="0" y="0" width="48" height="200">'
          '<rect width="48" height="200" fill="${u('f')}"/></mask>';

  // Band from y0 to y1 then the white body; when chosen the ink runs from y0 down.
  String barrel(double y0, double y1) {
    var s =
        '<rect x="9" y="${_n(y0)}" width="30" height="${_n(200 - y0)}" fill="${u(selected ? 'i' : 'b')}"/>';
    if (!selected) {
      s +=
          '<rect x="9" y="${_n(y0)}" width="30" height="${_n(y1 - y0)}" fill="${u('i')}"/>'
          '<path d="M9 ${_n(y1 - .4)}h30" stroke="${_drk(c, .3)}" stroke-width=".8" opacity=".35"/>';
    }
    return s;
  }

  String ticks(double y0) {
    if (!ruler) return '';
    final t = StringBuffer();
    for (var k = 0; k < 13; k++) {
      t.write(
        '<path d="M9 ${_fx(y0 + 4 + k * 4.6, 1)}h${k % 4 == 0 ? 12 : 7}"/>',
      );
    }
    return '<g stroke="#1c1e22" stroke-width=".9" opacity=".55">$t</g>';
  }

  String nib(String d, double slot) =>
      '<path d="$d" fill="${u('m')}"/><path d="$d" fill="${u('s')}"/>'
      '<path d="M24 3.6V${_n(slot)}" stroke="${_drk(c, .25)}" stroke-width=".9"/>'
      '<rect x="22.7" y="${_n(slot - 2.6)}" width="2.6" height="11" rx="1.3" fill="$c"/>';

  final section =
      '<rect x="13.4" y="49.8" width="21.2" height="3.6" rx="1.2" fill="${u('k')}"/>'
      '<path d="M11.6 53.4h24.8c.9 0 1.7.6 1.9 1.5L39 58H9l.7-3.1c.2-.9 1-1.5 1.9-1.5z" fill="${u('i')}"/>';

  // Tip and neck squeezed from 57 to 46 units, the tip kept at y .8.
  String short(String x) => '<g transform="matrix(1 0 0 .804 0 .157)">$x</g>';

  final String s;
  switch (kind) {
    case KitPenKind.fountain:
      s =
          barrel(46.8, 69.3) +
          short(
            section +
                nib(
                  'M24 .8c1.6 6.6 7.4 18.8 10.6 29.6 1.4 4.8 1.6 9.8.6 14.4-.4 2-1.2 3.8-2.2 5.4H15c-1-1.6-1.8-3.4-2.2-5.4-1-4.6-.8-9.6.6-14.4C16.6 19.6 22.4 7.4 24 .8z',
                  30,
                ),
          ) +
          ticks(46.8);
    case KitPenKind.calligraphy:
      s =
          barrel(46.8, 69.3) +
          short(
            section +
                nib(
                  'M19.6 2.2h8.8l.7 2.4c1.6 7 4.8 16.2 5.6 25 .6 6.6-.4 13.4-2.6 20.2H15.9c-2.2-6.8-3.2-13.6-2.6-20.2.8-8.8 4-18 5.6-25z',
                  28,
                ) +
                '<path d="M19.6 2.2h8.8" stroke="#9aa1ab" stroke-width=".8"/>',
          ) +
          ticks(46.8);
    case KitPenKind.finePen:
      const cone =
          'M20.8 11.2h6.4C31.8 20.4 36.6 35.2 39 55.6H9c2.4-20.4 7.2-35.2 11.8-44.4z';
      s =
          barrel(60, 80) +
          '<rect x="9" y="55.4" width="30" height="4.8" fill="${u('b')}"/>'
              '<path d="$cone" fill="${u('b')}"/><path d="$cone" fill="${u('s')}"/>'
              '<path d="M18.6 22.4c-2.6 8-4.6 17.6-5.4 29.4" stroke="#fff" stroke-width="2.2" stroke-linecap="round" fill="none" opacity=".6"/>'
              '<path d="M9 55.6h30" stroke="#d2d5da" stroke-width=".8"/>'
              '<path d="M21.8 5.2h4.4l1 6h-6.4z" fill="${u('m')}"/>'
              '<path d="M23 .8h2l.8 4.6h-3.6z" fill="$c"/>' +
          ticks(60);
    case KitPenKind.pencil:
      const paint =
          'M9 64V58.6c.9-2.6 1.9-3.9 3-3.9s2.1 1.3 3 3.9c1.9-5.6 5.3-8.4 9-8.4s7.1 2.8 9 8.4c.9-2.6 1.9-3.9 3-3.9s2.1 1.3 3 3.9V64z';
      s =
          '<path d="M20.7 12.4h6.6L39 57H9z" fill="${u('w')}"/>'
              '<path d="M22.4 14c-1.4 12-4.2 26-8 40" stroke="#fff" stroke-width="1.6" opacity=".5" fill="none"/>' +
          (selected
              ? '<path d="$paint" fill="${u('p')}"/><rect x="9" y="63.6" width="30" height="136.4" fill="${u('p')}"/>'
              : '<path d="$paint" fill="${u('b')}"/><rect x="9" y="63.6" width="30" height="20.4" fill="${u('p')}"/><rect x="9" y="84" width="30" height="116" fill="${u('b')}"/>') +
          '<path d="M24 .8c.9 0 2.7 6.6 3.3 11.6h-6.6C21.3 7.4 23.1.8 24 .8z" fill="${_drk(c, .28)}"/>' +
          ticks(64);
    case KitPenKind.brush:
      const hair =
          'M24 .6C26.6 10 37.8 29 37.7 42c-.1 9.6-2 17.6-3.3 22.4H13.6C12.3 59.6 10.4 51.6 10.3 42 10.2 29 21.4 10 24 .6z';
      s =
          '<rect x="9" y="77.6" width="30" height="122.4" fill="${u(selected ? 'i' : 'b')}"/>'
              '<path d="M13.6 64h20.8l4.6 14H9z" fill="${u('i')}"/>'
              '<path d="M14 64.6h20" stroke="${_lit(c, .5)}" stroke-width=".8" opacity=".6"/>'
              '<path d="$hair" fill="${u('h')}"/>' +
          ticks(64);
    case KitPenKind.highlighterChisel:
      final face = nibRight
          ? '<path d="M29.6 11.5 18.4 15.3v4.5h11.2z" fill="$c"/>'
                '<path d="M26 12.72l3.6-1.22v8.3H26z" fill="${_drk(c, .1)}"/>'
                '<path d="M29.6 11.5 18.4 15.3v1.5L29.6 13z" fill="${_lit(c, .14)}"/>'
          : '<path d="M18.4 11.5 29.6 15.3v4.5H18.4z" fill="$c"/>'
                '<path d="M26 14.08l3.6 1.22v4.5H26z" fill="${_drk(c, .1)}"/>'
                '<path d="M18.4 11.5 29.6 15.3v1.5L18.4 13z" fill="${_lit(c, .14)}"/>';
      s =
          barrel(58, 82) +
          '<rect x="9" y="52" width="30" height="6" fill="${u('d')}"/>'
              '<path d="M16.6 26h14.8c1.1 0 2 .7 2.4 1.7L39 44v8H9v-8l5.2-16.3c.4-1 1.3-1.7 2.4-1.7z" fill="${u('g')}"/>'
              '<rect x="16.6" y="19.6" width="14.8" height="6.6" fill="${u('g')}"/>' +
          face +
          ticks(58);
    case KitPenKind.highlighterRound:
      s =
          barrel(52, 76) +
          '<path d="M18 25h12c1.3 0 2.3.8 2.7 2L39 38v14H9V38l6.3-11c.4-1.2 1.4-2 2.7-2z" fill="${u('g')}"/>'
              '<rect x="18" y="15.2" width="12" height="10" fill="${u('g')}"/>'
              '<path d="M19 15.4c0-4.44 2.2-7.5 5-7.5s5 3.06 5 7.5z" fill="$c"/>'
              '<path d="M26.4 9.28c1.6 1.38 2.6 3.52 2.6 6.12h-2.4c0-2.45-.1-4.44-.2-6.12z" fill="${_drk(c, .1)}"/>'
              '<ellipse cx="22.4" cy="11.57" rx="1" ry="1.53" fill="#fff" opacity=".18"/>' +
          ticks(52);
  }
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 200">'
      '<defs>$defs</defs><g mask="${u('x')}">'
      '<g transform="matrix(.8 0 0 1 4.8 0)">$s</g></g></svg>';
}

// ---- sample strokes ----

/// How far the slider value stretches each pen's sample: [thinnest, thickest]
/// as a factor of the drawn sample (preview `K_RANGE`, 7th draft part 2).
const Map<KitPenKind, (double, double)> _kRange = {
  KitPenKind.fountain: (.2, 2.6),
  KitPenKind.calligraphy: (.45, 1.75),
  KitPenKind.finePen: (.3, 1.5),
  KitPenKind.pencil: (.3, 3.4),
  KitPenKind.brush: (.5, 2.3),
  KitPenKind.highlighterChisel: (.12, 1.9),
  KitPenKind.highlighterRound: (.1, 2.05),
};

/// Size factor of the sample for a slider [level] (1 to 100, clamped); preview `kFor`.
double kitPenK(KitPenKind kind, int level) {
  final (lo, hi) = _kRange[kind]!;
  return lo + (hi - lo) * math.max(1, math.min(100, level)) / 100;
}

const _hook =
    'M0 32.3C1.6 30.9 6.6 25.7 9.4 23.7C12.3 21.7 14.7 20.9 17.1 20.3C19.5 19.8 22.5 20 23.9 20.3C25.4 20.6 25.2 20.5 25.6 22C26.1 23.6 26.1 28 26.5 29.7C26.9 31.4 26.9 32 28.2 32.3C29.5 32.6 33.2 31.6 34.2 31.4';
const _broad =
    'M1.7 34C1.6 33.4 .1 32 .9 30.6C1.6 29.2 3.1 27.2 6 25.5C8.8 23.7 14.8 21.2 17.9 20.3C21.1 19.5 23.2 20 24.8 20.3C26.4 20.6 26.9 20 27.4 22C27.8 24 26.6 30.6 27.4 32.3C28.1 34 30.1 32.7 31.6 32.3C33.2 31.9 35.9 30.2 36.8 29.7';
const _loop =
    'M0 33.1C1 32 3.8 28 6 26.3C8.1 24.6 10.3 23.5 12.8 22.9C15.4 22.3 19.4 22.3 21.4 22.9C23.4 23.5 24.5 24.7 24.8 26.3C25.1 27.9 24.2 31 23.1 32.3C21.9 33.6 19.2 34.1 17.9 34C16.7 33.9 15.8 31.9 15.4 31.4';
const _brushPath =
    'M0 33.1C0 32.6-.4 30.7 0 29.7C.4 28.7-.1 28.7 2.6 27.2C5.3 25.6 12.7 21.5 16.2 20.3C19.8 19.2 22.2 19.6 23.9 20.3C25.6 21 26.5 23 26.5 24.6C26.5 26.2 24.1 28.3 23.9 29.7C23.8 31.2 24.1 32.7 25.6 33.1C27.2 33.6 32.1 32.4 33.3 32.3';
const _roundPath =
    'M1.6 34c-.1-2.2 1.2-3.6 2.8-3.2 1.5.4 2 2 3.8 1.9 1.9-.1 2.2-2.5 4.3-2.5';

/// Chisel flag: a pole as wide as the nib standing on it, then a ribbon to about
/// 32 units; a small [h] only thins the ribbon.
String _flagPath(double h, double p, double x0) {
  const l = 32.0;
  final top = 34 - p;
  final a = math.min(2.4, .8 + h * .1);
  const n = 16;
  final up = StringBuffer();
  final dn = <String>[];
  for (var i = 0; i <= n; i++) {
    final t = i / n;
    final x = x0 + (l - x0) * t;
    final off = -a * math.sin(2 * math.pi * t);
    up.write('L${_fx(x, 2)} ${_fx(top + off, 2)}');
    dn.add('${_fx(x, 2)} ${_fx(top + off + h, 2)}');
  }
  return 'M0 40V${_fx(top, 2)}${up}L${dn.reversed.join('L')}L${_n(x0)} 40z';
}

/// The inside of a sample's 60 x 34 box, the stroke starting at (0, 34) on the
/// pen tip (preview `penSampleInner`). [k] is the size factor from [kitPenK],
/// [alpha] the opacity, [straight] the straight-line correction, [dash] the fine
/// pen's line type. The `smd` class of the write-in mask is kept as in the preview.
String kitPenSampleSvg(
  KitPenKind kind,
  Color ink, {
  required double k,
  double alpha = 1,
  bool straight = false,
  KitPenDash dash = KitPenDash.solid,
}) {
  final c = _hex(ink);
  var counter = 0;
  String g(String x, [double? op]) => '<g opacity="${_op(op ?? alpha)}">$x</g>';
  String line(String d, double w, [String extra = '']) =>
      '<path d="$d" fill="none" stroke="$c" stroke-width="${_fx(w, 2)}" stroke-linecap="round" stroke-linejoin="round"$extra/>';
  // Stroked samples sit in a mask drawn along their own centre line.
  String smpMask(String d, double w, String body) {
    final id = 'sm${++counter}';
    return '<defs><mask id="$id" maskUnits="userSpaceOnUse" x="-24" y="-30" width="120" height="96">'
        '<path class="smd" d="$d" fill="none" stroke="#fff" stroke-width="${_fx(w, 1)}" stroke-linecap="round" stroke-linejoin="round"/>'
        '</mask></defs><g mask="url(#$id)">$body</g>';
  }

  switch (kind) {
    case KitPenKind.fountain:
      final d = straight ? 'M0 32.6H34' : _hook;
      final w = 4.4 * k;
      return g(smpMask(d, w + 4, line(d, w)));
    case KitPenKind.calligraphy:
      // The same path stamped along the nib angle.
      final d = straight ? 'M1 33H36' : _broad;
      final len = 3.2 * k;
      final s = StringBuffer();
      for (var i = 0; i < 7; i++) {
        final t = i / 6 - .5;
        s.write(
          '<path d="$d" transform="translate(${_fx(t * len, 2)} ${_fx(-t * len, 2)})" fill="none" stroke="$c" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round"/>',
        );
      }
      return g(smpMask(d, len * 1.5 + 5, '$s'));
    case KitPenKind.finePen:
      final d = straight ? 'M0 32.6H34' : _hook;
      final w = (dash == KitPenDash.thin ? 1.8 : 3.6) * k;
      if (dash == KitPenDash.dot) {
        // 7th draft part 2: width max(1.13 + 0.017 v, 0.0857 v - 0.43) px, each dash
        // 1.55 x width + 0.4 long, gap 2, round caps; in units (px / 0.9) the dash
        // is the length minus one width and the space the gap plus one width.
        final dw = math.max(1.256 + 1.574 * (k - .3), 7.937 * (k - .3) - .478);
        final dl = .55 * dw + .44;
        final dg = 2.22 + dw;
        return g(
          smpMask(
            d,
            dw + 4,
            line(d, dw, ' stroke-dasharray="${_fx(dl, 2)} ${_fx(dg, 2)}"'),
          ),
        );
      }
      return g(
        smpMask(
          d,
          w + 4,
          line(
            d,
            w,
            dash == KitPenDash.dash
                ? ' stroke-dasharray="${_fx(7 * k, 2)} ${_fx(4.6 * k, 2)}"'
                : '',
          ),
        ),
      );
    case KitPenKind.pencil:
      // Graphite: a core with a light speckle and a sparse smudge that widens
      // with the width.
      final d = straight ? 'M0 33.1H34' : _loop;
      final w = 1.7 * k;
      final fa = 'pg${++counter}';
      final fb = 'pg${++counter}';
      String grain(String fid, String amp, String base, int seed) =>
          '<filter id="$fid" filterUnits="userSpaceOnUse" x="-24" y="-30" width="120" height="96">'
          '<feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="$seed" result="n"/>'
          '<feColorMatrix in="n" type="matrix" values="0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $amp $base" result="m"/>'
          '<feComposite in="SourceGraphic" in2="m" operator="in"/></filter>';
      return g(
        smpMask(
          d,
          w * 1.9 + 4,
          '<defs>${grain(fa, '2.4', '-0.1', 3)}${grain(fb, '3.4', '-1.1', 9)}</defs>'
          '<g filter="url(#$fb)">${line(d, w * 1.9, ' opacity=".55"')}</g>'
          '<g filter="url(#$fa)">${line(d, w, ' opacity=".92"')}</g>',
        ),
      );
    case KitPenKind.brush:
      // Thick at the tip, thinning to a hair: layers of falling width, each drawn
      // over a longer part of the path.
      final d = straight ? 'M0 32.6H34' : _brushPath;
      final s0 = 4.2 * k;
      const e = 1.7;
      const n = 7;
      final s = StringBuffer();
      for (var i = 0; i < n; i++) {
        final f = i / (n - 1);
        s.write(
          '<path d="$d" pathLength="1" stroke-dasharray="${_fx(math.max(.02, f), 3)} 2" fill="none" stroke="$c" stroke-width="${_fx(s0 - (s0 - e) * f, 2)}" stroke-linecap="round" stroke-linejoin="round"/>',
        );
      }
      return g('$s', alpha * .55);
    case KitPenKind.highlighterChisel:
      final hh = 10 * k;
      const pole = 8.3;
      final pp = math.max(hh * 1.1, 7.0);
      final d = straight
          ? 'M0 40V${_fx(34 - pp, 2)}H34V${_fx(34 - pp + hh, 2)}H${_n(pole)}V40z'
          : _flagPath(hh, pp, pole);
      return g('<path d="$d" fill="$c"/>');
    case KitPenKind.highlighterRound:
      final w = 10 * k;
      final d = straight ? 'M1.6 ${_fx(35 - w / 2, 2)}H29' : _roundPath;
      return g(smpMask(d, w + 4, line(d, w)));
  }
}

// ---- pencil sample (drawn, not SVG) ----

/// Path of an SVG `d` that uses only M, L, H and C with absolute numbers (every
/// sample path of the preview does).
Path _svgPath(String d) {
  final path = Path();
  final tokens = RegExp(r'[MLHC]|-?(?:\d+\.?\d*|\.\d+)')
      .allMatches(d)
      .map((m) => m.group(0)!)
      .toList();
  var i = 0;
  var cmd = 'M';
  var y = 0.0;
  double next() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    if (RegExp('[MLHC]').hasMatch(tokens[i])) cmd = tokens[i++];
    switch (cmd) {
      case 'M':
        final x = next();
        y = next();
        path.moveTo(x, y);
        cmd = 'L';
      case 'L':
        final x = next();
        y = next();
        path.lineTo(x, y);
      case 'H':
        path.lineTo(next(), y);
      case 'C':
        final x1 = next(), y1 = next(), x2 = next(), y2 = next();
        final x = next();
        y = next();
        path.cubicTo(x1, y1, x2, y2, x, y);
    }
  }
  return path;
}

/// The pencil sample. flutter_svg cannot run the preview's grain filter
/// (feTurbulence), so the pencil is drawn here with the same two layers: an
/// outer band 1.9 x the width at opacity .55 with sparse grain, and a core at
/// opacity .92 with small holes. Each layer is the stroke inside a saveLayer,
/// cut by a repeating grain tile with BlendMode.dstIn. The tiles are made once
/// from fixed random seeds, so the grain is the same on every draw and a
/// redraw at another width only strokes two paths and fills two rectangles.
class _PencilPainter extends CustomPainter {
  new(this.ink, this.k, this.alpha, this.straight);

  final Color ink;
  final double k;
  final double alpha;
  final bool straight;

  static const _tilePx = 256;
  static const _tileScale = .1; // 10 tile pixels per sample unit
  static const _bounds = Rect.fromLTWH(-24, -30, 120, 96);

  static ui.Image? _coreTile;
  static ui.Image? _bandTile;
  static ui.ImageShader? _coreShader;
  static ui.ImageShader? _bandShader;

  /// Blobs with an irregular outline (two circles) at fixed random places,
  /// wrapped so the tile repeats without a seam.
  static ui.Image _makeTile({
    required int seed,
    required int count,
    required double rMin,
    required double rMax,
    required bool holes,
    required Color color,
  }) {
    final rnd = math.Random(seed);
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    const rect = Rect.fromLTWH(0, 0, 256, 256);
    final fill = Paint()..color = color;
    if (holes) {
      c.saveLayer(rect, Paint());
      c.drawRect(rect, fill);
    }
    final p = Paint();
    for (var n = 0; n < count; n++) {
      final x = rnd.nextDouble() * _tilePx;
      final y = rnd.nextDouble() * _tilePx;
      final r = rMin + (rMax - rMin) * rnd.nextDouble();
      final ox = (rnd.nextDouble() - .5) * r * 1.4;
      final oy = (rnd.nextDouble() - .5) * r * 1.4;
      final a = holes
          ? .45 + .45 * rnd.nextDouble()
          : .35 + .65 * rnd.nextDouble();
      p
        ..color = color.withValues(alpha: a)
        ..blendMode = holes ? BlendMode.dstOut : BlendMode.srcOver;
      // Copies across the edge only where the blob reaches it.
      final xs = [0, if (x < 8) _tilePx, if (x > _tilePx - 8) -_tilePx];
      final ys = [0, if (y < 8) _tilePx, if (y > _tilePx - 8) -_tilePx];
      for (final dx in xs) {
        for (final dy in ys) {
          c.drawCircle(Offset(x + dx, y + dy), r, p);
          c.drawCircle(Offset(x + dx + ox, y + dy + oy), r * .6, p);
        }
      }
    }
    if (holes) c.restore();
    return rec.endRecording().toImageSync(_tilePx, _tilePx);
  }

  ui.ImageShader _shader(bool core) {
    if (core) {
      _coreTile ??= _makeTile(
        seed: 3,
        count: 420,
        rMin: 1.2,
        rMax: 3,
        holes: true,
        color: ink.withValues(alpha: 1),
      );
      return _coreShader ??= ui.ImageShader(
        _coreTile!,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.diagonal3Values(_tileScale, _tileScale, 1).storage,
        filterQuality: FilterQuality.medium,
      );
    }
    _bandTile ??= _makeTile(
      seed: 9,
      count: 4000,
      rMin: 1.4,
      rMax: 3.8,
      holes: false,
      color: ink.withValues(alpha: 1),
    );
    return _bandShader ??= ui.ImageShader(
      _bandTile!,
      TileMode.repeated,
      TileMode.repeated,
      (Matrix4.diagonal3Values(
        _tileScale,
        _tileScale,
        1,
      )..setTranslationRaw(3.7, 1.9, 0)).storage,
      filterQuality: FilterQuality.medium,
    );
  }

  void _layer(
    Canvas canvas,
    Path path,
    double width,
    double opacity,
    bool core,
  ) {
    canvas.saveLayer(_bounds, Paint()..color = ink.withValues(alpha: opacity));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = ink,
    );
    canvas.drawRect(
      _bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = _shader(core),
    );
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 60, size.height / 34);
    final path = _svgPath(straight ? 'M0 33.1H34' : _loop);
    final w = 1.7 * k;
    _layer(canvas, path, w * 1.9, .55 * alpha, false);
    _layer(canvas, path, w, .92 * alpha, true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PencilPainter old) =>
      old.ink != ink ||
      old.k != k ||
      old.alpha != alpha ||
      old.straight != straight;
}

// ---- widgets ----

/// How far, in sheet units, a sample may draw past its 60 x 34 box (the
/// preview's `drawOn` opens 16 around it).
const _sampleReach = 16.0;

final _strokeTag = RegExp(r'<(path|g)\b([^>]*?)(/?)>');

/// [svg] as flutter_svg should get it: stroke-only lines and groups without a
/// fill get `fill="none"`. flutter_svg paints such a line's default black fill
/// (Chrome paints nothing for a fill without area), which made the pens' rims,
/// band edges and nib slits darker than the preview. Nothing else changes, so
/// [kitPenArtSvg] stays the preview's drawing.
String kitSvgForFlutter(String svg) => svg.replaceAllMapped(_strokeTag, (m) {
  final attrs = m.group(2)!;
  if (!attrs.contains('stroke=') || attrs.contains('fill=')) return m.group(0)!;
  return '<${m.group(1)}$attrs fill="none"${m.group(3)}>';
});

final _pathTag = RegExp(r'<path\b[^>]*>');
final _pathD = RegExp(r'\sd="([^"]*)"');
final _dashes = RegExp(r'\sstroke-dasharray="([\d.]+) ([\d.]+)"');

/// A sample [svg] as flutter_svg should get it: a dash along a path of
/// `pathLength="1"` (the brush's layers, each over a part of the path) is
/// given in the path's own units. flutter_svg ignores pathLength, so a dash
/// of .5 was half a unit, not half the path, and the brush came out even
/// instead of thinning to its tail. [kitPenSampleSvg] stays the preview's.
/// The attributes may come in any order; a pathLength path without a `d` or
/// without two dash numbers is a [StateError].
String kitSampleForFlutter(String svg) => svg.replaceAllMapped(_pathTag, (m) {
  final tag = m.group(0)!;
  if (!tag.contains(' pathLength="1"')) return tag;
  final d = _pathD.firstMatch(tag);
  final dashes = _dashes.firstMatch(tag);
  if (d == null || dashes == null) {
    throw StateError('a pathLength path needs d and two dashes: $tag');
  }
  final length = _svgPath(d.group(1)!)
      .computeMetrics()
      .fold(0.0, (sum, metric) => sum + metric.length);
  String units(String v) => _fx(double.parse(v) * length, 3);
  return tag
      .replaceRange(
        dashes.start,
        dashes.end,
        ' stroke-dasharray="${units(dashes.group(1)!)} '
        '${units(dashes.group(2)!)}"',
      )
      .replaceFirst(' pathLength="1"', '');
});

/// A pen drawn on its 48 x 200 sheet; the parent decides the size.
class KitPenArt extends StatelessWidget {
  const new(
    this.kind,
    this.ink, {
    super.key,
    this.selected = false,
    this.ruler = false,
  });

  final KitPenKind kind;
  final Color ink;
  final bool selected;
  final bool ruler;

  @override
  Widget build(BuildContext context) => SvgPicture.string(
    kitSvgForFlutter(kitPenArtSvg(kind, ink, selected: selected, ruler: ruler)),
    fit: BoxFit.contain,
    excludeFromSemantics: true,
  );
}

/// The sample stroke of a pen at slider [level], drawn in its 60 x 34 box
/// and past it where the stroke reaches out (preview `.psmp{overflow:visible}`:
/// the chisel flag's pole, the round end at the tip).
class KitPenSample extends StatefulWidget {
  const new(
    this.kind,
    this.ink, {
    super.key,
    required this.level,
    this.alpha = 1,
    this.straight = false,
    this.dash = KitPenDash.solid,
  });

  final KitPenKind kind;
  final Color ink;
  final int level;
  final double alpha;
  final bool straight;
  final KitPenDash dash;

  @override
  State<KitPenSample> createState() => _KitPenSampleState();
}

class _KitPenSampleState extends State<KitPenSample> {
  /// The last sample drawing and the whole SVG made from it: the write-on
  /// animation builds the sample every frame, and turning the brush's dashes
  /// into path units ([kitSampleForFlutter]) measures its path.
  String? _inner;
  var _svg = '';

  String _svgFor(String inner) {
    if (inner != _inner) {
      _inner = inner;
      _svg =
          '<svg xmlns="http://www.w3.org/2000/svg" '
          'viewBox="${_n(-_sampleReach)} ${_n(-_sampleReach)} '
          '${_n(60 + 2 * _sampleReach)} ${_n(34 + 2 * _sampleReach)}">'
          '${kitSampleForFlutter(inner)}</svg>';
    }
    return _svg;
  }

  @override
  Widget build(BuildContext context) {
    final KitPenSample(:kind, :ink, :level, :alpha, :straight, :dash) = widget;
    if (kind == KitPenKind.pencil) {
      // Drawn instead of SVG: flutter_svg has no grain filter (see _PencilPainter).
      return FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: 60,
          height: 34,
          child: CustomPaint(
            painter: _PencilPainter(ink, kitPenK(kind, level), alpha, straight),
          ),
        ),
      );
    }
    final svg = _svgFor(
      kitPenSampleSvg(
        kind,
        ink,
        k: kitPenK(kind, level),
        alpha: alpha,
        straight: straight,
        dash: dash,
      ),
    );
    // flutter_svg cuts a drawing at its viewBox, so the sheet is drawn
    // _sampleReach units larger on every side and placed so its 60 x 34 box
    // sits where a plain 60 x 34 drawing would (centred, kept in proportion).
    return Center(
      child: AspectRatio(
        aspectRatio: 60 / 34,
        child: LayoutBuilder(
          builder: (context, box) {
            final scale = box.maxWidth / 60;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: -_sampleReach * scale,
                  top: -_sampleReach * scale,
                  width: (60 + 2 * _sampleReach) * scale,
                  height: (34 + 2 * _sampleReach) * scale,
                  child: SvgPicture.string(
                    svg,
                    fit: BoxFit.fill,
                    clipBehavior: Clip.none,
                    excludeFromSemantics: true,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
