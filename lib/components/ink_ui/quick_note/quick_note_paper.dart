import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:saber/components/canvas/_canvas_painter.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/quick_note.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';

/// The quick note's page in its window (12th draft `.r1note .paper`): lined
/// paper as wide as the window, as long as the page in that width,
/// scrolling up and down. The strokes are drawn by the note's own page
/// painter ([CanvasPainter]); the one being drawn on a layer of its own over
/// them, so a new point paints that stroke alone.
///
/// One pointer writes at a time: [pen] draws, or the eraser rubs out whole
/// strokes while [erasing], with the pen's eraser end or its button (as on
/// the page). A cancelled touch ends its stroke. The pen and the mouse
/// write; fingers write when the editor lets them
/// (`stows.editorFingerDrawing`) and scroll otherwise, but not while the pen
/// is down (a palm); in gesture mode nothing writes and the pen scrolls too.
/// Without [note] (being read) the paper only shows; with [retry] too the
/// read failed, and the paper says so with 「다시 시도」.
class KitQuickNotePaper extends StatefulWidget {
  const new({
    super.key,
    required this.note,
    required this.pen,
    required this.erasing,
    this.retry,
  });

  final QuickNote? note;
  final Pen Function() pen;
  final bool Function() erasing;
  final VoidCallback? retry;

  @override
  State<KitQuickNotePaper> createState() => _KitQuickNotePaperState();
}

class _KitQuickNotePaperState extends State<KitQuickNotePaper> {
  final _scroll = ScrollController();

  /// The pointer writing now, and whether it rubs out.
  int? _pointer;
  var _rubbing = false;

  /// A pen (not a finger or the mouse) is down: fingers do not scroll.
  final _penDown = ValueNotifier(false);

  /// Page units to the window's pixels.
  var _scale = 1.0;

  @override
  void dispose() {
    _scroll.dispose();
    _penDown.dispose();
    super.dispose();
  }

  bool get _gesture => stows.editorGestureMode.value;

  bool _writes(PointerDeviceKind kind) => switch (kind) {
    _ when _gesture => false,
    PointerDeviceKind.touch => stows.editorFingerDrawing.value,
    PointerDeviceKind.stylus ||
    PointerDeviceKind.invertedStylus ||
    PointerDeviceKind.mouse => true,
    _ => false,
  };

  Set<PointerDeviceKind> get _scrolls => {
    PointerDeviceKind.trackpad,
    if ((_gesture || !stows.editorFingerDrawing.value) && !_penDown.value)
      PointerDeviceKind.touch,
    if (_gesture) ...{
      PointerDeviceKind.stylus,
      PointerDeviceKind.invertedStylus,
    },
  };

  Offset _onPage(Offset local) => local / _scale;

  double? _pressure(PointerEvent event) => switch (event.kind) {
    PointerDeviceKind.stylus ||
    PointerDeviceKind.invertedStylus => event.pressure,
    _ => null,
  };

  void _down(PointerDownEvent event) {
    final note = widget.note;
    if (note == null || _pointer != null || !_writes(event.kind)) return;
    _pointer = event.pointer;
    // the pen's eraser end and its button rub out, as on the page
    // (canvas_gesture_detector's stylus button)
    _rubbing =
        widget.erasing() ||
        event.kind == PointerDeviceKind.invertedStylus ||
        event.buttons == kSecondaryButton;
    _penDown.value =
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;
    final at = _onPage(event.localPosition);
    if (_rubbing) {
      note.eraseAt(at);
    } else {
      note.penDown(at, widget.pen(), _pressure(event), screenScale: _scale);
    }
  }

  void _move(PointerMoveEvent event) {
    final note = widget.note;
    if (note == null || event.pointer != _pointer) return;
    final at = _onPage(event.localPosition);
    if (_rubbing) {
      note.eraseAt(at);
    } else {
      note.penMove(at, _pressure(event));
    }
  }

