import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The note window of the toolbar's second button (preview 9th draft c
/// `.c9note`, Flexcil's floating note): a lined sheet that rises from the
/// bottom right of the page area. Stage 1 has no quick note yet, so it only
/// shows and closes; nothing written on it is kept.
///
/// The host lays it over the page area with `Positioned.fill`; beside the
/// sheet, taps reach the page.
class KitNoteSheet extends StatefulWidget {
  const new({super.key, required this.open});

  final ValueNotifier<bool> open;

  @override
  State<KitNoteSheet> createState() => _KitNoteSheetState();
}

abstract final class _Sheet {
  static const width = 300.0;
  static const height = 372.0;
  static const inset = 12.0;
  static const radius = 16.0;
  static const headHeight = 44.0;
  static const headButton = 34.0;
  static const headIcon = 22.0;
  static const headIconStroke = 1.4875 * 24 / headIcon;
  static const headInk = KitTokens.noteSheetHeadInk;
  static const lineGap = 26.0;
  static const paper = KitTokens.noteSheetPaper;
  static const paperLine = KitTokens.noteSheetPaperLine;

  /// It starts this far under its place (CSS `translateY(calc(100% + 24px))`).
  static const below = 24.0;
  static const rise = Duration(milliseconds: 160);
  static const shadow = KitTokens.noteSheetShadow;
}

class _KitNoteSheetState extends State<KitNoteSheet>
    with SingleTickerProviderStateMixin {
  late final _rise = AnimationController(
    vsync: this,
    value: widget.open.value ? 1 : 0,
  );
  late final _curve = CurvedAnimation(
    parent: _rise,
    curve: KitMotion.samsungDecel,
  );

  @override
  void initState() {
    super.initState();
    widget.open.addListener(_follow);
    _rise.addStatusListener((_) => setState(() {}));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    _rise
      ..duration = still ? Duration.zero : _Sheet.rise
      ..reverseDuration = still ? Duration.zero : _Sheet.rise;
  }

  void _follow() {
    if (widget.open.value) {
      _rise.forward();
    } else {
      _rise.reverse();
    }
  }

  @override
  void dispose() {
    widget.open.removeListener(_follow);
    _curve.dispose();
    _rise.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_rise.isDismissed) return const SizedBox.shrink();
    return ClipRect(
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.all(_Sheet.inset),
          child: AnimatedBuilder(
            animation: _curve,
            builder: (context, child) => Transform.translate(
              offset: Offset(
                0,
                (1 - _curve.value) *
                    (_Sheet.height + _Sheet.inset + _Sheet.below),
              ),
              child: child,
            ),
            child: IgnorePointer(
              ignoring: !widget.open.value,
              child: _sheet(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _headButton(KitIconName icon, {Key? key, VoidCallback? onTap}) {
    final drawn = SizedBox.square(
      dimension: _Sheet.headButton,
      child: Center(
        child: KitIcon(
          icon,
          size: _Sheet.headIcon,
          strokeWidth: _Sheet.headIconStroke,
          color: _Sheet.headInk,
        ),
      ),
    );
    if (onTap == null) return _off(icon.label, drawn);
    return Semantics(
      button: true,
      label: icon.label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(KitTokens.toolbarButtonRadius),
          onTap: onTap,
          child: drawn,
        ),
      ),
    );
  }

  /// A head tool that does nothing yet (stage 1 has no quick note): it keeps
  /// its place, dimmed as kit's off buttons, and takes no press.
  Widget _off(String label, Widget drawn) => Semantics(
    button: true,
    enabled: false,
    label: label,
    excludeSemantics: true,
    child: Opacity(opacity: KitTokens.disabledOpacity, child: drawn),
  );

  Widget _sheet() => Semantics(
    container: true,
    label: '노트 창',
    child: Container(
      key: const ValueKey('kit-note-sheet'),
      width: _Sheet.width,
      height: _Sheet.height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(_Sheet.radius),
        boxShadow: _Sheet.shadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            height: _Sheet.headHeight,
            padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: KitTokens.menuLine)),
            ),
            child: Row(
              spacing: 4,
              children: [
                // stage 1: the sheet's own tools are drawn dimmed, not
                // working yet
                _headButton(KitIconName.expand),
                _off(
                  '빠른 노트',
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 4,
                    children: [
                      Text(
                        '빠른 노트',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1,
                          fontWeight: FontWeight.w600,
                          color: KitTokens.menuInk,
                        ),
                      ),
                      KitIcon(
                        KitIconName.chev,
                        size: _Sheet.headIcon,
                        strokeWidth: _Sheet.headIconStroke,
                        color: KitTokens.menuInk,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                _headButton(KitIconName.undo),
                _headButton(
                  KitIconName.close,
                  key: const ValueKey('kit-note-sheet-close'),
                  onTap: () => widget.open.value = false,
                ),
              ],
            ),
          ),
          const Expanded(
            child: SizedBox.expand(
              key: ValueKey('kit-note-sheet-paper'),
              child: CustomPaint(painter: _LinedPaper()),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Yellowish paper with a line every 26 (`repeating-linear-gradient(#fffdf4
/// 0 25px, #e3dfc9 25px 26px)`).
class _LinedPaper extends CustomPainter {
  const new();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _Sheet.paper);
    final line = Paint()..color = _Sheet.paperLine;
    for (var y = _Sheet.lineGap - 1; y < size.height; y += _Sheet.lineGap) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), line);
    }
  }

  @override
  bool shouldRepaint(_LinedPaper old) => false;
}
