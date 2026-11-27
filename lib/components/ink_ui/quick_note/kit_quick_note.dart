import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// A drag on a part of the quick note: it begins, moves by a step, ends.
typedef KitQuickNoteDrag = ({
  VoidCallback start,
  ValueChanged<Offset> by,
  VoidCallback end,
});

/// The quick note window (12th draft `#extras12`, `.r1note`, `noteHtml`),
/// laid out by its host: the head (the grip, 「빠른 노트」, 「실행 취소」,
/// 「접기」, 「닫기」) over [paper]. On a tablet the head moves it ([move])
/// and the handle at the bottom right sizes it ([resize]); while it is sized
/// the paper's middle shows [size]. On a [phone] it is a sheet across the
/// page area's foot, its grab strip on top ([sheetDrag]), without the grip
/// and the handle.
///
/// 「실행 취소」 is off unless [canUndo]. A [readOnly] quick note shows the
/// 「읽기 전용」 icon after the title, and ink not saved yet ([unsaved]) a
/// dot there, both when both (not in the 12th draft: task 5's ruling and
/// the controller's in task 13 fix 1, with their names).
class KitQuickNoteWindow extends StatelessWidget {
  const new({
    super.key,
    required this.phone,
    required this.paper,
    required this.canUndo,
    required this.readOnly,
    required this.unsaved,
    required this.onUndo,
    required this.onFold,
    required this.onClose,
    this.move,
    this.resize,
    this.sheetDrag,
    this.size,
  });

  final bool phone;
  final Widget paper;
  final bool canUndo;
  final bool readOnly;
  final bool unsaved;
  final VoidCallback onUndo;
  final VoidCallback onFold;
  final VoidCallback onClose;
  final KitQuickNoteDrag? move;
  final KitQuickNoteDrag? resize;
  final KitQuickNoteDrag? sheetDrag;
  final Size? size;

  static const _title = TextStyle(
    fontSize: KitTokens.quickNoteTitleSize,
    height: KitTokens.lineHeightOne,
    letterSpacing: 0,
    fontWeight: FontWeight.w600,
    color: KitTokens.quickNoteTitleInk,
  );

  static Widget _dragging(KitQuickNoteDrag? drag, Widget child) => drag == null
      ? child
      : GestureDetector(
          behavior: HitTestBehavior.opaque,
          // it follows the finger from where it went down
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (_) => drag.start(),
          onPanUpdate: (details) => drag.by(details.delta),
          onPanEnd: (_) => drag.end(),
          onPanCancel: drag.end,
          child: child,
        );

