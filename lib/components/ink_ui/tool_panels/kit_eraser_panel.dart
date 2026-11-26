import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/ink_engine_support.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/ink_ui/tool_panels/tool_panel_common.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/eraser_targets.dart';

/// The eraser's kinds in stage 1 (preview 10th draft `MODES`): the mode,
/// its name, its short name on the bar's chip, its icon and what it does.
/// 「일반 지우개」 (partial erase) comes with the pen engine.
const eraserKinds = [
  (
    mode: EraserMode.stroke,
    name: '획 지우개',
    short: '획',
    icon: KitIconName.eraseStroke,
    help: '닿은 획 하나를 통째로 지웁니다.',
  ),
  (
    mode: EraserMode.lasso,
    name: '원형 선택 지우기',
    short: '원형',
    icon: KitIconName.eraseLasso,
    help: '둘러 그린 안쪽을 한꺼번에 지웁니다.',
  ),
];

/// [eraserKinds]' entry for [mode].
({EraserMode mode, String name, String short, KitIconName icon, String help})
eraserKindOf(EraserMode mode) => eraserKinds.firstWhere((k) => k.mode == mode);

/// The eraser size on the slider's 1-100 scale.
int eraserLevel() => sizeToLevel(
  stows.eraserSize.value,
  min: KitTokens.eraserSizeMin,
  max: KitTokens.eraserSizeMax,
);

/// Keeps [level] as the eraser size. The same number keeps a size kept
/// between two numbers (an older size).
void keepEraserLevel(int level) {
  if (level == eraserLevel()) return;
  stows.eraserSize.value = levelToSize(
    level,
    min: KitTokens.eraserSizeMin,
    max: KitTokens.eraserSizeMax,
  );
}

/// 「지우개 종류」 (opened from the bar's kind chip): the kinds as cards and
/// what the chosen one does. A card is taken at once. Only the kinds
/// [engine] has show; its kind in effect is marked.
class KitEraserTypePanel extends StatelessWidget {
  const new({super.key, this.engine = InkEngineSupport.editor});

  /// What the document's ink engine has.
  final InkEngineSupport engine;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: stows.eraserMode,
    builder: (context, chosen, _) {
      final offered = engine.eraserModes;
      final mode = engine.eraserModeOf(chosen);
      return ToolWindow(
        key: const ValueKey('kit-eraser-type-panel'),
        title: '지우개 종류',
        children: [
          ToolCards<EraserMode>(
            cards: [
              for (final kind in eraserKinds)
                if (offered == null || offered.contains(kind.mode))
                  (
                    value: kind.mode,
                    label: kind.name,
                    icon: kind.icon,
                    key: 'eraser-kind-${kind.mode.name}',
                  ),
            ],
            value: mode,
            onChanged: (m) => stows.eraserMode.value = m,
          ),
          toolWindowHelp(
            eraserKindOf(mode).help,
            key: const ValueKey('eraser-kind-help'),
          ),
        ],
      );
    },
  );
}

/// 「고급 설정」 (opened from the bar's toggles button): the size slider
/// (1-100, dimmed in circle select, which does not use it), 「지울 대상」 펜 ·
/// 연필 · 형광펜 · 도형, 「자동 해제」 and, when the host can, a red 「쪽
/// 지우기」 calling [onClearPage]. The last target on cannot be turned off;
/// trying says why in red until another one changes.
///
/// Dragging the size only redraws the slider; the size is kept once, when the
/// drag ends.
///
/// Only the 「지울 대상」 rows [engine] has show (the infinite note: 펜 and
/// 형광펜); then the last of those on is the one that stays.
class KitEraserAdvancedPanel extends StatefulWidget {
  const new({
    super.key,
    this.onClearPage,
    this.engine = InkEngineSupport.editor,
  });

  final VoidCallback? onClearPage;

  /// What the document's ink engine has.
  final InkEngineSupport engine;

  /// Why the last target on cannot be turned off.
  static const keepOne = '지울 대상은 하나 이상 있어야 합니다. 다른 대상을 먼저 켜세요.';

  @override
  State<KitEraserAdvancedPanel> createState() => _KitEraserAdvancedPanelState();
}

class _KitEraserAdvancedPanelState extends State<KitEraserAdvancedPanel> {
  late final ValueNotifier<int> _level;

  /// Set when the last target was tried; cleared by the next change.
  var _refused = false;

  static const _targets = [
    (StrokeKind.pen, '펜', KitIconName.pen),
    (StrokeKind.pencil, '연필', KitIconName.pencil),
    (StrokeKind.highlighter, '형광펜', KitIconName.marker),
    (StrokeKind.shape, '도형', KitIconName.shapes),
  ];

  @override
  void initState() {
    super.initState();
    _level = ValueNotifier(eraserLevel());
    stows.eraserSize.addListener(_sizeChanged);
  }

  @override
  void dispose() {
    stows.eraserSize.removeListener(_sizeChanged);
    _level.dispose();
    super.dispose();
  }

  void _sizeChanged() => _level.value = eraserLevel();

