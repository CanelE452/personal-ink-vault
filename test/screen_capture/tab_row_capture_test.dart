import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/kit_tab_row.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/toolbar/note_function_row.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the tab row and the other documents' function row
/// (Task 17) to build/screen-review/t17/app-t17-*.png with the app's fonts
/// at device pixel ratio 2, beside the 9th draft c tab row
/// (ref-t17-*.png, build/screen-review/t17/ref/make_refs.py): the tab row
/// on the preview's device (586 inside) and on a 360 phone, its ⌄ window, a
/// block page's row, the Markdown view's row, and ⋯ with the rows moved
/// from the old function row. Runs only with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t17');
const _latin = captureLatin;
const _korean = captureKorean;

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
      File('$_outDir/app-t17-$name.png')
          .writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

/// The 9th draft c tabs: 강의노트 3주차 open, 예시 논문, 회의 메모.
const _tabs = [
  KitTab(id: 'a', title: '강의노트 3주차'),
  KitTab(id: 'b', title: '예시 논문'),
  KitTab(id: 'c', title: '회의 메모'),
];

/// What the workspace offers a block page (its row's shortcuts), with the
/// workspace's names and icons; [markdown]: the view switch as the
/// Markdown view of a PDF note shows it.
List<AppAction> _pageActions({bool markdown = false}) {
  AppAction a(String id, String label, KitIconName icon, {Key? key}) =>
      AppAction(id: id, label: label, icon: icon, widgetKey: key, run: (_) {});
  return [
    a(AppActionIds.prev, '이전 위치', KitIconName.back),
    a(AppActionIds.next, '다음 위치', KitIconName.chevR),
    a(AppActionIds.save, '기기에 저장', KitIconName.download),
    if (!markdown)
      a(
        AppActionIds.documentExport,
        '문서 내보내기',
        KitIconName.upload,
        key: const ValueKey('portable-export-menu'),
      ),
    a(
      AppActionIds.viewToggle,
      markdown ? 'PDF·필기' : 'Markdown',
      markdown ? KitIconName.draw : KitIconName.textTt,
      key: const ValueKey('note-view-toggle'),
    ),
    a(AppActionIds.quickSwitch, '빠른 문서 전환', KitIconName.swap),
    a(AppActionIds.bookmarks, '북마크', KitIconName.bookmark),
    a(AppActionIds.copyPageLink, '현재 페이지 링크 복사', KitIconName.copy),
    a(AppActionIds.openNoteLink, '노트 링크 열기', KitIconName.open),
  ];
}

