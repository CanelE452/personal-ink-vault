import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/hover_badge.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/screen_capture.dart';
import '../utils/test_mock_channel_handlers.dart';

/// Writes screenshots to build/screen-review/t16 at device pixel ratio 2:
/// the pen tip badge (Task 16) over the preview's paper, cropped 120 x 90
/// around the tip as the references are (ref-t16-*.png,
/// build/screen-review/t16/ref/make_refs.py): the pen, the eraser and the
/// badge turned left at the right edge (app-t16-*.png); and 문서 개요 under
/// 「읽기 전용」, its buttons dimmed (app-t14-pagemanager-locked.png). Runs only
/// with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t16');
const _latin = captureLatin;
const _korean = captureKorean;

/// The preview's page: `--paper` with a 1px `--paper-grid` line every 22.
class _Paper extends CustomPainter {
  const new();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfffbf8ef),
    );
    final grid = Paint()..color = const Color(0xffece4cd);
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 22) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), grid);
    }
  }

  @override
  bool shouldRepaint(_Paper old) => false;
}

/// Paints [boundary] with shadows at ratio 2 and writes [crop] of it (in
/// logical px; the whole of it when null) to [file].
Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String file, {
  Rect? crop,
}) async {
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
      var image = await object.toImage(pixelRatio: 2);
      if (crop != null) {
        final source = Rect.fromLTRB(
          crop.left * 2,
          crop.top * 2,
          crop.right * 2,
          crop.bottom * 2,
        );
        final recorder = ui.PictureRecorder();
        Canvas(recorder)
            .drawImageRect(image, source, Offset.zero & source.size, Paint());
        final cut = await recorder.endRecording().toImage(
          source.width.round(),
          source.height.round(),
        );
        image.dispose();
        image = cut;
      }
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$file').writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

void main() {
  FlavorConfig.setup();

  /// The preview's page (586 x 734) with the badge for [icon], the pen
  /// hovering at [tip].
  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required KitIconName icon,
    required Offset tip,
  }) async {
    const size = Size(586, 734);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = HoverBadgeController();
    addTearDown(controller.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MediaQuery(
          data: const MediaQueryData(size: size, devicePixelRatio: 2),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                Positioned.fill(
                  child: HoverBadgeListener(
                    controller: controller,
                    child: const CustomPaint(
                      painter: _Paper(),
                      child: SizedBox.expand(),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: KitHoverBadge(controller: controller, toolIcon: icon),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.addPointer(location: tip - const Offset(4, 4));
    await pen.moveTo(tip);
    await tester.pump();
    expect(find.byKey(const ValueKey('kit-hover-badge')), findsOneWidget);
    // the references' crop: 120 x 90, the tip 60 from its left and top
    await _write(
      tester,
      boundary,
      'app-t16-$name.png',
      crop: Rect.fromLTWH(tip.dx - 60, tip.dy - 60, 120, 90),
    );
    await pen.removePointer();
  }

  group('pen tip badge captures', skip: !_capture, () {
    // the preview's place: the dot (430, 640), so the tip (436, 646)
    testWidgets('pen', (tester) {
      return shoot(
        tester,
        'pen',
        icon: KitIconName.pen,
        tip: const Offset(436, 646),
      );
    });
    testWidgets('eraser', (tester) {
      return shoot(
        tester,
        'eraser',
        icon: KitIconName.eraser,
        tip: const Offset(436, 646),
      );
    });
    // 5 from the right edge: the badge goes to the tip's left
    testWidgets('right', (tester) {
      return shoot(
        tester,
        'right',
        icon: KitIconName.pen,
        tip: const Offset(581, 646),
      );
    });

    // Task 14: 문서 개요 under 「읽기 전용」, a real editor with two pages
    testWidgets('page manager locked', (tester) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      setupMockPathProvider();
      setupMockPrinting();
      setupMockWindowManager();
      await FileManager.init();
      await tester.runAsync(loadCaptureFonts);
      final lastTool = stows.lastTool.value;
      stows.lastTool.value = ToolId.fountainPen;
      addTearDown(() => stows.lastTool.value = lastTool);
      const size = Size(586, 46 + 734);
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
                path: '/t16-page-manager-locked',
                customTitle: '강의노트 3주차',
                showDocumentHeader: false,
                onSaveSnapshot: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor = tester.state<EditorState>(find.byType(Editor));
      // two pages: the first is not the empty last one, so only the lock
      // dims its buttons
      editor.createPage(1);
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pumpAndSettle();
      final actions = tester
          .widget<AppActionScope>(find.byType(AppActionScope))
          .notifier!;
      final context = tester.element(find.byType(Editor));
      actions.run(AppActionIds.readOnly, context);
      await tester.pumpAndSettle(const Duration(seconds: 3));
      expect(editor.inkLocked.value, isTrue);
      actions.run(AppActionIds.pageList, context);
      await tester.pumpAndSettle();
      expect(find.text('문서 개요'), findsWidgets);
      await _write(tester, boundary, 'app-t14-pagemanager-locked.png');
      editor.cancelAutosaveAndMarkSaved();
    });
  });
}
