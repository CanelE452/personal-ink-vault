import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/settings_registry.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/settings/app_settings_page.dart';
import 'package:saber/pages/settings/settings_entries.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

Finder key(String value) => find.byKey(ValueKey(value));

/// Runs and what the fake actions saw, in order.
class _Calls {
  final runs = <String>[];
  final mounted = <bool>[];
  final routeActive = <bool>[];
  final hasNavigator = <bool>[];
  Route<void>? route;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  late SettingsRegistry reg;
  late AppActionRegistry acts;
  late _Calls calls;
  final owner = Object();

  AppAction fake(String id) => AppAction(
    id: id,
    label: id,
    icon: KitIconName.check,
    run: (context) {
      calls.runs.add(id);
      calls.mounted.add(context.mounted);
      calls.routeActive.add(calls.route?.isActive ?? false);
      calls.hasNavigator.add(Navigator.maybeOf(context) != null);
    },
  );

  setUp(() {
    reg = SettingsRegistry(reasons: ValueNotifier(<String, String>{}));
    registerSettingsEntries(reg);
    addTearDown(reg.dispose);
    calls = _Calls();
    acts = AppActionRegistry();
    addTearDown(acts.dispose);
  });

  void publishFive() => acts.publish(owner, [
    fake(AppActionIds.localVaults),
    fake(AppActionIds.backup),
    fake(AppActionIds.vaultExport),
    fake(AppActionIds.restore),
    fake(AppActionIds.openNoteLink),
  ]);

  void publishAll() => acts.publish(owner, [
    fake(AppActionIds.localVaults),
    fake(AppActionIds.backup),
    fake(AppActionIds.vaultExport),
    fake(AppActionIds.restore),
    fake(AppActionIds.openNoteLink),
    fake(AppActionIds.mcp),
    fake(AppActionIds.viewLogs),
    fake(AppActionIds.openDataDir),
  ]);

