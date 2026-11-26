import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/editor_chrome.dart';

import '../utils/screen_capture.dart';
import '../utils/test_mock_channel_handlers.dart';

/// Writes screenshots of the ⋯ document menu (Task 14) to
/// build/screen-review/t14/app-t14-*.png with the app's fonts at device
/// pixel ratio 2, beside the preview's 7th draft ⋯ menu (ref-t14-*.png,
/// build/t14/ref/make_refs.py) and the 9th draft c ⋯ window
/// (t13b/ref-v9c-doc*.png). Runs only with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t14');
const _latin = captureLatin;
const _korean = captureKorean;

/// What the editor and the workspace offer for a PDF note in stage 1, named
/// as they name them.
void _publish(AppActionRegistry actions, {bool locked = false}) {
  AppAction a(
    String id,
    String label,
    KitIconName icon, {
    bool? checked,
    bool enabled = true,
  }) => AppAction(
    id: id,
    label: label,
    icon: icon,
    checked: checked,
    enabled: enabled,
    run: (_) {},
  );
  actions.publish(Object(), [
    a(AppActionIds.pageList, '문서 개요', KitIconName.sidebar),
    a(AppActionIds.toolLasso, '올가미', KitIconName.lassoFree, checked: false),
    a(AppActionIds.toolPen, '펜', KitIconName.pen, checked: true),
    a(AppActionIds.toolEraser, '지우개', KitIconName.eraser, checked: false),
    a(AppActionIds.toolText, '글상자', KitIconName.text, checked: false),
    a(AppActionIds.toolShapes, '도형', KitIconName.shapes, checked: false),
    a(AppActionIds.pickPhoto, '사진', KitIconName.image),
    a(AppActionIds.insertPage, '페이지 추가', KitIconName.pageAdd),
    a(AppActionIds.fullscreen, '전체 화면', KitIconName.expand, checked: false),
    a(AppActionIds.pageMode, '한 쪽씩 보기', KitIconName.scrollDir, checked: false),
    a(AppActionIds.docInfo, '문서 정보', KitIconName.info),
    a(AppActionIds.rename, '이름 바꾸기', KitIconName.rename),
    a(AppActionIds.pdfSearch, 'PDF 본문 검색', KitIconName.search),
    a(AppActionIds.readOnly, '읽기 전용', KitIconName.readonly, checked: locked),
    a(AppActionIds.viewToggle, 'Markdown', KitIconName.textTt),
    a(AppActionIds.tabBarHide, '탭 줄 숨기기', KitIconName.noteTab, checked: false),
    a(AppActionIds.pageDuplicate, '쪽 복제', KitIconName.dup),
    a(AppActionIds.templateChange, '템플릿 바꾸기', KitIconName.template),
    a(AppActionIds.goToPage, '쪽으로 이동', KitIconName.gotoPage),
    a(AppActionIds.clearPage, '쪽 지우기', KitIconName.delPage),
    a(AppActionIds.moveToTrash, '휴지통으로', KitIconName.trash),
    a(AppActionIds.toolbarCustomize, '도구 막대 사용자화', KitIconName.tune),
    a(AppActionIds.openSettings, '설정', KitIconName.settings),
    a(AppActionIds.saveNow, '지금 저장', KitIconName.saved, enabled: false),
    a(AppActionIds.export, '파일 내보내기', KitIconName.share),
    a(AppActionIds.pdfRemake, '새 엔진으로 PDF 다시 만들기', KitIconName.refresh),
    a(AppActionIds.quickSwitch, '빠른 문서 전환', KitIconName.search),
    a(AppActionIds.bookmarks, '북마크', KitIconName.bookmark),
    a(AppActionIds.knowledge, '문서 연결 · 태그 · 그래프', KitIconName.link),
    a(AppActionIds.mcp, '다른 AI 연결 · MCP', KitIconName.ai),
    a(AppActionIds.copyPageLink, '현재 페이지 링크 복사', KitIconName.copy),
    a(AppActionIds.openNoteLink, '노트 링크 열기', KitIconName.link),
    a(AppActionIds.vaultExport, 'Obsidian 보관함 ZIP', KitIconName.share),
    a(AppActionIds.linkAdd, '링크 추가', KitIconName.link),
  ]);
}

