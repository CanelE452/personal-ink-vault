import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/kit_zoom_badge.dart' show KitDarkPill;
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pop_in.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// 「필기 모드」 or 「제스처 모드」 for [KitMotion.modePillShow] when the
/// writing/gesture mode changes (preview 9th draft c `.c9toast`,
/// task-13B-values.md §14-4): the dark pill 64 above the page area's foot,
/// rising 4 as it comes. 「읽기 전용」 or 「편집 가능」 the same way when
/// [inkLocked] changes (⋯ 「읽기 전용」). It takes no presses.
///
/// It fills the page area and places itself.
class KitModePill extends StatefulWidget {
  const new({super.key, required this.gestureMode, this.inkLocked});

  /// Gesture mode on (`stows.editorGestureMode`).
  final ValueListenable<bool> gestureMode;

  /// The editor's 「읽기 전용」 on.
  final ValueListenable<bool>? inkLocked;

  @override
  State<KitModePill> createState() => _KitModePillState();
}

class _KitModePillState extends State<KitModePill> {
  Timer? _hideTimer;

  /// Up (or coming).
  var _up = false;

  /// What changed last says it.
  var _text = '';

  @override
  void initState() {
    super.initState();
    widget.gestureMode.addListener(_sayMode);
    widget.inkLocked?.addListener(_sayLock);
    // a note opened in gesture mode says so once: pens draw nothing there
    if (widget.gestureMode.value) _sayMode();
  }

  @override
  void didUpdateWidget(KitModePill old) {
    super.didUpdateWidget(old);
    if (old.gestureMode != widget.gestureMode) {
      old.gestureMode.removeListener(_sayMode);
      widget.gestureMode.addListener(_sayMode);
    }
    if (old.inkLocked != widget.inkLocked) {
      old.inkLocked?.removeListener(_sayLock);
      widget.inkLocked?.addListener(_sayLock);
    }
  }

  @override
  void dispose() {
    widget.gestureMode.removeListener(_sayMode);
    widget.inkLocked?.removeListener(_sayLock);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _sayMode() =>
      _say(widget.gestureMode.value ? '제스처 모드' : '필기 모드');

  void _sayLock() =>
      _say((widget.inkLocked?.value ?? false) ? '읽기 전용' : '편집 가능');

  void _say(String text) {
    if (!mounted) return;
    setState(() {
      _up = true;
      _text = text;
    });
    _hideTimer?.cancel();
    _hideTimer = Timer(KitMotion.modePillShow, () {
      if (mounted) setState(() => _up = false);
    });
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.bottomCenter,
    child: Padding(
      padding: const EdgeInsets.only(bottom: KitTokens.modePillBottom),
      child: IgnorePointer(
        child: KitPopIn(
          shown: _up,
          open: KitMotion.modePillOpen,
          close: KitMotion.modePillClose,
          shift: KitTokens.zoomBadgeShift,
          linearFade: true,
          // read out as it changes (`role="status"`)
          child: Semantics(
            liveRegion: true,
            child: KitDarkPill(
              key: const ValueKey('kit-mode-pill'),
              text: _text,
            ),
          ),
        ),
      ),
    ),
  );
}
