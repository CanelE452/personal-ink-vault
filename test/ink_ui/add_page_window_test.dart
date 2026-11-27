import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show CheckedState;

import 'package:bson/bson.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/tool_id.dart';

import '../utils/office_preview.dart'
    show
        officePreviewPdfiumAvailable,
        officePreviewRead,
        withOfficePreviewPdfium;
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

/// A picked file the picker hands over by [name] and [bytes] (a picture), or
/// by [filePath] (a PDF, which the editor reads from the disk).
final class _PickedFile extends PlatformFile {
  new(this.name, {this.bytes, this.filePath});

  @override
  final String name;
  final Uint8List? bytes;
  final String? filePath;

  @override
  String? get path => filePath;

  @override
  Future<Uint8List> readAsBytes() async => bytes!;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected picked file access: ${invocation.memberName}',
  );
}

/// Hands [file] to the editor's picker, once per call it makes; runs
/// [whilePicking] before it does.
final class _Picker extends FilePickerPlatform {
  new(this.file, {this.whilePicking});
  final PlatformFile file;
  final VoidCallback? whilePicking;
  var calls = 0;

  @override
  Future<PlatformFile?> pickFile({
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
  }) async {
    calls++;
    whilePicking?.call();
    return file;
  }

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
  }) async {
    calls++;
    whilePicking?.call();
    return [file];
  }
}

