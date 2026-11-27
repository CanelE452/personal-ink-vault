import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// One page in the left panel's grid: its place in the note, its width over
/// its height, and whether it is a favourite or the page on screen.
/// [index] is the page's number in the note, also on the favourites tab.
class KitSidePage {
  const new({
    required this.index,
    required this.aspectRatio,
    this.favorite = false,
    this.current = false,
  });

  final int index;
  final double aspectRatio;
  final bool favorite;
  final bool current;
}

/// `.r1grid`: [pages] in rows of [columns] (2, a phone's 3), each a picture
/// drawn by [thumbnail] over its number. The page on screen has the accent
/// ring and number, a favourite a ribbon at its top right. A press calls
/// [onPage] with the page's index. It scrolls.
///
/// With [onFavorite] the ribbon is a button; [showRibbon] draws an outline
/// ribbon on the pages that are not favourites (a spot with nothing drawn is
/// not a button). With [onMenu] a vertical ⋮ at the picture's bottom right
/// opens that page's menu, and shows it open until what [onMenu] returns is
/// done. With [onMove] a long press lifts the page: the
/// pages between it and the place it hovers over step aside as if it were
/// already dropped there, and a drop calls it with the note indexes of both
/// (the grid runs on when the finger is near its top or bottom). Without
/// [onMove], a long press does nothing.
class KitSidePages extends StatefulWidget {
  const new({
    super.key,
    required this.pages,
    required this.columns,
    required this.thumbnail,
    required this.onPage,
    this.onMove,
    this.onFavorite,
    this.showRibbon = false,
    this.onMenu,
  });

  final List<KitSidePage> pages;
  final int columns;
  final Widget Function(int index) thumbnail;
  final ValueChanged<int> onPage;
  final void Function(int from, int to)? onMove;
  final ValueChanged<int>? onFavorite;
  final bool showRibbon;
  final FutureOr<void> Function(BuildContext context, int index)? onMenu;

  @override
  State<KitSidePages> createState() => _KitSidePagesState();
}

/// A page lifted at [from] (its place in the list) hovering over [over].
typedef _Drag = ({int from, int over});

