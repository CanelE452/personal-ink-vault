import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/components/toolbar/note_function_row.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
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

/// The editor's part of StarNote's function row and 기타 설정 (229): it
/// draws them itself when no host does (the Office PDF ink view), and hands
/// them to the host's controller otherwise (the workspace).
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
    final previousAlignment = stows.workspaceToolbarAlignment.value;
    final previousShortcuts = stows.noteShortcutLayout.value;
    stows.workspaceToolbarAlignment.value = AxisDirection.up;
    stows.noteShortcutLayout.value = const [];
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.workspaceToolbarAlignment.value = previousAlignment;
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

  Finder inRow(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('note-function-row')),
    matching: matching,
  );

  testWidgets('a standalone editor shows its own function row with page shortcuts', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    expect(inRow(find.byTooltip('페이지 추가')), findsOneWidget);
    expect(inRow(find.byKey(const ValueKey('note-other-settings'))), findsOneWidget);
    expect(inRow(find.byKey(const ValueKey('note-overview'))), findsOneWidget);
    final pages = editor.coreInfo.pages.length;
    await tester.tap(inRow(find.byTooltip('페이지 추가')));
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
      chrome.shortcuts.map((shortcut) => shortcut.id),
      containsAll(['insertPage', 'pageMode', 'finger', 'fullscreen', 'export']),
    );
    expect(chrome.fixed.map((shortcut) => shortcut.id), ['overview', 'otherSettings']);
    await tester.pumpWidget(const SizedBox());
    expect(chrome.editor, isNull);
  });

  testWidgets('other settings: 페이지로 이동 goes to the page', (tester) async {
    final editor = await mountEditor(tester);
    // createPage keeps one empty page after the one it makes.
    editor.createPage(2);
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    expect(editor.coreInfo.pages.length, greaterThanOrEqualTo(3));
    await tester.tap(find.byKey(const ValueKey('note-other-settings')));
    await tester.pumpAndSettle();
    final panel = find.byKey(const ValueKey('other-settings-panel'));
    expect(panel, findsOneWidget);
    for (final title in const ['페이지 설정', '문서 내보내기', '일반 설정']) {
      expect(find.descendant(of: panel, matching: find.text(title)), findsOneWidget);
    }
    await tester.enterText(
      find.byKey(const ValueKey('other-settings-go-to-page-field')),
      '3',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(editor.currentPageIndex, 2);
    expect(find.byKey(const ValueKey('other-settings-panel')), findsNothing);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a read-only note turns off the page shortcuts', (tester) async {
    final chrome = EditorChromeController();
    addTearDown(chrome.dispose);
    final editor = await mountEditor(tester, chrome: chrome);
    // ignore: invalid_use_of_protected_member
    editor.setState(() => editor.coreInfo.readOnlyReason = ReadOnlyReason.versionTooNew);
    await tester.pumpAndSettle();
    NoteShortcut shortcut(String id) =>
        chrome.shortcuts.firstWhere((shortcut) => shortcut.id == id);
    expect(shortcut('insertPage').onPressed, isNull);
    expect(shortcut('export').onPressed, isNull);
    expect(shortcut('fullscreen').onPressed, isNotNull);
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

  testWidgets('saving 사용자 지정 도구 모음 keeps the shortcuts the 228 toolbar hid', (
    tester,
  ) async {
    final previousToolbar = stows.pageToolbarLayout.value;
    stows.pageToolbarLayout.value = const ['!finger'];
    addTearDown(() => stows.pageToolbarLayout.value = previousToolbar);
    await mountEditor(tester);
    ShortcutSide finger() => ShortcutLayout.decode(
      noteShortcutItems,
      stows.noteShortcutLayout.value,
      legacyToolbar: stows.pageToolbarLayout.value,
    ).sideOf('finger');
    expect(finger(), ShortcutSide.more);
    await tester.tap(find.byKey(const ValueKey('note-other-settings')));
    await tester.pumpAndSettle();
    final custom = find.byKey(const ValueKey('other-settings-toolbar-custom'));
    await tester.ensureVisible(custom);
    await tester.pumpAndSettle();
    await tester.tap(custom);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('toolbar-custom-apply')));
    await tester.pumpAndSettle();
    // The dialog writes the tools only; the old switches are gone from it.
    expect(stows.pageToolbarLayout.value, isNot(contains('!finger')));
    expect(finger(), ShortcutSide.more);
  });

  testWidgets(
    'while a PDF is being imported, the page shortcuts and 기타 설정 are off',
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
      NoteShortcut shortcut(String id) => [
        ...chrome.shortcuts,
        ...chrome.fixed,
      ].firstWhere((shortcut) => shortcut.id == id);
      const pageActions = ['insertPage', 'export', 'overview', 'otherSettings'];
      try {
        for (final id in pageActions) {
          expect(shortcut(id).onPressed, isNull, reason: id);
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
        expect(shortcut(id).onPressed, isNotNull, reason: id);
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