Future<void> _write(WidgetTester tester, GlobalKey boundary, String name) async {
  debugDisableShadows = false;
  try {
    void mark(RenderObject o) {
      o.markNeedsPaint();
      o.visitChildren(mark);
    }

    mark(boundary.currentContext!.findRenderObject()!);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final object =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await object.toImage(pixelRatio: 2);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/app-t14-$name.png')
          .writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

void main() {
  FlavorConfig.setup();

  /// The 9th draft c bar (inner width 586, or a 360 phone) over a page
  /// area [page] high, ⋯ open, then [then].
  Future<void> shoot(
    WidgetTester tester,
    String name, {
    double width = 586,
    double page = 1500,
    bool locked = false,
    Future<void> Function()? then,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    final size = Size(width, 46 + page);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    stows.lastZoomLock.value = false;
    final actions = AppActionRegistry();
    final open = ValueNotifier(false);
    final sheet = ValueNotifier(false);
    addTearDown(() {
      actions.dispose();
      open.dispose();
      sheet.dispose();
    });
    _publish(actions, locked: locked);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: _latin,
            fontFamilyFallback: const [_korean],
          ),
          home: Material(
            color: const Color(0xfffbf8ef),
            child: Column(
              children: [
                KitEditorToolbar(
                  actions: actions,
                  title: '강의노트 3주차',
                  floatingBarOpen: open,
                  noteSheetOpen: sheet,
                  pages: () => (index: 1, count: 5),
                  zoom: DocZoom(scale: () => 1, zoomTo: (_) {}),
                ),
                const Expanded(child: SizedBox.expand()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    await then?.call();
    await tester.pumpAndSettle();
    await _write(tester, boundary, name);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('doc menu captures', skip: !_capture, () {
    testWidgets('doc', (tester) => shoot(tester, 'doc'));
    testWidgets(
      'readonly',
      (tester) => shoot(tester, 'readonly', page: 734, locked: true),
    );
    testWidgets(
      'zoom',
      (tester) => shoot(
        tester,
        'zoom',
        then: () => tap(tester, find.text('확대 비율')),
      ),
    );
    testWidgets(
      'layout',
      (tester) => shoot(
        tester,
        'layout',
        page: 734,
        then: () => tap(tester, find.text('쪽 배치')),
      ),
    );
    testWidgets(
      'phone',
      (tester) => shoot(tester, 'phone', width: 360, page: 594),
    );
    testWidgets(
      'phone-scrolled',
      (tester) => shoot(
        tester,
        'phone-scrolled',
        width: 360,
        page: 594,
        then: () async {
          await tester.drag(find.text('문서 정보'), const Offset(0, -600));
          await tester.pumpAndSettle();
        },
      ),
    );

    // 문서 정보 is the editor's own window: a real editor in a host that
    // gives the file's time and the Drive state
    testWidgets('info', (tester) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      setupMockPathProvider();
      setupMockPrinting();
      setupMockWindowManager();
      await FileManager.init();
      await tester.runAsync(loadCaptureFonts);
      const size = Size(586, 46 + 734);
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chrome = EditorChromeController()
        ..docInfo = () => DocInfo(
          lastEdited: DateTime.now().subtract(const Duration(minutes: 43)),
          syncLabel: '동기화됨',
          synced: true,
          offlineLabel: '준비됨',
        );
      addTearDown(chrome.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: TranslationProvider(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: const [
                FlutterQuillLocalizations.delegate,
              ],
              theme: ThemeData(
                fontFamily: _latin,
                fontFamilyFallback: const [_korean],
              ),
              home: Editor(
                path: '/강의노트 3주차',
                customTitle: '강의노트 3주차',
                showDocumentHeader: false,
                chrome: chrome,
                onSaveSnapshot: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('문서 정보'));
      await tester.pumpAndSettle();
      await _write(tester, boundary, 'info');
    });
  });
}