  double opacityOf(WidgetTester tester, String rowKey) => tester
      .widget<Opacity>(
        find.ancestor(of: key(rowKey), matching: find.byType(Opacity)),
      )
      .opacity;

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// A screen with one button that pushes the settings page.
  Future<void> openPage(
    WidgetTester tester, {
    SettingsRegistry? registry,
    String? initialQuery,
  }) async {
    calls.route = appSettingsRoute(
      actions: acts,
      registry: registry ?? reg,
      initialQuery: initialQuery,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => Navigator.of(context).push(calls.route!),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(key('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('search narrows the rows by name or description', (tester) async {
    tall(tester);
    publishAll();
    await openPage(tester);
    expect(key('toolbar-auto-straighten'), findsOneWidget);
    await tester.enterText(key('settings-search'), '손가락');
    await tester.pump();
    // 이름에 든 줄
    expect(find.text('한 손가락 이동 잠금'), findsOneWidget);
    // 설명에만 든 줄: 「확대 잠금」의 설명은 "두 손가락으로 …"
    expect(key('toolbar-zoom-lock'), findsOneWidget);
    expect(find.textContaining('두 손가락으로'), findsOneWidget);
    // 이름에도 설명에도 없는 줄
    expect(key('toolbar-auto-straighten'), findsNothing);
    expect(key('toolbar-shape-delay'), findsNothing);
    // 줄이 없어진 묶음은 머리도 목록 항목도 없다
    expect(key('settings-head-보관함'), findsNothing);
    expect(key('settings-nav-보관함'), findsNothing);
    expect(key('settings-head-고급'), findsNothing);
    expect(key('settings-head-필기'), findsOneWidget);
    expect(key('settings-nav-필기'), findsOneWidget);
    await tester.enterText(key('settings-search'), '없는설정이름');
    await tester.pump();
    expect(find.text("'없는설정이름'에 맞는 설정이 없습니다"), findsOneWidget);
  });

  testWidgets('the search box starts with initialQuery', (tester) async {
    tall(tester);
    publishFive();
    await openPage(tester, initialQuery: '확대 잠금');
    expect(key('toolbar-zoom-lock'), findsOneWidget);
    expect(key('toolbar-auto-straighten'), findsNothing);
    expect(
      tester.widget<TextField>(key('settings-search')).controller!.text,
      '확대 잠금',
    );
  });

  testWidgets('an auto-off row shows its reason under it', (tester) async {
    tall(tester);
    final a = ValueNotifier(true);
    final b = ValueNotifier(false);
    final test = SettingsRegistry(reasons: ValueNotifier(<String, String>{}));
    addTearDown(test.dispose);
    test
      ..register(
        ToggleSetting(
          key: 'a',
          label: '시험 하나',
          group: '시험',
          widgetKey: const ValueKey('row-a'),
          notifier: a,
        ),
      )
      ..register(
        ToggleSetting(
          key: 'b',
          label: '시험 둘',
          group: '시험',
          widgetKey: const ValueKey('row-b'),
          notifier: b,
          conflictsWith: const ['a'],
        ),
      );
    await openPage(tester, registry: test);
    expect(find.textContaining('꺼졌습니다'), findsNothing);
    expect(opacityOf(tester, 'row-a'), 1);
    await tester.tap(key('row-b'));
    await tester.pump();
    expect(a.value, isFalse);
    expect(b.value, isTrue);
    final reason = find.descendant(
      of: key('settings-row-a'),
      matching: find.text('시험 둘이 켜져 있어서 꺼졌습니다'),
    );
    expect(reason, findsOneWidget);
    expect(tester.widget<Text>(reason).style!.color, KitTokens.settingsDanger);
    expect(tester.widget<Text>(reason).style!.fontSize, 11);
    expect(
      find.descendant(
        of: key('settings-row-b'),
        matching: find.textContaining('꺼졌습니다'),
      ),
      findsNothing,
    );
    // 꺼진 줄은 투명도 .45, 켜진 줄은 그대로. 꺼진 줄도 눌러서 켤 수 있다.
    expect(opacityOf(tester, 'row-a'), KitTokens.settingsDimOpacity);
    expect(opacityOf(tester, 'row-b'), 1);
    await tester.tap(key('row-a'));
    await tester.pump();
    expect(a.value, isTrue);
  });

  testWidgets('writing group has the six moved value rows', (tester) async {
    tall(tester);
    publishAll();
    await openPage(tester);
    List<String> inGroup(String g) => [for (final e in reg.inGroup(g)) e.key];
    // 안 B: 옛 「기타 설정」 여섯 줄이 「필기」 한 묶음에 모인다.
    expect(reg.groups, ['일반', '보관함', '필기', '필기 화면', '펜·도구', '고급']);
    // 줄은 key로 찾는다 (옛 widgetKey 그대로).
    expect(key('toolbar-zoom-lock'), findsOneWidget);
    expect(key('toolbar-auto-straighten'), findsOneWidget);
    expect(key('toolbar-shape-delay'), findsOneWidget);
    expect(inGroup('필기'), [
      stows.lastZoomLock.key,
      stows.lastSingleFingerPanLock.key,
      stows.lastAxisAlignedPanLock.key,
      stows.autoStraightenLines.key,
      stows.autoDisableFingerDrawingWhenStylusDetected.key,
      stows.shapeRecognitionDelay.key,
    ]);
    // 그 여섯 줄은 화면에서 「필기」 머리와 「필기 화면」 머리 사이에 놓인다.
    final writingTop = tester.getTopLeft(key('settings-head-필기')).dy;
    final nextTop = tester.getTopLeft(key('settings-head-필기 화면')).dy;
    for (final k in inGroup('필기')) {
      final top = tester.getTopLeft(key('settings-row-$k')).dy;
      expect(top, greaterThan(writingTop), reason: k);
      expect(top, lessThan(nextTop), reason: k);
    }
    // 줄이 없는 「손가락 제스처」는 머리도 목록 항목도 없다.
    expect(key('settings-head-손가락 제스처'), findsNothing);
    expect(key('settings-nav-손가락 제스처'), findsNothing);
    expect(inGroup('펜·도구'), [
      stows.preferGreyscale.key,
      stows.recentColorsDontSavePresets.key,
      stows.recentColorsLength.key,
    ]);
    expect(inGroup('필기 화면'), [
      stows.disableEraserAfterUse.key,
      stows.hideFingerDrawingToggle.key,
      stows.editorToolbarShowInFullscreen.key,
      stows.editorAutoInvert.key,
      stows.autosaveDelay.key,
      stows.maxImageSize.key,
    ]);
    expect(find.text('직선 자동 보정'), findsOneWidget);
    expect(find.text('거의 곧은 선을 직선으로'), findsNothing);
    // 문서 명령 줄은 설정 화면에 없다 (⋯ 메뉴와 도구 막대로 감).
    for (final text in const [
      '템플릿 변경',
      '쪽으로 이동',
      '문서 개요',
      '연속 스크롤',
      '이미지로 내보내기',
      '사용자 지정 도구 모음',
    ]) {
      expect(find.textContaining(text), findsNothing, reason: text);
    }
    // 한 줄을 누르면 stow에 쓰인다.
    final before = stows.lastZoomLock.value;
    addTearDown(() => stows.lastZoomLock.value = before);
    await tester.tap(key('toolbar-zoom-lock'));
    await tester.pump();
    expect(stows.lastZoomLock.value, !before);
  });

  testWidgets('the left list has the six groups in order, none hidden', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(876, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    publishAll();
    await openPage(tester);
    expect(key('settings-nav'), findsOneWidget);
    expect(
      tester.getSize(key('settings-nav')).width,
      KitTokens.settingsNavWidth,
    );
    final names = ['일반', '보관함', '필기', '필기 화면', '펜·도구', '고급'];
    final tops = <double>[];
    for (final n in names) {
      expect(key('settings-nav-$n'), findsOneWidget, reason: n);
      expect(
        find.descendant(of: key('settings-nav-$n'), matching: find.text(n)),
        findsOneWidget,
      );
      tops.add(tester.getTopLeft(key('settings-nav-$n')).dy);
    }
    expect(tops, [...tops]..sort());
    expect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey &&
            (w.key! as ValueKey).value.toString().startsWith('settings-nav-'),
      ),
      findsNWidgets(6),
    );
    // 목록과 오른쪽 머리의 이름이 같다.
    for (final n in names) {
      expect(
        find.descendant(of: key('settings-head-$n'), matching: find.text(n)),
        findsOneWidget,
      );
    }
  });

