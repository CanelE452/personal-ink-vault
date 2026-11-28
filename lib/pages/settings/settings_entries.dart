import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_icons.g.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/settings_registry.dart';
import 'package:stow_plain/stow_plain.dart';

// Group assignment lives here and only here (option B: the six value rows of
// the old 「기타 설정」 stay together in 「필기」; the other groups come from the
// approved preview's list). Registration order is the group order, and the
// row order inside each group. 「손가락 제스처」 has no rows in stage 1, so
// it is not registered and the page shows no such group.
const _general = '일반';
const _vault = '보관함';
const _writing = '필기';
const _writingScreen = '필기 화면';
const _pen = '펜·도구';
const _advanced = '고급';

const _groupIcons = <String, KitIconName>{
  _general: KitIconName.tune,
  _vault: KitIconName.folder,
  _writing: KitIconName.draw, // not in the preview's list; the table's pick
  _writingScreen: KitIconName.editNote,
  _pen: KitIconName.stylus,
  _advanced: KitIconName.wrench,
};

/// The icon in front of each value row, by setting key; never changed.
final _rowIcons = Map<String, KitIconName>.unmodifiable({
  stows.appTheme.key: KitIconName.palette,
  stows.hyperlegibleFont.key: KitIconName.fontAa,
  stows.editorPromptRename.key: KitIconName.rename,
  stows.printPageIndicators.key: KitIconName.doc,
  stows.lastZoomLock.key: KitIconName.zoom,
  stows.lastSingleFingerPanLock.key: KitIconName.tap,
  stows.lastAxisAlignedPanLock.key: KitIconName.move,
  straightLineInHandKey: KitIconName.magic,
  stows.autoDisableFingerDrawingWhenStylusDetected.key: KitIconName.draw,
  stows.shapeRecognitionDelay.key: KitIconName.shapes,
  stows.disableEraserAfterUse.key: KitIconName.eraser,
  stows.hideFingerDrawingToggle.key: KitIconName.draw,
  stows.editorToolbarShowInFullscreen.key: KitIconName.expand,
  stows.editorAutoInvert.key: KitIconName.fill,
  stows.autosaveDelay.key: KitIconName.checkCircle,
  stows.maxImageSize.key: KitIconName.image,
  stows.preferGreyscale.key: KitIconName.palette,
  stows.recentColorsDontSavePresets.key: KitIconName.colorDd,
  stows.recentColorsLength.key: KitIconName.history,
});

/// The icon in front of a value row (by setting key); a plain one when the
/// key is not one of ours.
KitIconName settingsRowIcon(String key) => _rowIcons[key] ?? KitIconName.tune;

/// The icon of a group in the page's left list.
KitIconName settingsGroupIcon(String group) =>
    _groupIcons[group] ?? KitIconName.tune;

