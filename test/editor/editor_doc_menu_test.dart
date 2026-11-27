import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations, QuillEditor;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/extensions/matrix4_extensions.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:saber/pages/settings/app_settings_page.dart';
import 'package:saber/pages/settings/settings_entries.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The ⋯ document menu's rows the editor runs itself (Task 14): 읽기 전용,
/// 확대 비율, the page rows, 지금 저장 and 문서 정보.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
    final saved = (
      stows.lastTool.value,
      stows.lastPenFamily.value,
      stows.editorToolbarTools.value,
      stows.pageToolbarLayout.value,
      stows.lastZoomLock.value,
      stows.editorFingerDrawing.value,
      stows.lastSinglePageMode.value,
    );
    stows.lastTool.value = ToolId.fountainPen;
    stows.lastPenFamily.value = ToolId.fountainPen;
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    stows.lastZoomLock.value = false;
    stows.editorFingerDrawing.value = false;
    stows.lastSinglePageMode.value = false;
    addTearDown(() {
      stows.lastTool.value = saved.$1;
      stows.lastPenFamily.value = saved.$2;
      stows.editorToolbarTools.value = saved.$3;
      stows.pageToolbarLayout.value = saved.$4;
      stows.lastZoomLock.value = saved.$5;
      stows.editorFingerDrawing.value = saved.$6;
      stows.lastSinglePageMode.value = saved.$7;
      stows.editorGestureMode.value = false;
    });
  });

  // each editor its own path: the canvas keeps the last zoom and scroll
  // of a path for the next editor of that path
  var opened = 0;

  Future<EditorState> mountEditor(
    WidgetTester tester, {
    Size size = const Size(1000, 1400),
    EditorChromeController? chrome,
    Future<void> Function()? onSave,
  }) async {
    final path = '/editor-doc-menu-${opened++}';
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              key: ValueKey(path),
              path: path,
              chrome: chrome,
              onSaveSnapshot: (_, _) async => await onSave?.call(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  int strokes(EditorState editor) =>
      editor.coreInfo.pages.expand((page) => page.strokes).length;

  Rect pageOnScreen(WidgetTester tester, EditorState editor) {
    final page = editor.coreInfo.pages.first;
    final box = page.renderBox!;
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(page.size.bottomRight(Offset.zero)),
    ).intersect(tester.getRect(find.byType(InteractiveCanvasViewer)));
  }

  Future<void> drawStroke(WidgetTester tester, EditorState editor) async {
    final center = pageOnScreen(tester, editor).center;
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(center - const Offset(30, 5));
    await pen.moveTo(center);
    await pen.moveTo(center + const Offset(30, 5));
    await pen.up();
    await tester.pump();
  }

  /// Two fingers from the page's middle, each moved by [first] and
  /// [second] in a few steps.
  Future<void> twoFingers(
    WidgetTester tester,
    EditorState editor, {
    required Offset first,
    required Offset second,
  }) async {
    final center = pageOnScreen(tester, editor).center;
    final a = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 11,
    );
    final b = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 12,
    );
    var at = (center - const Offset(40, 0), center + const Offset(40, 0));
    await a.down(at.$1);
    await b.down(at.$2);
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      at = (at.$1 + first / 6, at.$2 + second / 6);
      await a.moveTo(at.$1);
      await b.moveTo(at.$2);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
  }

  Matrix4 view(WidgetTester tester) => tester
      .widget<InteractiveCanvasViewer>(find.byType(InteractiveCanvasViewer))
      .transformationController!
      .value;

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
  }

  Future<void> menuRow(WidgetTester tester, String text) async {
    await openMenu(tester);
    // the menu's row: the mode pill under it may say the same
    final row = find.text(text).last;
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  testWidgets('read-only blocks ink but not scrolling', (tester) async {
    final editor = await mountEditor(tester);
    expect(editor.inkLocked.value, isFalse);
    await menuRow(tester, '읽기 전용');
    expect(editor.inkLocked.value, isTrue);
    expect(
      editor.actions.lookup(AppActionIds.readOnly)?.checked,
      isTrue,
      reason: 'the quick button shows it is on',
    );

    // a pen drawing on the locked page leaves no stroke
    await drawStroke(tester, editor);
    expect(strokes(editor), 0);

    // two fingers still move the page
    final before = view(tester).getTranslation();
    await twoFingers(
      tester,
      editor,
      first: const Offset(0, -120),
      second: const Offset(0, -120),
    );
    expect(
      view(tester).getTranslation().y,
      lessThan(before.y - 50),
      reason: 'the page moved up',
    );
    // and two fingers spreading still zoom (final review B-7)
    final scale = view(tester).approxScale;
    await twoFingers(
      tester,
      editor,
      first: const Offset(-80, 0),
      second: const Offset(80, 0),
    );
    expect(
      view(tester).approxScale,
      greaterThan(scale * 1.2),
      reason: 'the page zoomed in',
    );

    // off again: the pen writes
    await menuRow(tester, '읽기 전용');
    expect(editor.inkLocked.value, isFalse);
    await drawStroke(tester, editor);
    expect(strokes(editor), 1);
    editor.cancelAutosaveAndMarkSaved();

    // not kept: the note opened again is not locked
    await menuRow(tester, '읽기 전용');
    expect(editor.inkLocked.value, isTrue);
    final again = await mountEditor(tester);
    expect(again.inkLocked.value, isFalse);
  });

  testWidgets('the zoom lock can be turned off from ⋯ 확대 비율', (
    tester,
  ) async {
    stows.lastZoomLock.value = true;
    await mountEditor(tester);
    await menuRow(tester, '확대 비율');
    await tester.tap(find.byKey(const ValueKey('editor-doc-zoom-lock')));
    await tester.pumpAndSettle();
    expect(stows.lastZoomLock.value, isFalse);
  });

  testWidgets('확대 비율 sets the scale; the lock stops two-finger zoom', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    expect(view(tester).approxScale, moreOrLessEquals(1, epsilon: .01));
    await menuRow(tester, '확대 비율');
    await tester.tap(find.byKey(const ValueKey('editor-doc-zoom-2.0')));
    await tester.pumpAndSettle();
    expect(view(tester).approxScale, moreOrLessEquals(2, epsilon: .01));

    // the menu reads the scale when it opens
    await menuRow(tester, '확대 비율');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-doc-zoom')),
        matching: find.text('200%'),
      ),
      findsOneWidget,
    );
    // locked, two fingers spreading do not zoom
    await tester.tap(find.byKey(const ValueKey('editor-doc-zoom-lock')));
    await tester.pumpAndSettle();
    expect(stows.lastZoomLock.value, isTrue);
    // out of the submenu, then out of the menu
    await tester.tapAt(const Offset(5, 1300));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 1300));
    await tester.pumpAndSettle();
    expect(find.text('확대 비율'), findsNothing);
    await twoFingers(
      tester,
      editor,
      first: const Offset(-80, 0),
      second: const Offset(80, 0),
    );
    expect(view(tester).approxScale, moreOrLessEquals(2, epsilon: .01));

    // while locked the menu still chooses, and the lock holds the new one
    await menuRow(tester, '확대 비율');
    await tester.tap(find.byKey(const ValueKey('editor-doc-zoom-1.0')));
    await tester.pumpAndSettle();
    expect(view(tester).approxScale, moreOrLessEquals(1, epsilon: .01));
    await twoFingers(
      tester,
      editor,
      first: const Offset(-80, 0),
      second: const Offset(80, 0),
    );
    expect(view(tester).approxScale, moreOrLessEquals(1, epsilon: .01));

    // unlocked, the same fingers zoom
    stows.lastZoomLock.value = false;
    await tester.pumpAndSettle();
    await twoFingers(
      tester,
      editor,
      first: const Offset(-80, 0),
      second: const Offset(80, 0),
    );
    expect(view(tester).approxScale, greaterThan(1.2));
  });

  testWidgets('쪽 복제, 쪽으로 이동 and 템플릿 바꾸기 act on the page', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await drawStroke(tester, editor);
    final pages = editor.coreInfo.pages.length;
    await menuRow(tester, '쪽 복제');
    expect(editor.coreInfo.pages.length, pages + 1);
    expect(editor.coreInfo.pages[1].strokes, hasLength(1), reason: 'a copy');

    editor.createPage(3);
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    await openMenu(tester);
    expect(
      find.text('1 / ${editor.coreInfo.pages.length}'),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(5, 1300));
    await tester.pumpAndSettle();
    await menuRow(tester, '쪽으로 이동');
    await tester.enterText(find.byKey(const ValueKey('go-to-page-field')), '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(editor.currentPageIndex, 2);

    await menuRow(tester, '템플릿 바꾸기');
    expect(find.byType(BottomSheet), findsOneWidget);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('지금 저장 saves at once and is dimmed once saved', (
    tester,
  ) async {
    var saves = 0;
    final editor = await mountEditor(tester, onSave: () async => saves++);
    editor.cancelAutosaveAndMarkSaved();
    await tester.pump();
    await tester.pump();
    expect(editor.actions.lookup(AppActionIds.saveNow)?.enabled, isFalse);
    await drawStroke(tester, editor);
    await tester.pump();
    await tester.pump();
    expect(editor.actions.lookup(AppActionIds.saveNow)?.enabled, isTrue);
    await menuRow(tester, '지금 저장');
    await tester.pump();
    expect(saves, 1);
    await tester.pump();
    await tester.pump();
    expect(editor.actions.lookup(AppActionIds.saveNow)?.enabled, isFalse);
  });

  testWidgets('문서 정보 shows the last edit, the sync and offline rows', (
    tester,
  ) async {
    // alone: the editor's own values
    final editor = await mountEditor(tester);
    await drawStroke(tester, editor);
    editor.cancelAutosaveAndMarkSaved();
    await menuRow(tester, '문서 정보');
    for (final text in [
      '마지막 편집',
      '방금 전',
      '동기화',
      // an editor alone does not know the Drive
      '알 수 없음',
      '오프라인용 저장',
      '준비됨',
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    // in a host: the host's file time and Drive state
    final chrome = EditorChromeController()
      ..docInfo = () => DocInfo(
        lastEdited: DateTime.now().subtract(const Duration(minutes: 43)),
        syncLabel: '동기화됨',
        synced: true,
        offlineLabel: '준비됨',
      );
    addTearDown(chrome.dispose);
    await mountEditor(tester, chrome: chrome);
    await menuRow(tester, '문서 정보');
    expect(find.text('43분 전'), findsOneWidget);
    // synced reads green (preview `.ksub` #1d8a52); 닫기 is the kit blue
    expect(
      tester.widget<Text>(find.text('동기화됨')).style?.color,
      KitTokens.ok,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '닫기'))
          .style
          ?.foregroundColor
          ?.resolve({}),
      KitTokens.accent,
    );
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    // nothing known about the last edit: said so
    final unknown = EditorChromeController()
      ..docInfo = () =>
          const DocInfo(syncLabel: '연결 안 됨', offlineLabel: '준비됨');
    addTearDown(unknown.dispose);
    await mountEditor(tester, chrome: unknown);
    await menuRow(tester, '문서 정보');
    expect(find.text('알 수 없음'), findsOneWidget);
    expect(find.text('연 뒤 고친 것 없음'), findsNothing);
  });

  testWidgets('the 기타 설정 panel is gone; its rows live in ⋯', (tester) async {
    final editor = await mountEditor(tester);
    expect(find.byKey(const ValueKey('note-other-settings')), findsNothing);
    expect(find.byType(Drawer), findsNothing);
    for (final id in [
      AppActionIds.readOnly,
      AppActionIds.pageDuplicate,
      AppActionIds.templateChange,
      AppActionIds.goToPage,
      AppActionIds.clearPage,
      AppActionIds.toolbarCustomize,
      AppActionIds.saveNow,
      AppActionIds.export,
    ]) {
      expect(editor.actions.has(id), isTrue, reason: id);
    }
    // not in stage 1
    expect(editor.actions.has(AppActionIds.pageRotate), isFalse);
  });

  testWidgets('an editor alone opens the full settings page from ⋯', (
    tester,
  ) async {
    // the app's table, as main() fills it; emptied again after
    if (settingsRegistry.entries.isEmpty) {
      registerSettingsEntries(settingsRegistry);
      addTearDown(settingsRegistry.clear);
    }
    await mountEditor(tester);
    await menuRow(tester, '전체 설정 열기');
    expect(find.byType(AppSettingsPage), findsOneWidget);
    // the old 기타 설정's writing settings are rows there
    for (final text in [
      '확대 잠금',
      '한 손가락 이동 잠금',
      '가로·세로로만 이동',
      '직선 자동 보정',
      '펜이 닿으면 손가락 필기 끄기',
      '도형 미리보기',
    ]) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('settings-scroll')),
          matching: find.text(text),
        ),
        findsOneWidget,
        reason: text,
      );
    }
  });

  testWidgets("a host's 설정 wins over the editor's own", (tester) async {
    final ran = <String>[];
    final app = AppActionRegistry();
    addTearDown(app.dispose);
    app.publish(Object(), [
      AppAction(
        id: AppActionIds.openSettings,
        label: '설정',
        icon: KitIconName.settings,
        run: (_) => ran.add('host'),
      ),
    ]);
    final chrome = EditorChromeController(appActions: app);
    addTearDown(chrome.dispose);
    await mountEditor(tester, chrome: chrome);
    await menuRow(tester, '전체 설정 열기');
    expect(ran, ['host']);
    expect(find.byType(AppSettingsPage), findsNothing);
  });

  testWidgets('read-only protects the note: no text box, no editing rows', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await drawStroke(tester, editor);
    // the text box in hand, then locked
    editor.actions.run(
      AppActionIds.toolText,
      tester.element(find.byType(Editor)),
    );
    await tester.pumpAndSettle();
    bool textIgnored() => tester
        .widget<IgnorePointer>(
          find
              .ancestor(
                of: find.byType(QuillEditor).first,
                matching: find.byType(IgnorePointer),
              )
              .first,
        )
        .ignoring;
    expect(textIgnored(), isFalse);
    await menuRow(tester, '읽기 전용');
    expect(textIgnored(), isTrue, reason: 'taps do not reach the text box');
    expect(editor.currentTool, isNot(Tool.textEditing));
    // even with the text tool in hand, the lock keeps taps off the text box
    editor.currentTool = Tool.textEditing;
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    expect(textIgnored(), isTrue);
    editor.currentTool = Pen.currentPen;
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    const changing = [
      AppActionIds.toolText,
      AppActionIds.clearPage,
      AppActionIds.pageDuplicate,
      AppActionIds.templateChange,
      AppActionIds.insertPage,
      AppActionIds.undo,
      AppActionIds.pickPhoto,
      AppActionIds.paste,
      AppActionIds.linkAdd,
    ];
    for (final id in changing) {
      expect(editor.actions.lookup(id)?.enabled, isFalse, reason: id);
    }
    // the menu shows them dimmed
    await openMenu(tester);
    await tester.ensureVisible(find.text('쪽 비우기'));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('editor-doc-clearPage')))
          .flagsCollection
          .isEnabled
          .toBoolOrNull(),
      isFalse,
    );
    await tester.tapAt(const Offset(5, 1300));
    await tester.pumpAndSettle();

    // unlocked, all of them come back
    await menuRow(tester, '읽기 전용');
    for (final id in changing) {
      expect(editor.actions.lookup(id)?.enabled, isTrue, reason: id);
    }
    editor.actions.run(
      AppActionIds.toolText,
      tester.element(find.byType(Editor)),
    );
    await tester.pumpAndSettle();
    expect(textIgnored(), isFalse);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('turning read-only on and off says so in the mode pill', (
    tester,
  ) async {
    await mountEditor(tester);
    final pill = find.byKey(const ValueKey('kit-mode-pill'));
    await menuRow(tester, '읽기 전용');
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(of: pill, matching: find.text('읽기 전용')),
      findsOneWidget,
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
    await menuRow(tester, '읽기 전용');
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.descendant(of: pill, matching: find.text('편집 가능')),
      findsOneWidget,
    );
    await tester.pumpAndSettle(const Duration(seconds: 3));
  });
}