  testWidgets('tapping a list entry brings its header into view', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(876, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    publishAll();
    await openPage(tester);
    Color? navColor(String n) => tester
        .widget<Text>(
          find.descendant(
            of: key('settings-nav-$n'),
            matching: find.byType(Text),
          ),
        )
        .style!
        .color;
    expect(tester.getTopLeft(key('settings-head-고급')).dy, greaterThan(600));
    expect(navColor('일반'), KitTokens.accent);
    expect(navColor('고급'), isNot(KitTokens.accent));
    await tester.tap(key('settings-nav-고급'));
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(key('settings-head-고급')).dy;
    expect(top, lessThan(600));
    expect(top, greaterThanOrEqualTo(0));
    // 목록은 보이는 머리를 따라간다.
    expect(navColor('고급'), KitTokens.accent);
    expect(navColor('일반'), isNot(KitTokens.accent));
    await tester.tap(key('settings-nav-보관함'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(key('settings-head-보관함')).dy, lessThan(300));
    expect(navColor('보관함'), KitTokens.accent);
  });

  testWidgets('every row has a 19px icon with stroke 1.70004', (tester) async {
    tall(tester);
    publishAll();
    await openPage(tester);
    final rowKeys = [for (final e in reg.entries) e.key];
    expect(rowKeys, hasLength(27));
    for (final k in rowKeys) {
      final icon = find.descendant(
        of: key('settings-row-$k'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is KitIcon &&
              w.size == KitTokens.settingsIconSize &&
              w.strokeWidth == KitTokens.settingsIconStroke,
        ),
      );
      expect(icon, findsOneWidget, reason: k);
    }
    expect(KitTokens.settingsIconSize, 19);
    expect(KitTokens.settingsIconStroke, 1.70004);
  });

  testWidgets('the search box sits at the right end of the top bar', (
    tester,
  ) async {
    tall(tester);
    publishAll();
    await openPage(tester);
    final bar = tester.getRect(key('settings-topbar'));
    final box = tester.getRect(key('settings-search-box'));
    expect(bar.height, 48);
    expect(box.width, 240);
    expect(box.right, bar.right - KitTokens.settingsTopBarPadH);
    expect(box.top, greaterThanOrEqualTo(bar.top));
    expect(box.bottom, lessThanOrEqualTo(bar.bottom));
    // 누르면 테두리가 강조색
    Color border() =>
        ((tester.widget<Container>(key('settings-search-box')).decoration!
                as BoxDecoration)
            .border!
            .top
            .color);
    expect(border(), KitTokens.settingsLine);
    await tester.tap(key('settings-search'));
    await tester.pump();
    expect(border(), KitTokens.accent);
  });

  testWidgets('below 720 wide the left list is gone', (tester) async {
    tester.view.physicalSize = const Size(700, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    publishAll();
    await openPage(tester);
    expect(key('settings-nav'), findsNothing);
    // 머리가 있는 한 줄 목록은 그대로 있다.
    expect(key('settings-head-일반'), findsOneWidget);
    expect(key('settings-head-고급'), findsOneWidget);
    expect(key('toolbar-zoom-lock'), findsOneWidget);
  });

  testWidgets('the list follows the header in view: middle, bottom, top', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(876, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    publishAll();
    await openPage(tester);
    const names = ['일반', '보관함', '필기', '필기 화면', '펜·도구', '고급'];
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: key('settings-scroll'),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    final viewTop = tester.getTopLeft(key('settings-scroll')).dy;
    String selected() {
      final on = [
        for (final n in names)
          if (tester
                  .widget<Text>(
                    find.descendant(
                      of: key('settings-nav-$n'),
                      matching: find.byType(Text),
                    ),
                  )
                  .style!
                  .color ==
              KitTokens.accent)
            n,
      ];
      expect(on, hasLength(1), reason: 'exactly one item is chosen');
      return on.single;
    }

    double headDy(String g) =>
        tester.getTopLeft(key('settings-head-$g')).dy - viewTop;
    Future<void> placeHead(String g, double dy) async {
      position.jumpTo(position.pixels + headDy(g) - dy);
      await tester.pump();
    }

    expect(selected(), '일반');
    // middle: a header at the top of the view is the chosen group
    await placeHead('필기', 0);
    expect(selected(), '필기');
    // a header still 30 below the top is not yet; 8 below it is
    await placeHead('필기 화면', 30);
    expect(selected(), '필기');
    await placeHead('필기 화면', 8);
    expect(selected(), '필기 화면');
    // bottom: the last header cannot reach the top, the last group is chosen
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    expect(headDy('고급'), greaterThan(12), reason: 'the end is the case');
    expect(selected(), '고급');
    // top
    position.jumpTo(0);
    await tester.pump();
    expect(selected(), '일반');
  });

  testWidgets(
    'the top bar puts the arrow at 14, the title at 44, search 29 high',
    (tester) async {
      tall(tester);
      publishAll();
      await openPage(tester);
      final arrow = find.descendant(
        of: key('settings-back'),
        matching: find.byType(KitIcon),
      );
      expect(tester.getTopLeft(arrow).dx, closeTo(14, 0.5));
      expect(tester.getSize(arrow).width, 20);
      expect(tester.getTopLeft(find.text('설정')).dx, closeTo(44, 0.5));
      final tap = tester.getSize(key('settings-back'));
      expect(tap.width, greaterThanOrEqualTo(44));
      expect(tap.height, greaterThanOrEqualTo(44));
      expect(
        tester.getSize(key('settings-search-box')).height,
        closeTo(29.1, 0.5),
      );
    },
  );

  testWidgets('row heights are 38, 52 and 41.8', (tester) async {
    tall(tester);
    publishAll();
    await openPage(tester);
    double h(String k) => tester.getSize(key('settings-row-$k')).height;
    // switch and action rows without a note
    expect(h(stows.editorToolbarShowInFullscreen.key), closeTo(38, 0.5));
    expect(h(AppActionIds.backup), closeTo(38, 0.5));
    // with a note
    expect(h(stows.hyperlegibleFont.key), closeTo(52, 0.5));
    expect(h(AppActionIds.restore), closeTo(52, 0.5));
    // a value chip row
    expect(h(stows.recentColorsLength.key), closeTo(41.8, 0.5));
    expect(h(stows.appTheme.key), closeTo(41.8, 0.5));
  });

  testWidgets('action rows hide when the action is missing', (tester) async {
    tall(tester);
    publishFive(); // no mcp, no viewLogs, no openDataDir
    await openPage(tester);
    for (final k in const [
      'settings-local-vaults',
      'settings-backup',
      'settings-obsidian',
      'settings-restore',
      'settings-open-link',
    ]) {
      expect(key(k), findsOneWidget, reason: k);
    }
    expect(key('settings-mcp'), findsNothing);
    expect(find.text('기록 보기'), findsNothing);
    expect(find.text('데이터 폴더 열기'), findsNothing);
    // 나중에 동작이 생기면 줄이 나타난다.
    acts.publish(owner, [
      fake(AppActionIds.localVaults),
      fake(AppActionIds.backup),
      fake(AppActionIds.vaultExport),
      fake(AppActionIds.restore),
      fake(AppActionIds.openNoteLink),
      fake(AppActionIds.mcp),
    ]);
    await tester.pump();
    await tester.pump();
    expect(key('settings-mcp'), findsOneWidget);
  });

  testWidgets('a disabled action row cannot be pressed', (tester) async {
    tall(tester);
    acts.publish(owner, [
      AppAction(
        id: AppActionIds.backup,
        label: '백업',
        icon: KitIconName.check,
        enabled: false,
        run: (_) => calls.runs.add('backup'),
      ),
    ]);
    await openPage(tester);
    await tester.tap(key('settings-backup'));
    await tester.pumpAndSettle();
    expect(calls.runs, isEmpty);
    expect(find.byType(AppSettingsPage), findsOneWidget);
  });

  testWidgets('an action row closes the page and then runs', (tester) async {
    tall(tester);
    publishFive();
    await openPage(tester);
    expect(find.byType(AppSettingsPage), findsOneWidget);
    await tester.tap(key('settings-backup'));
    expect(calls.runs, isEmpty, reason: 'not before the next frame');
    await tester.pump();
    expect(calls.runs, ['backup']);
    expect(calls.mounted, [true]);
    expect(calls.hasNavigator, [true], reason: 'showDialog needs a Navigator');
    expect(calls.routeActive, [false], reason: 'the page was closed first');
    await tester.pumpAndSettle();
    expect(find.byType(AppSettingsPage), findsNothing);
    expect(calls.runs, ['backup']);
  });

  testWidgets('a value chip opens a menu and picking writes the stow', (
    tester,
  ) async {
    tall(tester);
    final before = stows.shapeRecognitionDelay.value;
    addTearDown(() => stows.shapeRecognitionDelay.value = before);
    stows.shapeRecognitionDelay.value = 500;
    publishAll();
    await openPage(tester);
    final chip = key('settings-chip-${stows.shapeRecognitionDelay.key}');
    expect(
      find.descendant(of: chip, matching: find.text('0.5초')),
      findsOneWidget,
    );
    // 칩의 화살표는 16
    expect(
      find.descendant(
        of: chip,
        matching: find.byWidgetPredicate(
          (w) =>
              w is KitIcon &&
              w.size == KitTokens.settingsChipIconSize &&
              w.strokeWidth == KitTokens.settingsIconStroke,
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('1초'), findsNothing);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(find.text('1초'), findsOneWidget);
    expect(find.text('끄기'), findsOneWidget);
    await tester.tap(find.text('1초'));
    await tester.pumpAndSettle();
    expect(stows.shapeRecognitionDelay.value, 1000);
    // 바로 효과가 난다 (새로 고침 없음)
    expect(ShapePen.debounceDuration, const Duration(seconds: 1));
    expect(find.text('끄기'), findsNothing, reason: 'the menu closed');
    expect(
      find.descendant(of: chip, matching: find.text('1초')),
      findsOneWidget,
    );
    await tester.tap(chip);
    await tester.pumpAndSettle();
    await tester.tap(find.text('끄기'));
    await tester.pumpAndSettle();
    expect(ShapePen.debounceDuration, const Duration(hours: 1));
  });

  testWidgets('a choice of five also uses the chip and a menu', (tester) async {
    tall(tester);
    final value = ValueNotifier<int>(2);
    final test = SettingsRegistry(reasons: ValueNotifier(<String, String>{}));
    addTearDown(test.dispose);
    test.register(
      ChoiceSetting<int>(
        key: 'many',
        label: '많은 고르기',
        group: '시험',
        widgetKey: const ValueKey('row-many'),
        notifier: value,
        options: [for (var i = 1; i <= 5; i++) (i, '$i번')],
      ),
    );
    await openPage(tester, registry: test);
    expect(
      find.descendant(of: key('settings-chip-many'), matching: find.text('2번')),
      findsOneWidget,
    );
    await tester.tap(key('settings-chip-many'));
    await tester.pumpAndSettle();
    expect(find.text('5번'), findsOneWidget);
    await tester.tap(find.text('5번'));
    await tester.pumpAndSettle();
    expect(value.value, 5);
  });

  testWidgets(
    'the page slides in with the slow step and skips it without animations',
    (tester) async {
      publishFive();
      await openPage(tester);
      final route = calls.route! as PageRoute<void>;
      expect(route.transitionDuration, KitMotion.open(KitMotionStep.slow));
      expect(
        route.reverseTransitionDuration,
        KitMotion.close(KitMotionStep.slow),
      );
      // 가운데쯤에서는 아직 오른쪽에서 들어오는 중이다.
      await tester.pumpWidget(const SizedBox());
      final slow = appSettingsRoute(actions: acts, registry: reg);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => Navigator.of(context).push(slow),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(key('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final left = tester.getTopLeft(find.byType(AppSettingsPage)).dx;
      expect(left, greaterThan(0));
      expect(left, lessThan(800));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byType(AppSettingsPage)).dx, 0);
    },
  );

  testWidgets('without animations the page has no slide', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    publishFive();
    final route = appSettingsRoute(actions: acts, registry: reg);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open'),
            onPressed: () => Navigator.of(context).push(route),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(key('open'));
    await tester.pump();
    expect((route as PageRoute<void>).transitionDuration, Duration.zero);
    expect(route.reverseTransitionDuration, Duration.zero);
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.getTopLeft(find.byType(AppSettingsPage)).dx, 0);
  });

  group('in the workspace', () {
    late Directory directory;
    late WorkspaceController controller;
    var closed = false;
    Future<void>? closing;

    setUp(() async {
      registerSettingsEntries(settingsRegistry);
      await FileManager.init(shouldWatchRootDirectory: false);
      directory = await Directory.systemTemp.createTemp('app-settings-ui-');
      closed = false;
      closing = null;
      controller = WorkspaceController(
        await NoteRepository.open(
          Directory('${directory.path}/vault'),
          createFormatVersion: 2,
        ),
        directoryProvider: () async => Directory('${directory.path}/support'),
      );
      await controller.refresh();
    });

    Future<void> closeOwned() async {
      if (closed) return;
      controller.dispose();
      await controller.repository.close().timeout(const Duration(seconds: 20));
      await directory
          .delete(recursive: true)
          .timeout(const Duration(seconds: 20));
      closed = true;
    }

    Future<void> close() => closing ??= closeOwned();

    Future<void> wait(WidgetTester tester, bool Function() done) async {
      final elapsed = Stopwatch()..start();
      while (!done()) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (elapsed.elapsed > const Duration(seconds: 20)) {
          fail('The library did not appear');
        }
      }
    }

    testWidgets('library settings opens the full screen page', (tester) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: StudyWorkspace(controller: controller)),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        var done = false;
        await tester.runAsync(() async {
          await close();
          done = true;
        });
        expect(done, isTrue);
      });
      await wait(tester, () => key('library-settings').evaluate().isNotEmpty);
      expect(find.byType(AppSettingsPage), findsNothing);
      await tester.tap(key('library-settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AppSettingsPage), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      // 작업 공간이 낸 앱 범위 동작이 줄로 보인다 (MCP 연결도 있다).
      for (final k in const [
        'settings-local-vaults',
        'settings-backup',
        'settings-restore',
        'settings-open-link',
        'settings-mcp',
      ]) {
        expect(key(k), findsOneWidget, reason: k);
      }
    });
  });

  // Final review A-5: the row icons are a fixed table now, apart from the
  // rows; every value row still has its own.
  test('every value row has its own icon', () {
    final valueRows = reg.entries.where((e) => e is! ActionSetting).toList();
    expect(valueRows, hasLength(19));
    for (final row in valueRows) {
      expect(settingsRowIcon(row.key), isNot(KitIconName.tune), reason: row.key);
    }
    expect(settingsRowIcon(stows.lastZoomLock.key), KitIconName.zoom);
    expect(settingsRowIcon('not-a-setting'), KitIconName.tune);
  });

  test('the shape preview delay reaches the shape pen at once', () {
    final delay = stows.shapeRecognitionDelay.value;
    addTearDown(() => stows.shapeRecognitionDelay.value = delay);
    stows.shapeRecognitionDelay.value = -1;
    // The shape pen picks it up at once, not after a restart.
    expect(ShapePen.debounceDuration, const Duration(hours: 1));
    stows.shapeRecognitionDelay.value = 500;
    expect(ShapePen.debounceDuration, const Duration(milliseconds: 500));
  });
}
