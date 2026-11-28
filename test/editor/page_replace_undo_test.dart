import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/editor/ink_swap.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// A 1 x 1 transparent PNG.
final _onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

/// A picture the picker hands over.
final class _PickedPhoto extends PlatformFile {
  @override
  String get name => 'photo.png';

  @override
  String? get path => null;

  @override
  Future<Uint8List> readAsBytes() async => _onePixelPng;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected picked file access: ${invocation.memberName}',
  );
}

/// The picture picker, which hands over one picture at once.
final class _OnePhotoPicker extends FilePickerPlatform {
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => [_PickedPhoto()];
}

/// The eraser, the lasso's 「삭제」 and clearing pages are one undo step that
/// swaps strokes and pictures by their places: undoing puts each back where
/// it was, on the same page (the record holds the page, so the tidying of
/// empty pages at the note's end does not drop it).
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
    String path = '/page-replace-undo',
  }) async {
    final previousLayout = stows.pageToolbarLayout.value;
    final previousTool = stows.lastTool.value;
    final previousRectangle = stows.selectRectangle.value;
    final previousFinger = stows.editorFingerDrawing.value;
    stows.pageToolbarLayout.value = const [];
    stows.lastTool.value = stows.lastTool.defaultValue;
    stows.eraserMode.value = EraserMode.stroke;
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.pageToolbarLayout.value = previousLayout;
      stows.lastTool.value = previousTool;
      stows.selectRectangle.value = previousRectangle;
      stows.editorFingerDrawing.value = previousFinger;
      stows.eraserMode.value = stows.eraserMode.defaultValue;
      stows.lastPenFamily.value = stows.lastPenFamily.defaultValue;
      stows.penBox.value = stows.penBox.defaultValue;
      Pen.currentPen = Pen.fountainPen();
      Pencil.currentPencil = Pencil();
      Highlighter.currentHighlighter = Highlighter();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1200, 2000)),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(path: path, onSaveSnapshot: (_, _) async {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  /// A straight pen line at [y] of page [index], x 300 to 700.
  Stroke line(EditorState editor, int index, double y) => Stroke(
    color: Colors.black,
    pressureEnabled: false,
    options: Pen.defaultOptions.copyWith(),
    pageIndex: index,
    page: editor.coreInfo.pages[index],
    toolId: ToolId.ballpointPen,
  )..addPoints([Offset(300, y), Offset(500, y), Offset(700, y)]);

  /// Pages [A (a line), X (empty), C (two lines), S (the empty last page)].
  Future<void> fourPages(WidgetTester tester, EditorState editor) async {
    editor.createPage(2);
    expect(editor.coreInfo.pages, hasLength(4));
    editor.coreInfo.pages[0].strokes.add(line(editor, 0, 300));
    editor.coreInfo.pages[2].strokes
      ..add(line(editor, 2, 300))
      ..add(line(editor, 2, 600));
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
  }

  void expectCBack(
    EditorState editor,
    EditorPage c,
    String cId,
    List<Stroke> cStrokes,
  ) {
    final pages = editor.coreInfo.pages;
    expect(pages[2], same(c), reason: 'the cleared page itself comes back');
    expect(pages[2].pageId, cId);
    expect(
      pages[2].strokes,
      pairwiseCompare<Stroke, Stroke>(cStrokes, identical, 'the same stroke'),
    );
    expect(pages.last.isEmpty, isTrue, reason: 'the note ends empty');
  }

  testWidgets(
    'clearing a page between an empty page and the end keeps its page id '
    'after undo',
    (tester) async {
      final editor = await mountEditor(tester);
      await fourPages(tester, editor);
      final c = editor.coreInfo.pages[2];
      final cId = c.pageId;
      final cStrokes = List.of(c.strokes);

      editor.clearPage(2);
      await tester.pump();
      expect(editor.coreInfo.pages.expand((p) => p.strokes), hasLength(1));
      editor.undo();
      await tester.pump();
      expectCBack(editor, c, cId, cStrokes);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets(
    'erasing the last strokes of such a page keeps its page id after undo',
    (tester) async {
      final editor = await mountEditor(tester);
      // Small pages, so all four are on screen at once.
      tester.view.physicalSize = const Size(400, 4000);
      await tester.pumpAndSettle();
      await fourPages(tester, editor);
      await tester.ensureVisible(find.byTooltip('지우개'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('지우개'));
      await tester.pumpAndSettle();
      final c = editor.coreInfo.pages[2];
      final cId = c.pageId;
      final cStrokes = List.of(c.strokes);

      // Along the first line, then back along the second.
      const points = [
        Offset(300, 300),
        Offset(500, 300),
        Offset(700, 300),
        Offset(800, 300),
        Offset(700, 600),
        Offset(500, 600),
        Offset(300, 600),
        Offset(200, 600),
      ];
      final gesture = await tester.startGesture(
        c.renderBox!.localToGlobal(points.first),
        kind: PointerDeviceKind.stylus,
      );
      var time = 0;
      for (final point in points.skip(1)) {
        time += 16;
        await gesture.moveTo(
          c.renderBox!.localToGlobal(point),
          timeStamp: Duration(milliseconds: time),
        );
      }
      await gesture.up(timeStamp: Duration(milliseconds: time + 10));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(c.strokes, isEmpty, reason: 'both lines erased');
      editor.undo();
      await tester.pump();
      expectCBack(editor, c, cId, cStrokes);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  Matcher sameStrokes(List<Stroke> strokes) =>
      pairwiseCompare<Stroke, Stroke>(strokes, identical, 'the same stroke');

  testWidgets('a replace undoes to the original places and redoes to the new '
      'ones', (tester) async {
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    final [a, b, c, d, e] = [
      for (var i = 0; i < 5; i++) line(editor, 0, 100.0 + i * 100),
    ];
    page.strokes.addAll([a, b, c]);
    // b goes, d comes in first and e last: [d, a, c, e].
    page.strokes
      ..remove(b)
      ..insert(0, d)
      ..add(e);
    expect(
      editor.pageList.recordReplace([
        (
          page: page,
          swap: InkSwap(
            removedStrokes: [(1, b)],
            addedStrokes: [(0, d), (3, e)],
          ),
        ),
      ]),
      isTrue,
    );
    editor.undo();
    await tester.pump();
    expect(page.strokes, sameStrokes([a, b, c]));
    editor.redo();
    await tester.pump();
    expect(page.strokes, sameStrokes([d, a, c, e]));
    expect(page.strokes.map((s) => s.pageIndex), everyElement(0));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a replace whose page is gone does nothing', (tester) async {
    final editor = await mountEditor(tester);
    await fourPages(tester, editor);
    final pages = List.of(editor.coreInfo.pages);
    final strokes = [for (final page in pages) List.of(page.strokes)];
    final stray = EditorPage();
    addTearDown(stray.dispose);
    final s = line(editor, 0, 900);
    expect(
      () => editor.pageList.undoSwaps([
        (page: stray, swap: InkSwap(removedStrokes: [(0, s)])),
      ]),
      throwsA(isA<AssertionError>()),
    );
    expect(
      editor.coreInfo.pages,
      pairwiseCompare<EditorPage, EditorPage>(pages, identical, 'same page'),
    );
    for (final (i, page) in pages.indexed) {
      expect(page.strokes, sameStrokes(strokes[i]), reason: 'page $i');
    }
    expect(stray.strokes, isEmpty);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('clear all pages is one undo step', (tester) async {
    final editor = await mountEditor(tester);
    await fourPages(tester, editor);
    final pages = List.of(editor.coreInfo.pages);
    final strokes = [for (final page in pages) List.of(page.strokes)];
    expect(editor.history.canUndo, isFalse);

    editor.clearAllPages();
    await tester.pump();
    expect(editor.coreInfo.pages.expand((p) => p.strokes), isEmpty);
    editor.undo();
    await tester.pump();
    expect(editor.history.canUndo, isFalse, reason: 'one step');
    for (final (i, page) in pages.indexed.take(3)) {
      expect(editor.coreInfo.pages[i], same(page), reason: 'page $i');
      expect(page.strokes, sameStrokes(strokes[i]), reason: 'page $i');
    }
    expect(editor.coreInfo.pages.last.isEmpty, isTrue);
    editor.redo();
    await tester.pump();
    expect(editor.coreInfo.pages.expand((p) => p.strokes), isEmpty);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a draw record holds its page', (tester) async {
    final editor = await mountEditor(tester);
    // Small pages, so all four are on screen at once.
    tester.view.physicalSize = const Size(400, 4000);
    await tester.pumpAndSettle();
    // [A (a line), X, Y, S], all but A empty.
    editor.createPage(2);
    editor.coreInfo.pages[0].strokes.add(line(editor, 0, 300));
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    final y = editor.coreInfo.pages[2];

    final gesture = await tester.startGesture(
      y.renderBox!.localToGlobal(const Offset(300, 300)),
      kind: PointerDeviceKind.stylus,
    );
    for (final (i, x) in const [400.0, 500.0, 600.0].indexed) {
      await gesture.moveTo(
        y.renderBox!.localToGlobal(Offset(x, 300)),
        timeStamp: Duration(milliseconds: 16 * (i + 1)),
      );
    }
    await gesture.up(timeStamp: const Duration(milliseconds: 80));
    await tester.pumpAndSettle();
    expect(y.strokes, hasLength(1));
    final stroke = y.strokes.single;
    expect(editor.history.holds(y), isTrue);

    // Undoing tidies the empty pages at the end, but not the page the record
    // (now to redo) holds, so redoing draws on that same page again.
    editor.undo();
    await tester.pump();
    expect(editor.coreInfo.pages[2], same(y));
    editor.redo();
    await tester.pump();
    expect(editor.coreInfo.pages[2], same(y));
    expect(y.strokes, sameStrokes([stroke]));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a lasso delete undoes to the original places', (tester) async {
    stows.selectRectangle.value = true;
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    final strokes = [
      for (final y in const [150.0, 300.0, 450.0]) line(editor, 0, y),
    ];
    page.strokes.addAll(strokes);
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pump();
    final actions = tester
        .widget<AppActionScope>(find.byType(AppActionScope))
        .notifier!;
    final context = tester.element(find.byType(Editor));
    expect(actions.run(AppActionIds.toolLasso, context), isTrue);
    await tester.pump();
    // A rectangle around the middle line only.
    final from = page.renderBox!.localToGlobal(const Offset(200, 240));
    final to = page.renderBox!.localToGlobal(const Offset(800, 360));
    final pen = await tester.startGesture(from, kind: PointerDeviceKind.stylus);
    await pen.moveTo(Offset.lerp(from, to, .5)!);
    await pen.moveTo(to);
    await pen.up();
    await tester.pumpAndSettle();

    expect(actions.run(AppActionIds.deleteSelection, context), isTrue);
    await tester.pump();
    expect(page.strokes, sameStrokes([strokes[0], strokes[2]]));
    editor.undo();
    await tester.pump();
    expect(page.strokes, sameStrokes(strokes));
    editor.redo();
    await tester.pump();
    expect(page.strokes, sameStrokes([strokes[0], strokes[2]]));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('clearing an empty page records nothing', (tester) async {
    final editor = await mountEditor(tester);
    expect(editor.coreInfo.pages.first.isEmpty, isTrue);
    expect(editor.history.canUndo, isFalse);
    editor.clearPage(0);
    await tester.pump();
    expect(editor.history.canUndo, isFalse);
    editor.cancelAutosaveAndMarkSaved();
  });

  Matcher samePages(List<EditorPage> pages) =>
      pairwiseCompare<EditorPage, EditorPage>(pages, identical, 'same page');

  testWidgets('redoing a cleared page tidies the end as clearing did', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await fourPages(tester, editor);
    editor.clearPage(2);
    await tester.pump();
    final cleared = List.of(editor.coreInfo.pages);
    expect(cleared, hasLength(3), reason: 'the record holds C, S went');
    editor.undo();
    await tester.pump();
    editor.redo();
    await tester.pump();
    expect(editor.coreInfo.pages, samePages(cleared));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a picture insert record holds its page', (tester) async {
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _OnePhotoPicker();
    addTearDown(() => FilePickerPlatform.instance = previous);
    // Its own note: the scroll position is cached per note path, so a shared
    // path would open the next test scrolled to page 3.
    final editor = await mountEditor(
      tester,
      path: '/page-replace-undo-picture',
    );
    // [A (a line), X, Y, S], all but A empty; Y is the page on screen.
    editor.createPage(2);
    editor.coreInfo.pages[0].strokes.add(line(editor, 0, 300));
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('쪽으로 이동'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('go-to-page-field')), '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(editor.currentPageIndex, 2);
    final y = editor.coreInfo.pages[2];

    final actions = tester
        .widget<AppActionScope>(find.byType(AppActionScope))
        .notifier!;
    expect(
      actions.run(AppActionIds.pickPhoto, tester.element(find.byType(Editor))),
      isTrue,
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(y.images, hasLength(1));
    final picture = y.images.single;
    expect(editor.history.holds(y), isTrue);

    // Undoing tidies the empty pages at the end, but not the page the record
    // (now to redo) holds, so redoing puts the picture on that same page.
    editor.undo();
    await tester.pump();
    expect(editor.coreInfo.pages[2], same(y));
    expect(y.images, isEmpty);
    editor.redo();
    await tester.pump();
    expect(editor.coreInfo.pages[2], same(y));
    expect(y.images.single, same(picture));
    editor.cancelAutosaveAndMarkSaved();
    // A picture lets its image go 5 s after it leaves the screen.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a lasso duplicate record holds its page', (tester) async {
    stows.selectRectangle.value = true;
    final editor = await mountEditor(tester);
    // Small pages, so all four are on screen at once.
    tester.view.physicalSize = const Size(400, 4000);
    await tester.pumpAndSettle();
    // [A (a line), X, Y (a line), S].
    editor.createPage(2);
    editor.coreInfo.pages[0].strokes.add(line(editor, 0, 300));
    editor.coreInfo.pages[2].strokes.add(line(editor, 2, 300));
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    final y = editor.coreInfo.pages[2];
    final original = y.strokes.single;

    final actions = tester
        .widget<AppActionScope>(find.byType(AppActionScope))
        .notifier!;
    final context = tester.element(find.byType(Editor));
    expect(actions.run(AppActionIds.toolLasso, context), isTrue);
    await tester.pump();
    final from = y.renderBox!.localToGlobal(const Offset(200, 240));
    final to = y.renderBox!.localToGlobal(const Offset(800, 360));
    final pen = await tester.startGesture(from, kind: PointerDeviceKind.stylus);
    await pen.moveTo(Offset.lerp(from, to, .5)!);
    await pen.moveTo(to);
    await pen.up();
    await tester.pumpAndSettle();
    expect(actions.run(AppActionIds.duplicateSelection, context), isTrue);
    await tester.pump();
    expect(y.strokes, hasLength(2));
    final copy = y.strokes.last;
    // Only the duplicate is in the history, so only its record holds Y.
    expect(editor.history.holds(y), isTrue);

    editor.undo();
    await tester.pump();
    expect(editor.coreInfo.pages[2], same(y));
    expect(y.strokes, sameStrokes([original]));
    editor.redo();
    await tester.pump();
    expect(editor.coreInfo.pages[2], same(y));
    expect(y.strokes, sameStrokes([original, copy]));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a second finger takes back what the first finger erased', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    stows.editorFingerDrawing.value = true;
    final page = editor.coreInfo.pages.first;
    final strokes = [
      for (final y in const [300.0, 500.0, 700.0]) line(editor, 0, y),
    ];
    page.strokes.addAll(strokes);
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    final canUndo = editor.history.canUndo;
    Offset at(double x, double y) =>
        page.renderBox!.localToGlobal(Offset(x, y));

    // One finger rubs out the middle line, then a second finger lands: a
    // pinch, so the first finger's erase is taken back.
    final finger = await tester.startGesture(at(300, 500), pointer: 11);
    var time = 0;
    for (final x in const [400.0, 500.0, 600.0, 700.0, 800.0]) {
      time += 16;
      await finger.moveTo(at(x, 500), timeStamp: Duration(milliseconds: time));
    }
    expect(page.strokes, sameStrokes([strokes[0], strokes[2]]));
    final second = await tester.startGesture(at(600, 900), pointer: 12);
    await second.moveTo(
      at(650, 960),
      timeStamp: Duration(milliseconds: time + 16),
    );
    await finger.up(timeStamp: Duration(milliseconds: time + 32));
    await second.up(timeStamp: Duration(milliseconds: time + 48));
    await tester.pumpAndSettle();
    expect(page.strokes, sameStrokes(strokes));
    expect(editor.history.canUndo, canUndo);
    editor.cancelAutosaveAndMarkSaved();
  });
}