class _KitSidePagesState extends State<KitSidePages>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  late final Ticker _ticker = createTicker(_run);
  final _drag = ValueNotifier<_Drag?>(null);
  final _cells = <int, _PageState>{};
  Offset? _finger;
  Duration _last = Duration.zero;
  // set by a drop: the real order is drawn at once, nothing slides back
  var _dropped = false;
  // a cell's width, and what its height has beyond its picture's (the gap and
  // the number), measured on the lifted page when the drag begins
  double? _cellWidth;
  double? _cellExtra;
  _Drag? _planFor;
  var _homeTops = <double>[];
  var _newTops = <double>[];
  var _newSlots = <int>[];

  @override
  void dispose() {
    _ticker.dispose();
    _scroll.dispose();
    _drag.dispose();
    super.dispose();
  }

  void _dragStart(int from, double width, double extra) {
    _dropped = false;
    _cellWidth = width;
    _cellExtra = extra;
    _planFor = null;
    _last = Duration.zero;
    _drag.value = (from: from, over: from);
    if (!_ticker.isActive) _ticker.start();
  }

  void _dragUpdate(Offset global) {
    _finger = global;
    _hover();
  }

  void _dragEnd() {
    _finger = null;
    _ticker.stop();
    _drag.value = null;
  }

  void _drop() {
    final drag = _drag.value;
    if (drag == null || drag.over == drag.from) return;
    _dropped = true;
    widget.onMove!(
      widget.pages[drag.from].index,
      widget.pages[drag.over].index,
    );
  }

  /// Where the page at [slot] is drawn while [drag] is on: in the order with
  /// the lifted page already dropped, its row as tall as the tallest page in
  /// it, so pages of other ratios do not overlap. Worked out from the ratios
  /// and one cell's width; the layout itself stays as it is, so a page built
  /// in the middle of a drag takes its place at once.
  Offset shiftOf(int slot, _Drag? drag) {
    final width = _cellWidth;
    final extra = _cellExtra;
    if (drag == null ||
        drag.over == drag.from ||
        width == null ||
        extra == null) {
      return Offset.zero;
    }
    final pages = widget.pages;
    final columns = widget.columns;
    if (_planFor != drag) {
      _planFor = drag;
      final order = [for (var i = 0; i < pages.length; i++) i]
        ..removeAt(drag.from)
        ..insert(drag.over, drag.from);
      List<double> tops(List<int> pagesInOrder) {
        final out = <double>[];
        var y = 0.0;
        for (var row = 0; row * columns < pagesInOrder.length; row++) {
          var tallest = 0.0;
          for (var c = 0; c < columns; c++) {
            final k = row * columns + c;
            if (k >= pagesInOrder.length) break;
            tallest = math.max(
              tallest,
              width / pages[pagesInOrder[k]].aspectRatio + extra,
            );
          }
          out.add(y);
          y += tallest + KitTokens.sideGridGap;
        }
        return out;
      }

      _homeTops = tops([for (var i = 0; i < pages.length; i++) i]);
      _newTops = tops(order);
      _newSlots = List.filled(pages.length, 0);
      for (var k = 0; k < order.length; k++) {
        _newSlots[order[k]] = k;
      }
    }
    final now = _newSlots[slot];
    return Offset(
      (now % columns - slot % columns) * (width + KitTokens.sideGridGap),
      _newTops[now ~/ columns] - _homeTops[slot ~/ columns],
    );
  }

  /// The place under the finger, read from where the pages sit in the layout
  /// and not from where they are drawn, so it does not flicker as they step
  /// aside. Between two pages the last place stays.
  void _hover() {
    final drag = _drag.value;
    final finger = _finger;
    final box = context.findRenderObject();
    if (drag == null || finger == null || box is! RenderBox || !box.hasSize) {
      return;
    }
    if (!(Offset.zero & box.size).contains(box.globalToLocal(finger))) {
      _drag.value = (from: drag.from, over: drag.from);
      return;
    }
    for (final MapEntry(key: slot, value: cell) in _cells.entries) {
      final cellBox = cell.mounted ? cell.context.findRenderObject() : null;
      if (cellBox is! RenderBox || !cellBox.attached || !cellBox.hasSize) {
        continue;
      }
      final rect = cellBox.localToGlobal(Offset.zero) & cellBox.size;
      if (rect.contains(finger)) {
        if (slot != drag.over) _drag.value = (from: drag.from, over: slot);
        return;
      }
    }
  }

  /// Every frame of a drag: a finger in the top or bottom edge strip moves the
  /// grid on, the deeper in the faster; the place under it is read again once
  /// the grid has moved.
  void _run(Duration elapsed) {
    final seconds = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final finger = _finger;
    final box = context.findRenderObject();
    if (finger == null ||
        box is! RenderBox ||
        !box.hasSize ||
        !_scroll.hasClients) {
      return;
    }
    const edge = KitTokens.sideDragAutoScrollEdge;
    final y = box.globalToLocal(finger).dy;
    final depth = y < edge
        ? y - edge
        : y > box.size.height - edge
        ? y - (box.size.height - edge)
        : 0.0;
    if (depth == 0) return;
    final position = _scroll.position;
    final step = depth.clamp(-edge, edge) / edge;
    final to =
        (position.pixels + step * KitTokens.sideDragAutoScrollSpeed * seconds)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (to == position.pixels) return;
    position.jumpTo(to);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _ticker.isActive) _hover();
    });
  }

  @override
  Widget build(BuildContext context) {
    final columns = widget.columns;
    final pages = widget.pages;
    final rows = (pages.length / columns).ceil();
    final list = ListView.separated(
      controller: _scroll,
      padding: KitTokens.sideGridPadding,
      itemCount: rows,
      separatorBuilder: (_, _) => const SizedBox(height: KitTokens.sideGridGap),
      itemBuilder: (context, row) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var column = 0; column < columns; column++) ...[
            if (column > 0) const SizedBox(width: KitTokens.sideGridGap),
            Expanded(
              child: switch (row * columns + column) {
                final i when i < pages.length => _Page(
                  slot: i,
                  columns: columns,
                  page: pages[i],
                  thumbnail: widget.thumbnail,
                  onPage: widget.onPage,
                  canMove: widget.onMove != null,
                  onFavorite: widget.onFavorite,
                  showRibbon: widget.showRibbon,
                  onMenu: widget.onMenu,
                  cells: _cells,
                  shiftOf: shiftOf,
                  drag: _drag,
                  dropped: () => _dropped,
                  onDragStart: _dragStart,
                  onDragUpdate: _dragUpdate,
                  onDragEnd: _dragEnd,
                ),
                _ => const SizedBox.shrink(),
              },
            ),
          ],
        ],
      ),
    );
    if (widget.onMove == null) return list;
    return DragTarget<int>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (_) => _drop(),
      builder: (context, _, _) => list,
    );
  }
}

