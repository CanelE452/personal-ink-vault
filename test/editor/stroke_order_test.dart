import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bson/bson.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:sbn/has_size.dart';
import 'package:sbn/tool_id.dart';
import 'package:worker_manager/worker_manager.dart';

import '../ink/legacy_notes.dart';
import '../utils/test_mock_channel_handlers.dart';

/// The order strokes are drawn in. Notes up to version 20 without the note
/// key 'so' open grouped by tool, as build 234 shows them, and an untouched
/// one saves the same bytes. Version 21 notes and notes with 'so' keep the
/// file's order; 'so' is written only when a page's order differs from what
/// opening it the old way gives, and it never raises the version.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  final bundle = Directory('test/ink/legacy');
  late Directory temp;

  setUp(() async {
    setupMockPathProvider();
    temp = await Directory.systemTemp.createTemp('piv-stroke-order-');
    EditorImage.shouldLoadOutImmediately = true;
    await FileManager.init(
      documentsDirectory: '${temp.path}/working',
      shouldWatchRootDirectory: false,
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Uint8List bytesOf(String file) =>
      Uint8List.fromList(File('${bundle.path}/$file').readAsBytesSync());

  /// Copies the legacy note's files into the documents folder and opens it.
  Future<EditorCoreInfo> open(String name, {bool isolate = false}) async {
    final dir = Directory('${FileManager.documentsDirectory}/legacy');
    await dir.create(recursive: true);
    for (final file in bundle.listSync().whereType<File>()) {
      final base = file.uri.pathSegments.last;
      if (base == '$name.sbn2' ||
          RegExp('^$name\\.sbn2\\.\\d+\$').hasMatch(base)) {
        await File('${dir.path}/$base').writeAsBytes(file.readAsBytesSync());
      }
    }
    return EditorCoreInfo.loadFromFileContents(
      bsonBytes: bytesOf('$name.sbn2'),
      path: '/legacy/$name',
      onlyFirstPage: false,
      alwaysUseIsolate: isolate,
    );
  }

  Future<EditorCoreInfo> reopen(EditorCoreInfo core) {
    final (bson, _) = core.saveToBinary(currentPageIndex: null);
    return EditorCoreInfo.loadFromFileContents(
      bsonBytes: bson,
      path: '/stroke-order/reopened',
      onlyFirstPage: false,
    );
  }

  Uint8List savedBytes(EditorCoreInfo core) {
    final (json, _) = core.toJson();
    return BsonCodec.serialize(json).byteList;
  }

  /// A short straight line at [y], so the strokes can be told apart.
  Stroke strokeOf(
    EditorPage page,
    ToolId tool,
    double y, {
    int color = 0xFF000000,
    StrokeStyle style = const StrokeStyle(),
  }) {
    final stroke =
        Stroke(
            color: Color(color),
            pressureEnabled: false,
            options: StrokeOptions(size: 5, streamline: 0),
            pageIndex: 0,
            page: page,
            toolId: tool,
          )
          ..addPoints([for (var i = 0; i <= 10; i++) Offset(40 + 10.0 * i, y)])
          ..style = style;
    stroke.options.isComplete = true;
    return stroke;
  }

  List<double> ysOf(EditorPage page) => [
    for (final stroke in page.strokes) stroke.points.first.y,
  ];

  String fingerprint(Stroke s) =>
      '${s.runtimeType} ${s.toolId.id} ${s.color.toARGB32()} '
      '${s.points.length} ${s.points.firstOrNull}';

  /// Each page's strokes, in the order build 234's code opened them (the
  /// `.saved.sbn2` of the legacy bundle, read without sorting).
  List<List<String>> baselineOrder(String name) {
    final json = BsonCodec.deserialize(
      BsonBinary.from(bytesOf('$name.saved.sbn2')),
    );
    return [
      for (final page in (json['z'] as List).cast<Map>())
        [
          for (final stroke in EditorPage.parseStrokesJson(
            page['s'] as List?,
            page: HasSize(
              Size(
                (page['w'] as num).toDouble(),
                (page['h'] as num).toDouble(),
              ),
            ),
            onlyFirstPage: false,
            fileVersion: json['v'] as int,
          ))
            fingerprint(stroke),
        ],
    ];
  }

  List<List<String>> orderOf(EditorCoreInfo core) => [
    for (final page in core.pages)
      [for (final s in page.strokes) fingerprint(s)],
  ];

  test('a pencil stroke drawn after a pen stroke stays above it after save and '
      'reopen', () async {
    final core = EditorCoreInfo(filePath: '/stroke-order/pencil-over-pen');
    final page = EditorPage();
    core.pages.add(page);
    page.insertStroke(strokeOf(page, ToolId.ballpointPen, 100));
    page.insertStroke(strokeOf(page, ToolId.pencil, 200));
    expect(ysOf(page), [100, 200]);
    final (json, _) = core.toJson();
    expect(json['v'], 19);
    expect(json['so'], 1);
    final reopened = await reopen(core);
    expect(ysOf(reopened.pages.first), [100, 200]);
    reopened.dispose();
    core.dispose();
  });

  test('an untouched old note writes no so key', () async {
    for (final name in legacyNoteNames) {
      final core = await open(name);
      final (json, _) = core.toJson();
      expect(json.containsKey('so'), isFalse, reason: name);
      expect(savedBytes(core), bytesOf('$name.saved.sbn2'), reason: name);
      core.dispose();
    }
  });

  test('forty_strokes opened and saved untouched writes no so key', () async {
    final core = await open('forty_strokes');
    expect(core.pages.first.strokes, hasLength(48));
    final (json, _) = core.toJson();
    expect(json.containsKey('so'), isFalse);
    expect(savedBytes(core), bytesOf('forty_strokes.saved.sbn2'));
    core.dispose();
  });

  test('lasso_duplicated opens grouped by tool as 234 shows it', () async {
    final core = await open('lasso_duplicated');
    expect(orderOf(core), baselineOrder('lasso_duplicated'));
    final strokes = core.pages.first.strokes;
    for (var i = 1; i < strokes.length; i++) {
      expect(
        strokes[i - 1].toolId.id.compareTo(strokes[i].toolId.id),
        lessThanOrEqualTo(0),
        reason: 'stroke $i is grouped with its tool',
      );
    }
    core.dispose();
  });

  test('forty_colours keeps its baseline order', () async {
    final core = await open('forty_colours');
    expect(orderOf(core), baselineOrder('forty_colours'));
    core.dispose();
  });

  test('legacy notes keep their order', () async {
    for (final name in legacyNoteNames) {
      final core = await open(name);
      expect(orderOf(core), baselineOrder(name), reason: name);
      core.dispose();
    }
  });

  test('the so key alone keeps the note v19', () async {
    final core = await open('tools_five');
    final page = core.pages.first;
    // Only the order changes: a pen stroke goes on top of the others.
    final pen = page.strokes.firstWhere((s) => s.toolId != ToolId.highlighter);
    page.strokes
      ..remove(pen)
      ..add(pen);
    final order = orderOf(core);
    final (json, _) = core.toJson();
    expect(json['so'], 1);
    expect(json['v'], 19);
    final reopened = await reopen(core);
    expect(orderOf(reopened), order);
    reopened.dispose();
    core.dispose();
  });

  test('a v21 file keeps its file order', () async {
    final core = EditorCoreInfo(filePath: '/stroke-order/v21');
    final page = EditorPage();
    core.pages.add(page);
    page.strokes.addAll([
      strokeOf(page, ToolId.ballpointPen, 100),
      strokeOf(page, ToolId.pencil, 200),
      strokeOf(page, ToolId.brush, 300),
    ]);
    expect(core.versionToWrite(), 21);
    final reopened = await reopen(core);
    expect(ysOf(reopened.pages.first), [100, 200, 300]);
    reopened.dispose();
    core.dispose();
  });

  test(
    'a mixed-tool v21 note opened and saved untouched writes no so key',
    () async {
      final made = EditorCoreInfo(filePath: '/stroke-order/v21-untouched');
      final page = EditorPage();
      made.pages.add(page);
      // In drawn order, which the old grouping by tool would change.
      page.strokes.addAll([
        strokeOf(page, ToolId.ballpointPen, 100),
        strokeOf(page, ToolId.pencil, 200),
        strokeOf(page, ToolId.brush, 300),
        strokeOf(page, ToolId.fountainPen, 400),
      ]);
      // The note ends with an empty page, as the editor saves it.
      made.pages.add(EditorPage());
      final (bytes, _) = made.saveToBinary(currentPageIndex: null);
      final opened = await EditorCoreInfo.loadFromFileContents(
        bsonBytes: bytes,
        path: '/stroke-order/v21-opened',
        onlyFirstPage: false,
      );
      expect(ysOf(opened.pages.first), [100, 200, 300, 400]);
      final (json, _) = opened.toJson();
      expect(json['v'], 21);
      expect(json.containsKey('so'), isFalse);
      expect(savedBytes(opened), bytes);
      opened.dispose();
      made.dispose();
    },
  );

  test('insertStroke puts a highlighter at the end of its colour and opacity '
      'group', () {
    final page = EditorPage();
    const yellow = 0x64FFEB3B, green = 0x644CAF50;
    page.insertStroke(strokeOf(page, ToolId.ballpointPen, 10));
    page.insertStroke(strokeOf(page, ToolId.highlighter, 20, color: yellow));
    page.insertStroke(
      strokeOf(
        page,
        ToolId.highlighter,
        30,
        color: yellow,
        style: const StrokeStyle(alpha: 50),
      ),
    );
    page.insertStroke(strokeOf(page, ToolId.highlighter, 40, color: green));
    expect(ysOf(page), [40, 30, 20, 10]);
    page.insertStroke(strokeOf(page, ToolId.highlighter, 50, color: yellow));
    expect(ysOf(page), [40, 30, 20, 50, 10]);
    page.insertStroke(strokeOf(page, ToolId.pencil, 60));
    expect(ysOf(page), [40, 30, 20, 50, 10, 60]);
    page.dispose();
  });

  test(
    'a page added after opening with a pencil over a pen writes so',
    () async {
      final core = await open('tools_five');
      final page = EditorPage(size: core.pages.first.size);
      core.pages.insert(1, page);
      page.updatePageIndex(1);
      for (var i = 2; i < core.pages.length; i++) {
        core.pages[i].updatePageIndex(i);
      }
      page.insertStroke(strokeOf(page, ToolId.ballpointPen, 100));
      page.insertStroke(strokeOf(page, ToolId.pencil, 200));
      final (json, _) = core.toJson();
      expect(json['so'], 1);
      expect(json['v'], 19);
      final reopened = await reopen(core);
      expect(ysOf(reopened.pages[1]), [100, 200]);
      reopened.dispose();
      core.dispose();
    },
  );

  test('a note opened with so and saved untouched keeps so', () async {
    final made = EditorCoreInfo(filePath: '/stroke-order/so');
    final page = EditorPage();
    made.pages.add(page);
    page.strokes.addAll([
      strokeOf(page, ToolId.ballpointPen, 100),
      strokeOf(page, ToolId.pencil, 200),
    ]);
    final (madeJson, _) = made.toJson();
    madeJson['so'] = 1;
    final opened = await EditorCoreInfo.loadFromFileContents(
      bsonBytes: BsonCodec.serialize(madeJson).byteList,
      path: '/stroke-order/so-opened',
      onlyFirstPage: false,
    );
    expect(ysOf(opened.pages.first), [100, 200]);
    final (json, _) = opened.toJson();
    expect(json['so'], 1);
    expect(json['v'], 19);
    final reopened = await reopen(opened);
    expect(ysOf(reopened.pages.first), [100, 200]);
    reopened.dispose();
    opened.dispose();
    made.dispose();
  });

  test('a new page with forty pen strokes in drawn order writes so', () async {
    final core = EditorCoreInfo(filePath: '/stroke-order/forty-pens');
    final page = EditorPage();
    core.pages.add(page);
    for (var i = 0; i < 40; i++) {
      page.insertStroke(strokeOf(page, ToolId.fountainPen, 20.0 + i * 30));
    }
    final drawn = ysOf(page);
    expect(drawn, [for (var i = 0; i < 40; i++) 20.0 + i * 30]);
    final (json, _) = core.toJson();
    expect(json['so'], 1);
    expect(json['v'], 19);
    final reopened = await reopen(core);
    expect(ysOf(reopened.pages.first), drawn);
    reopened.dispose();
    core.dispose();
  });

  test('a big note opened on another isolate writes no so key', () async {
    final EditorCoreInfo core;
    try {
      core = await open(
        'forty_strokes',
        isolate: true,
      ).timeout(const Duration(seconds: 60));
    } on TimeoutException catch (error) {
      // Only a worker that never answers is a skip; any other error fails.
      await workerManager.dispose();
      markTestSkipped('the worker isolate did not run here: $error');
      return;
    } catch (_) {
      await workerManager.dispose();
      rethrow;
    }
    try {
      expect(core.pages.first.strokes, hasLength(48));
      final (json, _) = core.toJson();
      expect(json.containsKey('so'), isFalse);
      // Not the bytes: the worker sets the stroke defaults the app sets at
      // start (StrokeOptionsExtension.setDefaults), this test's isolate not.
      expect(orderOf(core), baselineOrder('forty_strokes'));
      core.dispose();
    } finally {
      await workerManager.dispose();
    }
  });
}
