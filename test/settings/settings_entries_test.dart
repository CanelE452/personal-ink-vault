import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_icons.g.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/settings_registry.dart';
import 'package:saber/pages/settings/settings_entries.dart';

void main() {
  FlavorConfig.setup();
  late SettingsRegistry reg;

  setUp(() {
    reg = SettingsRegistry(reasons: ValueNotifier(<String, String>{}));
    registerSettingsEntries(reg);
    addTearDown(reg.dispose);
  });

  List<String> keys(String g) => [for (final e in reg.inGroup(g)) e.key];

  test('one key is one row', () {
    final all = [for (final e in reg.entries) e.key];
    expect(all.toSet().length, all.length, reason: all.join(', '));
    expect(
      all.where((k) => k == stows.shapeRecognitionDelay.key),
      hasLength(1),
    );
    expect(all.where((k) => k == straightLineInHandKey), hasLength(1));
    expect(
      all.where(
        (k) => k == stows.autoDisableFingerDrawingWhenStylusDetected.key,
      ),
      hasLength(1),
    );
  });

  test('groups are option B in the approved preview order', () {
    expect(reg.groups, ['일반', '보관함', '필기', '필기 화면', '펜·도구', '고급']);
    expect(reg.entries.length, 27);
    // 「손가락 제스처」 has no rows in stage 1, so it is not a group yet.
    expect(reg.inGroup('손가락 제스처'), isEmpty);
    expect([for (final g in reg.groups) settingsGroupIcon(g)], [
      KitIconName.tune,
      KitIconName.folder,
      KitIconName.draw,
      KitIconName.editNote,
      KitIconName.stylus,
      KitIconName.wrench,
    ]);
  });

  test('each row sits in its group, in the proposed order', () {
    expect(keys('일반'), [
      stows.appTheme.key,
      stows.hyperlegibleFont.key,
      stows.editorPromptRename.key,
      stows.printPageIndicators.key,
    ]);
    expect(keys('보관함'), [
      AppActionIds.localVaults,
      AppActionIds.backup,
      AppActionIds.vaultExport,
      AppActionIds.restore,
      AppActionIds.mcp,
      AppActionIds.openNoteLink,
    ]);
    // 필기: the six value rows of the old 「기타 설정」, with the table's icons
    expect(keys('필기'), [
      stows.lastZoomLock.key,
      stows.lastSingleFingerPanLock.key,
      stows.lastAxisAlignedPanLock.key,
      straightLineInHandKey,
      stows.autoDisableFingerDrawingWhenStylusDetected.key,
      stows.shapeRecognitionDelay.key,
    ]);
    expect([for (final k in keys('필기')) settingsRowIcon(k)], [
      KitIconName.zoom,
      KitIconName.tap,
      KitIconName.move,
      KitIconName.magic,
      KitIconName.draw,
      KitIconName.shapes,
    ]);
    expect(keys('필기 화면'), [
      stows.disableEraserAfterUse.key,
      stows.hideFingerDrawingToggle.key,
      stows.editorToolbarShowInFullscreen.key,
      stows.editorAutoInvert.key,
      stows.autosaveDelay.key,
      stows.maxImageSize.key,
    ]);
    expect(keys('펜·도구'), [
      stows.preferGreyscale.key,
      stows.recentColorsDontSavePresets.key,
      stows.recentColorsLength.key,
    ]);
    expect(keys('고급'), [AppActionIds.viewLogs, AppActionIds.openDataDir]);
  });

  test('the moved writing rows keep their names and old keys', () {
    expect(reg.byKey(straightLineInHandKey)!.label, '직선 자동 보정');
    final delay = reg.byKey(stows.shapeRecognitionDelay.key);
    expect(delay, isA<ChoiceSetting<int>>());
    expect((delay! as ChoiceSetting<int>).options, [
      (500, '0.5초'),
      (1000, '1초'),
      (-1, '끄기'),
    ]);
    expect(reg.byKey(stows.lastZoomLock.key)!.widgetKey, const ValueKey('toolbar-zoom-lock'));
    expect(
      reg.byKey(straightLineInHandKey)!.widgetKey,
      const ValueKey('toolbar-auto-straighten'),
    );
    expect(delay.widgetKey, const ValueKey('toolbar-shape-delay'));
  });

  test('the vault group is six action rows with the old keys', () {
    final rows = reg.inGroup('보관함');
    expect(rows.every((e) => e is ActionSetting), isTrue);
    expect([for (final e in rows) (e.widgetKey! as ValueKey).value], [
      'settings-local-vaults',
      'settings-backup',
      'settings-obsidian',
      'settings-restore',
      'settings-mcp',
      'settings-open-link',
    ]);
  });

  test('names the review asked for', () {
    final autosave = reg.byKey(stows.autosaveDelay.key)! as ChoiceSetting<int>;
    expect(autosave.options.last, (-1, '안 함'));
    final size = reg.byKey(stows.maxImageSize.key)! as ChoiceSetting<double>;
    expect([for (final o in size.options) o.$2], [
      '500픽셀',
      '1000픽셀',
      '2000픽셀',
    ]);
    expect(
      reg.byKey(stows.hideFingerDrawingToggle.key)!.label,
      '손가락 필기 단추 숨기기',
    );
    expect(
      reg.byKey(stows.autoDisableFingerDrawingWhenStylusDetected.key)!.label,
      '펜이 닿으면 손가락 필기 끄기',
    );
    expect(reg.byKey(AppActionIds.restore)!.label, '백업을 새 저장소로 복원');
    expect(reg.byKey(AppActionIds.restore)!.description, isNotNull);
  });

  test('the greyscale row says what it does in the pen panel and the old bar', () {
    // The pen panel opens its colour row on the greyscale page with it; the old
    // colour bar shows the greyscale palette until Task 19 removes it.
    final row = reg.byKey(stows.preferGreyscale.key)!;
    expect(row, isA<ToggleSetting>());
    expect(row.label, '회색조 색 먼저 보기');
    expect(row.description, '색을 고를 때 회색조 색을 먼저 보여 줍니다.');
    expect(row.group, '펜·도구');
    expect(row.widgetKey, isNull);
    expect(settingsRowIcon(row.key), KitIconName.palette);
  });

  test('every value row and group has an icon', () {
    for (final e in reg.entries) {
      if (e is ActionSetting) continue;
      expect(settingsRowIcon(e.key), isNot(settingsRowIcon('no such key')),
          reason: e.key);
    }
    for (final g in reg.groups) {
      expect(settingsGroupIcon(g), isNotNull);
    }
  });

  test('every action row names an action id that exists', () {
    for (final e in reg.entries.whereType<ActionSetting>()) {
      expect(AppActionIds.all, contains(e.actionId));
    }
  });

  test('registering again does not add rows', () {
    final before = reg.entries.length;
    registerSettingsEntries(reg);
    expect(reg.entries.length, before);
  });

  test('no real pair is registered in stage 1', () {
    expect(
      reg.entries.whereType<ToggleSetting>().every(
        (t) => t.conflictsWith.isEmpty,
      ),
      isTrue,
    );
  });
}
