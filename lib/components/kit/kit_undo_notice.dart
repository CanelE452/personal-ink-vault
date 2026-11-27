import 'dart:async';

import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// One notice: its line and, with [onAction], the [action] that undoes what
/// it tells of.
class KitNotice {
  const new(
    this.text, {
    this.action = KitTokens.undoNoticeAction,
    this.onAction,
    this.onEnd,
  });

  final String text;
  final String action;
  final VoidCallback? onAction;

  /// Heard once when the notice goes without its action pressed: by itself,
  /// for another notice, or by [KitUndoNoticeController.hide].
  final VoidCallback? onEnd;
}

/// What a [KitUndoNotice] shows: the notice last [show]n, until it goes by
/// itself, its action is pressed or [hide] is called. A notice takes the
/// place of the one before it.
class KitUndoNoticeController extends ChangeNotifier {
  KitNotice? _notice;

  KitNotice? get notice => _notice;

  /// Shows [text]; with [onAction], [action] beside it (「실행 취소」), and
  /// [onEnd] heard when it goes unpressed ([KitNotice.onEnd]).
  void show(
    String text, {
    String action = KitTokens.undoNoticeAction,
    VoidCallback? onAction,
    VoidCallback? onEnd,
  }) {
    final last = _notice;
    _notice = KitNotice(text, action: action, onAction: onAction, onEnd: onEnd);
    notifyListeners();
    last?.onEnd?.call();
  }

  void hide() {
    final last = _notice;
    if (last == null) return;
    _notice = null;
    notifyListeners();
    last.onEnd?.call();
  }

  /// Its action was pressed: the notice goes and its action runs (not its
  /// [KitNotice.onEnd]).
  void act() {
    final notice = _notice;
    if (notice == null) return;
    _notice = null;
    notifyListeners();
    notice.onAction?.call();
  }
}

/// The notice over the page area (12th draft `.r1toast`): a dark pill in the
/// middle, [bottom] over the area's foot, with its line
/// and its action. It fills its parent. It rises in and fades out on its
/// own; it stays [KitMotion.undoNoticeShow] with an action and
/// [KitMotion.undoNoticeShowSolo] without one. A press on the action hides it
/// and then runs the action, once.
class KitUndoNotice extends StatefulWidget {
  const new({
    super.key,
    required this.controller,
    this.bottom = KitTokens.undoNoticeBottom,
  });

  final KitUndoNoticeController controller;

  /// How far over the area's foot it stands.
  final double bottom;

  @override
  State<KitUndoNotice> createState() => _KitUndoNoticeState();
}

class _KitUndoNoticeState extends State<KitUndoNotice>
    with SingleTickerProviderStateMixin {
  late final _shown = AnimationController(
    vsync: this,
    duration: KitMotion.undoNoticeIn,
    reverseDuration: KitMotion.undoNoticeOut,
  )..addStatusListener((_) => setState(() {}));

  // the preview eases its rise both ways on the same curve, from where it
  // starts
  late final _rise = CurvedAnimation(
    parent: _shown,
    curve: KitMotion.samsungDecel,
    reverseCurve: KitMotion.samsungDecel.flipped,
  );

  /// The notice drawn: kept while it fades out.
  KitNotice? _notice;
  Timer? _timer;

  KitUndoNoticeController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    if (controller.notice != null) _changed();
  }

  @override
  void didUpdateWidget(KitUndoNotice old) {
    super.didUpdateWidget(old);
    if (old.controller != controller) {
      old.controller.removeListener(_changed);
      controller.addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    _timer?.cancel();
    _rise.dispose();
    _shown.dispose();
    super.dispose();
  }

  void _changed() {
    _timer?.cancel();
    final notice = controller.notice;
    if (notice == null) {
      _shown.reverse();
      return;
    }
    setState(() => _notice = notice);
    _shown.forward();
    _timer = Timer(
      notice.onAction == null
          ? KitMotion.undoNoticeShowSolo
          : KitMotion.undoNoticeShow,
      () {
        if (identical(controller.notice, notice)) controller.hide();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final notice = _notice;
    if (notice == null || _shown.isDismissed) return const SizedBox.shrink();
    final acts = notice.onAction != null;
    const style = TextStyle(
      fontSize: KitTokens.undoNoticeFontSize,
      height: KitTokens.lineHeightOne,
      fontWeight: FontWeight.w600,
      letterSpacing: 0,
      color: KitTokens.undoNoticeInk,
      decoration: TextDecoration.none,
    );
    final pill = SizedBox(
      key: const ValueKey('kit-undo-notice'),
      height: KitTokens.undoNoticeHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: KitTokens.undoNoticeBg,
          borderRadius: BorderRadius.circular(KitTokens.undoNoticeRadius),
        ),
        child: Padding(
          padding: acts
              ? KitTokens.undoNoticePadding
              : KitTokens.undoNoticeSoloPadding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: KitText(
                  notice.text,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
              if (acts) ...[
                const SizedBox(width: KitTokens.undoNoticeGap),
                Semantics(
                  button: true,
                  label: notice.action,
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: const ValueKey('kit-undo-notice-action'),
                    behavior: HitTestBehavior.opaque,
                    onTap: controller.act,
                    child: SizedBox(
                      height: KitTokens.undoNoticeActionHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: KitTokens.undoNoticeActionPadH,
                        ),
                        child: Center(
                          widthFactor: 1,
                          child: KitText(
                            notice.action,
                            maxLines: 1,
                            style: style.copyWith(
                              color: KitTokens.undoNoticeActionInk,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          KitTokens.undoNoticeMargin / 2,
          0,
          KitTokens.undoNoticeMargin / 2,
          widget.bottom,
        ),
        child: IgnorePointer(
          ignoring: controller.notice == null,
          child: Semantics(
            liveRegion: true,
            container: true,
            child: FadeTransition(
              opacity: _shown,
              child: AnimatedBuilder(
                animation: _rise,
                builder: (context, child) => Transform.translate(
                  offset: Offset(
                    0,
                    KitTokens.undoNoticeRise * (1 - _rise.value),
                  ),
                  child: child,
                ),
                child: pill,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