void main() {
  FlavorConfig.setup();

  /// [child] on the preview's page colour, [size] logical px, at ratio 2.
  Future<GlobalKey> mount(WidgetTester tester, Size size, Widget child) async {
    await tester.runAsync(loadCaptureFonts);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MediaQuery(
          data: MediaQueryData(size: size, devicePixelRatio: 2),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: _latin,
              fontFamilyFallback: const [_korean],
            ),
            home: Material(
              color: const Color(0xfffbf8ef),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [child, const Expanded(child: SizedBox.expand())],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return boundary;
  }

  Widget tabRow() => KitTabRow(
    tabs: _tabs,
    activeId: 'a',
    onHome: () {},
    onSelect: (_) {},
    onClose: (_) {},
    onCloseOthers: (_) {},
    onNewTab: () {},
    docInfo: () => DocInfo(
      lastEdited: DateTime.now().subtract(const Duration(minutes: 36)),
      syncLabel: '동기화됨',
      synced: true,
      offlineLabel: '준비됨',
    ),
    onRename: () {},
  );

  Widget functionRow({bool markdown = false}) => NoteFunctionRow(
    shortcuts: _pageActions(markdown: markdown),
    layout: ShortcutLayout.decode(noteShortcutItems, const []),
    onCustomize: () {},
  );

  group('tab row captures', skip: !_capture, () {
    // the preview's device: 600 wide, 586 inside its border
    testWidgets('tablet', (tester) async {
      final boundary = await mount(
        tester,
        const Size(586, KitTokens.tabRowHeight),
        tabRow(),
      );
      await _write(tester, boundary, 'tabs-tablet');
    });

    testWidgets('phone', (tester) async {
      final boundary = await mount(
        tester,
        const Size(360, KitTokens.tabRowHeight),
        tabRow(),
      );
      await _write(tester, boundary, 'tabs-phone');
    });

    testWidgets('tab menu', (tester) async {
      final boundary = await mount(tester, const Size(586, 260), tabRow());
      await tester.tap(find.byKey(const ValueKey('document-tab-info')));
      await tester.pumpAndSettle();
      await _write(tester, boundary, 'tab-menu');
    });

    testWidgets('phone tab menu', (tester) async {
      final boundary = await mount(tester, const Size(360, 260), tabRow());
      await tester.tap(find.byKey(const ValueKey('document-tab-info')));
      await tester.pumpAndSettle();
      await _write(tester, boundary, 'tab-menu-phone');
    });

    // a note read-only by its version: its toolbar is folded away, the row
    // holds the workspace's and the editor's shortcuts (Task 17 fix 1)
    testWidgets('read-only note row', (tester) async {
      AppAction a(
        String id,
        String label,
        KitIconName icon, {
        bool enabled = true,
        Key? key,
      }) => AppAction(
        id: id,
        label: label,
        icon: icon,
        enabled: enabled,
        widgetKey: key,
        run: (_) {},
      );
      final boundary = await mount(
        tester,
        const Size(586, KitTokens.toolbarHeight),
        NoteFunctionRow(
          shortcuts: [
            a(AppActionIds.prev, '이전 위치', KitIconName.back),
            a(AppActionIds.next, '다음 위치', KitIconName.chevR, enabled: false),
            a(AppActionIds.save, '기기에 저장', KitIconName.download),
            a(AppActionIds.insertPage, '페이지 추가', KitIconName.pageAdd, enabled: false),
            a(AppActionIds.pageMode, '한 쪽씩 보기', KitIconName.scrollDir),
            a(AppActionIds.finger, '손가락 필기', KitIconName.tap, enabled: false),
            a(AppActionIds.viewToggle, 'Markdown', KitIconName.textTt),
            a(AppActionIds.fullscreen, '전체 화면', KitIconName.expand),
          ],
          fixed: [
            a(
              AppActionIds.pageList,
              '문서 개요',
              KitIconName.sidebar,
              enabled: false,
            ),
          ],
          layout: ShortcutLayout.decode(noteShortcutItems, const []),
          onCustomize: () {},
        ),
      );
      await _write(tester, boundary, 'row-readonly');
    });

    testWidgets('page row', (tester) async {
      final boundary = await mount(
        tester,
        const Size(586, KitTokens.toolbarHeight),
        functionRow(),
      );
      await _write(tester, boundary, 'row-page');
    });

    testWidgets('page row more', (tester) async {
      final boundary = await mount(tester, const Size(586, 420), functionRow());
      await tester.tap(find.byKey(const ValueKey('workspace-more-actions')));
      await tester.pumpAndSettle();
      await _write(tester, boundary, 'row-page-more');
    });

    testWidgets('markdown row', (tester) async {
      final boundary = await mount(
        tester,
        const Size(586, KitTokens.toolbarHeight),
        functionRow(markdown: true),
      );
      await _write(tester, boundary, 'row-markdown');
    });

    testWidgets('phone page row', (tester) async {
      final boundary = await mount(
        tester,
        const Size(360, KitTokens.toolbarHeight),
        functionRow(),
      );
      await _write(tester, boundary, 'row-page-phone');
    });

    // ⋯ of the ink editor with the three rows from the old function row
    testWidgets('doc menu moved rows', (tester) async {
      final finger = stows.editorFingerDrawing.value;
      addTearDown(() => stows.editorFingerDrawing.value = finger);
      stows.editorToolbarTools.value = const [];
      stows.pageToolbarLayout.value = const [];
      stows.editorGestureMode.value = false;
      stows.editorFingerDrawing.value = false;
      final actions = AppActionRegistry();
      final open = ValueNotifier(false);
      final sheet = ValueNotifier(false);
      addTearDown(() {
        actions.dispose();
        open.dispose();
        sheet.dispose();
      });
      AppAction a(String id, String label, KitIconName icon, {bool? on}) =>
          AppAction(id: id, label: label, icon: icon, checked: on, run: (_) {});
      actions.publish(Object(), [
        a(AppActionIds.pageList, '문서 개요', KitIconName.sidebar),
        a(AppActionIds.toolPen, '펜', KitIconName.pen, on: true),
        a(AppActionIds.insertPage, '페이지 추가', KitIconName.pageAdd),
        a(AppActionIds.fullscreen, '전체 화면', KitIconName.expand, on: false),
        a(AppActionIds.pageMode, '한 쪽씩 보기', KitIconName.scrollDir, on: false),
        a(AppActionIds.docInfo, '문서 정보', KitIconName.info),
        a(AppActionIds.rename, '이름 바꾸기', KitIconName.rename),
        a(AppActionIds.readOnly, '읽기 전용', KitIconName.readonly, on: false),
        a(AppActionIds.viewToggle, 'Markdown', KitIconName.textTt),
        a(AppActionIds.tabBarHide, '탭 줄 숨기기', KitIconName.noteTab, on: false),
        a(AppActionIds.prev, '이전 위치', KitIconName.back),
        a(AppActionIds.next, '다음 위치', KitIconName.chevR),
        a(AppActionIds.toolbarCustomize, '도구 막대 사용자화', KitIconName.tune),
        a(AppActionIds.finger, '손가락 필기', KitIconName.tap, on: false),
        a(AppActionIds.openSettings, '설정', KitIconName.settings),
        a(AppActionIds.saveNow, '지금 저장', KitIconName.saved),
        a(AppActionIds.save, '기기에 저장', KitIconName.download),
        a(AppActionIds.export, '파일 내보내기', KitIconName.share),
      ]);
      final boundary = await mount(
        tester,
        const Size(586, 46 + 1000),
        KitEditorToolbar(
          actions: actions,
          title: '강의노트 3주차',
          floatingBarOpen: open,
          noteSheetOpen: sheet,
          pages: () => (index: 1, count: 5),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
      await tester.pumpAndSettle();
      await _write(tester, boundary, 'docmenu-moved');
    });
  });
}
