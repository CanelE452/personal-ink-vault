import 'package:bson/bson.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The new pens write their strokes the way the note format expects: their
/// own tool id and only the style keys that differ from what an older app
/// draws, so the version follows what was drawn.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  StrokeOptionsExtension.setDefaults();
  // the pencil draws with its shader in the editor
  setUpAll(PencilShader.init);

  setUp(() async {
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    await FileManager.init();
  });
  tearDown(() {
    Pen.currentStroke = null;
    for (final stow in [
      stows.highlighterOpacity,
      stows.roundHighlighterOpacity,
      stows.lastRoundHighlighterColor,
      stows.lastRoundHighlighterOptions,
    ]) {
      stow.value = stow.defaultValue;
    }
  });

  /// One stroke drawn with [pen] the way the editor draws it.
  Stroke draw(Pen pen, EditorPage page) {
    pen.onDragStart(const Offset(40, 60), page, 0, null);
    for (var i = 1; i <= 10; i++) {
      pen.onDragUpdate(Offset(40 + 10.0 * i, 60 + i.toDouble()), null);
    }
    return pen.onDragEnd()!;
  }

  EditorCoreInfo noteDrawnWith(Pen pen) {
    final core = EditorCoreInfo(filePath: '/new-pens/note')
      ..backgroundPattern = CanvasBackgroundPattern.lined;
    final page = EditorPage();
    core.pages.add(page);
    page.insertStroke(draw(pen, page));
    return core;
  }

  Map<String, dynamic> savedStroke(Map<String, dynamic> json) =>
      ((json['z'] as List).single['s'] as List).single as Map<String, dynamic>;

  Future<EditorCoreInfo> reopen(EditorCoreInfo core) async {
    final (bson, _) = core.saveToBinary(currentPageIndex: null);
    return EditorCoreInfo.loadFromFileContents(
      bsonBytes: bson,
      path: '/new-pens/reopened',
      onlyFirstPage: false,
    );
  }

  test('a brush stroke saved and reopened is a brush stroke and the note is '
      'v21', () async {
    final core = noteDrawnWith(Pen.brush());
    final (bson, _) = core.saveToBinary(currentPageIndex: null);
    final json = BsonCodec.deserialize(BsonBinary.from(bson));
    expect(json['v'], 21);
    expect(savedStroke(json)['ty'], 'brush');

    final reopened = await reopen(core);
    expect(reopened.readOnlyReason, isNull);
    final stroke = reopened.pages.first.strokes.single;
    expect(stroke.toolId, ToolId.brush);
    expect(kindOfStroke(stroke.toolId, stroke.style), KitPenKind.brush);
    expect(reopened.versionToWrite(), 21);
    core.dispose();
    reopened.dispose();
  });

  test('a 납작 형광펜 stroke is saved with nb chisel and makes the note v21', () {
    final core = noteDrawnWith(Highlighter());
    final stroke = core.pages.single.strokes.single;
    expect(stroke.style.nib, InkNib.chisel);
    expect(core.versionToWrite(), 21);
    final (json, _) = core.toJson();
    expect(json['v'], 21);
    final saved = savedStroke(json);
    expect(saved['ty'], ToolId.highlighter.id);
    expect(saved['nb'], 'chisel');
    // its angle is the flat highlighter's own, never saved; at the default
    // opacity no op either
    expect(saved.containsKey('na'), isFalse);
    expect(saved.containsKey('op'), isFalse);
    core.dispose();
  });

  test('a 둥근 형광펜 stroke at the default opacity is saved without nb or op '
      'and keeps the note v19', () {
    final core = noteDrawnWith(Highlighter.round());
    final stroke = core.pages.single.strokes.single;
    expect(
      kindOfStroke(stroke.toolId, stroke.style),
      KitPenKind.highlighterRound,
    );
    expect(stroke.alpha, Highlighter.alpha);
    expect(core.versionToWrite(), 19);
    final (json, _) = core.toJson();
    expect(json['v'], 19);
    final saved = savedStroke(json);
    expect(saved['ty'], ToolId.highlighter.id);
    for (final key in ['nb', 'op', 'na', 'ls']) {
      expect(saved.containsKey(key), isFalse, reason: key);
    }
    core.dispose();
  });

  test(
    'a 둥근 형광펜 stroke at another opacity saves op and makes the note v21',
    () {
      stows.roundHighlighterOpacity.value = 60;
      final core = noteDrawnWith(Highlighter.round());
      final (json, _) = core.toJson();
      expect(json['v'], 21);
      expect(savedStroke(json)['op'], 60);
      expect(savedStroke(json).containsKey('nb'), isFalse);
      core.dispose();
    },
  );

  test('a pen stroke has its style from the first point', () {
    // the outline is built as the first point goes in: a style set later
    // would not show until the polygon is rebuilt
    final page = EditorPage();
    final highlighter = Highlighter();
    highlighter.onDragStart(const Offset(40, 60), page, 0, null);
    final drawing = Pen.currentStroke!;
    expect(drawing.points, hasLength(1));
    expect(drawing.style.nib, InkNib.chisel);
    expect(drawing.usesChisel, isTrue);
    highlighter.onDragEnd();
    page.dispose();
  });

  test(
    'the round highlighter starts with the flat one\'s colour and width',
    () {
      stows.lastHighlighterColor.value = 0x64e5323e;
      stows.lastHighlighterOptions.value = Pen.highlighterOptions.copyWith(
        size: 70,
      );
      // a round highlighter only made (the pen box drawing its entries) reads
      // the flat one's values and writes no setting
      final made = Highlighter.round();
      expect(made.color.toARGB32(), 0x64e5323e);
      expect(stows.lastRoundHighlighterColor.value, isNull);
      expect(stows.lastRoundHighlighterOptions.value, isNull);
      // the one picked up through the tool state keeps them as its own
      final state = InkToolState(Pen.fountainPen());
      addTearDown(state.dispose);
      final round = state.penFor(KitPenKind.highlighterRound) as Highlighter;
      expect(round.nib, InkNib.round);
      expect(round.color.toARGB32(), 0x64e5323e);
      expect(round.options.size, 70);
      expect(stows.lastRoundHighlighterColor.value, 0x64e5323e);
      // filled once: the flat highlighter changing later leaves it
      stows.lastHighlighterColor.value = 0x641f2023;
      expect(Highlighter.round().color.toARGB32(), 0x64e5323e);
      round.setColor(const Color(0x642f55d4));
      expect(stows.lastRoundHighlighterColor.value, 0x642f55d4);
      expect(stows.lastHighlighterColor.value, 0x641f2023);
      stows.lastHighlighterColor.value =
          stows.lastHighlighterColor.defaultValue;
      stows.lastHighlighterOptions.value =
          stows.lastHighlighterOptions.defaultValue;
    },
  );

  test('a 둥근 형광펜 picked from the pen box keeps its own width', () {
    // the entry's width and stabilisation are the flat one's: setting them
    // changes nothing, so the pick itself has to give the round highlighter
    // its own values
    stows.lastHighlighterOptions.value = Pen.highlighterOptions.copyWith(
      size: 40,
    );
    addTearDown(
      () => stows.lastHighlighterOptions.value =
          stows.lastHighlighterOptions.defaultValue,
    );
    final entry = PenBoxEntry(
      toolId: ToolId.highlighter,
      kind: KitPenKind.highlighterRound,
      color: 0xffe5323e,
      size: 40,
      streamline: Pen.highlighterOptions.streamline,
    );
    final round = entry.createPen() as Highlighter;
    expect(round.nib, InkNib.round);
    expect(round.options.size, 40);
    // the flat one gets wider; the round one picked up again does not
    stows.lastHighlighterOptions.value = Pen.highlighterOptions.copyWith(
      size: 70,
    );
    expect(Highlighter.round().options.size, 40);
    expect(stows.lastRoundHighlighterOptions.value?.size, 40);
  });

  testWidgets('turning straight line on for the pencil only straightens '
      'pencil lines and not pen lines', (tester) async {
    const size = Size(1000, 1600);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final previousTool = stows.lastTool.value;
    final previousLayout = stows.pageToolbarLayout.value;
    stows.lastTool.value = ToolId.fountainPen;
    stows.pageToolbarLayout.value = const [];
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      stows.lastTool.value = previousTool;
      stows.pageToolbarLayout.value = previousLayout;
      stows.straightLineByPen.value = stows.straightLineByPen.defaultValue;
      stows.lastPenFamily.value = stows.lastPenFamily.defaultValue;
      Pen.currentPen = Pen.fountainPen();
      Pencil.currentPencil = Pencil();
    });
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: size),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              path: '/new-pens/straight',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    final page = editor.coreInfo.pages.first;

    /// A nearly straight line at [y], drawn with the stylus: 80 moves, as
    /// the line recogniser needs at least 64 points.
    Future<Stroke> line(double y) async {
      Offset at(double x, double dy) =>
          page.renderBox!.localToGlobal(Offset(x, y + dy));
      final gesture = await tester.startGesture(
        at(200, 0),
        kind: PointerDeviceKind.stylus,
      );
      for (var i = 1; i <= 80; i++) {
        await gesture.moveTo(at(200 + 4.0 * i, i.isEven ? 1 : 0));
      }
      await gesture.up();
      await tester.pump();
      return page.strokes.last;
    }

    setStraightLine(KitPenKind.pencil, true);
    editor.currentTool = Pencil.currentPencil;
    expect((await line(300)).length, 3);
    editor.currentTool = Pen.currentPen;
    expect(Pen.currentPen.toolId, ToolId.fountainPen);
    expect((await line(500)).length, greaterThan(3));
    editor.currentTool = Pen.ballpointPen();
    expect((await line(700)).length, greaterThan(3));
    expect(page.strokes, hasLength(3));
    editor.cancelAutosaveAndMarkSaved();
  });
}
