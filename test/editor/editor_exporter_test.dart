import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:sbn/has_size.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  Stroke stroke(ToolId tool, [StrokeStyle style = const StrokeStyle()]) =>
      Stroke(
        color: Stroke.defaultColor,
        pressureEnabled: true,
        options: StrokeOptions(size: 6),
        pageIndex: 0,
        page: const HasSize(Size(100, 100)),
        toolId: tool,
        style: style,
      )..addPoint(const Offset(5, 5), 0.5);

  test('pdf export rasterizes dash, chisel and opacity strokes and keeps old '
      'strokes as vectors', () {
    bool raster(ToolId tool, [StrokeStyle style = const StrokeStyle()]) =>
        EditorExporter.shouldRasterizeStroke(stroke(tool, style));

    // old strokes stay vectors
    expect(raster(ToolId.fountainPen), isFalse);
    expect(raster(ToolId.ballpointPen), isFalse);
    expect(raster(ToolId.shapePen), isFalse);
    // the old rasterised ones still are
    expect(raster(ToolId.highlighter), isTrue);
    expect(raster(ToolId.pencil), isTrue);
    // dash and dot
    expect(
      raster(
        ToolId.ballpointPen,
        const StrokeStyle(lineStyle: KitPenDash.dash),
      ),
      isTrue,
    );
    expect(
      raster(ToolId.ballpointPen, const StrokeStyle(lineStyle: KitPenDash.dot)),
      isTrue,
    );
    // the thin line is a vector with a thinner width
    expect(
      raster(
        ToolId.ballpointPen,
        const StrokeStyle(lineStyle: KitPenDash.thin),
      ),
      isFalse,
    );
    // an opacity other than the pen's default
    expect(raster(ToolId.fountainPen, const StrokeStyle(alpha: 128)), isTrue);
    expect(raster(ToolId.fountainPen, const StrokeStyle(alpha: 255)), isFalse);
    // wide nibs: the calligraphy pen and the flat highlighter
    expect(raster(ToolId.calligraphyPen), isTrue);
    expect(
      raster(ToolId.highlighter, const StrokeStyle(nib: InkNib.chisel)),
      isTrue,
    );
    // the brush is a plain outline
    expect(raster(ToolId.brush), isFalse);
  });

  group('the exported pdf', () {
    setupMockPathProvider();
    FlavorConfig.setup();
    setUpAll(() => Future.wait([FileManager.init(), PencilShader.init()]));

    /// The page's pen stroke is added to the pdf as vector graphics when it is
    /// not rasterised, and then its path (a move-to operator, `m`) is in the
    /// page's content stream. Returns whether that stream draws a path.
    Future<bool> hasVectorFill(WidgetTester tester, Stroke stroke) async {
      final page = EditorPage(size: const Size(200, 200));
      addTearDown(page.dispose);
      page.strokes.add(stroke);
      final core = EditorCoreInfo(filePath: '/pdf')..pages.add(page);

      final completer = Completer<BuildContext>();
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                if (!completer.isCompleted) completer.complete(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final context = await completer.future;
      final bytes = await tester.runAsync(() async {
        final doc = await EditorExporter.generatePdf(core, context);
        return doc.save();
      });
      var content = '';
      final raw = latin1.decode(bytes!);
      for (final m in RegExp(r'(?<!end)stream\r?\n').allMatches(raw)) {
        final end = raw.indexOf('endstream', m.end);
        final body = bytes.sublist(m.end, end);
        try {
          final text = latin1.decode(zlib.decode(body));
          // the page's content stream: the picture and the clip, then paths
          if (text.contains(' re W n')) content += text;
        } on Object {
          // not deflated: an image or a font
        }
      }
      return RegExp(r'\d m\s').hasMatch(content);
    }

    testWidgets('keeps an old pen stroke as a vector, not a dashed one', (
      tester,
    ) async {
      final old = stroke(ToolId.fountainPen);
      final dashed = stroke(
        ToolId.ballpointPen,
        const StrokeStyle(lineStyle: KitPenDash.dash),
      );
      for (final s in [old, dashed]) {
        s.addPoint(const Offset(60, 60), 0.5);
        s.addPoint(const Offset(150, 150), 0.5);
      }
      expect(await hasVectorFill(tester, old), isTrue);
      expect(await hasVectorFill(tester, dashed), isFalse);
    });

    testWidgets('the raster copy of a page holds the new strokes, not the '
        'old one', (tester) async {
      final page = EditorPage(size: const Size(200, 200));
      addTearDown(page.dispose);
      final old = stroke(ToolId.fountainPen);
      final dashed = stroke(
        ToolId.ballpointPen,
        const StrokeStyle(lineStyle: KitPenDash.dash),
      );
      final chisel = stroke(ToolId.calligraphyPen);
      final faded = stroke(ToolId.fountainPen, const StrokeStyle(alpha: 128));
      page.strokes.addAll([old, dashed, chisel, faded]);

      final copy = page.cloneForRasterization();
      addTearDown(copy.disposeClonedData);
      expect(copy.strokes, [dashed, chisel, faded]);
    });
  });
}