  /// Lifted or cancelled: the stroke or the rubbing ends.
  void _end(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    _penDown.value = false;
    widget.note?.penUp();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final note = widget.note;
      final page = note?.page.size ?? EditorPage.defaultSize;
      _scale = box.maxWidth / page.width;
      final drawn = SizedBox.fromSize(
        size: page,
        child: Stack(
          children: [
            RepaintBoundary(
              key: const ValueKey('quick-note-strokes'),
              child: CustomPaint(
                size: page,
                painter: _LinedPaper(page.width),
                foregroundPainter: note == null
                    ? null
                    : _strokes(context, note),
              ),
            ),
            if (note != null)
              RepaintBoundary(
                key: const ValueKey('quick-note-live'),
                child: ValueListenableBuilder(
                  valueListenable: note.currentStroke,
                  builder: (context, stroke, _) => CustomPaint(
                    size: page,
                    painter: stroke == null
                        ? null
                        : _strokes(context, note, current: stroke),
                  ),
                ),
              ),
          ],
        ),
      );
      final paper = ListenableBuilder(
        listenable: Listenable.merge([
          stows.editorGestureMode,
          stows.editorFingerDrawing,
          _penDown,
        ]),
        builder: (context, child) => ScrollConfiguration(
          behavior: ScrollConfiguration.of(context)
              .copyWith(dragDevices: _scrolls, scrollbars: false),
          child: child!,
        ),
        child: SingleChildScrollView(
          key: const ValueKey('quick-note-scroll'),
          controller: _scroll,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _end,
            onPointerCancel: _end,
            child: RepaintBoundary(
              child: SizedBox(
                key: const ValueKey('quick-note-page'),
                width: box.maxWidth,
                height: page.height * _scale,
                child: FittedBox(
                  fit: BoxFit.fitWidth,
                  alignment: Alignment.topLeft,
                  child: drawn,
                ),
              ),
            ),
          ),
        ),
      );
      final retry = widget.retry;
      if (retry == null || note != null) return paper;
      return Stack(
        children: [
          Positioned.fill(child: paper),
          Positioned.fill(child: _Failed(retry: retry)),
        ],
      );
    },
  );

  /// The page's strokes (repainted as the page says), or only [current].
  CanvasPainter _strokes(
    BuildContext context,
    QuickNote note, {
    Stroke? current,
  }) {
    final theme = Theme.of(context);
    return CanvasPainter(
      repaint: current == null ? note.page : null,
      strokes: current == null ? note.page.strokes : const [],
      laserStrokes: const [],
      currentStroke: current,
      currentSelection: null,
      primaryColor: theme.colorScheme.primary,
      page: note.page,
      showPageIndicator: false,
      pageIndex: 0,
      totalPages: 1,
      currentScale: double.maxFinite,
      defaultTextStyle: theme.textTheme.bodyMedium!,
    );
  }
}

/// The read failed (controller's copy, task 13 fix 1): one line and
/// 「다시 시도」 in the paper's middle, as an empty tab of the left panel
/// says its line and as its 「완료」 is drawn, on a box of the paper's colour
/// (no ruling through them, task 13 fix 2).
class _Failed extends StatelessWidget {
  const new({required this.retry});

  final VoidCallback retry;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      child: ColoredBox(
        key: const ValueKey('quick-note-failed'),
        color: KitTokens.quickNotePaper,
        child: Padding(
          padding: KitTokens.sideEmptyPadding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const KitText(
                '빠른 노트를 읽지 못했습니다.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: KitTokens.sideEmptyFontSize,
                  height: KitTokens.sideEmptyLineHeight,
                  letterSpacing: 0,
                  color: KitTokens.sideEmptyInk,
                ),
              ),
              const SizedBox(height: KitTokens.sideEmptyIconGap),
              Semantics(
                container: true,
                button: true,
                label: '다시 시도',
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: retry,
                  child: const SizedBox(
                    height: KitTokens.sideDoneHeight,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: KitTokens.sideDonePadH,
                      ),
                      child: Center(
                        widthFactor: 1,
                        child: KitText(
                          '다시 시도',
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: KitTokens.sideDoneFontSize,
                            height: KitTokens.lineHeightOne,
                            letterSpacing: 0,
                            fontWeight: FontWeight.w600,
                            color: KitTokens.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// `repeating-linear-gradient(#fffdf4 0 25px, #e3dfc9 25px 26px)` in page
/// units: a line every [KitTokens.quickNoteLineGap] at the window's first
/// width, so the lines grow with the writing.
class _LinedPaper extends CustomPainter {
  const new(this.pageWidth);

  final double pageWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = pageWidth / KitTokens.quickNoteWidth;
    final gap = KitTokens.quickNoteLineGap * unit;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = KitTokens.quickNotePaper,
    );
    final line = Paint()..color = KitTokens.quickNotePaperLine;
    for (var y = gap - unit; y < size.height; y += gap) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, unit), line);
    }
  }

  @override
  bool shouldRepaint(_LinedPaper old) => old.pageWidth != pageWidth;
}