  @override
  Widget build(BuildContext context) => ToolWindow(
    key: const ValueKey('kit-eraser-advanced-panel'),
    title: '고급 설정',
    children: [
      const ToolWindowGroupTitle('크기'),
      SizedBox(
        height: KitTokens.penPanelRowHeight,
        child: Center(
          child: ListenableBuilder(
            listenable: Listenable.merge([stows.eraserMode, _level]),
            builder: (context, _) => KitSlider(
              key: const ValueKey('eraser-advanced-size'),
              value: _level.value,
              onChanged: (v) => _level.value = v,
              onChangeEnd: keepEraserLevel,
              enabled:
                  widget.engine.eraserModeOf(stows.eraserMode.value) !=
                  EraserMode.lasso,
              // the 7th draft eraser panel's slider (`SLD.esize`)
              label: '지우개 크기',
              decreaseLabel: '작게',
              increaseLabel: '크게',
              markColor: KitTokens.eraserMarkInk,
              markDiameter: (v) =>
                  KitTokens.eraserMarkBase + v * KitTokens.eraserMarkPerLevel,
            ),
          ),
        ),
      ),
      const ToolWindowGroupTitle('지울 대상'),
      ListenableBuilder(
        listenable: Listenable.merge([
          stows.eraserTargets,
          stows.eraseHighlighterOnly,
        ]),
        builder: (context, _) {
          final on = EraserTargets.value;
          final shown = widget.engine.eraserTargets ?? StrokeKind.values;
          final oneOn = shown.where(on.contains).length == 1;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (kind, label, icon) in _targets)
                if (shown.contains(kind))
                  ToolSwitchRow(
                    key: ValueKey('eraser-target-${kind.name}'),
                    label: label,
                    icon: icon,
                    value: on.contains(kind),
                    lockedReason: on.contains(kind) && oneOn
                        ? KitEraserAdvancedPanel.keepOne
                        : null,
                    onLocked: () => setState(() => _refused = true),
                    onChanged: (v) {
                      if (EraserTargets.set(kind, v)) {
                        setState(() => _refused = false);
                      }
                    },
                  ),
            ],
          );
        },
      ),
      toolWindowHelp(
        '꺼 둔 대상의 흔적은 지우지 않습니다.',
        key: const ValueKey('eraser-target-help'),
        left: true,
      ),
      if (_refused)
        toolWindowMessage(
          KitEraserAdvancedPanel.keepOne,
          key: const ValueKey('eraser-target-message'),
        ),
      const ToolWindowLine(),
      ValueListenableBuilder(
        valueListenable: stows.disableEraserAfterUse,
        builder: (context, on, _) => ToolSwitchRow(
          key: const ValueKey('eraser-auto-release'),
          label: '자동 해제',
          value: on,
          onChanged: (v) => stows.disableEraserAfterUse.value = v,
        ),
      ),
      toolWindowNote('지우고 나면 전에 쓰던 도구로 돌아갑니다.'),
      if (widget.onClearPage case final clear?) ...[
        const ToolWindowLine(),
        ToolWindowRedButton(
          key: const ValueKey('eraser-clear-page'),
          label: '쪽 지우기',
          onTap: clear,
        ),
      ],
    ],
  );
}

/// Asks before 「쪽 지우기」; true when the user goes on. The preview draws
/// no confirm window, so it is a tool window (the eraser window's surface,
/// menu shadow and no outline, as the floating bar's tool windows; title,
/// note, line and red row) in the middle of the screen, over the kit's
/// light dim (a step that clears a page keeps a dim behind it). 「취소」 is
/// the bolder row under a 1 px line (final review design call 1).
Future<bool> confirmClearPage(BuildContext context) async {
  final radius = BorderRadius.circular(KitTokens.penPanelRadius);
  return await showDialog<bool>(
        context: context,
        barrierColor: KitTokens.customizeScrim,
        builder: (context) => Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: KitTokens.menuBg,
              borderRadius: radius,
              boxShadow: KitTokens.menuShadow,
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Material(
                type: MaterialType.transparency,
                child: ToolWindow(
                  title: '쪽 지우기',
                  children: [
                    toolWindowNote(
                      '이 쪽의 필기와 사진을 모두 지웁니다. 실행 취소로 되돌릴 수 있습니다.',
                    ),
                    const ToolWindowLine(),
                    ToolWindowRedButton(
                      key: const ValueKey('eraser-clear-page-confirm'),
                      label: '지우기',
                      onTap: () => Navigator.of(context).pop(true),
                    ),
                    // 1 px between the two rows, in the window's line colour
                    const SizedBox(
                      key: ValueKey('eraser-clear-page-divider'),
                      height: 1,
                      child: ColoredBox(color: KitTokens.toolLineColor),
                    ),
                    ToolWindowRedButton(
                      key: const ValueKey('eraser-clear-page-cancel'),
                      label: '취소',
                      danger: false,
                      onTap: () => Navigator.of(context).pop(false),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ) ??
      false;
}
