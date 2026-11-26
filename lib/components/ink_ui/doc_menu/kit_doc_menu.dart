import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/kit_zoom_badge.dart';
import 'package:saber/components/ink_ui/tool_panels/kit_eraser_panel.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/prefs.dart';

/// What 「문서 정보」 shows beside the name, the kind and the pages: the last
/// edit, the Drive state and whether the note is kept on the device. The
/// host (the workspace) knows them; an editor alone fills them itself.
class DocInfo {
  const new({
    this.lastEdited,
    required this.syncLabel,
    this.synced = false,
    required this.offlineLabel,
  });

  final DateTime? lastEdited;
  final String syncLabel;

  /// The note is on the Drive as it is here ([syncLabel] reads green).
  final bool synced;
  final String offlineLabel;
}

/// 「마지막 편집」 of ⋯ 「문서 정보」 and of the tab ⌄, one rule for both:
/// the editor's last change while it has one, else the vault's.
DateTime? docLastEdited({DateTime? editor, DateTime? vault}) =>
    editor ?? vault;

/// 「43분 전」: how long before [now] [at] was; after a week, the date.
String docInfoAgo(DateTime at, DateTime now) {
  final gone = now.difference(at);
  if (gone.inMinutes < 1) return '방금 전';
  if (gone.inHours < 1) return '${gone.inMinutes}분 전';
  if (gone.inDays < 1) return '${gone.inHours}시간 전';
  if (gone.inDays < 7) return '${gone.inDays}일 전';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)}';
}

/// Where 「확대 비율」 reads the scale (when the menu opens: zooming does not
/// build the editor again) and how it changes it.
class DocZoom {
  const new({required this.scale, required this.zoomTo});

  final double Function() scale;
  final ValueChanged<double> zoomTo;
}

String _percent(double scale) => '${(scale * 100).round()}%';

/// Closes the window on [context]'s navigator (with its submenu, [depth]
/// 2), then runs [then] in the same frame (ledger ruling, Task 14 fix 1):
/// the toolbar's ⌄ and ⋯ windows both close this way.
void closeMenuThen(BuildContext context, VoidCallback then, {int depth = 1}) {
  final navigator = Navigator.of(context);
  for (var i = 0; i < depth; i++) {
    navigator.pop();
  }
  then();
}

/// 「확대 비율」 and its submenu, the same in the editor's ⋯ and the
/// function row's ⋯: the zoom steps (the one at [scale] checked, 100 %
/// named [fitLabel]) and 「확대 잠금」, the editor's lock (two fingers and
/// the wheel keep the scale; a step picked here still applies, user
/// 2026-11-19). A step closes the window on [context] and its submenu, then
/// zooms. The rows' keys start with [keyPrefix].
KitMenuRow zoomSubmenu({
  required BuildContext context,
  required String keyPrefix,
  required DocZoom zoom,
  required double scale,
  String fitLabel = '100%',
}) => KitMenuRow.submenu(
  key: ValueKey(keyPrefix),
  icon: KitIconName.zoom,
  label: '확대 비율',
  value: _percent(scale),
  children: [
    for (final step in zoomSteps)
      KitMenuRow.action(
        key: ValueKey('$keyPrefix-$step'),
        label: step == 1 ? fitLabel : _percent(step),
        checked: (scale - step).abs() < .005,
        onTap: () => closeMenuThen(context, () => zoom.zoomTo(step), depth: 2),
      ),
    KitMenuRow.toggle(
      key: ValueKey('$keyPrefix-lock'),
      lineAbove: true,
      label: '확대 잠금',
      value: stows.lastZoomLock.value,
      onChanged: (on) => stows.lastZoomLock.value = on,
    ),
  ],
);

/// The rows that change the note: dimmed while 「읽기 전용」 is on, also
/// when their owner (the workspace's 휴지통으로) does not know the lock.
const _changesNote = {
  AppActionIds.pageDuplicate,
  AppActionIds.pageRotate,
  AppActionIds.outlineAdd,
  AppActionIds.templateChange,
  AppActionIds.selectiveErase,
  AppActionIds.clearPage,
  AppActionIds.moveToTrash,
  AppActionIds.pdfRemake,
  AppActionIds.linkAdd,
};

