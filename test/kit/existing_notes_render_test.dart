import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/_canvas_painter.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/data/editor/page.dart';
import 'package:sbn/tool_id.dart';

const _pageSize = Size(600, 848);
const _photoRect = Rect.fromLTWH(330, 560, 220, 160);

/// A wavy line from [from] to [to], the same every run.
List<(Offset, double)> _wave(Offset from, Offset to, {double amplitude = 14}) {
  const steps = 40;
  return [
    for (var i = 0; i <= steps; i++)
      (
        Offset.lerp(from, to, i / steps)! +
            Offset(0, amplitude * sin(i / steps * 4 * pi)),
        0.3 + 0.5 * sin(i / steps * pi),
      ),
  ];
}

Stroke _stroke(
  EditorPage page,
  ToolId toolId,
  Color color,
  StrokeOptions options,
  List<(Offset, double)> points, {
  bool pressureEnabled = true,
}) {
  final stroke = Stroke(
    color: color,
    pressureEnabled: pressureEnabled,
    options: options,
    pageIndex: 0,
    page: page,
    toolId: toolId,
  );
  for (final (point, pressure) in points) {
    stroke.addPoint(point, pressure);
  }
  return stroke;
}

/// A small picture made here, so the test needs no file outside the repo.
Future<Uint8List> _photoBytes() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 44, 32),
    Paint()..color = const Color(0xFF3F7FBF),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 20, 44, 12),
    Paint()..color = const Color(0xFF5FA05F),
  );
  canvas.drawCircle(
    const Offset(32, 9),
    5,
    Paint()..color = const Color(0xFFF2C94C),
  );
  final image = await recorder.endRecording().toImage(44, 32);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await PencilShader.init();
  });

  // The baseline picture was made on Windows: other systems draw text and
  // curves a little differently.
  final skip = !Platform.isWindows;

  testWidgets('existing strokes render the same', (tester) async {
    tester.view.physicalSize = _pageSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final page = EditorPage(size: _pageSize);
    addTearDown(page.dispose);

    final fountain = StrokeOptions(size: 6);
    final ballpoint = StrokeOptions(size: 5);
    final pencil = StrokeOptions(
      size: 5,
      streamline: 0.1,
      start: StrokeEndOptions.start(taperEnabled: true, customTaper: 1),
      end: StrokeEndOptions.end(taperEnabled: true, customTaper: 1),
    );
    final highlighter = StrokeOptions(size: 40);
    final shape = StrokeOptions(size: 5, smoothing: 0, streamline: 0);

    page.strokes.addAll([
      _stroke(
        page,
        ToolId.highlighter,
        const Color(0xFFFFEB3B),
        highlighter,
        _wave(const Offset(60, 330), const Offset(540, 330), amplitude: 6),
        pressureEnabled: false,
      ),
      _stroke(
        page,
        ToolId.fountainPen,
        const Color(0xFF000000),
        fountain,
        _wave(const Offset(60, 90), const Offset(540, 90)),
      ),
      _stroke(
        page,
        ToolId.ballpointPen,
        const Color(0xFF1565C0),
        ballpoint,
        _wave(const Offset(60, 170), const Offset(540, 170)),
      ),
      _stroke(
        page,
        ToolId.pencil,
        const Color(0xFF424242),
        pencil,
        _wave(const Offset(60, 250), const Offset(540, 250)),
      ),
      _stroke(page, ToolId.shapePen, const Color(0xFFC62828), shape, [
        for (final p in const [
          Offset(60, 420),
          Offset(260, 420),
          Offset(260, 520),
          Offset(60, 520),
          Offset(60, 420),
        ])
          (p, 0.5),
      ], pressureEnabled: false),
    ]);

    final bytes = await tester.runAsync(_photoBytes);
    final photo = PngEditorImage(
      id: 0,
      assetCache: AssetCache(),
      extension: '.png',
      imageProvider: MemoryImage(bytes!),
      pageIndex: 0,
      pageSize: _pageSize,
      onMoveImage: null,
      onDeleteImage: null,
      onMiscChange: null,
      newImage: false,
      dstRect: _photoRect,
    );
    page.images.add(photo);

    final theme = ThemeData(useMaterial3: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        debugShowCheckedModeBanner: false,
        home: Center(
          child: RepaintBoundary(
            key: const ValueKey('render-under-test'),
            child: SizedBox.fromSize(
              size: _pageSize,
              // Same layering as InnerCanvas: images under, strokes over.
              child: CustomPaint(
                foregroundPainter: CanvasPainter(
                  invert: false,
                  strokes: page.strokes,
                  laserStrokes: page.laserStrokes,
                  currentStroke: null,
                  currentSelection: null,
                  primaryColor: theme.colorScheme.primary,
                  page: page,
                  showPageIndicator: false,
                  pageIndex: 0,
                  totalPages: 1,
                  currentScale: 1,
                  defaultTextStyle: theme.textTheme.bodyMedium!,
                ),
                child: ColoredBox(
                  color: Colors.white,
                  child: Stack(
                    children: [
                      Positioned.fromRect(
                        rect: _photoRect,
                        child: Builder(
                          builder: (context) => photo.buildImageWidget(
                            context: context,
                            overrideBoxFit: null,
                            isBackground: false,
                            invert: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => photo.precache(tester.element(find.byType(Stack).first)),
    );
    await tester.pump();

    await expectLater(
      find.byKey(const ValueKey('render-under-test')),
      matchesGoldenFile('goldens/existing_notes_page1.png'),
    );
  }, skip: skip);
}
