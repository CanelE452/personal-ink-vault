import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_toolbar.dart';
import 'package:saber/components/toolbar/note_function_row.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/data/actions/app_action.dart';

import 'utils/kit_menu_finders.dart';

/// The function row of the documents that are not the ink editor (Task 17,
/// design 「다른 문서와 무한 노트」): StarNote's items (back, the shortcut
/// bar's left and right parts, each scrolling, the fixed shortcuts, ⋯
/// "더 많은 기능") in the kit toolbar's look. The shortcuts are the open
/// document's actions; ⋯ is a kit window.
void main() {
  final log = <String>[];
  final contexts = <BuildContext>[];
  setUp(() {
    log.clear();
    contexts.clear();
  });

  AppAction action(String id, String label, {bool enabled = true}) =>
      AppAction(
        id: id,
        label: label,
        icon: KitIconName.share,
        enabled: enabled,
        widgetKey: ValueKey('sc-$id'),
        run: (context) {
          log.add(id);
          contexts.add(context);
        },
      );

  List<AppAction> shortcuts({Set<String> without = const {}}) => [
    for (final item in noteShortcutItems)
      if (!without.contains(item.id)) action(item.id, item.label),
  ];

  final fixed = [
    AppAction(
      id: 'pageList',
      label: '문서 개요',
      icon: KitIconName.sidebar,
      widgetKey: const ValueKey('note-overview'),
      run: (_) => log.add('overview'),
    ),
  ];

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    Set<String> without = const {},
    List<String> stored = const [],
    List<AppAction>? actions,
    List<NoteSwitch> switches = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                NoteFunctionRow(
                  back: KitToolbarButton(
                    key: const ValueKey('back'),
                    icon: KitIconName.back,
                    tooltip: '문서 목록으로',
                    onPressed: () => log.add('back'),
                  ),
                  shortcuts: actions ?? shortcuts(without: without),
                  fixed: fixed,
                  layout: ShortcutLayout.decode(noteShortcutItems, stored),
                  onCustomize: () => log.add('customize'),
                  switches: switches,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inPart(String part, String key) => find.descendant(
    of: find.byKey(ValueKey(part)),
    matching: find.byKey(ValueKey(key)),
  );

  final more = find.byKey(const ValueKey('workspace-more-actions'));

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(more);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the bar shows left and right shortcuts, fixed items at the end and the rest under 더 많은 기능',
    (tester) async {
      await mount(tester);
      final row = find.byKey(const ValueKey('note-function-row'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(KitToolbar)),
        findsOneWidget,
      );
      expect(tester.getSize(row).height, KitTokens.toolbarHeight);
      expect(inPart('note-function-left', 'sc-insertPage'), findsOneWidget);
      expect(inPart('note-function-left', 'sc-prev'), findsOneWidget);
      expect(inPart('note-function-right', 'sc-viewToggle'), findsOneWidget);
      // the fixed one sits after the right part's scroll, so it never
      // scrolls away
      expect(inPart('note-function-row', 'note-overview'), findsOneWidget);
      expect(inPart('note-function-right', 'note-overview'), findsNothing);
      expect(
        tester.getCenter(find.byKey(const ValueKey('note-overview'))).dx,
        greaterThan(
          tester.getCenter(find.byKey(const ValueKey('sc-fullscreen'))).dx,
        ),
      );
      expect(find.byKey(const ValueKey('sc-export')), findsNothing);
      // kit buttons: the action's icon at the tool bar's size
      final button = tester.widget<KitToolbarButton>(
        find.byKey(const ValueKey('sc-prev')),
      );
      expect(button.icon, KitIconName.share);
      expect(button.tooltip, '이전 위치');

      await openMore(tester);
      expect(find.byType(KitMenu), findsOneWidget);
      expect(findMenuText('사용자 지정 바로가기 막대'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sc-export')));
      await tester.pumpAndSettle();
      expect(log, ['export']);
      expect(find.byType(KitMenu), findsNothing, reason: 'closed first');

      await tester.tap(find.byKey(const ValueKey('sc-insertPage')));
      await tester.tap(find.byKey(const ValueKey('note-overview')));
      await tester.tap(find.byKey(const ValueKey('back')));
      expect(log, ['export', 'insertPage', 'overview', 'back']);
    },
  );

  testWidgets('a shortcut missing from this document is not shown anywhere', (
    tester,
  ) async {
    await mount(tester, without: {'pdfSearch', 'pdfRemake'});
    expect(find.byKey(const ValueKey('sc-pdfSearch')), findsNothing);
    await openMore(tester);
    expect(find.text('PDF 본문 검색'), findsNothing);
    expect(find.byKey(const ValueKey('sc-pdfRemake')), findsNothing);
  });

  testWidgets('a shortcut that is off is dimmed and takes no tap', (
    tester,
  ) async {
    await mount(
      tester,
      actions: [
        action('prev', '이전 위치', enabled: false),
        action('quickSwitch', '빠른 문서 전환', enabled: false),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('sc-prev')));
    await openMore(tester);
    await tester.tap(find.byKey(const ValueKey('sc-quickSwitch')));
    await tester.pumpAndSettle();
    expect(log, isEmpty);
  });

  testWidgets('at phone width the row does not overflow', (tester) async {
    await mount(tester, size: const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(more, findsOneWidget);
    expect(tester.getRect(more).right, lessThanOrEqualTo(360));
  });

  testWidgets('at phone width 문서 개요 and ⋯ stay in view at the right end', (
    tester,
  ) async {
    await mount(tester, size: const Size(360, 640));
    for (final key in const ['note-overview', 'workspace-more-actions']) {
      final button = find.byKey(ValueKey(key));
      expect(button.hitTestable(), findsOneWidget, reason: key);
      expect(tester.getRect(button).right, lessThanOrEqualTo(360));
    }
    await tester.tap(find.byKey(const ValueKey('note-overview')));
    expect(log, ['overview']);
  });

  testWidgets('a shortcut runs with the context of the control that called it', (
    tester,
  ) async {
    Rect rectOf(BuildContext context) {
      final box = context.findRenderObject()! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    }

    // on the bar: the button's own
    await mount(tester, stored: const ['L:quickSwitch']);
    await tester.tap(find.byKey(const ValueKey('sc-quickSwitch')));
    expect(log, ['quickSwitch']);
    expect(
      rectOf(contexts.single),
      tester.getRect(find.byKey(const ValueKey('sc-quickSwitch'))),
    );

    // from 더 많은 기능: ⋯'s, in the frame the window closes
    log.clear();
    contexts.clear();
    await mount(tester);
    await openMore(tester);
    await tester.tap(find.byKey(const ValueKey('sc-quickSwitch')));
    expect(log, ['quickSwitch']);
    expect(rectOf(contexts.single), tester.getRect(more));
    await tester.pumpAndSettle();
    expect(find.byType(KitMenu), findsNothing);
  });

  testWidgets('⋯ is a kit window under the button, inside the screen', (
    tester,
  ) async {
    await mount(tester, size: const Size(360, 640));
    await openMore(tester);
    final window = tester.getRect(find.byType(KitMenu));
    expect(window.width, NoteFunctionRow.moreWidth);
    expect(
      window.top,
      tester.getRect(find.byKey(const ValueKey('note-function-row'))).bottom +
          KitTokens.toolWindowGapToolbar,
    );
    expect(window.right, lessThanOrEqualTo(360));
    expect(window.bottom, lessThanOrEqualTo(640));
  });

  // Task 18 re-review: the switch shows what its owner holds now; the
  // action's `checked` is a copy published before the tap.
  testWidgets('a ⋯ switch shows its live value, not the published checked', (
    tester,
  ) async {
    var on = false;
    final finger = AppAction(
      id: 'finger',
      label: '손가락 필기',
      icon: KitIconName.tap,
      checked: false, // published once, never again
      widgetKey: const ValueKey('note-more-finger'),
      run: (_) => on = !on,
    );
    await mount(tester, switches: [(action: finger, on: () => on)]);
    await openMore(tester);
    bool shown() => tester
        .widget<KitSwitch>(
          find.descendant(
            of: find.byKey(const ValueKey('note-more-finger')),
            matching: find.byType(KitSwitch),
          ),
        )
        .value;
    expect(shown(), isFalse);
    for (final expected in [true, false, true]) {
      await tester.tap(find.byKey(const ValueKey('note-more-finger')));
      await tester.pumpAndSettle();
      expect(on, expected);
      expect(shown(), expected, reason: 'the window stays open and follows');
    }
  });

  testWidgets('더 많은 기능 opens the shortcut bar editor', (tester) async {
    await mount(tester);
    await openMore(tester);
    await tester.tap(find.byKey(const ValueKey('shortcut-bar-customize')));
    await tester.pumpAndSettle();
    expect(log, ['customize']);
    expect(find.byType(KitMenu), findsNothing);
  });
}
