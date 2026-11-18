import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:saber/data/editor/page_link.dart';

/// What the user asks of a link: a tap opens it, and the badge's long press
/// menu offers all four.
enum PageLinkAction { open, edit, copy, delete }

/// One page's links (Notein's hyperlinks), on top of the page's pictures: a
/// light blue underline below each link's area and a blue chain badge at its
/// top-right corner. An icon link (put where the user tapped) shows the badge
/// only. Badge and underline keep their size on screen at any zoom.
///
/// The pen opens a link from the badge's circle only, and writes everywhere
/// else, also inside an area. A finger opens it from a box around the badge
/// or from the area; a palm resting there while the pen writes, or any hold
/// longer than a long press, is not a tap. A long press on the badge shows
/// its menu. With [ignoring] (the lasso or the text box in hand) every pointer
/// goes through. With [onPlace] the page waits for one tap, anywhere, to put
/// a new link.
class PageLinkLayer extends StatelessWidget {
  const new({
    super.key,
    required this.links,
    required this.pageSize,
    required this.screenScale,
    required this.onAction,
    this.readOnly = false,
    this.ignoring = false,
    this.onPlace,
  });

  final List<PageLink> links;
  final Size pageSize;

  /// Logical pixels on screen per page unit (the page's fit times the zoom).
  final double screenScale;
  final void Function(PageLink link, PageLinkAction action) onAction;

  /// A read-only note offers 「링크 열기」 and 「링크 복사」 only.
  final bool readOnly;
  final bool ignoring;

  /// The tap's position on the page, in page coordinates.
  final ValueChanged<Offset>? onPlace;

  static const color = Color(0xFF1A73E8);

  /// On-screen sizes, in logical pixels.
  static const badgeSize = 22.0;
  static const iconSize = 14.0;
  static const fingerTarget = 48.0;
  static const underline = 2.0;

  /// Everything but a finger: these open a link from the badge's circle only.
  static const _notFingers = {
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };

  /// A length of [logical] pixels on screen, in page units.
  double _page(double logical) => logical / max(screenScale, 0.01);

