import 'dart:async';
import 'dart:math' as math;

import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_swatches.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pinned_colors.dart';

/// The colour pages' names (preview `CPAGES`, lines 2116-2121; 「기본 색」 for
/// the preview's 「기본」, design review M-3).
const _pageNames = ['기본 색', '파스텔', '회색조', '최근 색', '고정한 색'];

const _greyPage = 2;
const _recentPage = 3;
const _pinnedPage = 4;

/// One page shows at most eight colours (the 218 wide page area); a longer
/// list goes on more pages, numbered (「최근 색 1/2」).
const _perPage = 8;

/// The most pinned colours (preview `cpPin`: 고정은 8개까지, line 2286).
const maxPinnedColors = 8;

const _pinHint = '길게 눌러 고정';
const _pinsFull = '고정은 8개까지';

/// The pen panel's colour row: the basic, pastel and grey pages, then the
/// recent and pinned colours (pages without colours are hidden with their
/// dots), the eyedropper when [onEyedropper] is given, and the colour wheel.
///
/// Colours show as the page shows them; [onSelected] gets the colour to keep,
/// and only a press sets a colour (opening the row never does). A long press
/// pins a colour or takes its pin off.
class KitPenColorRow extends StatefulWidget {
  const new({
    super.key,
    required this.selected,
    required this.onSelected,
    this.onEyedropper,
  });

  /// The pen's colour (any opacity).
  final Color? selected;
  final ValueChanged<Color> onSelected;
  final VoidCallback? onEyedropper;

  @override
  State<KitPenColorRow> createState() => _KitPenColorRowState();
}

class _KitPenColorRowState extends State<KitPenColorRow> {
  String? _note;
  Timer? _noteTimer;

  @override
  void dispose() {
    _noteTimer?.cancel();
    super.dispose();
  }

  void _showNote(String note) {
    _noteTimer?.cancel();
    setState(() => _note = note);
    _noteTimer = Timer(KitMotion.noteShow, () {
      if (mounted) setState(() => _note = null);
    });
  }