/// The editor's ⋯ document menu (user 2026-11-25 「⋯ 아래에 묶어 둠」): the
/// 9th draft c rows on top (문서 정보 · 이름 바꾸기 · 쪽 배치), then the
/// design's 「⋯ 문서 메뉴」 table in its order: the quick buttons 검색 ·
/// 읽기 전용, 보기, 쪽 N, 지우기, 정렬·설정 and 더 보기 (229's ⋯ shortcuts
/// in their order, after 「지금 저장」). The table's 연속 스크롤 / 한 쪽씩
/// 보기 is 쪽 배치 on top. What only 229's function row held goes in too
/// (Task 17): 이전·다음 위치 in 보기, 손가락 필기 in 정렬·설정, 기기에
/// 저장 in 더 보기.
///
/// A row shows only when [actions] has its action, a group only with a row
/// left, and a row is dimmed while its action is off, or while 「읽기 전용」
/// is on when it changes the note. A row closes the menu (and its submenu)
/// and then runs its action on [context], the ⋯ button's. 「쪽 지우기」
/// asks first. 「확대 비율」 shows with [zoom] only.
KitMenu buildDocMenu({
  required BuildContext context,
  required String title,
  required AppActionRegistry actions,
  required int pageIndex,
  required int pageCount,
  DocZoom? zoom,
  double width = 224,
  double layoutTop = 112,
}) {
  void closeThen(VoidCallback then, {int depth = 1}) =>
      closeMenuThen(context, then, depth: depth);

  final locked = actions.lookup(AppActionIds.readOnly)?.checked ?? false;

  void run(String id, {int depth = 1}) =>
      closeThen(() => actions.run(id, context), depth: depth);

  /// The row of action [id], named [label] (else as the action names
  /// itself), or nothing when nobody offers it.
  KitMenuRow? row(
    String id, {
    String? label,
    KitIconName? icon,
    bool danger = false,
    bool opens = false,
    String? value,
    bool? checked,
    VoidCallback? onTap,
    Key? key,
  }) {
    final action = actions.lookup(id);
    if (action == null) return null;
    return KitMenuRow.action(
      key: key ?? action.widgetKey ?? ValueKey('editor-doc-$id'),
      icon: icon ?? action.icon,
      label: label ?? action.label,
      danger: danger,
      opens: opens,
      value: value,
      checked: checked ?? action.checked ?? false,
      enabled: action.enabled && !(locked && _changesNote.contains(id)),
      onTap: onTap ?? () => run(id),
    );
  }

  final single = actions.lookup(AppActionIds.pageMode)?.checked ?? false;
  final tabsHidden = actions.lookup(AppActionIds.tabBarHide)?.checked ?? false;
  final scale = zoom?.scale();
  final search = actions.lookup(AppActionIds.pdfSearch);
  final readOnly = actions.lookup(AppActionIds.readOnly);
  return KitMenu(
    title: title,
    width: width,
    window: true,
    quickAfter: 1,
    quick: [
      if (search != null)
        KitMenuQuick(
          key: const ValueKey('editor-doc-search'),
          icon: KitIconName.search,
          label: '검색',
          enabled: search.enabled,
          onTap: () => run(AppActionIds.pdfSearch),
        ),
      if (readOnly != null)
        KitMenuQuick(
          key: const ValueKey('editor-doc-read-only'),
          icon: KitIconName.readonly,
          label: '읽기 전용',
          selected: readOnly.checked ?? false,
          enabled: readOnly.enabled,
          onTap: () => run(AppActionIds.readOnly),
        ),
    ],
    groups: [
      KitMenuGroup(
        rows: [
          ?row(
            AppActionIds.docInfo,
            key: const ValueKey('editor-doc-info'),
            label: '문서 정보',
            icon: KitIconName.info,
            opens: true,
          ),
          ?row(AppActionIds.rename, label: '이름 바꾸기', icon: KitIconName.rename),
          if (actions.lookup(AppActionIds.pageMode) case final mode?)
            KitMenuRow.submenu(
              key: const ValueKey('editor-doc-layout'),
              icon: KitIconName.scrollDir,
              label: '쪽 배치',
              value: single ? '가로' : '세로',
              // preview `openDoc`: under the ⋯ window's top, not its row
              windowTop: layoutTop,
              children: [
                for (final (horizontal, label, icon) in const [
                  (false, '세로로 이어 보기', KitIconName.scrollDir),
                  (true, '가로로 넘기기', KitIconName.swipeLr),
                ])
                  KitMenuRow.action(
                    key: ValueKey('editor-doc-layout-$horizontal'),
                    icon: icon,
                    label: label,
                    checked: horizontal == single,
                    onTap: horizontal == single || !mode.enabled
                        ? () => closeThen(() {}, depth: 2)
                        : () => run(AppActionIds.pageMode, depth: 2),
                  ),
              ],
            ),
        ],
      ),
      KitMenuGroup(
        title: '보기',
        rows: [
          ?row(AppActionIds.viewToggle),
          ?row(
            AppActionIds.fullscreen,
            label: '전체 화면',
            icon: KitIconName.expand,
          ),
          // hidden, the row is the way back (design 「다른 문서와 무한
          // 노트」), not a mode with a check
          ?row(
            AppActionIds.tabBarHide,
            label: tabsHidden ? '탭 줄 보이기' : '탭 줄 숨기기',
            checked: false,
          ),
          // 229's 이전 위치 · 다음 위치 (Task 17: the old row's last home)
          ?row(AppActionIds.prev),
          ?row(AppActionIds.next),
          if (zoom != null && scale != null)
            zoomSubmenu(
              context: context,
              keyPrefix: 'editor-doc-zoom',
              zoom: zoom,
              scale: scale,
              fitLabel: '100% (화면 너비)',
            ),
        ],
      ),
      KitMenuGroup(
        title: '쪽 ${pageIndex + 1}',
        rows: [
          ?row(
            AppActionIds.pageBookmark,
            label: '쪽 즐겨찾기',
            icon: KitIconName.bookmark,
          ),
          ?row(AppActionIds.pageCopy, label: '쪽 복사', icon: KitIconName.pageCopy),
          ?row(AppActionIds.pageDuplicate, label: '쪽 복제', icon: KitIconName.dup),
          ?row(
            AppActionIds.pageRotate,
            label: '쪽 돌리기',
            icon: KitIconName.rotatePage,
            opens: true,
          ),
          ?row(
            AppActionIds.outlineAdd,
            label: '개요에 추가',
            icon: KitIconName.outlineAdd,
          ),
          ?row(
            AppActionIds.templateChange,
            label: '템플릿 바꾸기',
            icon: KitIconName.template,
          ),
          ?row(
            AppActionIds.goToPage,
            label: '쪽으로 이동',
            icon: KitIconName.gotoPage,
            value: '${pageIndex + 1} / $pageCount',
          ),
        ],
      ),
      KitMenuGroup(
        title: '지우기',
        rows: [
          ?row(
            AppActionIds.selectiveErase,
            label: '골라서 지우기',
            icon: KitIconName.delItems,
          ),
          ?row(
            AppActionIds.clearPage,
            label: '쪽 지우기',
            icon: KitIconName.delPage,
            danger: true,
            onTap: () => closeThen(() async {
              if (!await confirmClearPage(context) || !context.mounted) return;
              actions.run(AppActionIds.clearPage, context);
            }),
          ),
          ?row(
            AppActionIds.moveToTrash,
            label: '휴지통으로',
            icon: KitIconName.trash,
            danger: true,
          ),
        ],
      ),
      KitMenuGroup(
        title: '정렬·설정',
        rows: [
          ?row(
            AppActionIds.alignObjects,
            label: '객체 정렬',
            icon: KitIconName.objAlign,
          ),
          ?row(
            AppActionIds.showDoneMemos,
            label: '끝낸 메모도 보기',
            icon: KitIconName.comment,
          ),
          ?row(
            AppActionIds.toolbarCustomize,
            label: '도구 막대 사용자화',
            icon: KitIconName.tune,
          ),
          // 229's 손가락 필기, a switch that leaves the window open; it
          // shows the setting the action flips
          if (actions.lookup(AppActionIds.finger) case final finger?)
            KitMenuRow.toggle(
              key: const ValueKey('editor-doc-finger'),
              icon: finger.icon,
              label: finger.label,
              value: stows.editorFingerDrawing.value,
              onChanged: (_) => actions.run(AppActionIds.finger, context),
            ),
          ?row(
            AppActionIds.openSettings,
            label: '전체 설정 열기',
            icon: KitIconName.settings,
            opens: true,
          ),
        ],
      ),
      KitMenuGroup(
        title: '더 보기',
        rows: [
          ?row(AppActionIds.saveNow, label: '지금 저장'),
          // 229's 기기에 저장
          ?row(AppActionIds.save),
          for (final id in AppActionIds.more229) ?row(id),
        ],
      ),
    ],
  );
}