  @override
  Widget build(BuildContext context) {
    final onPlace = this.onPlace;
    final areas = [
      for (final link in links)
        if (!link.isIcon) link,
    ];
    final thickness = _page(underline);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            ignoring: ignoring,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Areas first, badges last: a badge stays on top of any area.
                for (final link in areas)
                  Positioned.fromRect(
                    rect: link.rect,
                    child: _FingerTarget(
                      key: ValueKey('page-link-area-${link.id}'),
                      onTap: () => onAction(link, PageLinkAction.open),
                    ),
                  ),
                for (final link in areas)
                  Positioned(
                    left: link.rect.left,
                    top: min(link.rect.bottom, pageSize.height - thickness),
                    width: link.rect.width,
                    height: thickness,
                    child: IgnorePointer(
                      child: ColoredBox(
                        key: ValueKey('page-link-underline-${link.id}'),
                        color: color.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                for (final link in links) _badge(context, link),
              ],
            ),
          ),
        ),
        if (onPlace != null)
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('page-link-place'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => onPlace(details.localPosition),
            ),
          ),
      ],
    );
  }

  Widget _badge(BuildContext context, PageLink link) {
    final diameter = _page(badgeSize);
    final box = _page(fingerTarget);
    final radius = diameter / 2;
    final x = link.rect.right
        .clamp(radius, max(radius, pageSize.width - radius))
        .toDouble();
    final y = link.rect.top
        .clamp(radius, max(radius, pageSize.height - radius))
        .toDouble();
    void open() => onAction(link, PageLinkAction.open);
    void menu(Offset position) => _showMenu(context, link, position);
    return Positioned(
      left: x - box / 2,
      top: y - box / 2,
      width: box,
      height: box,
      child: Semantics(
        button: true,
        label: '링크',
        child: _FingerTarget(
          key: ValueKey('page-link-badge-touch-${link.id}'),
          onTap: open,
          onLongPress: menu,
          child: Center(
            child: GestureDetector(
              key: ValueKey('page-link-badge-${link.id}'),
              supportedDevices: _notFingers,
              onTap: open,
              onLongPressStart: (details) => menu(details.globalPosition),
              onSecondaryTapUp: (details) => menu(details.globalPosition),
              // The circle hit-tests as a circle, so the pen next to it writes.
              child: SizedBox.square(
                dimension: diameter,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Icon(
                      Icons.link,
                      size: _page(iconSize),
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(
    BuildContext context,
    PageLink link,
    Offset globalPosition,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(globalPosition);
    final action = await showMenu<PageLinkAction>(
      context: context,
      position: RelativeRect.fromRect(
        point & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: [
        _item(PageLinkAction.open, '링크 열기', Icons.open_in_new),
        if (!readOnly) _item(PageLinkAction.edit, '링크 편집', Icons.edit_outlined),
        _item(PageLinkAction.copy, '링크 복사', Icons.content_copy),
        if (!readOnly)
          _item(PageLinkAction.delete, '링크 삭제', Icons.delete_outline),
      ],
    );
    if (action != null) onAction(link, action);
  }

  static PopupMenuItem<PageLinkAction> _item(
    PageLinkAction action,
    String label,
    IconData icon,
  ) => PopupMenuItem(
    key: ValueKey('page-link-menu-${action.name}'),
    value: action,
    child: Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
    ),
  );
}

/// Pen touch-downs anywhere in the app so far, and pens touching the screen
/// now; [_FingerTarget] reads them to tell a palm from a tap.
var _penDowns = 0;
var _pensDown = 0;
var _watchingPens = false;

void _watchPens() {
  if (_watchingPens) return;
  _watchingPens = true;
  GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    if (event is PointerDownEvent) {
      _penDowns++;
      _pensDown++;
    } else if ((event is PointerUpEvent || event is PointerCancelEvent) &&
        _pensDown > 0) {
      _pensDown--;
    }
  });
}

/// A finger target that tells a tap from a resting palm. A touch is not a tap
/// (nor a long press) if the pen was on the screen when it began or touched
/// down while it lasted: a palm lying on a link while the user writes. A touch
/// held longer than a long press is not a tap either.
class _FingerTarget extends StatefulWidget {
  const new({super.key, required this.onTap, this.onLongPress, this.child});

  final VoidCallback onTap;
  final ValueChanged<Offset>? onLongPress;
  final Widget? child;

  @override
  State<_FingerTarget> createState() => _FingerTargetState();
}

class _FingerTargetState extends State<_FingerTarget> {
  var _touches = 0;
  var _penAtTouch = false;
  var _penDownsAtTouch = 0;
  var _downAt = Duration.zero;
  var _upAt = Duration.zero;

  @override
  void initState() {
    super.initState();
    _watchPens();
  }

  bool get _palm => _penAtTouch || _penDowns != _penDownsAtTouch;

  void _down(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch || _touches++ > 0) return;
    _downAt = event.timeStamp;
    _penAtTouch = _pensDown > 0;
    _penDownsAtTouch = _penDowns;
  }

  void _up(PointerEvent event) {
    if (event.kind != PointerDeviceKind.touch || _touches == 0) return;
    _touches--;
    _upAt = event.timeStamp;
  }

  @override
  Widget build(BuildContext context) {
    final onLongPress = widget.onLongPress;
    return Listener(
      onPointerDown: _down,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        supportedDevices: const {PointerDeviceKind.touch},
        onTap: () {
          if (!_palm && _upAt - _downAt <= kLongPressTimeout) widget.onTap();
        },
        onLongPressStart: onLongPress == null
            ? null
            : (details) {
                if (!_palm) onLongPress(details.globalPosition);
              },
        child: widget.child,
      ),
    );
  }
}