  Widget _button(
    String key,
    KitIconName icon,
    String label,
    VoidCallback onTap, {
    bool enabled = true,
  }) {
    final drawn = SizedBox.square(
      dimension: KitTokens.quickNoteButton,
      child: Center(
        child: KitIcon(
          icon,
          size: KitTokens.quickNoteIconSize,
          strokeWidth: KitTokens.quickNoteIconStroke,
          color: KitTokens.quickNoteButtonInk,
        ),
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: enabled
          ? Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: ValueKey(key),
                borderRadius: BorderRadius.circular(
                  KitTokens.quickNoteButtonRadius,
                ),
                onTap: onTap,
                child: drawn,
              ),
            )
          : Opacity(
              key: ValueKey(key),
              opacity: KitTokens.disabledOpacity,
              child: drawn,
            ),
    );
  }

  /// The dot of ink not saved yet; read-only, that ink stays in memory only
  /// and the dot says so (also on a long press or a hover).
  Widget _unsavedDot() {
    const dot = DecoratedBox(
      key: ValueKey('quick-note-unsaved'),
      decoration: BoxDecoration(
        color: KitTokens.quickNoteGripInk,
        shape: BoxShape.circle,
      ),
      child: SizedBox.square(dimension: KitTokens.quickNoteUnsavedDot),
    );
    if (!readOnly) {
      return Semantics(
        container: true,
        label: '저장 안 됨',
        excludeSemantics: true,
        child: dot,
      );
    }
    const lost = '읽기 전용이라 이 필기는 저장되지 않습니다';
    return Semantics(
      container: true,
      label: lost,
      excludeSemantics: true,
      child: const Tooltip(
        message: lost,
        excludeFromSemantics: true,
        child: dot,
      ),
    );
  }

  Widget _head() {
    final title = Row(
      children: [
        const Flexible(
          child: KitText(
            '빠른 노트',
            style: _title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (readOnly) ...[
          const SizedBox(width: KitTokens.quickNoteMarkGap),
          Semantics(
            container: true,
            label: '읽기 전용',
            excludeSemantics: true,
            child: const KitIcon(
              KitIconName.readonly,
              key: ValueKey('quick-note-read-only'),
              size: KitTokens.quickNoteIconSize,
              strokeWidth: KitTokens.quickNoteIconStroke,
              color: KitTokens.quickNoteGripInk,
            ),
          ),
        ],
        if (unsaved) ...[
          const SizedBox(width: KitTokens.quickNoteMarkGap),
          _unsavedDot(),
        ],
      ],
    );
    return Container(
      height: phone
          ? KitTokens.quickNoteSheetHeadHeight
          : KitTokens.quickNoteHeadHeight,
      padding: phone
          ? KitTokens.quickNoteSheetHeadPadding
          : KitTokens.quickNoteHeadPadding,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: KitTokens.quickNoteHeadLine)),
      ),
      child: Row(
        spacing: KitTokens.quickNoteHeadGap,
        children: [
          if (!phone)
            const ExcludeSemantics(
              child: SizedBox(
                width: KitTokens.quickNoteGripWidth,
                height: KitTokens.quickNoteHeadHeight,
                child: Center(
                  child: KitIcon(
                    KitIconName.menu,
                    size: KitTokens.quickNoteIconSize,
                    strokeWidth: KitTokens.quickNoteIconStroke,
                    color: KitTokens.quickNoteGripInk,
                  ),
                ),
              ),
            ),
          Expanded(child: title),
          _button(
            'quick-note-undo',
            KitIconName.undo,
            '실행 취소',
            onUndo,
            enabled: canUndo,
          ),
          _button('quick-note-fold', KitIconName.collapse, '접기', onFold),
          _button('quick-note-close', KitIconName.close, '닫기', onClose),
        ],
      ),
    );
  }

  Widget _grab() => _dragging(
    sheetDrag,
    const SizedBox(
      key: ValueKey('quick-note-grab'),
      height: KitTokens.quickNoteSheetGrab,
      width: double.infinity,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: KitTokens.quickNoteSheetBarTop),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: KitTokens.quickNoteSheetBar,
              borderRadius: BorderRadius.all(
                Radius.circular(KitTokens.quickNoteSheetBarRadius),
              ),
            ),
            child: SizedBox(
              width: KitTokens.quickNoteSheetBarWidth,
              height: KitTokens.quickNoteSheetBarHeight,
            ),
          ),
        ),
      ),
    ),
  );

  Widget _handle() => Semantics(
    button: true,
    label: '크기 바꾸기',
    excludeSemantics: true,
    child: _dragging(
      resize,
      const SizedBox.square(
        key: ValueKey('quick-note-resize'),
        dimension: KitTokens.quickNoteHandle,
        child: KitIcon(
          KitIconName.gripCorner,
          size: KitTokens.quickNoteHandle,
          strokeWidth: KitTokens.quickNoteHandleStroke,
          color: KitTokens.quickNoteHandleInk,
        ),
      ),
    ),
  );

  Widget _sizeBadge(Size size) => IgnorePointer(
    child: Center(
      child: Container(
        key: const ValueKey('quick-note-size'),
        height: KitTokens.quickNoteSizeHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: KitTokens.quickNoteSizePadH,
        ),
        decoration: BoxDecoration(
          color: KitTokens.quickNoteSizeBg,
          borderRadius: BorderRadius.circular(KitTokens.quickNoteSizeRadius),
        ),
        child: Center(
          widthFactor: 1,
          child: KitText(
            '${size.width.round()} × ${size.height.round()}',
            style: const TextStyle(
              fontSize: KitTokens.quickNoteTitleSize,
              height: KitTokens.lineHeightOne,
              letterSpacing: 0,
              fontWeight: FontWeight.w600,
              color: KitTokens.quickNoteSizeInk,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final radius = phone
        ? const BorderRadius.vertical(
            top: Radius.circular(KitTokens.quickNoteSheetRadius),
          )
        : BorderRadius.circular(KitTokens.quickNoteRadius);
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '빠른 노트',
      child: DecoratedBox(
        key: const ValueKey('quick-note-window'),
        decoration: BoxDecoration(
          color: KitTokens.quickNoteBg,
          borderRadius: radius,
          boxShadow: phone
              ? KitTokens.quickNoteSheetShadow
              : KitTokens.quickNoteShadow,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Column(
            children: [
              if (phone) _grab(),
              _dragging(move, _head()),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: paper),
                    if (!phone)
                      Positioned(right: 0, bottom: 0, child: _handle()),
                    if (size case final size? when !phone)
                      Positioned.fill(child: _sizeBadge(size)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The folded quick note (`.r1npill`): 「빠른 노트」 in a pill; its host
/// moves it and opens the window again on a press.
class KitQuickNotePill extends StatelessWidget {
  const new({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: '빠른 노트 펼치기',
    excludeSemantics: true,
    onTap: onOpen,
    child: Container(
      key: const ValueKey('quick-note-pill'),
      height: KitTokens.quickNotePillHeight,
      padding: KitTokens.quickNotePillPadding,
      decoration: BoxDecoration(
        color: KitTokens.quickNoteBg,
        borderRadius: BorderRadius.circular(KitTokens.quickNotePillRadius),
        boxShadow: KitTokens.quickNotePillShadow,
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        spacing: KitTokens.quickNotePillGap,
        children: [
          KitIcon(
            KitIconName.noteUp,
            size: KitTokens.quickNotePillIconSize,
            strokeWidth: KitTokens.quickNotePillIconStroke,
            color: KitTokens.quickNoteButtonInk,
          ),
          KitText('빠른 노트', style: KitQuickNoteWindow._title),
        ],
      ),
    ),
  );
}
