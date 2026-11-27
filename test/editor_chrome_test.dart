import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:sbn/read_only_reason.dart';

import 'utils/office_preview.dart'
    show
        officePreviewDocumentsClosed,
        officePreviewPdf,
        officePreviewPdfiumAvailable,
        officePreviewRead,
        officePreviewUntil,
        withOfficePreviewPdfium;
import 'utils/test_mock_channel_handlers.dart';

/// The editor's actions for its host: an editor with a controller (the
/// workspace) publishes them there, one without keeps them; neither draws
/// 229's function row any more (Task 17: its toolbar and ⋯ hold those
/// items). 기타 설정's rows moved to ⋯ (Task 14).
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  Future<EditorState> mountEditor(
    WidgetTester tester, {
    EditorChromeController? chrome,
  }) async {
    final previousShortcuts = stows.noteShortcutLayout.value;
    stows.noteShortcutLayout.value = const [];
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.noteShortcutLayout.value = previousShortcuts;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Editor(
            path: '/editor-chrome',
            onSaveSnapshot: (_, _) async {},
            chrome: chrome,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  testWidgets('a standalone editor has no function row; its toolbar adds pages', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    expect(find.byKey(const ValueKey('note-function-row')), findsNothing);
    expect(
      find.byKey(const ValueKey('note-other-settings')),
      findsNothing,
      reason: '기타 설정 is gone; its rows are in ⋯',
    );
    // the page list is the toolbar's 쪽 목록
    expect(
      find.byKey(const ValueKey('editor-page-list')).hitTestable(),
      findsOneWidget,
    );
    final pages = editor.coreInfo.pages.length;
    // 노트 추가 opens its window; a pattern there puts the page in
    await tester.tap(find.byKey(const ValueKey('editor-insert-page')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-page-card-lined')));
    await tester.pumpAndSettle();
    expect(editor.coreInfo.pages, hasLength(pages + 1));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('with a controller the editor draws no function row and lists its shortcuts', (
    tester,
  ) async {
    final chrome = EditorChromeController();
    addTearDown(chrome.dispose);
    var heard = 0;
    chrome.addListener(() => heard++);
    final editor = await mountEditor(tester, chrome: chrome);
    expect(find.byKey(const ValueKey('note-function-row')), findsNothing);
    expect(chrome.editor, same(editor));
    expect(heard, greaterThan(0));
    expect(
      [
        for (final id in AppActionIds.all)
          if (chrome.actions.has(id)) id,
      ],
      containsAll(['insertPage', 'pageMode', 'finger', 'fullscreen', 'export']),
    );
    // A hosted editor leaves 저장 to its host.
    expect(chrome.actions.has(AppActionIds.save), isFalse);
    // 쪽 목록, which an Office PDF's function row keeps at its end
    final pageList = chrome.actions.lookup(AppActionIds.pageList);
    expect(pageList?.widgetKey, const ValueKey('note-page-list'));
    expect(pageList?.label, '쪽 목록');
    await tester.pumpWidget(const SizedBox());
    expect(chrome.editor, isNull);
  });

  testWidgets('⋯ 쪽으로 이동 goes to the page', (tester) async {
    final editor = await mountEditor(tester);
    // createPage keeps one empty page after the one it makes.
    editor.createPage(2);
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    expect(editor.coreInfo.pages.length, greaterThanOrEqualTo(3));
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('쪽으로 이동'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('go-to-page-field')), '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(editor.currentPageIndex, 2);
    expect(find.byKey(const ValueKey('go-to-page-field')), findsNothing);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a read-only note turns off the page shortcuts', (tester) async {
    final chrome = EditorChromeController();
    addTearDown(chrome.dispose);
    final editor = await mountEditor(tester, chrome: chrome);
    // ignore: invalid_use_of_protected_member
    editor.setState(() => editor.coreInfo.readOnlyReason = ReadOnlyReason.versionTooNew);
    await tester.pumpAndSettle();
    bool enabled(String id) => chrome.actions.lookup(id)!.enabled;
    expect(enabled('insertPage'), isFalse);
    expect(enabled('export'), isFalse);
    expect(enabled('fullscreen'), isTrue);
  });

  testWidgets('a read-only note in full screen keeps a way back', (tester) async {
    addTearDown(() => DynamicMaterialApp.setFullscreen(false, updateSystem: false));
    final editor = await mountEditor(tester);
    // ignore: invalid_use_of_protected_member
    editor.setState(() => editor.coreInfo.readOnlyReason = ReadOnlyReason.versionTooNew);
    DynamicMaterialApp.setFullscreen(true, updateSystem: false);
    await tester.pumpAndSettle();
    // The toolbar is folded away on a read-only note, and the function row is hidden in full screen.
    final exit = find.widgetWithIcon(FloatingActionButton, Icons.fullscreen_exit);
    expect(exit, findsOneWidget);
    await tester.tap(exit);
    await tester.pumpAndSettle();
    expect(DynamicMaterialApp.isFullscreen, isFalse);
  });

  testWidgets(
    'while a PDF is being imported, the page shortcuts are off',
    (tester) => withOfficePreviewPdfium(tester, () async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final chrome = EditorChromeController();
      addTearDown(chrome.dispose);
      final directory = await officePreviewRead(
        tester,
        () => Directory.systemTemp.createTemp('editor-chrome-import-'),
      );
      final pdf = await officePreviewRead(
        tester,
        () async => File('${directory.path}/import.pdf')
            .writeAsBytes(await officePreviewPdf(PdfColors.white)),
      );
      // The import ends with a first save; it stays pending until the test lets it go.
      final firstSave = Completer<void>();
      var saving = false;
      var loaded = false;
      final path = '${directory.path}/import.sbn2';
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Editor(
              path: path,
              pdfPath: pdf.path,
              loadSnapshot: () async => EditorCoreInfo(filePath: path),
              onSaveSnapshot: (_, _) {
                saving = true;
                return firstSave.future;
              },
              onLoaded: (_) => loaded = true,
              chrome: chrome,
            ),
          ),
        ),
      );
      await officePreviewUntil(
        tester,
        () => saving,
        'The PDF import must reach its first save',
      );
      // The page actions are the editor's actions, 쪽 목록 too.
      bool on(String id) => chrome.actions.lookup(id)!.enabled;
      const pageActions = ['insertPage', 'export', 'pageList'];
      try {
        for (final id in pageActions) {
          expect(on(id), isFalse, reason: id);
        }
      } finally {
        if (!firstSave.isCompleted) firstSave.complete();
      }
      await officePreviewUntil(
        tester,
        () => loaded,
        'The import must finish once its first save does',
      );
      await tester.pump();
      for (final id in pageActions) {
        expect(on(id), isTrue, reason: id);
      }
      tester.state<EditorState>(find.byType(Editor)).cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      await officePreviewDocumentsClosed(tester);
      await tester.runAsync(() => directory.delete(recursive: true));
    }),
    skip: !officePreviewPdfiumAvailable,
  );
}
