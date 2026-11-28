import 'package:bson/bson.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/read_only_reason.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// A note is written as 21 only when it holds a pen engine value that 233 and
/// older apps would drop on their next save; every other note stays 19 or 20.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  StrokeOptionsExtension.setDefaults();

  setUp(() async {
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    await FileManager.init();
  });
  tearDown(() => Pen.currentStroke = null);

  Pen penOf(ToolId tool) => Pen(
    name: 'test',
    sizeMin: 1,
    sizeMax: 25,
    sizeStep: 1,
    icon: Pen.ballpointPenIcon,
    options: StrokeOptions(size: 5, streamline: 0),
    pressureEnabled: false,
    color: Colors.black,
    toolId: tool,
  );

  Stroke strokeOf(
    EditorPage page, {
    ToolId tool = ToolId.ballpointPen,
    StrokeStyle style = const StrokeStyle(),
  }) {
    final stroke = penOf(tool).createStroke(page, 0);
    for (var i = 0; i <= 10; i++) {
      stroke.addPoint(Offset(40 + 10.0 * i, 60), null);
    }
    stroke
      ..options.isComplete = true
      ..style = style
      ..markPolygonNeedsUpdating();
    return stroke;
  }

  EditorCoreInfo noteWith(
    List<Stroke Function(EditorPage)> makers, {
    CanvasBackgroundPattern? pagePattern,
  }) {
    final core = EditorCoreInfo(filePath: '/version-21/note')
      ..backgroundPattern = CanvasBackgroundPattern.lined;
    final page = EditorPage(backgroundPattern: pagePattern);
    for (final make in makers) {
      page.insertStroke(make(page));
    }
    core.pages.add(page);
    return core;
  }

  Future<EditorCoreInfo> reopen(EditorCoreInfo core) async {
    final (bson, _) = core.saveToBinary(currentPageIndex: null);
    return EditorCoreInfo.loadFromFileContents(
      bsonBytes: bson,
      path: '/version-21/reopened',
      onlyFirstPage: false,
    );
  }

  test('one stroke with op 128 makes the note v21', () {
    final core = noteWith([
      (page) => strokeOf(page, style: const StrokeStyle(alpha: 128)),
    ]);
    expect(core.versionToWrite(), 21);
    final (json, _) = core.toJson();
    expect(json['v'], 21);
    final stroke = ((json['z'] as List).single['s'] as List).single as Map;
    expect(stroke['op'], 128);
    core.dispose();
  });

  test('a brush stroke makes the note v21', () {
    final core = noteWith([(page) => strokeOf(page, tool: ToolId.brush)]);
    expect(core.versionToWrite(), 21);
    final calligraphy = noteWith([
      (page) => strokeOf(page, tool: ToolId.calligraphyPen),
    ]);
    expect(calligraphy.versionToWrite(), 21);
    core.dispose();
    calligraphy.dispose();
  });

  test('a chisel highlighter stroke makes the note v21', () {
    final core = noteWith([
      (page) => strokeOf(
        page,
        tool: ToolId.highlighter,
        style: const StrokeStyle(nib: InkNib.chisel),
      ),
    ]);
    expect(core.versionToWrite(), 21);
    core.dispose();
  });

  test('a page with its own pattern and a brush stroke is v21', () {
    final core = noteWith([
      (page) => strokeOf(page, tool: ToolId.brush),
    ], pagePattern: CanvasBackgroundPattern.dots);
    expect(core.pages.single.hasOwnPattern(core.backgroundPattern), isTrue);
    expect(core.versionToWrite(), 21);
    core.dispose();
  });

  test('a page with its own pattern only is v20', () {
    final core = noteWith([
      (page) => strokeOf(page),
    ], pagePattern: CanvasBackgroundPattern.dots);
    expect(core.versionToWrite(), 20);
    expect(EditorCoreInfo.pagePatternVersion, 20);
    core.dispose();
  });

  test('a note with no new values is v19', () {
    final core = noteWith([
      (page) => strokeOf(page),
      (page) => strokeOf(
        page,
        tool: ToolId.highlighter,
        style: const StrokeStyle(alpha: 100),
      ),
      (page) => strokeOf(page, tool: ToolId.pencil),
    ]);
    expect(core.versionToWrite(), 19);
    final (json, _) = core.toJson();
    expect(json['v'], 19);
    core.dispose();
  });

  // Note key 'so' (the drawing order mark) is excluded from the version
  // calculation: it never raises the version. Its test, `the so key alone
  // keeps the note v19`, is in stroke_order_test.dart (task 9), the task that
  // writes 'so'; here an unknown key is dropped on reading, so it would pass
  // by itself.
  test('every key outside the v19 and v20 lists makes the note v21', () {
    final styles = <StrokeStyle>[
      const StrokeStyle(alpha: 128),
      const StrokeStyle(lineStyle: KitPenDash.dash),
      const StrokeStyle(nib: InkNib.chisel),
      const StrokeStyle(nibAngle: 30),
    ];
    final newKeys = <String>{};
    for (final style in styles) {
      final core = noteWith([
        (page) => strokeOf(page, tool: ToolId.fountainPen, style: style),
      ]);
      final (json, _) = core.toJson();
      final page = (json['z'] as List).single as Map<String, dynamic>;
      final stroke = (page['s'] as List).single as Map<String, dynamic>;
      final outside = stroke.keys.toSet().difference(v20StrokeKeys);
      expect(outside, hasLength(1), reason: '$stroke');
      expect(core.versionToWrite(), 21, reason: '$outside');
      expect(json['v'], 21);
      newKeys.addAll(outside);
      core.dispose();
    }
    expect(newKeys, {'op', 'ls', 'nb', 'na'});

    // a note without new values writes only keys of the v20 lists
    final plain = noteWith([(page) => strokeOf(page)]);
    final (json, _) = plain.toJson();
    final page = (json['z'] as List).single as Map<String, dynamic>;
    expect(v20PageKeys.containsAll(page.keys), isTrue, reason: '$page');
    for (final stroke in (page['s'] as List).cast<Map>()) {
      expect(v20StrokeKeys.containsAll(stroke.keys), isTrue, reason: '$stroke');
    }
    expect(json['v'], 19);
    plain.dispose();
  });

  test('a file at 22 opens as too new; 21 opens writable', () async {
    Future<EditorCoreInfo> read(int version) {
      final core = EditorCoreInfo(filePath: '/version-21/version')
        ..pages.add(EditorPage());
      final (json, _) = core.toJson();
      core.dispose();
      json['v'] = version;
      return EditorCoreInfo.loadFromFileContents(
        bsonBytes: BsonCodec.serialize(json).byteList,
        path: '/version-21/version',
        onlyFirstPage: false,
      );
    }

    expect(EditorCoreInfo.newestSbnVersion, 21);
    final writable = await read(21);
    expect(writable.readOnlyReason, isNull);
    writable.dispose();
    final tooNew = await read(22);
    expect(tooNew.readOnlyReason, ReadOnlyReason.versionTooNew);
    tooNew.dispose();
  });

  test('brush strokes reopen as brush strokes', () async {
    final core = noteWith([
      (page) => strokeOf(
        page,
        tool: ToolId.brush,
        style: const StrokeStyle(alpha: 128, lineStyle: KitPenDash.dot),
      ),
      (page) => strokeOf(
        page,
        tool: ToolId.calligraphyPen,
        style: const StrokeStyle(nib: InkNib.chisel, nibAngle: 30),
      ),
    ]);
    final reopened = await reopen(core);
    expect(reopened.readOnlyReason, isNull);
    final strokes = reopened.pages.first.strokes;
    expect(strokes.map((s) => s.toolId).toSet(), {
      ToolId.brush,
      ToolId.calligraphyPen,
    });
    final brush = strokes.singleWhere((s) => s.toolId == ToolId.brush);
    expect(brush.style.alpha, 128);
    expect(brush.style.lineStyle, KitPenDash.dot);
    final calligraphy = strokes.singleWhere(
      (s) => s.toolId == ToolId.calligraphyPen,
    );
    expect(calligraphy.style.nib, InkNib.chisel);
    expect(calligraphy.style.nibAngle, 30);
    expect(reopened.versionToWrite(), 21);
    core.dispose();
    reopened.dispose();
  });
}
