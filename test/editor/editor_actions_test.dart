import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/data/tools/shape_pen.dart';
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

/// The picture picker, which answers only when [answer] completes.
final class _HeldPicker extends FilePickerPlatform {
  final answer = Completer<List<PlatformFile>>();
  var asked = false;

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
  }) {
    asked = true;
    return answer.future;
  }
}

/// The editor's actions (editor_actions.dart): the old toolbar and the
/// actions call the same code.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  Future<EditorState> mountEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          // The text box (a Quill editor) needs its strings.
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(
            path: '/editor-actions',
            onSaveSnapshot: (_, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  AppActionRegistry actionsOf(WidgetTester tester) =>
      tester.widget<AppActionScope>(find.byType(AppActionScope)).notifier!;

  /// Lassoes x 60-540, y 240-360 of the first page with a rectangle.
  Future<void> lassoAround(
    WidgetTester tester,
    EditorState editor,
    AppActionRegistry actions,
  ) async {
    final page = editor.coreInfo.pages.first;
    expect(
      actions.run(AppActionIds.toolLasso, tester.element(find.byType(Editor))),
      isTrue,
    );
    await tester.pump();
    final from = page.renderBox!.localToGlobal(const Offset(60, 240));
    final to = page.renderBox!.localToGlobal(const Offset(540, 360));
    final pen = await tester.startGesture(from, kind: PointerDeviceKind.stylus);
    await pen.moveTo(Offset.lerp(from, to, .5)!);
    await pen.moveTo(to);
    await pen.up();
    await tester.pumpAndSettle();
  }

  /// The lasso as a rectangle that also takes pictures; restored after.
  void lassoSettings() {
    final rectangle = stows.selectRectangle.value;
    final images = stows.selectImages.value;
    final lastTool = stows.lastTool.value;
    final lastPenFamily = stows.lastPenFamily.value;
    stows.selectRectangle.value = true;
    stows.selectImages.value = true;
    addTearDown(() {
      stows.selectRectangle.value = rectangle;
      stows.selectImages.value = images;
      stows.lastTool.value = lastTool;
      stows.lastPenFamily.value = lastPenFamily;
    });
  }

  /// A picture over x 150-350, y 260-340 of the first page, no strokes.
  Future<PngEditorImage> putPicture(
    WidgetTester tester,
    EditorState editor,
  ) async {
    final page = editor.coreInfo.pages.first;
    final photo = PngEditorImage(
      id: editor.coreInfo.nextImageId++,
      assetCache: editor.coreInfo.assetCache,
      extension: '.png',
      imageProvider: MemoryImage(_onePixelPng),
      pageIndex: 0,
      pageSize: page.size,
      onMoveImage: null,
      onDeleteImage: null,
      onMiscChange: null,
      newImage: false,
      dstRect: const Rect.fromLTWH(150, 260, 200, 80),
    );
    page.images.add(photo);
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pump();
    return photo;
  }

  /// Closes the editor: a picture lets its image go 5 s after it leaves the
  /// screen, and that timer must have run by the test's end.
  Future<void> closeWithPictures(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  /// A straight line 40 wide from x 100 to 500 at y 300 of [page].
  Stroke line(EditorPage page) => Stroke(
    color: const Color(0xFF1E88E5),
    pressureEnabled: false,
    options: StrokeOptions(size: 40),
    pageIndex: 0,
    page: page,
    toolId: ToolId.ballpointPen,
  )..addPoints([for (var x = 100.0; x <= 500; x += 20) Offset(x, 300)]);

  testWidgets('old toolbar and the action share one implementation', (
    tester,
  ) async {
    lassoSettings();
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    page.insertStroke(line(page));
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pump();
    final actions = actionsOf(tester);
    final context = tester.element(find.byType(Editor));

    Future<void> lasso() async {
      await lassoAround(tester, editor, actions);
      expect(Select.currentSelect.selectResult.strokes, hasLength(1));
      expect(actions.lookup(AppActionIds.duplicateSelection)!.enabled, isTrue);
    }

    List<Offset> pointsOf(Stroke stroke) => [
      for (final point in stroke.points) Offset(point.x, point.y),
    ];

    expect(actions.lookup(AppActionIds.duplicateSelection)!.enabled, isFalse);
    await lasso();
    await tester.tap(find.byKey(const ValueKey('lasso-bar-duplicate')));
    await tester.pump();
    expect(page.strokes, hasLength(2));
    final byBar = pointsOf(page.strokes.last);
    editor.undo();
    await tester.pump();
    expect(page.strokes, hasLength(1), reason: 'one undo takes the copy back');

    await lasso();
    expect(actions.run(AppActionIds.duplicateSelection, context), isTrue);
    await tester.pump();
    expect(page.strokes, hasLength(2));
    expect(pointsOf(page.strokes.last), byBar);
    editor.undo();
    await tester.pump();
    expect(page.strokes, hasLength(1));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a lasso around pictures only deletes them as one undo step', (
    tester,
  ) async {
    lassoSettings();
    final editor = await mountEditor(tester);
    final photo = await putPicture(tester, editor);
    final actions = actionsOf(tester);
    await lassoAround(tester, editor, actions);
    expect(Select.currentSelect.selectResult.images, [photo]);
    expect(Select.currentSelect.selectResult.strokes, isEmpty);
    final page = editor.coreInfo.pages.first;

    expect(
      actions.run(
        AppActionIds.deleteSelection,
        tester.element(find.byType(Editor)),
      ),
      isTrue,
    );
    await tester.pump();
    expect(page.images, isEmpty);
    editor.undo();
    await tester.pump();
    expect(page.images, [photo], reason: 'one undo puts the picture back');
    editor.cancelAutosaveAndMarkSaved();
    await closeWithPictures(tester);
  });

  testWidgets('a lasso around pictures only has no colour to change', (
    tester,
  ) async {
    lassoSettings();
    final editor = await mountEditor(tester);
    final photo = await putPicture(tester, editor);
    final actions = actionsOf(tester);
    await lassoAround(tester, editor, actions);
    expect(Select.currentSelect.selectResult.images, [photo]);

    expect(actions.lookup(AppActionIds.recolorSelection)!.enabled, isFalse);
    // Run anyway (the old colour bar reaches the same code): nothing breaks.
    actions
        .lookup(AppActionIds.recolorSelection)!
        .run(tester.element(find.byType(Editor)));
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .byWidgetPredicate(
            (widget) =>
                widget.key is ValueKey<String> &&
                (widget.key! as ValueKey<String>).value.startsWith(
                  'kit-swatch-ff',
                ),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(editor.coreInfo.pages.first.images, [photo]);
    expect(editor.history.canUndo, isFalse, reason: 'no colour change kept');
    editor.cancelAutosaveAndMarkSaved();
    await closeWithPictures(tester);
  });

  testWidgets('the pen action brings back the last ink tool', (tester) async {
    final lastTool = stows.lastTool.value;
    final lastPenFamily = stows.lastPenFamily.value;
    stows.lastTool.value = ToolId.fountainPen;
    addTearDown(() {
      stows.lastTool.value = lastTool;
      stows.lastPenFamily.value = lastPenFamily;
    });
    final editor = await mountEditor(tester);
    final actions = actionsOf(tester);
    final context = tester.element(find.byType(Editor));
    Future<void> run(String id) async {
      expect(actions.run(id, context), isTrue, reason: id);
      await tester.pump();
    }

    await run(AppActionIds.toolHighlighter);
    await run(AppActionIds.toolEraser);
    await run(AppActionIds.toolPen);
    expect(editor.currentTool, isA<Highlighter>());
    await run(AppActionIds.toolShapes);
    expect(editor.currentTool, isA<ShapePen>());
    await run(AppActionIds.toolPen);
    expect(
      editor.currentTool,
      isA<Highlighter>(),
      reason: 'the shape pen is not an ink tool',
    );
    await run(AppActionIds.toolText);
    expect(editor.currentTool, Tool.textEditing);
    await run(AppActionIds.toolText);
    expect(editor.currentTool, isA<Highlighter>(), reason: 'out of the text box');
    expect(actions.lookup(AppActionIds.toolHighlighter)!.checked, isTrue);
    expect(actions.lookup(AppActionIds.toolPen)!.checked, isFalse);
    expect(actions.lookup(AppActionIds.toolText)!.checked, isFalse);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the clear page action clears the current page as one undo '
      'step', (tester) async {
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    page.insertStroke(line(page));
    page.insertStroke(line(page));
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pump();
    final actions = actionsOf(tester);
    final clear = actions.lookup(AppActionIds.clearPage);
    expect(clear, isNotNull, reason: 'the eraser window runs it');
    expect(clear!.label, '쪽 비우기');
    expect(
      actions.run(AppActionIds.clearPage, tester.element(find.byType(Editor))),
      isTrue,
    );
    await tester.pump();
    expect(page.strokes, isEmpty);
    editor.undo();
    await tester.pump();
    expect(page.strokes, hasLength(2), reason: 'one undo brings both back');
    editor.cancelAutosaveAndMarkSaved();
  });

  // The tool state goes with the editor: a picture picked after the editor
  // closed takes no lasso up there.
  testWidgets('a picture picked after the editor closed changes nothing', (
    tester,
  ) async {
    final picker = _HeldPicker();
    final previous = FilePickerPlatform.instance;
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = previous);
    final editor = await mountEditor(tester);
    expect(
      actionsOf(tester)
          .run(AppActionIds.pickPhoto, tester.element(find.byType(Editor))),
      isTrue,
    );
    await tester.pump();
    expect(picker.asked, isTrue);
    editor.cancelAutosaveAndMarkSaved();
    await tester.pumpWidget(const SizedBox());
    picker.answer.complete([_PickedPhoto()]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