/// The toolbar's 노트 추가 window (supplement Task 14, 12th draft
/// `#extras12`: `addHtml`, `insertPage`, `.r1o`, `.r1seg`, `.r1card`).
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
    final saved = (
      stows.addPagePlace.value,
      stows.addPageRecent.value,
      stows.editorToolbarTools.value,
      stows.pageToolbarLayout.value,
    );
    stows.addPagePlace.value = 'after';
    stows.addPageRecent.value = const [];
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    addTearDown(() {
      stows.addPagePlace.value = saved.$1;
      stows.addPageRecent.value = saved.$2;
      stows.editorToolbarTools.value = saved.$3;
      stows.pageToolbarLayout.value = saved.$4;
    });
  });

  /// A straight line from x 100 to 500 at y 300 of [page].
  Stroke line(EditorPage page) => Stroke(
    color: const Color(0xFF1E88E5),
    pressureEnabled: false,
    options: StrokeOptions(size: 10),
    pageIndex: 0,
    page: page,
    toolId: ToolId.ballpointPen,
  )..addPoints([for (var x = 100.0; x <= 500; x += 20) Offset(x, 300)]);

  /// An editor of [size] on a note of three written pages (and the blank
  /// page after them), in [pattern]; the first page on screen.
  Future<EditorState> mountEditor(
    WidgetTester tester, {
    Size size = const Size(1200, 1600),
    CanvasBackgroundPattern pattern = CanvasBackgroundPattern.grid,
  }) async {
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
            // a new note each time: a saved one would be read again
            home: Editor(
              path: '/add-page-${DateTime.now().microsecondsSinceEpoch}',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    editor.coreInfo.backgroundPattern = pattern;
    editor.createPage(2);
    for (final (i, page) in editor.coreInfo.pages.take(3).indexed) {
      page.insertStroke(line(page)..pageIndex = i);
    }
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
    expect(editor.coreInfo.pages, hasLength(4));
    expect(editor.currentPageIndex, 0);
    addTearDown(editor.cancelAutosaveAndMarkSaved);
    return editor;
  }

  /// A PDF of [count] pages (red, blue, ...) in a folder that goes after
  /// the test; read in real time, as pdfium does.
  Future<File> writePdf(WidgetTester tester, int count) async {
    final directory = await officePreviewRead(
      tester,
      () => Directory.systemTemp.createTemp('piv-add-page-'),
    );
    addTearDown(() => tester.runAsync(() => directory.delete(recursive: true)));
    return officePreviewRead(tester, () async {
      final document = pw.Document();
      for (final color in [PdfColors.red, PdfColors.blue].take(count)) {
        document.addPage(
          pw.Page(
            pageFormat: const PdfPageFormat(200, 280),
            margin: pw.EdgeInsets.zero,
            build: (_) => pw.Container(color: color),
          ),
        );
      }
      return File('${directory.path}/pages-$count.pdf')
          .writeAsBytes(await document.save());
    });
  }

  /// Lets the PDF be read (pdfium, in real time) and put in.
  Future<void> letPdfIn(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await officePreviewRead(
      tester,
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
  }

  final window = find.byKey(const ValueKey('kit-add-page-window'));
  Finder card(String name) => find.byKey(ValueKey('add-page-card-$name'));
  Finder recentCard(String name) =>
      find.byKey(ValueKey('add-page-recent-$name'));
  Finder place(String name) => find.byKey(ValueKey('add-page-place-$name'));

  Future<void> openWindow(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('editor-insert-page')));
    await tester.pumpAndSettle();
    expect(window, findsOneWidget);
  }

  /// Puts a page in [pattern] (its card [name]) at [where] by the window.
  Future<void> insert(WidgetTester tester, String where, String name) async {
    await openWindow(tester);
    await tester.tap(place(where));
    await tester.pumpAndSettle();
    await tester.tap(card(name));
    await tester.pumpAndSettle();
    expect(window, findsNothing, reason: 'a card puts the page in and closes');
  }

  bool placeChosen(WidgetTester tester, String name) =>
      tester.getSemantics(place(name)).flagsCollection.isChecked ==
      CheckedState.isTrue;

  Map<String, dynamic> saved(EditorState editor) {
    final (bson, _) = editor.coreInfo.saveToBinary(currentPageIndex: 0);
    return BsonCodec.deserialize(BsonBinary.from(bson));
  }

  for (final (where, at, label) in [
    ('before', 0, '이 쪽 앞'),
    ('after', 1, '이 쪽 뒤'),
    ('end', 3, '맨 끝'),
  ]) {
    testWidgets('「$label」 puts the page there, goes to it; 「실행 취소」 '
        'takes it out', (tester) async {
      final editor = await mountEditor(tester);
      final before = [...editor.coreInfo.pages];
      await openWindow(tester);
      expect(find.text('노트 추가'), findsWidgets);
      expect(find.text(label), findsOneWidget);
      await tester.tap(place(where));
      await tester.pumpAndSettle();
      expect(placeChosen(tester, where), isTrue);
      await tester.tap(card('lined'));
      await tester.pumpAndSettle();

      final pages = editor.coreInfo.pages;
      expect(pages, hasLength(5));
      final added = pages[at];
      expect(before, isNot(contains(added)));
      expect([...pages]..removeAt(at), orderedEquals(before));
      expect(added.backgroundPattern, CanvasBackgroundPattern.lined);
      for (final (i, page) in pages.indexed) {
        for (final stroke in page.strokes) {
          expect(stroke.pageIndex, i, reason: 'the pages after it move on');
        }
      }
      expect(editor.currentPageIndex, at, reason: 'it goes to the new page');
      expect(editor.side.notice.notice?.text, '${at + 1}쪽에 줄 쪽을 넣었습니다');
      expect(find.text('${at + 1}쪽에 줄 쪽을 넣었습니다'), findsOneWidget);

      await tester.tap(find.text(KitTokens.undoNoticeAction));
      await tester.pumpAndSettle();
      expect(editor.coreInfo.pages, orderedEquals(before));
      expect(editor.currentPageIndex, 0, reason: 'back where it was');
      expect(find.text('${at + 1}쪽에 줄 쪽을 넣었습니다'), findsNothing);
    });
  }

  testWidgets('the notice goes once another change comes or the page is '
      'undone: no 「실행 취소」 that does nothing', (tester) async {
    final editor = await mountEditor(tester);
    await insert(tester, 'after', 'dot');
    expect(editor.side.notice.notice, isNotNull);
    final pages = [...editor.coreInfo.pages];
    final written = pages.first;
    final stroke = line(written);
    written.insertStroke(stroke);
    editor.history.recordChange(
      EditorHistoryItem(
        type: .draw,
        pageIndex: 0,
        strokes: [stroke],
        images: const [],
      ),
    );
    await tester.pumpAndSettle();
    expect(editor.side.notice.notice, isNull, reason: 'a stroke came after');
    expect(find.text(KitTokens.undoNoticeAction), findsNothing);
    expect(editor.coreInfo.pages, orderedEquals(pages));
    expect(written.strokes, contains(stroke));

    // put in again, then taken out by the toolbar's undo
    await insert(tester, 'after', 'lined');
    expect(editor.side.notice.notice, isNotNull);
    editor.undo();
    await tester.pumpAndSettle();
    expect(editor.side.notice.notice, isNull, reason: 'undone already');
    expect(editor.coreInfo.pages, orderedEquals(pages));
  });

  testWidgets('쪽 메뉴 「뒤에 쪽 추가」 moves the pages after it on: a stroke '
      'erased there comes back on its page', (tester) async {
    final editor = await mountEditor(tester);
    final moved = editor.coreInfo.pages[2];
    final stroke = moved.strokes.single;
    await tester.tap(find.byKey(const ValueKey('editor-page-list')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kit-side-page-0-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kit-page-menu-뒤에 쪽 추가')));
    await tester.pumpAndSettle();
    final pages = editor.coreInfo.pages;
    expect(pages, hasLength(5));
    expect(pages[3], same(moved));

    // the stroke erased on its page, then the erasing undone
    moved.strokes.remove(stroke);
    editor.history.recordChange(
      EditorHistoryItem(
        type: .erase,
        pageIndex: 3,
        strokes: [stroke],
        images: const [],
      ),
    );
    editor.undo();
    await tester.pumpAndSettle();
    expect(moved.strokes, contains(stroke), reason: 'back on its page');
    expect(pages[2].strokes, hasLength(1), reason: 'not on the one before');
    for (final (i, page) in pages.indexed) {
      for (final each in page.strokes) {
        expect(each.pageIndex, i);
      }
    }
  });

  testWidgets('쪽 메뉴 「복제」 undone takes the copy out: the original '
      'stays, the pages after it are numbered back', (tester) async {
    final editor = await mountEditor(tester);
    final before = [...editor.coreInfo.pages];
    await tester.tap(find.byKey(const ValueKey('editor-page-list')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kit-side-page-0-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('kit-page-menu-복제')));
    await tester.pumpAndSettle();
    final pages = editor.coreInfo.pages;
    expect(pages, hasLength(5));
    expect(pages[0], same(before[0]));
    expect(pages[1].strokes.single.pageIndex, 1, reason: 'the copy');
    expect(pages[2].strokes.single.pageIndex, 2, reason: 'moved on');

    editor.undo();
    await tester.pumpAndSettle();
    expect(pages, orderedEquals(before), reason: 'the original stays');
    for (final (i, page) in pages.indexed) {
      for (final stroke in page.strokes) {
        expect(stroke.pageIndex, i);
      }
    }
  });

  testWidgets('「이 쪽 뒤」 on the blank page that ends the note puts the page '
      'before it, as 「맨 끝」', (tester) async {
    final editor = await mountEditor(tester);
    await tester.tap(find.byKey(const ValueKey('editor-page-list')));
    await tester.pumpAndSettle();
    final last = find.byKey(const ValueKey('kit-side-page-3'));
    await tester.ensureVisible(last);
    await tester.pumpAndSettle();
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(editor.currentPageIndex, 3);
    final blank = editor.coreInfo.pages.last;
    expect(blank.isEmpty, isTrue);

    await insert(tester, 'after', 'lined');
    final pages = editor.coreInfo.pages;
    expect(pages, hasLength(5));
    expect(pages[3].backgroundPattern, CanvasBackgroundPattern.lined);
    expect(pages.last, same(blank), reason: 'the note still ends blank');
    expect(editor.side.notice.notice?.text, '4쪽에 줄 쪽을 넣었습니다');
    expect(editor.currentPageIndex, 3);
  });

  testWidgets('「페이지 추가」 waits for the kept place and patterns', (tester) async {
    final editor = await mountEditor(tester);
    final place = stows.addPagePlace, recent = stows.addPageRecent;
    final wasLoaded = (place.loaded, recent.loaded);
    addTearDown(() {
      place.loaded = wasLoaded.$1;
      recent.loaded = wasLoaded.$2;
    });
    place.loaded = false;
    recent.loaded = false;
    // the device's settings, read once the gate opens
    final gate = Completer<void>();
    unawaited(
      // ignore: invalid_use_of_visible_for_overriding_member
      place.readMutex.protect(() async {
        await gate.future;
        place.value = 'before';
        place.loaded = true;
      }),
    );
    unawaited(
      // ignore: invalid_use_of_visible_for_overriding_member
      recent.readMutex.protect(() async {
        await gate.future;
        recent.value = const ['lined'];
        recent.loaded = true;
      }),
    );
    final actions = tester
        .widget<AppActionScope>(find.byType(AppActionScope))
        .notifier!;
    expect(
      actions.run(AppActionIds.insertPage, tester.element(find.byType(Editor))),
      isTrue,
    );
    await tester.pump();
    expect(editor.coreInfo.pages, hasLength(4), reason: 'not read yet');

    gate.complete();
    await tester.pumpAndSettle();
    final pages = editor.coreInfo.pages;
    expect(pages, hasLength(5));
    expect(pages[0].backgroundPattern, CanvasBackgroundPattern.lined);
    expect(editor.side.notice.notice?.text, '1쪽에 줄 쪽을 넣었습니다');
  });

  testWidgets('a page in the note\'s pattern follows it: version 19', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await insert(tester, 'after', 'grid');
    final added = editor.coreInfo.pages[1];
    expect(added.backgroundPattern, isNull);
    expect(editor.coreInfo.versionToWrite(), 19);
    final json = saved(editor);
    expect(json['v'], 19);
    for (final page in json['z'] as List) {
      expect((page as Map).containsKey('bp'), isFalse);
    }
  });

  testWidgets('a page in another pattern: that page only, version 20', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await insert(tester, 'before', 'dot');
    expect(
      editor.coreInfo.pages[0].backgroundPattern,
      CanvasBackgroundPattern.dots,
    );
    final json = saved(editor);
    expect(json['v'], EditorCoreInfo.pagePatternVersion);
    expect(json['p'], 'grid');
    final pages = (json['z'] as List).cast<Map>();
    expect(pages[0]['bp'], 'dots');
    for (final page in pages.skip(1)) {
      expect(page.containsKey('bp'), isFalse);
    }
    // 빈 종이 in a grid note: its own pattern is none (named '')
    await insert(tester, 'after', 'blank');
    expect(
      editor.coreInfo.pages[1].backgroundPattern,
      CanvasBackgroundPattern.none,
    );
    expect((saved(editor)['z'] as List)[1]['bp'], '');
  });

  testWidgets('the recent patterns: the last three, newest first, by name', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await openWindow(tester);
    expect(find.text('최근 양식'), findsNothing, reason: 'none used yet');
    await tester.tapAt(const Offset(20, 1500));
    await tester.pumpAndSettle();

    for (final name in ['lined', 'grid', 'dot', 'blank']) {
      await insert(tester, 'after', name);
    }
    expect(stows.addPageRecent.value, ['', 'dots', 'grid']);
    await openWindow(tester);
    expect(find.text('최근 양식'), findsOneWidget);
    final cards = [
      for (final name in ['blank', 'dot', 'grid'])
        tester.getRect(recentCard(name)),
    ];
    expect(recentCard('lined'), findsNothing);
    expect(cards[0].left, lessThan(cards[1].left));
    expect(cards[1].left, lessThan(cards[2].left));
    expect(
      find.descendant(of: recentCard('dot'), matching: find.text('점')),
      findsOneWidget,
    );
    // a recent card puts its pattern in and comes first
    await tester.tap(recentCard('grid'));
    await tester.pumpAndSettle();
    expect(stows.addPageRecent.value, ['grid', '', 'dots']);
    expect(editor.coreInfo.pages, hasLength(9));
  });

  testWidgets('the place is kept: the window and 「페이지 추가」 use it', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await openWindow(tester);
    expect(placeChosen(tester, 'after'), isTrue, reason: 'after to start');
    await tester.tap(place('end'));
    await tester.pumpAndSettle();
    expect(stows.addPagePlace.value, 'end');
    await tester.tapAt(const Offset(20, 1500));
    await tester.pumpAndSettle();
    expect(window, findsNothing);
    expect(editor.coreInfo.pages, hasLength(4), reason: 'nothing put in');

    await openWindow(tester);
    expect(placeChosen(tester, 'end'), isTrue);
    expect(placeChosen(tester, 'after'), isFalse);
    await tester.tapAt(const Offset(20, 1500));
    await tester.pumpAndSettle();

    // 「페이지 추가」 (the action, as a key or a shortcut runs it): the last
    // place and the last pattern, without the window
    stows.addPageRecent.value = const ['dots'];
    final actions = tester
        .widget<AppActionScope>(find.byType(AppActionScope))
        .notifier!;
    expect(
      actions.run(AppActionIds.insertPage, tester.element(find.byType(Editor))),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(window, findsNothing);
    expect(editor.coreInfo.pages, hasLength(5));
    expect(
      editor.coreInfo.pages[3].backgroundPattern,
      CanvasBackgroundPattern.dots,
    );
    expect(editor.side.notice.notice?.text, '4쪽에 점 쪽을 넣었습니다');
  });

  testWidgets('「이미지 가져오기」 puts the picture on a new page there', (
    tester,
  ) async {
    final picker = _Picker(_PickedFile('photo.png', bytes: _onePixelPng));
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    final editor = await mountEditor(tester);
    final before = [...editor.coreInfo.pages];
    await openWindow(tester);
    expect(find.text('이미지 가져오기'), findsOneWidget);
    expect(find.text('사진'), findsWidgets);
    await tester.tap(place('before'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('add-page-import-image')));
    await tester.pumpAndSettle();
    expect(picker.calls, 1);
    final pages = editor.coreInfo.pages;
    expect(pages, hasLength(5));
    expect(pages.skip(1), orderedEquals(before));
    expect(pages[0].images, hasLength(1));
    expect(pages[0].images.single.pageIndex, 0);
    for (final page in before) {
      expect(page.images, isEmpty);
    }
    expect(pages[1].strokes.single.pageIndex, 1);
    await _letPicturesGo(tester);
  });

  // A recording goes on while the app's own picker is open (final fix
  // wave 3): it counts as a screen of the app.
  testWidgets('the picture picker counts as a screen of the app', (
    tester,
  ) async {
    final active = <bool>[];
    final picker = _Picker(
      _PickedFile('photo.png', bytes: _onePixelPng),
      whilePicking: () => active.add(AppExternalScreen.active),
    );
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    await mountEditor(tester);
    await openWindow(tester);
    await tester.tap(find.byKey(const ValueKey('add-page-import-image')));
    await tester.pumpAndSettle();
    expect(active, [true]);
    expect(AppExternalScreen.active, isFalse);
    await _letPicturesGo(tester);
  });

  testWidgets(
    '「문서 가져오기」 puts the PDF\'s pages there, after a patterned last page',
    (tester) => withOfficePreviewPdfium(tester, () async {
      final pdf = await writePdf(tester, 2);
      final picker = _Picker(_PickedFile('two.pdf', filePath: pdf.path));
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      final editor = await mountEditor(tester);
      // the last page: blank in its own pattern, so not the note's end page
      await insert(tester, 'end', 'dot');
      final before = [...editor.coreInfo.pages];
      expect(before[3].backgroundPattern, CanvasBackgroundPattern.dots);
      expect(before.last.isEmpty, isTrue);
      editor.coreInfo.pages.removeLast().dispose();

      await openWindow(tester);
      expect(find.text('문서 가져오기'), findsOneWidget);
      expect(find.text('PDF'), findsOneWidget);
      expect(placeChosen(tester, 'end'), isTrue);
      await tester.tap(find.byKey(const ValueKey('add-page-import-document')));
      await letPdfIn(tester);
      expect(picker.calls, 1);
      final pages = editor.coreInfo.pages;
      expect(pages.take(4), orderedEquals(before.take(4)));
      expect(pages, hasLength(7), reason: 'the PDF pages, then a blank page');
      for (final (i, page) in pages.indexed.skip(4).take(2)) {
        final background = page.backgroundImage as PdfEditorImage;
        expect(background.pdfPage, i - 4);
        expect(background.pageIndex, i);
      }
      expect(pages.last.isEmpty, isTrue);
      expect(editor.currentPageIndex, 4, reason: 'it goes to the first one');

      // 「이 쪽 앞」 on that page: before it, the pages after it move on
      await openWindow(tester);
      await tester.tap(place('before'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-page-import-document')));
      await letPdfIn(tester);
      expect(pages, hasLength(9));
      expect(pages.take(4), orderedEquals(before.take(4)));
      final first = pages[6];
      expect((first.backgroundImage! as PdfEditorImage).pdfPage, 0);
      expect((first.backgroundImage! as PdfEditorImage).pageIndex, 6);
      expect((pages[4].backgroundImage! as PdfEditorImage).pdfPage, 0);
      expect((pages[5].backgroundImage! as PdfEditorImage).pdfPage, 1);
      expect((pages[7].backgroundImage! as PdfEditorImage).pageIndex, 7);
      await _letPicturesGo(tester);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    '「문서 가져오기」 still goes in when pages went while picking',
    (tester) => withOfficePreviewPdfium(tester, () async {
      final pdf = await writePdf(tester, 1);
      late final EditorState editor;
      bool? inApp;
      final picker = _Picker(
        _PickedFile('one.pdf', filePath: pdf.path),
        // the last two pages go while the file is picked
        whilePicking: () {
          inApp = AppExternalScreen.active;
          editor.coreInfo.pages.removeLast().dispose();
          editor.coreInfo.pages.removeLast().dispose();
        },
      );
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      editor = await mountEditor(tester);
      final kept = editor.coreInfo.pages.take(2).toList();
      await openWindow(tester);
      await tester.tap(place('end'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-page-import-document')));
      await letPdfIn(tester);
      expect(picker.calls, 1);
      expect(inApp, isTrue, reason: 'a screen of the app while picking');
      expect(tester.takeException(), isNull);
      final pages = editor.coreInfo.pages;
      expect(pages.take(2), orderedEquals(kept));
      expect(pages, hasLength(4), reason: 'the PDF page, then a blank page');
      final background = pages[2].backgroundImage! as PdfEditorImage;
      expect(background.pageIndex, 2);
      expect(pages.last.isEmpty, isTrue);
      await _letPicturesGo(tester);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'text written on a page brought in from a PDF is an undo step',
    (tester) => withOfficePreviewPdfium(tester, () async {
      final pdf = await writePdf(tester, 1);
      final picker = _Picker(_PickedFile('one.pdf', filePath: pdf.path));
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      final editor = await mountEditor(tester);
      await openWindow(tester);
      await tester.tap(place('end'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add-page-import-document')));
      await letPdfIn(tester);
      final page = editor.coreInfo.pages[3];
      expect(page.backgroundImage, isA<PdfEditorImage>());
      expect(editor.history.peekUndo().type, EditorHistoryItemType.insertPage);

      page.quill.controller.document.insert(0, '메모');
      await tester.pumpAndSettle();
      final last = editor.history.peekUndo();
      expect(last.type, EditorHistoryItemType.quillChange);
      expect(last.pageIndex, 3);
      await _letPicturesGo(tester);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets('the dot sample draws its dots 0.9 across', (tester) async {
    await mountEditor(tester);
    await openWindow(tester);
    final sample = find.descendant(
      of: card('dot'),
      matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.size == KitTokens.addPageSampleSize,
      ),
    );
    expect(
      tester.renderObject(sample),
      paints..circle(
        x: KitTokens.addPageDotFirst,
        y: KitTokens.addPageDotFirst,
        radius: 0.9,
      ),
    );
  });

  testWidgets('the window is 300 wide, under its button and lit', (
    tester,
  ) async {
    await mountEditor(tester);
    await openWindow(tester);
    final box = tester.getRect(window);
    expect(box.width, KitTokens.addPagePanelWidth);
    final button = find.byKey(const ValueKey('editor-insert-page'));
    expect(box.top, greaterThanOrEqualTo(tester.getRect(button).bottom));
    expect(box.right, lessThanOrEqualTo(1200 - KitTokens.popoverEdgeGap));
    final lit = tester.widget<Material>(
      find.descendant(of: button, matching: find.byType(Material)).first,
    );
    expect(lit.color, isNot(Colors.transparent), reason: 'its window is open');
    Size sizeOf(String key) => tester.getSize(find.byKey(ValueKey(key)));
    expect(sizeOf('add-page-import-document').height, 44);
    expect(sizeOf('add-page-import-image').height, 43, reason: 'under a line');
    expect(KitTokens.addPageDotRadius, 0.9);
    await tester.tapAt(const Offset(20, 1500));
    await tester.pumpAndSettle();
    expect(window, findsNothing);
  });

  testWidgets('on a short phone the window scrolls', (tester) async {
    stows.addPageRecent.value = const ['grid', 'lined'];
    await mountEditor(tester, size: const Size(360, 520));
    await openWindow(tester);
    final phone = tester.getRect(window);
    expect(phone.width, KitTokens.addPagePanelWidth);
    final scroll = find.descendant(
      of: find.byType(Overlay),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );
    final view = find.ancestor(of: window, matching: scroll).first;
    final position = tester.state<ScrollableState>(view).position;
    expect(position.maxScrollExtent, greaterThan(0), reason: 'more below');
    final image = find.byKey(const ValueKey('add-page-import-image'));
    expect(tester.getRect(image).bottom, greaterThan(520));
    await tester.drag(view, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    expect(tester.getRect(image).bottom, lessThanOrEqualTo(520));
  });
}

/// A picture let go of the screen frees its image 5 seconds later
/// (`EditorImage.loadOut`): the editor goes and that time passes.
Future<void> _letPicturesGo(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 6));
}