/// Fills [registry] with every settings row, group by group (option B, in the
/// order of the preview's list). Calling it again replaces each row in place.
///
/// Value rows hold the stow itself and use its key. Stage 1 has no pair that
/// turns another setting off, so no row names a `conflictsWith`.
void registerSettingsEntries(SettingsRegistry registry) {
  void toggle(
    PlainStow<bool> stow,
    String label,
    String group, {
    String? description,
    String? widgetKey,
  }) {
    registry.register(
      ToggleSetting(
        key: stow.key,
        label: label,
        description: description,
        group: group,
        widgetKey: widgetKey == null ? null : ValueKey(widgetKey),
        notifier: stow,
      ),
    );
  }

  void choice<T>(
    ValueNotifier<T> notifier,
    String key,
    String label,
    String group,
    List<(T, String)> options, {
    String? description,
    String? widgetKey,
  }) {
    registry.register(
      ChoiceSetting<T>(
        key: key,
        label: label,
        description: description,
        group: group,
        widgetKey: widgetKey == null ? null : ValueKey(widgetKey),
        notifier: notifier,
        options: options,
      ),
    );
  }

  void action(
    String id,
    String label,
    String group, {
    String? description,
    String? widgetKey,
  }) => registry.register(
    ActionSetting(
      actionId: id,
      label: label,
      description: description,
      group: group,
      widgetKey: widgetKey == null ? null : ValueKey(widgetKey),
    ),
  );

  // 일반: what applies to the whole app.
  choice<ThemeMode>(
    stows.appTheme,
    stows.appTheme.key,
    '앱 테마',
    _general,
    const [
      (ThemeMode.system, '시스템'),
      (ThemeMode.light, '밝게'),
      (ThemeMode.dark, '어둡게'),
    ],
  );
  toggle(
    stows.hyperlegibleFont,
    '읽기 쉬운 글꼴',
    _general,
    description: 'Atkinson Hyperlegible 글꼴로 글자를 또렷하게 보여 줍니다.',
  );
  toggle(
    stows.editorPromptRename,
    '새 노트의 이름 묻기',
    _general,
    description: '이름은 나중에 언제든 바꿀 수 있습니다.',
  );
  toggle(
    stows.printPageIndicators,
    '쪽 표시 넣기',
    _general,
    description: '내보내기와 미리보기에 쪽 표시를 넣습니다.',
  );

  // 보관함: the old settings window's vault rows, run by the workspace.
  action(
    AppActionIds.localVaults,
    '기기의 저장소',
    _vault,
    widgetKey: 'settings-local-vaults',
  );
  action(
    AppActionIds.backup,
    '백업 내보내기',
    _vault,
    widgetKey: 'settings-backup',
  );
  action(
    AppActionIds.vaultExport,
    'Obsidian 보관함 ZIP',
    _vault,
    widgetKey: 'settings-obsidian',
  );
  action(
    AppActionIds.restore,
    '백업을 새 저장소로 복원',
    _vault,
    description: '지금 쓰는 저장소는 그대로 두고, 백업을 새 저장소로 풀어 그 저장소를 엽니다.',
    widgetKey: 'settings-restore',
  );
  action(
    AppActionIds.mcp,
    '다른 AI 연결 · MCP',
    _vault,
    widgetKey: 'settings-mcp',
  );
  action(
    AppActionIds.openNoteLink,
    '노트 링크 열기',
    _vault,
    widgetKey: 'settings-open-link',
  );

  // 필기: the six value rows of the old 「기타 설정」 panel.
  toggle(
    stows.lastZoomLock,
    '확대 잠금',
    _writing,
    description: '두 손가락으로 확대·축소하지 않습니다.',
    widgetKey: 'toolbar-zoom-lock',
  );
  toggle(
    stows.lastSingleFingerPanLock,
    '한 손가락 이동 잠금',
    _writing,
    description: '한 손가락으로는 화면이 움직이지 않습니다.',
  );
  toggle(
    stows.lastAxisAlignedPanLock,
    '가로·세로로만 이동',
    _writing,
    description: '화면을 비스듬히 움직이지 않습니다.',
  );
  // the pen in hand's straight line (each pen has its own, user answer 2),
  // and its 수평/수직 for the pen panel's rule only; outside the editor the
  // pen a note opens with. The table owns the two values and lets them go
  // with their rows, so filling it again leaves no listener behind.
  registry.register(
    ToggleSetting(
      key: straightLineInHandKey,
      label: '직선 자동 보정',
      description: '손으로 그은 선이 거의 곧으면 반듯하게 바꿉니다.',
      group: _writing,
      widgetKey: const ValueKey('toolbar-auto-straighten'),
      notifier: PenSettingInHand.straightLine(),
      ownsNotifier: true,
    ),
  );
  registry.register(
    ToggleSetting(
      key: axisLockInHandKey,
      label: '수평/수직 그리기',
      group: _pen,
      onPage: false,
      notifier: PenSettingInHand.axisLock(),
      ownsNotifier: true,
    ),
  );
  toggle(
    stows.autoDisableFingerDrawingWhenStylusDetected,
    '펜이 닿으면 손가락 필기 끄기',
    _writing,
    description: '펜으로 쓰는 동안 손가락은 화면만 움직입니다.',
  );
  choice<int>(
    stows.shapeRecognitionDelay,
    stows.shapeRecognitionDelay.key,
    '도형 미리보기',
    _writing,
    const [(500, '0.5초'), (1000, '1초'), (-1, '끄기')],
    description:
        '도형 펜으로 그리다 멈추면 이 시간 뒤에 반듯한 도형을 미리 보여 줍니다. '
        '꺼도 펜을 떼면 도형으로 바뀝니다.',
    widgetKey: 'toolbar-shape-delay',
  );

  // 필기 화면
  toggle(
    stows.disableEraserAfterUse,
    '지우개를 쓴 뒤 펜으로 돌아가기',
    _writingScreen,
    description: '지우개를 한 번 쓰면 자동으로 펜으로 바꿉니다.',
  );
  toggle(
    stows.hideFingerDrawingToggle,
    '손가락 필기 단추 숨기기',
    _writingScreen,
    description: '도구 막대의 손가락 필기 켜고 끄기 단추를 숨깁니다.',
  );
  toggle(
    stows.editorToolbarShowInFullscreen,
    '전체 화면에서도 도구 막대 보이기',
    _writingScreen,
  );
  toggle(
    stows.editorAutoInvert,
    '어두운 모드에서 노트 색 반전',
    _writingScreen,
  );
  choice<int>(
    stows.autosaveDelay,
    stows.autosaveDelay.key,
    '자동 저장',
    _writingScreen,
    const [(5000, '5초'), (10000, '10초'), (-1, '안 함')],
    description:
        '필기를 멈추고 이 시간이 지나면 저장합니다. 「안 함」이면 자동으로 저장하지 않지만, 노트를 닫을 때는 저장합니다.',
  );
  choice<double>(
    stows.maxImageSize,
    stows.maxImageSize.key,
    '사진 최대 크기',
    _writingScreen,
    const [(500.0, '500픽셀'), (1000.0, '1000픽셀'), (2000.0, '2000픽셀')],
    description: '긴 변이 이보다 큰 사진은 줄여서 넣습니다.',
  );

  // 펜·도구
  // The pen panel opens its colour row on the greyscale page with it (the
  // only reader since the 229 colour bar went in Task 19).
  toggle(
    stows.preferGreyscale,
    '회색조 색 먼저 보기',
    _pen,
    description: '색을 고를 때 회색조 색을 먼저 보여 줍니다.',
  );
  toggle(
    stows.recentColorsDontSavePresets,
    '기본 색은 최근 색에 넣지 않기',
    _pen,
    description: '기본 색을 고르면 최근 색 줄에는 남기지 않습니다.',
  );
  choice<int>(
    stows.recentColorsLength,
    stows.recentColorsLength.key,
    '최근 색 개수',
    _pen,
    const [(5, '5'), (10, '10')],
  );

  // 고급
  action(AppActionIds.viewLogs, '기록 보기', _advanced);
  action(AppActionIds.openDataDir, '데이터 폴더 열기', _advanced);
}