class _Page extends StatefulWidget {
  const new({
    required this.slot,
    required this.columns,
    required this.page,
    required this.thumbnail,
    required this.onPage,
    required this.canMove,
    required this.onFavorite,
    required this.showRibbon,
    required this.onMenu,
    required this.cells,
    required this.shiftOf,
    required this.drag,
    required this.dropped,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final int slot;
  final int columns;
  final KitSidePage page;
  final Widget Function(int index) thumbnail;
  final ValueChanged<int> onPage;
  final bool canMove;
  final ValueChanged<int>? onFavorite;
  final bool showRibbon;
  final FutureOr<void> Function(BuildContext context, int index)? onMenu;
  final Map<int, _PageState> cells;
  final Offset Function(int slot, _Drag? drag) shiftOf;
  final ValueNotifier<_Drag?> drag;
  final bool Function() dropped;
  final void Function(int slot, double width, double extra) onDragStart;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  State<_Page> createState() => _PageState();
}

const _radius = BorderRadius.all(Radius.circular(KitTokens.sideThumbRadius));

class _PageState extends State<_Page> with AutomaticKeepAliveClientMixin {
  // A page being dragged stays built while the grid scrolls it out of view;
  // otherwise its drag would end with it.
  var _dragging = false;
  var _menuOpen = false;

  @override
  bool get wantKeepAlive => _dragging;

  /// Opens the menu hung from [button], shown open until it is done.
  Future<void> _openMenu(BuildContext button) async {
    setState(() => _menuOpen = true);
    try {
      await widget.onMenu!(button, widget.page.index);
    } finally {
      if (mounted) setState(() => _menuOpen = false);
    }
  }

  @override
  void dispose() {
    if (identical(widget.cells[widget.slot], this)) {
      widget.cells.remove(widget.slot);
    }
    super.dispose();
  }

  void _setDragging(bool value) {
    _dragging = value;
    updateKeepAlive();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    widget.cells[widget.slot] = this;
    return ValueListenableBuilder<_Drag?>(
      valueListenable: widget.drag,
      builder: (context, drag, _) => TweenAnimationBuilder<Offset>(
        tween: Tween(end: widget.shiftOf(widget.slot, drag)),
        duration: drag == null && widget.dropped()
            ? Duration.zero
            : KitMotion.sideDragMove,
        curve: KitMotion.fastCurve,
        builder: (context, offset, child) =>
            Transform.translate(offset: offset, child: child),
        child: AnimatedOpacity(
          opacity: drag?.from == widget.slot
              ? KitTokens.sideDragLeftOpacity
              : 1,
          duration: KitMotion.sideDragMove,
          child: _draggable(),
        ),
      ),
    );
  }

  Widget _draggable() {
    final page = widget.page;
    final i = page.index;
    final content = Semantics(
      container: true,
      button: true,
      label: [
        '쪽 ${i + 1}',
        if (page.favorite) '즐겨찾기',
        if (page.current) '지금 쪽',
      ].join(', '),
      onTap: () => widget.onPage(i),
      child: GestureDetector(
        key: ValueKey('kit-side-page-$i'),
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onPage(i),
        child: _content(),
      ),
    );
    if (!widget.canMove) return content;
    return LayoutBuilder(
      builder: (context, constraints) => LongPressDraggable<int>(
        data: widget.slot,
        maxSimultaneousDrags: 1,
        onDragStarted: () {
          _setDragging(true);
          final size = (this.context.findRenderObject()! as RenderBox).size;
          widget.onDragStart(
            widget.slot,
            size.width,
            size.height - size.width / page.aspectRatio,
          );
        },
        onDragUpdate: (d) => widget.onDragUpdate(d.globalPosition),
        onDragEnd: (_) {
          widget.onDragEnd();
          if (mounted) _setDragging(false);
        },
        feedback: _Lifted(
          width: constraints.maxWidth,
          aspectRatio: page.aspectRatio,
          child: widget.thumbnail(i),
        ),
        childWhenDragging: content,
        child: content,
      ),
    );
  }

  Widget _content() {
    final page = widget.page;
    final i = page.index;
    return Column(
      children: [
        AspectRatio(
          aspectRatio: page.aspectRatio,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  key: ValueKey('kit-side-page-$i-picture'),
                  decoration: BoxDecoration(
                    color: KitTokens.sideThumbBg,
                    borderRadius: _radius,
                    boxShadow: page.current
                        ? KitTokens.sideThumbOnShadow
                        : KitTokens.sideThumbShadow,
                  ),
                  child: ClipRRect(
                    borderRadius: _radius,
                    child: ExcludeSemantics(
                      child: IgnorePointer(child: widget.thumbnail(i)),
                    ),
                  ),
                ),
              ),
              if (page.favorite || widget.showRibbon)
                Positioned(
                  right: 0,
                  top: 0,
                  child: _RibbonButton(
                    index: i,
                    favorite: page.favorite,
                    onFavorite: widget.onFavorite,
                  ),
                ),
              if (widget.onMenu != null)
                Positioned(
                  right: 0,
                  bottom: 0,
                  // the menu hangs from the button: it is given the
                  // button's own context
                  child: Builder(
                    builder: (button) => Semantics(
                      container: true,
                      button: true,
                      label: '쪽 메뉴',
                      expanded: _menuOpen,
                      onTap: () => unawaited(_openMenu(button)),
                      excludeSemantics: true,
                      child: GestureDetector(
                        key: ValueKey('kit-side-page-$i-menu'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => unawaited(_openMenu(button)),
                        child: SizedBox(
                          width: KitTokens.sideMenuDotsHit,
                          height: KitTokens.sideMenuDotsHit,
                          child: Center(
                            child: _menuOpen
                                ? const DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: KitTokens.sideMenuDotsOpenBg,
                                      shape: BoxShape.circle,
                                    ),
                                    child: SizedBox.square(
                                      dimension: KitTokens.sideMenuDotsOpenSize,
                                      child: Center(child: _dots),
                                    ),
                                  )
                                : _dots,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: KitTokens.sideThumbGap),
        ExcludeSemantics(
          child: KitText(
            '${i + 1}',
            maxLines: 1,
            style: TextStyle(
              fontSize: KitTokens.sideThumbFontSize,
              height: KitTokens.sideLineHeight,
              letterSpacing: 0,
              color: page.current
                  ? KitTokens.sideThumbOnInk
                  : KitTokens.sideThumbInk,
              fontWeight: page.current ? FontWeight.w600 : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

const _dots = KitIcon(
  KitIconName.moreV,
  size: KitTokens.sideMenuDotsIconSize,
  color: KitTokens.sideMenuDotsInk,
);

/// The picture under the finger while a page is dragged.
class _Lifted extends StatelessWidget {
  const new({
    required this.width,
    required this.aspectRatio,
    required this.child,
  });

  final double width;
  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox(
      width: width,
      height: width / aspectRatio,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: KitTokens.sideThumbBg,
          borderRadius: _radius,
          boxShadow: KitTokens.sideDragLift,
        ),
        child: ClipRRect(borderRadius: _radius, child: child),
      ),
    ),
  );
}

/// The ribbon spot at the picture's top right: the favourite's filled ribbon
/// or the outline of one, pressed anywhere in [KitTokens.sideRibbonHit] when
/// [onFavorite] is set.
class _RibbonButton extends StatelessWidget {
  const new({
    required this.index,
    required this.favorite,
    required this.onFavorite,
  });

  final int index;
  final bool favorite;
  final ValueChanged<int>? onFavorite;

  @override
  Widget build(BuildContext context) {
    final ribbon = favorite
        ? ClipPath(
            clipper: const _Ribbon(),
            child: SizedBox(
              key: ValueKey('kit-side-page-$index-ribbon'),
              width: KitTokens.sideRibbonWidth,
              height: KitTokens.sideRibbonHeight,
              child: const ColoredBox(color: KitTokens.accent),
            ),
          )
        : SizedBox(
            key: ValueKey('kit-side-page-$index-ribbon'),
            width: KitTokens.sideRibbonWidth,
            height: KitTokens.sideRibbonHeight,
            child: const CustomPaint(painter: _RibbonOutline()),
          );
    final spot = SizedBox(
      width: KitTokens.sideRibbonHit,
      height: KitTokens.sideRibbonHit,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: KitTokens.sideRibbonRight,
            top: KitTokens.sideRibbonTop,
            child: ribbon,
          ),
        ],
      ),
    );
    if (onFavorite == null) return IgnorePointer(child: spot);
    return Semantics(
      container: true,
      button: true,
      label: favorite ? '즐겨찾기에서 빼기' : '즐겨찾기에 추가',
      onTap: () => onFavorite!(index),
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('kit-side-page-$index-favorite-button'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onFavorite!(index),
        child: spot,
      ),
    );
  }
}

Path _ribbonPath(Size size) => Path()
  ..moveTo(0, 0)
  ..lineTo(size.width, 0)
  ..lineTo(size.width, size.height)
  ..lineTo(size.width / 2, size.height * KitTokens.sideRibbonNotch)
  ..lineTo(0, size.height)
  ..close();

/// The ribbon's cut foot: `polygon(0 0,100% 0,100% 100%,50% 70%,0 100%)`.
class _Ribbon extends CustomClipper<Path> {
  const new();

  @override
  Path getClip(Size size) => _ribbonPath(size);

  @override
  bool shouldReclip(_Ribbon old) => false;
}

class _RibbonOutline extends CustomPainter {
  const new();

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = KitTokens.sideRibbonOutlineStroke;
    // the line sits inside the 11 x 15 box
    final inner = Size(size.width - stroke, size.height - stroke);
    canvas.save();
    canvas.translate(stroke / 2, stroke / 2);
    canvas.drawPath(
      _ribbonPath(inner),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeJoin = StrokeJoin.round
        ..color = KitTokens.sideRibbonOutline,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RibbonOutline old) => false;
}
