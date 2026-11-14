import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/card_canvas_raster.dart';
import 'package:saber/pages/workspace/card_canvas.dart';

void main() {
  test('JSON Canvas preserves unknown nested fields and original geometry while editing a node', () {
    final raw = <String, dynamic>{
      'application': {
        'future': [
          1,
          {'keep': true},
        ],
      },
      'nodes': [
        {
          'id': 'n1',
          'type': 'text',
          'x': -300,
          'y': 20,
          'width': 280,
          'height': 180,
          'text': '메모',
          'future': {
            'nested': [2, 3],
          },
        },
        {
          'id': 'future',
          'type': 'future-type',
          'x': 20,
          'y': 20,
          'width': 100,
          'height': 100,
          'opaque': {'payload': '보존'},
        },
      ],
      'edges': [
        {
          'id': 'e1',
          'fromNode': 'n1',
          'toNode': 'future',
          'fromSide': 'top',
          'toEnd': 'none',
          'future': [4],
        },
      ],
    };
    final doc = CardCanvasDocument.fromJson(raw);
    final moved = doc.copyWith(
      nodes: [
        doc.nodes.first.copyWith(x: -500, text: '수정'),
        doc.nodes.last,
      ],
    );
    final encoded = moved.toJson();
    expect(encoded['application'], {
      'future': [
        1,
        {'keep': true},
      ],
    });
    expect((encoded['nodes'] as List)[0], {
      'id': 'n1',
      'type': 'text',
      'x': -500,
      'y': 20,
      'width': 280,
      'height': 180,
      'text': '수정',
      'future': {
        'nested': [2, 3],
      },
    });
    expect((encoded['nodes'] as List)[1], raw['nodes'][1]);
    expect(encoded['edges'], raw['edges']);
    (encoded['application'] as Map)['future'].clear();
    expect(doc.toJson()['application'], {
      'future': [
        1,
        {'keep': true},
      ],
    });
    expect(
      CardCanvasDocument.fromJson(jsonDecode(jsonEncode(moved.toJson())))
          .nodes
          .first
          .x,
      -500,
    );
  });

  test('viewport zoom keeps its focal world point and coordinates have no page boundary', () {
    const view = CardCanvasViewport(offset: Offset(50, 100), scale: 2);
    const world = Offset(-1000000, 500);
    expect(view.screenToWorld(view.worldToScreen(world)), world);
    final zoom = view.zoomAt(const Offset(80, 120), 3);
    expect(
      zoom.screenToWorld(const Offset(80, 120)),
      view.screenToWorld(const Offset(80, 120)),
    );
    expect(view.pan(const Offset(-10000000, 0)).offset.dx, -9999950);
  });

  test(
    'file-card bindings and safe navigation preserve original Canvas fields',
    () {
      const id = '11111111-1111-4111-8111-111111111111';
      final raw = <String, dynamic>{
        'id': 'file-card',
        'type': 'file',
        'file': 'Notes/Café.md',
        'subpath': '#^example',
        'inkVaultNoteId': id,
        'x': 0,
        'y': 0,
        'width': 200,
        'height': 100,
        'future': {'keep': true},
      };
      final node = CardCanvasNode.fromJson(raw);
      expect(node.linkedNoteId, id);
      expect(node.file, 'Notes/Café.md');
      expect(node.subpath, '#^example');
      expect(node.copyWith(x: 4).toJson(), {...raw, 'x': 4});
      final legacy = {...raw, 'file': id}..remove('inkVaultNoteId');
      expect(CardCanvasNode.fromJson(legacy).linkedNoteId, id);
      expect(
        CardCanvasNode.fromJson({...legacy, 'inkVaultNoteId': null})
            .linkedNoteId,
        isNull,
      );
      expect(
        CardCanvasNode.fromJson({...legacy, 'inkVaultNoteId': 42}).linkedNoteId,
        isNull,
      );
      expect(
        CardCanvasNode.fromJson({...raw, 'subpath': '#\n'}).subpath,
        isNull,
      );
      final link = {
        ...raw,
        'type': 'link',
        'url': 'https://example.invalid/path',
      };
      expect(CardCanvasNode.fromJson(link).safeUrl, link['url']);
      expect(CardCanvasNode.fromJson(link).linkedNoteId, isNull);
      expect(CardCanvasNode.fromJson(link).subpath, isNull);
      for (final url in [
        'file:///private.txt',
        'https://example.invalid@other.invalid',
        'https://example.invalid/\n',
      ]) {
        expect(CardCanvasNode.fromJson({...link, 'url': url}).safeUrl, isNull);
      }
    },
  );

  test('duplicate IDs and invalid nonfinite geometry are rejected', () {
    final node = {
      'id': 'a',
      'type': 'text',
      'x': 0,
      'y': 0,
      'width': 200,
      'height': 100,
      'text': '',
    };
    expect(
      () => CardCanvasDocument.fromJson({
        'nodes': [node, node],
      }),
      throwsFormatException,
    );
    expect(
      () => CardCanvasNode.fromJson({...node, 'x': double.infinity}),
      throwsFormatException,
    );
  });

  Future<GlobalKey<CardCanvasState>> mount(
    WidgetTester tester, {
    CardCanvasDocument initial = const CardCanvasDocument.empty(),
    Future<void> Function(CardCanvasDocument)? save,
    ValueChanged<bool>? dirty,
    ValueChanged<bool>? busy,
    VoidCallback? back,
    ValueChanged<String>? open,
    ValueChanged<CardCanvasNode>? openFile,
    ValueChanged<String>? openExternal,
    List<CardCanvasNote> notes = const [],
    bool fitOnFirstLayout = false,
    Future<void> Function(CardCanvasViewport)? saveViewport,
    Future<CardCanvasRaster?> Function(CardCanvasNode)? loadRaster,
    Object? rasterScope,
    GlobalKey<CardCanvasState>? canvasKey,
  }) async {
    final key = canvasKey ?? GlobalKey<CardCanvasState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CardCanvas(
            key: key,
            initialDocument: initial,
            onSave: save ?? (_) async {},
            onBack: back ?? () {},
            onDirtyChanged: dirty,
            onBusyChanged: busy,
            notes: notes,
            onOpenNote: open,
            onOpenFile: openFile,
            onOpenExternal: openExternal,
            loadRaster: loadRaster,
            rasterScope: rasterScope,
            fitOnFirstLayout: fitOnFirstLayout,
            onSaveViewport: saveViewport,
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    );
    return key;
  }

  Offset point(
    WidgetTester tester,
    CardCanvasState state,
    CardCanvasNode node,
  ) =>
      tester.getTopLeft(find.byKey(const ValueKey('card-canvas-surface'))) +
      state.viewport.worldToScreen(Offset(node.x + 30, node.y + 30));

  testWidgets(
    'Canvas group creation and rename share save, undo and redo on a phone',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      CardCanvasDocument? saved;
      final key = await mount(
        tester,
        save: (document) async => saved = document,
      );

      await tester.tap(find.byTooltip('그룹 추가'));
      await tester.pump();
      final state = key.currentState!;
      final created = state.document.nodes.single;
      expect(created.type, 'group');
      expect(created.label, '제목 없는 그룹');
      expect(created.bounds.isEmpty, isFalse);
      final screenCenter = tester
          .getSize(find.byKey(const ValueKey('card-canvas-surface')))
          .center(Offset.zero);
      expect(
        (state.viewport.worldToScreen(created.bounds.center) - screenCenter)
            .distance,
        lessThan(1),
      );

      await tester.tap(find.text('그룹 이름 바꾸기'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('card-canvas-group-name')),
        '연구 기록',
      );
      await tester.tap(find.text('이름 저장'));
      await tester.pumpAndSettle();
      expect(state.document.nodes.single.label, '연구 기록');
      expect(state.document.nodes.single.id, created.id);
      expect(state.document.nodes.single.bounds, created.bounds);

      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(state.document.nodes.single.label, created.label);
      await tester.ensureVisible(find.byTooltip('다시 실행'));
      await tester.tap(find.byTooltip('다시 실행'));
      await tester.pump();
      expect(state.document.nodes.single.label, '연구 기록');
      await state.save();
      expect(saved!.toJson(), state.document.toJson());
    },
  );

  testWidgets(
    'renaming an imported Canvas group preserves other groups, cards, edges and metadata',
    (tester) async {
      final imported = <String, dynamic>{
        'id': 'imported-group',
        'type': 'group',
        'label': '원래 이름',
        'inkVaultTitle': 'extension metadata',
        'x': 10,
        'y': 10,
        'width': 380,
        'height': 280,
        'background': 'Media/cover.png',
        'backgroundStyle': 'repeat',
        'color': '5',
        'future': {
          'keys': [7, 8],
        },
      };
      final card = CardCanvasNode.text(
        id: 'inside',
        text: 'Card',
        x: 60,
        y: 75,
      );
      final other = {
        ...imported,
        'id': 'other-group',
        'label': '다른 그룹',
        'x': 400,
      };
      final edge = CardCanvasEdge.connect(
        id: 'edge',
        fromNode: 'inside',
        toNode: 'other-group',
      );
      final initial = const CardCanvasDocument.empty().copyWith(
        nodes: [
          card,
          CardCanvasNode.fromJson(imported),
          CardCanvasNode.fromJson(other),
        ],
        edges: [edge],
      );
      var saves = 0;
      final key = await mount(
        tester,
        initial: initial,
        save: (_) async => saves++,
      );
      final state = key.currentState!;
      await tester.tapAt(point(tester, state, initial.nodes[1]));
      await tester.pump();

      await tester.tap(find.text('그룹 이름 바꾸기'));
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('card-canvas-group-name'));
      await tester.enterText(input, '취소할 이름');
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      await state.save();
      expect(saves, 0);
      expect(state.document.toJson(), initial.toJson());

      await tester.tap(find.text('그룹 이름 바꾸기'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: input, matching: find.byType(EditableText)),
            )
            .controller
            .text,
        '원래 이름',
      );
      await tester.tap(find.text('이름 저장'));
      await tester.pumpAndSettle();
      await state.save();
      expect(saves, 0);

      await tester.tap(find.text('그룹 이름 바꾸기'));
      await tester.pumpAndSettle();
      await tester.enterText(input, '새 그룹 이름');
      await tester.tap(find.text('이름 저장'));
      await tester.pumpAndSettle();
      await state.save();
      expect(saves, 1);
      expect(state.document.nodes[1].toJson(), {
        ...imported,
        'label': '새 그룹 이름',
      });
      expect(state.document.nodes.first.toJson(), card.toJson());
      expect(state.document.nodes.last.toJson(), other);
      expect(state.document.edges.single.toJson(), edge.toJson());
      expect(find.text('새 그룹 이름'), findsWidgets);
    },
  );

  CardCanvasNode rasterGroup(
    String id,
    double x, {
    String? style,
    String? path,
  }) => CardCanvasNode.fromJson({
    'id': id,
    'type': 'group',
    'x': x.round(),
    'y': 10,
    'width': 120,
    'height': 88,
    'label': id,
    'background': path ?? 'Media/$id.png',
    'backgroundStyle': ?style,
  });

  final testRaster = CardCanvasRaster(
    bytes: base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAABAAAAAICAIAAAB/FOjAAAAAE0lEQVR4nGNwXVhCEmIY1UALDQBlxK0BwHJ6JAAAAABJRU5ErkJggg==',
    ),
    width: 16,
    height: 8,
  );

  Finder raster(String id) => find.byKey(ValueKey('card-canvas-raster-$id'));

  testWidgets('raster cards and group styles keep the saved geometry', (
    tester,
  ) async {
    const noteId = '11111111-1111-4111-8111-111111111111';
    final initial = const CardCanvasDocument.empty().copyWith(
      nodes: [
        rasterGroup('cover', 10),
        rasterGroup('ratio', 145, style: 'ratio'),
        rasterGroup('repeat', 280, style: 'repeat'),
        rasterGroup('duplicate', 10, path: 'Media/cover.png'),
        CardCanvasNode.note(
          id: 'image',
          noteId: noteId,
          title: 'Photo',
          y: 150,
        ),
      ],
    );
    final requests = <String>[];
    final key = await mount(
      tester,
      initial: initial,
      notes: const [CardCanvasNote(noteId, 'Photo', isRaster: true)],
      loadRaster: (node) async {
        requests.add(node.id);
        return testRaster;
      },
    );
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Image>(raster('cover')).fit, BoxFit.cover);
    expect(tester.widget<Image>(raster('ratio')).fit, BoxFit.contain);
    final repeat = tester.widget<Image>(raster('repeat'));
    expect(repeat.fit, BoxFit.none);
    expect(repeat.repeat, ImageRepeat.repeat);
    expect(repeat.alignment, Alignment.topLeft);
    expect(tester.widget<Image>(raster('image')).fit, BoxFit.contain);
    expect(raster('duplicate'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
    expect(requests, ['cover', 'ratio', 'repeat', 'image']);
    await tester.tap(find.byTooltip('확대'));
    await tester.pump();
    expect(requests, ['cover', 'ratio', 'repeat', 'image']);
    expect(key.currentState!.document.toJson(), initial.toJson());
    expect(find.text('저장됨'), findsOneWidget);
  });

  testWidgets('a changed raster scope discards the previous image and read', (
    tester,
  ) async {
    final key = GlobalKey<CardCanvasState>();
    final initial = const CardCanvasDocument.empty().copyWith(
      nodes: [rasterGroup('cover', 10)],
    );
    final stale = Completer<CardCanvasRaster?>();
    var freshRead = false;
    await mount(
      tester,
      initial: initial,
      canvasKey: key,
      rasterScope: 'before',
      loadRaster: (_) => stale.future,
    );
    await tester.pump();
    await mount(
      tester,
      initial: initial,
      canvasKey: key,
      rasterScope: 'after',
      loadRaster: (_) async {
        freshRead = true;
        return null;
      },
    );
    await tester.pump();
    expect(freshRead, isTrue);
    stale.complete(testRaster);
    await tester.pump();
    await tester.pump();
    expect(raster('cover'), findsNothing);
    expect(find.text('cover'), findsOneWidget);
  });

  testWidgets('repeat paints natural tiles across a very large group', (
    tester,
  ) async {
    const captureKey = ValueKey('canvas-raster-capture');
    final tiled = CardCanvasRaster(
      bytes: base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAFElEQVR4nGP4z8AARwz/caDBLwEACR8/wW1AkEoAAAAASUVORK5CYII=',
      ),
      width: 8,
      height: 8,
    );
    final group = rasterGroup(
      'tiled',
      10,
      style: 'repeat',
    ).copyWith(width: 1000000, height: 1000000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: captureKey,
            child: CardCanvas(
              initialDocument: const CardCanvasDocument.empty().copyWith(
                nodes: [group],
              ),
              onSave: (_) async {},
              onBack: () {},
              loadRaster: (_) async => tiled,
            ),
          ),
        ),
      ),
    );
    final tiles = find.descendant(
      of: raster('tiled'),
      matching: find.byType(CustomPaint),
    );
    for (var retry = 0; retry < 20 && tiles.evaluate().isEmpty; retry++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(tiles, findsOneWidget);
    final capture = find.byKey(captureKey);
    final boundary = tester.renderObject<RenderRepaintBoundary>(capture);
    final offset =
        tester.getTopLeft(find.byKey(const ValueKey('card-canvas-surface'))) -
        tester.getTopLeft(capture);
    final pixels = (await tester.runAsync(() async {
      final result = await boundary.toImage();
      try {
        final data = (await result.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return (data, result.width);
      } finally {
        result.dispose();
      }
    }))!;
    List<int> pixel(int x) {
      final row = (offset.dy + group.y + 48).round();
      final column = (offset.dx + group.x + x).round();
      final index = (row * pixels.$2 + column) * 4;
      return pixels.$1.buffer.asUint8List(index, 4);
    }

    expect(pixel(2), [255, 0, 0, 255]);
    expect(pixel(6), [0, 255, 0, 255]);
    expect(pixel(10), pixel(2));
    expect(pixel(14), pixel(6));
  });

  testWidgets('missing rasters keep captions and distant cards do not load', (
    tester,
  ) async {
    final requests = <String>[];
    await mount(
      tester,
      initial: const CardCanvasDocument.empty().copyWith(
        nodes: [rasterGroup('unavailable', 20), rasterGroup('far', 200000)],
      ),
      loadRaster: (node) async {
        requests.add(node.id);
        throw StateError('Missing attachment');
      },
    );
    await tester.pump();
    await tester.pump();
    expect(requests, ['unavailable']);
    expect(raster('unavailable'), findsNothing);
    expect(find.text('unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a group above a card frames it without blocking its contents', (
    tester,
  ) async {
    final card = CardCanvasNode.text(
      id: 'inside',
      text: 'Inside',
      x: 45,
      y: 70,
    );
    final partial = CardCanvasNode.text(
      id: 'partial',
      text: 'Partly outside',
      x: 370,
      y: 140,
      width: 80,
    );
    final group = CardCanvasNode.fromJson({
      'id': 'group',
      'type': 'group',
      'x': 10,
      'y': 10,
      'width': 380,
      'height': 280,
      'label': 'Study area',
      'color': '5',
    });
    final key = await mount(
      tester,
      initial: const CardCanvasDocument.empty().copyWith(
        nodes: [card, partial, group],
      ),
    );
    final frame = tester.widget<DecoratedBox>(
      find
          .ancestor(
            of: find.text('Study area'),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = frame.decoration as BoxDecoration;
    expect(decoration.color?.a ?? 0, 0);
    expect(decoration.border, isNotNull);

    await tester.tapAt(point(tester, key.currentState!, card));
    await tester.pump();
    expect(find.byKey(const ValueKey('card-canvas-text')), findsOneWidget);
    final state = key.currentState!;
    expect(state.document.nodes.map((node) => node.id), [
      'inside',
      'partial',
      'group',
    ]);
    await tester.dragFrom(point(tester, state, group), const Offset(60, 50));
    await tester.pump();
    expect(state.document.nodes[0].bounds.topLeft, const Offset(105, 120));
    expect(state.document.nodes[1].bounds, partial.bounds);
    expect(state.document.nodes[2].bounds.topLeft, const Offset(70, 60));
    await tester.tap(find.byTooltip('실행 취소'));
    await tester.pump();
    expect(state.document.nodes[0].bounds, card.bounds);
    expect(state.document.nodes[2].bounds, group.bounds);
  });

  testWidgets(
    'unexpected optional edge styles are preserved without crashing',
    (tester) async {
      final initial = CardCanvasDocument.fromJson({
        'nodes': [
          CardCanvasNode.text(id: 'a').toJson(),
          CardCanvasNode.text(id: 'b', x: 300, y: 80).toJson(),
        ],
        'edges': [
          {
            'id': 'edge',
            'fromNode': 'a',
            'toNode': 'b',
            'fromSide': 3,
            'color': false,
            'label': {'future': 'label'},
          },
        ],
      });
      final key = await mount(tester, initial: initial);
      expect(tester.takeException(), isNull);
      expect(key.currentState!.document.toJson(), initial.toJson());
    },
  );

  testWidgets('an imported canvas fits off-screen nodes without editing them', (
    tester,
  ) async {
    final initial = const CardCanvasDocument.empty().copyWith(
      nodes: [
        CardCanvasNode.text(id: 'a', text: 'First', x: -3000, y: 1600),
        CardCanvasNode.text(id: 'b', text: 'Second', x: -1800, y: 2100),
      ],
    );
    final key = await mount(tester, initial: initial, fitOnFirstLayout: true);
    await tester.pump();
    final state = key.currentState!;
    final size = tester.getSize(
      find.byKey(const ValueKey('card-canvas-surface')),
    );
    final surface = Offset.zero & size;
    for (final node in initial.nodes) {
      expect(
        surface.contains(state.viewport.worldToScreen(node.bounds.topLeft)),
        isTrue,
      );
      expect(
        surface.contains(state.viewport.worldToScreen(node.bounds.bottomRight)),
        isTrue,
      );
    }
    expect(state.document.toJson(), initial.toJson());
    expect(find.text('저장됨'), findsOneWidget);
  });

  testWidgets(
    'imported file cards open stable bindings and preserve subpaths',
    (tester) async {
      const noteId = '01234567-89ab-4cde-8123-456789abcdef';
      final bound = CardCanvasNode.fromJson({
        'id': 'bound',
        'type': 'file',
        'x': 10,
        'y': 10,
        'width': 220,
        'height': 140,
        'file': 'Study/Reading.md',
        'subpath': '#Outline',
        'inkVaultNoteId': noteId,
      });
      final unresolved = CardCanvasNode.fromJson({
        ...bound.toJson(),
        'id': 'unresolved',
        'x': 250,
        'file': noteId,
        'inkVaultNoteId': null,
      });
      final files = <CardCanvasNode>[];
      final legacy = <String>[];
      final key = await mount(
        tester,
        initial: const CardCanvasDocument.empty().copyWith(
          nodes: [bound, unresolved],
        ),
        notes: const [CardCanvasNote(noteId, 'Reading')],
        openFile: files.add,
        open: legacy.add,
      );
      await tester.tapAt(point(tester, key.currentState!, bound));
      await tester.pump();
      await tester.tap(find.text('문서 열기'));
      await tester.pump();
      expect(files.single.linkedNoteId, noteId);
      expect(files.single.file, 'Study/Reading.md');
      expect(files.single.subpath, '#Outline');
      expect(legacy, isEmpty);

      await tester.tapAt(point(tester, key.currentState!, unresolved));
      await tester.pump();
      expect(find.text('문서 열기'), findsNothing);
      expect(files, hasLength(1));
    },
  );

  testWidgets('web card opens HTTP(S) only through the explicit action', (
    tester,
  ) async {
    CardCanvasNode link(String id, String url, int x) =>
        CardCanvasNode.fromJson({
          'id': id,
          'type': 'link',
          'url': url,
          'x': x,
          'y': 10,
          'width': 220,
          'height': 140,
        });
    final safe = link('safe', 'https://example.test/notes', 10);
    final local = link('local', 'file:///C:/Users/private.txt', 250);
    final opened = <String>[];
    final key = await mount(
      tester,
      initial: const CardCanvasDocument.empty().copyWith(nodes: [safe, local]),
      openExternal: opened.add,
    );
    expect(opened, isEmpty);
    await tester.tapAt(point(tester, key.currentState!, safe));
    await tester.pump();
    expect(opened, isEmpty);
    await tester.tap(find.text('웹 링크 열기'));
    await tester.pump();
    expect(opened, ['https://example.test/notes']);

    await tester.tapAt(point(tester, key.currentState!, local));
    await tester.pump();
    expect(find.text('웹 링크 열기'), findsNothing);
    expect(opened, hasLength(1));
  });

  testWidgets(
    'save persists viewport even when canvas content did not change',
    (tester) async {
      var contentSaves = 0;
      CardCanvasViewport? saved;
      final key = await mount(
        tester,
        save: (_) async {
          contentSaves++;
        },
        saveViewport: (view) async {
          saved = view;
        },
      );
      await tester.tap(find.byTooltip('확대'));
      await tester.pump();
      await key.currentState!.save();
      expect(contentSaves, 0);
      expect(saved, isNotNull);
      expect(saved!.scale, closeTo(1.2, .0001));
      expect(
        key.currentState!.document.toJson().containsKey('viewport'),
        false,
      );
    },
  );

  testWidgets(
    'text card editing moving saving and reloading preserves actual content',
    (tester) async {
      CardCanvasDocument? saved;
      final key = await mount(
        tester,
        save: (doc) async {
          saved = doc;
        },
      );
      await tester.tap(find.byTooltip('텍스트 카드 추가'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('card-canvas-text')),
        '연구 질문\n결과 연결',
      );
      await tester.pump();
      final node = key.currentState!.document.nodes.single;
      final before = node.bounds.topLeft;
      await tester.dragFrom(
        point(tester, key.currentState!, node),
        const Offset(-80, 35),
      );
      await tester.pump();
      await key.currentState!.save();
      expect(saved!.nodes.single.text, '연구 질문\n결과 연결');
      expect(
        saved!.nodes.single.bounds.topLeft,
        before + const Offset(-80, 35),
      );
      final restored = CardCanvasDocument.fromJson(
        jsonDecode(jsonEncode(saved!.toJson())),
      );
      expect(restored.nodes.single.text, '연구 질문\n결과 연결');
      expect(restored.nodes.single.id, node.id);
    },
  );

  testWidgets(
    'connections colors deletion and undo preserve node and edge identities',
    (tester) async {
      final initial = CardCanvasDocument.fromJson({
        'nodes': [
          {
            'id': 'a',
            'type': 'text',
            'x': 30,
            'y': 30,
            'width': 150,
            'height': 100,
            'text': 'A',
          },
          {
            'id': 'b',
            'type': 'text',
            'x': 240,
            'y': 30,
            'width': 150,
            'height': 100,
            'text': 'B',
          },
        ],
        'edges': [],
      });
      final key = await mount(tester, initial: initial);
      await tester.tapAt(point(tester, key.currentState!, initial.nodes.first));
      await tester.pump();
      await tester.tap(find.byTooltip('카드 연결'));
      await tester.tapAt(point(tester, key.currentState!, initial.nodes.last));
      await tester.pump();
      expect(key.currentState!.document.edges.single.fromNode, 'a');
      expect(key.currentState!.document.edges.single.toNode, 'b');
      final edgeId = key.currentState!.document.edges.single.id;
      await tester.tap(find.byTooltip('카드 색'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('청록'));
      await tester.pumpAndSettle();
      expect(key.currentState!.document.nodes.last.color, '5');
      await tester.tap(find.byTooltip('선택 삭제'));
      await tester.pump();
      expect(key.currentState!.document.nodes.map((node) => node.id), ['a']);
      expect(key.currentState!.document.edges, isEmpty);
      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(key.currentState!.document.edges.single.id, edgeId);
      expect(key.currentState!.document.nodes.last.id, 'b');
      await tester.tap(find.byTooltip('다시 실행'));
      await tester.pump();
      expect(key.currentState!.document.edges, isEmpty);
    },
  );

  testWidgets(
    'Canvas edge labels can be changed, cleared and undone without changing the cards',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 760);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final a = CardCanvasNode.text(
        id: 'a',
        x: 24,
        y: 70,
        width: 86,
        height: 80,
        text: 'A',
      );
      final b = CardCanvasNode.text(
        id: 'b',
        x: 290,
        y: 70,
        width: 85,
        height: 80,
        text: 'B',
      );
      final raw = <String, dynamic>{
        'id': 'named',
        'fromNode': a.id,
        'fromSide': 'right',
        'fromEnd': 'arrow',
        'toNode': b.id,
        'toSide': 'left',
        'toEnd': 'none',
        'color': '2',
        'label': '기존 이름',
        'vendor': {'rank': 2},
      };
      final other = CardCanvasEdge.fromJson({
        ...raw,
        'id': 'other',
        'fromSide': 'bottom',
        'toSide': 'bottom',
      });
      final initial = const CardCanvasDocument.empty().copyWith(
        nodes: [a, b],
        edges: [CardCanvasEdge.fromJson(raw), other],
      );
      final saved = <CardCanvasDocument>[];
      final key = await mount(
        tester,
        initial: initial,
        save: (document) async => saved.add(document),
      );
      final state = key.currentState!;
      final surface = find.byKey(const ValueKey('card-canvas-surface'));
      final edgePoint = tester.getTopLeft(surface) + const Offset(190, 117);
      final rename = find.text('연결선 이름 바꾸기');
      final field = find.byKey(const ValueKey('card-canvas-edge-name'));
      Future<void> selectEdge() async {
        await tester.tapAt(edgePoint);
        await tester.pumpAndSettle();
        expect(rename, findsOneWidget);
      }

      await selectEdge();
      expect(find.text('기존 이름'), findsOneWidget);
      await tester.tap(rename);
      await tester.pumpAndSettle();
      await tester.enterText(field, '취소할 이름');
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      await state.save();
      expect(saved, isEmpty);

      await tester.tap(rename);
      await tester.pumpAndSettle();
      await tester.enterText(field, '  선행 관계  ');
      await tester.tap(find.text('이름 저장'));
      await tester.pumpAndSettle();
      await state.save();
      expect(saved.single.edges.first.toJson(), {...raw, 'label': '선행 관계'});
      expect(saved.single.edges.last.toJson(), other.toJson());
      expect(saved.single.toJson()['nodes'], initial.toJson()['nodes']);

      await tester.tap(rename);
      await tester.pumpAndSettle();
      await tester.enterText(field, '   ');
      await tester.tap(find.text('이름 저장'));
      await tester.pumpAndSettle();
      expect(state.document.edges.first.toJson(), {...raw}..remove('label'));
      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(state.document.edges.first.toJson()['label'], '선행 관계');
      await tester.tap(find.byTooltip('다시 실행'));
      await tester.pump();
      expect(state.document.edges.first.toJson().containsKey('label'), isFalse);

      await selectEdge();
      await tester.tap(find.text('연결선 삭제'));
      await tester.pump();
      expect(state.document.edges.map((edge) => edge.id), ['other']);
      expect(state.document.toJson()['nodes'], initial.toJson()['nodes']);
      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(state.document.edges.map((edge) => edge.id), ['named', 'other']);
    },
  );

  testWidgets(
    'Canvas edge hit testing respects painted endpoints, cards, zoom and pans',
    (tester) async {
      final a = CardCanvasNode.text(
        id: 'a',
        x: 60,
        y: 65,
        width: 80,
        height: 70,
        text: 'A',
      );
      final b = CardCanvasNode.text(
        id: 'b',
        x: 320,
        y: 65,
        width: 80,
        height: 70,
        text: 'B',
      );
      final cover = CardCanvasNode.text(
        id: 'cover',
        x: 170,
        y: 75,
        width: 66,
        height: 50,
        text: 'Cover',
      );
      final group = CardCanvasNode.group(
        id: 'group',
        label: 'Group',
        bounds: const Rect.fromLTWH(140, 20, 180, 170),
      );
      final edge = CardCanvasEdge.connect(
        id: 'edge',
        fromNode: a.id,
        toNode: b.id,
      );
      final initial = const CardCanvasDocument.empty().copyWith(
        nodes: [group, a, b, cover],
        edges: [edge],
      );
      final key = await mount(tester, initial: initial);
      final state = key.currentState!;
      final surface = find.byKey(const ValueKey('card-canvas-surface'));
      final rename = find.text('연결선 이름 바꾸기');
      Offset screen(Offset world) =>
          tester.getTopLeft(surface) + state.viewport.worldToScreen(world);

      await tester.tapAt(
        screen(const Offset(200, 100)),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('card-canvas-text')), findsOneWidget);
      expect(rename, findsNothing);

      await tester.tap(find.byTooltip('확대'));
      await tester.pump();
      final onEdge = screen(const Offset(275, 100));
      await tester.tapAt(
        onEdge + const Offset(0, 8),
        kind: ui.PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(rename, findsOneWidget);
      await tester.tapAt(screen(const Offset(260, 240)));
      await tester.pump();
      expect(rename, findsNothing);

      final oldOffset = state.viewport.offset;
      await tester.dragFrom(onEdge, const Offset(40, 30));
      await tester.pump();
      expect(state.viewport.offset, oldOffset + const Offset(40, 30));
      expect(state.document.toJson(), initial.toJson());
      expect(rename, findsNothing);

      final first = await tester.startGesture(screen(const Offset(275, 100)));
      final second = await tester.startGesture(screen(const Offset(275, 155)));
      await second.moveBy(const Offset(0, 22));
      await second.up();
      await first.up();
      await tester.pump();
      expect(state.viewport.scale, greaterThan(1.2));
      expect(rename, findsNothing);
    },
  );

  testWidgets(
    'document cards only open known note IDs through the supplied callback',
    (tester) async {
      const noteId = '01234567-89ab-4cde-8123-456789abcdef';
      final opened = <String>[];
      final key = await mount(
        tester,
        notes: const [CardCanvasNote(noteId, '연구노트')],
        open: opened.add,
      );
      await tester.tap(find.byTooltip('문서 카드 추가'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('연구노트'));
      await tester.pumpAndSettle();
      expect(key.currentState!.document.nodes.single.file, noteId);
      await tester.tap(find.text('문서 열기'));
      expect(opened, [noteId]);
      final unsafe = CardCanvasDocument.fromJson({
        'nodes': [
          {
            'id': 'unsafe',
            'type': 'file',
            'x': 20,
            'y': 20,
            'width': 200,
            'height': 100,
            'file': '../../outside.exe',
          },
        ],
      });
      final second = await mount(tester, initial: unsafe, open: opened.add);
      await tester.tapAt(
        point(tester, second.currentState!, unsafe.nodes.single),
      );
      await tester.pump();
      expect(find.text('연결할 수 없는 문서'), findsOneWidget);
      expect(opened, [noteId]);
      expect(find.text('문서 열기'), findsNothing);
    },
  );

  testWidgets('failed back save keeps a dirty draft and retry can close it', (
    tester,
  ) async {
    var attempts = 0;
    var backs = 0;
    final dirty = <bool>[];
    await mount(
      tester,
      dirty: dirty.add,
      back: () {
        backs++;
      },
      save: (_) async {
        if (++attempts == 1) throw StateError('disk');
      },
    );
    await tester.tap(find.byTooltip('텍스트 카드 추가'));
    await tester.pump();
    await tester.tap(find.byTooltip('문서 목록으로'));
    await tester.pump();
    expect(backs, 0);
    expect(dirty.last, true);
    expect(find.textContaining('저장하지 못했습니다'), findsOneWidget);
    await tester.tap(find.text('저장 재시도'));
    await tester.pump();
    expect(dirty.last, false);
    await tester.tap(find.byTooltip('문서 목록으로'));
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets(
    'save shares one pending writer and includes edits made during that save',
    (tester) async {
      final first = Completer<void>();
      final second = Completer<void>();
      final sizes = <int>[];
      final key = await mount(
        tester,
        save: (doc) {
          sizes.add(doc.nodes.length);
          return sizes.length == 1 ? first.future : second.future;
        },
      );
      await tester.tap(find.byTooltip('텍스트 카드 추가'));
      await tester.pump();
      final saving = key.currentState!.save();
      expect(identical(saving, key.currentState!.save()), true);
      await tester.tap(find.byTooltip('텍스트 카드 추가'));
      await tester.pump();
      var done = false;
      saving.then((_) {
        done = true;
      });
      first.complete();
      await tester.pump();
      expect(sizes, [1, 2]);
      expect(done, false);
      second.complete();
      await tester.pump();
      expect(done, true);
    },
  );

  testWidgets(
    'card drag temporarily disables deletion and text editing until the contact ends',
    (tester) async {
      final initial = CardCanvasDocument.fromJson({
        'nodes': [
          {
            'id': 'a',
            'type': 'text',
            'x': 50,
            'y': 20,
            'width': 180,
            'height': 120,
            'text': '보존할 메모',
          },
        ],
      });
      final key = await mount(tester, initial: initial);
      final gesture = await tester.startGesture(
        point(tester, key.currentState!, initial.nodes.single),
        pointer: 47,
      );
      await gesture.moveBy(const Offset(20, 10));
      await tester.pump();
      final delete = find.widgetWithIcon(IconButton, Icons.delete_outline);
      expect(tester.widget<IconButton>(delete).onPressed, isNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('card-canvas-text')))
            .enabled,
        false,
      );
      await tester.tap(delete);
      expect(key.currentState!.document.nodes, hasLength(1));
      await gesture.up();
      await tester.pump();
      expect(tester.widget<IconButton>(delete).onPressed, isNotNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('card-canvas-text')))
            .enabled,
        true,
      );
      expect(key.currentState!.document.nodes.single.text, '보존할 메모');
      expect(key.currentState!.document.nodes.single.x, 70);
    },
  );

  testWidgets('save during a card drag awaits the final world position', (
    tester,
  ) async {
    final initial = CardCanvasDocument.fromJson({
      'nodes': [
        {
          'id': 'a',
          'type': 'text',
          'x': 50,
          'y': 20,
          'width': 180,
          'height': 120,
          'text': 'A',
        },
      ],
    });
    CardCanvasDocument? saved;
    final busy = <bool>[];
    final key = await mount(
      tester,
      initial: initial,
      busy: busy.add,
      save: (doc) async {
        saved = doc;
      },
    );
    final start = point(tester, key.currentState!, initial.nodes.single);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(30, 10));
    final saving = key.currentState!.save();
    await tester.pump();
    expect(saved, isNull);
    await gesture.moveBy(const Offset(20, 10));
    await gesture.up();
    await tester.pump();
    await saving;
    expect(saved!.nodes.single.x, 100);
    expect(saved!.nodes.single.y, 40);
    expect(busy, contains(true));
    expect(busy.last, false);
  });
}