  /// Pins [colour] or takes its pin off. A basic colour (the first page,
  /// 「기본 색」) unpinned does not go back to the recent ones while
  /// 「기본 색은 최근 색에 넣지 않기」 is on; pastel and grey colours do.
  void _togglePin(Color colour) {
    final basic = KitTokens.penPanelColorPages.first.contains(colour);
    final change = PinnedColors.toggle(
      colour.toARGB32().toString(),
      max: maxPinnedColors,
      backToRecent: !(basic && stows.recentColorsDontSavePresets.value),
    );
    if (change == PinChange.full) _showNote(_pinsFull);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      stows.recentColorsPositioned,
      stows.pinnedColors,
    ]),
    builder: (context, _) => _swatches(context),
  );

  Widget _swatches(BuildContext context) {
    final invert = inkInverted(context);
    Color show(Color c) => visibleInk(c, invert);
    final sources = [
      ...KitTokens.penPanelColorPages,
      _parse(stows.recentColorsPositioned.value),
      _parse(stows.pinnedColors.value),
    ];
    final kept = <List<Color>>[]; // each shown page, in the colours to keep
    final names = <String>[];
    final hints = <String?>[];
    final firstPageOf = <int, int>{};
    for (final (source, colours) in sources.indexed) {
      final parts = (colours.length + _perPage - 1) ~/ _perPage;
      for (var part = 0; part < parts; part++) {
        firstPageOf[source] ??= kept.length;
        kept.add(
          colours.sublist(
            part * _perPage,
            math.min((part + 1) * _perPage, colours.length),
          ),
        );
        final name = _pageNames[source];
        names.add(parts > 1 ? '$name ${part + 1}/$parts' : name);
        hints.add(
          source == _recentPage && sources[_pinnedPage].isEmpty
              ? _pinHint
              : null,
        );
      }
    }
    final shownPages = [
      for (final page in kept) [for (final c in page) show(c)],
    ];
    final keep = <Color, Color>{
      for (final page in kept)
        for (final c in page) show(c): c,
    };
    final chosen = widget.selected?.withValues(alpha: 1);
    final rings = [for (final page in kept) _match(page, chosen)];
    return KitSwatches(
      pages: shownPages,
      pageNames: names,
      pageHints: hints,
      note: _note,
      initialPage: _firstPage(sources, rings, firstPageOf, chosen),
      pinned: {for (final c in sources[_pinnedPage]) show(c)},
      selected: null,
      isSelected: (page, c) =>
          page < rings.length && rings[page] != null && show(rings[page]!) == c,
      colourLabel: (page, index, colour) => '색 ${index + 1}',
      onSelected: (c) => widget.onSelected(keep[c] ?? c),
      onLongPressColor: (c) => _togglePin(keep[c] ?? c),
      onEyedropper: widget.onEyedropper,
      onPalette: () async {
        final made = await showKitColorPicker(
          context,
          initial: widget.selected ?? Colors.black,
        );
        if (made != null) widget.onSelected(made);
      },
    );
  }

  /// The page the row opens on:
  /// 1. a colour found only among the recent ones (the eyedropper's, a made
  ///    colour) opens the recent page;
  /// 2. otherwise the first page that holds the colour, a near grey counting
  ///    as the same (so black opens the basic page on its #1f2023);
  /// 3. a colour no page holds opens the greys when 「회색조 색 먼저 보기」
  ///    (`preferGreyscale`) is on, else the basic page.
  static int _firstPage(
    List<List<Color>> sources,
    List<Color?> rings,
    Map<int, int> firstPageOf,
    Color? chosen,
  ) {
    if (chosen != null) {
      final holders = [
        for (final (i, colours) in sources.indexed)
          if (colours.contains(chosen)) i,
      ];
      if (holders.length == 1 && holders.single == _recentPage) {
        return firstPageOf[_recentPage]!;
      }
      final holder = rings.indexWhere((ring) => ring != null);
      if (holder >= 0) return holder;
    }
    return stows.preferGreyscale.value ? firstPageOf[_greyPage]! : 0;
  }

  /// The colour of [page] that gets the chosen ring for [chosen]: the same
  /// colour, or else the nearest grey within `penColorSameGreyLuma`.
  static Color? _match(List<Color> page, Color? chosen) {
    if (chosen == null) return null;
    if (page.contains(chosen)) return chosen;
    if (!_grey(chosen)) return null;
    Color? best;
    var bestGap = KitTokens.penColorSameGreyLuma;
    for (final c in page) {
      if (!_grey(c)) continue;
      final gap = (_luma(c) - _luma(chosen)).abs();
      if (gap <= bestGap) {
        best = c;
        bestGap = gap;
      }
    }
    return best;
  }

  static double _luma(Color c) =>
      255 * (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b);

  static bool _grey(Color c) =>
      255 *
          (math.max(c.r, math.max(c.g, c.b)) -
              math.min(c.r, math.min(c.g, c.b))) <=
      KitTokens.penColorSameGreyChroma;

  /// Colours as the recent and pinned lists keep them (ARGB numbers), opaque.
  static List<Color> _parse(List<String> list) => [
    for (final s in list)
      if (int.tryParse(s) case final v?) Color(v).withValues(alpha: 1),
  ];
}

/// The colour wheel of 229's 「색 만들기」. It opens on [initial] as the page
/// shows it and gives back the colour to keep (inverted back in the dark
/// theme), or null when it is closed without saving. With [pageInk] false
/// the colour is not one the page inverts (the text box's letters): it is
/// shown and given back as it is.
Future<Color?> showKitColorPicker(
  BuildContext context, {
  required Color initial,
  bool pageInk = true,
}) async {
  final invert = pageInk && inkInverted(context);
  var picked = visibleInk(initial, invert);
  final save = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(KitIconName.custom.label),
      content: SingleChildScrollView(
        child: ColorPicker(
          color: picked,
          pickersEnabled: const {ColorPickerType.wheel: true},
          onColorChanged: (c) => picked = c,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(MaterialLocalizations.of(context).saveButtonLabel),
        ),
      ],
    ),
  );
  return save == true ? picked.withInversion(invert) : null;
}
