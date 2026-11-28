import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/ink_timing_replay.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The pen and finger settings the replay may touch while it plays.
Object _settings() => (
  tool: stows.lastTool.value,
  family: stows.lastPenFamily.value,
  highlighter: stows.lastHighlighterKind.value,
  finger: stows.editorFingerDrawing.value,
  line: stows.finePenLineStyle.value,
  straight: stows.straightLineByPen.value,
  axis: stows.axisLockByPen.value,
);

/// The measurement replay in a real editor, on the test's clock: the stylus
/// events reach the page through the editor's input, the page pans, the
/// replay stays in the measurement note's editor, and it leaves the pen and
/// finger settings as they were. Frame times are not reported in tests, so
/// the results count no frames; their names and order are checked.
void main() {
  setUpAll(PencilShader.init);

  late Directory temp;
  late NoteRepository repository;
  late String folderId;
  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('ink-timing-editor-');
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
  });
  tearDownAll(() async {
    await repository.close().timeout(const Duration(seconds: 30));
    await temp.delete(recursive: true);
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  /// A replay that hands each result's name to [write]; it knows the 측정
  /// folder of [repository] (the first one makes it).
  Future<InkTimingReplay> replayFor(
    WidgetTester tester,
    Future<void> Function(String name) write,
  ) async {
    final replay = InkTimingReplay(
      enabled: true,
      write: (result) => write(result.name),
    );
    addTearDown(replay.cancel);
    await tester.runAsync(() async {
      await replay.seedNotes(repository, directory: temp);
      folderId = (await LibraryStore(repository).listFolders()).single.id;
    });
    return replay;
  }

  const size = Size(1000, 1600);

  Widget app(InkTimingNote note, {Key? key}) {
    final path = '/ink-timing-${note.name}-$key';
    return MediaQuery(
      data: const MediaQueryData(size: size),
      child: TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(
            key: key,
            path: path,
            loadSnapshot: () async => buildTimingNote(note, filePath: path),
            onSaveSnapshot: (_, _) async {},
          ),
        ),
      ),
    );
  }

  /// The settings the test itself sets up go back to their defaults after
  /// it, once its own checks have run.
  void setUpSettings() {
    stows.pageToolbarLayout.value = const [];
    stows.lastTool.value = stows.lastTool.defaultValue;
    addTearDown(() {
      stows.pageToolbarLayout.value = stows.pageToolbarLayout.defaultValue;
      stows.lastTool.value = stows.lastTool.defaultValue;
      stows.lastPenFamily.value = stows.lastPenFamily.defaultValue;
      stows.lastHighlighterKind.value = stows.lastHighlighterKind.defaultValue;
      stows.editorFingerDrawing.value = stows.editorFingerDrawing.defaultValue;
      stows.autoDisableFingerDrawingWhenStylusDetected.value =
          stows.autoDisableFingerDrawingWhenStylusDetected.defaultValue;
      stows.hideFingerDrawingToggle.value =
          stows.hideFingerDrawingToggle.defaultValue;
      stows.finePenLineStyle.value = stows.finePenLineStyle.defaultValue;
      stows.straightLineByPen.value = stows.straightLineByPen.defaultValue;
      Pen.currentPen = Pen.fountainPen();
      Pencil.currentPencil = Pencil();
      Highlighter.currentHighlighter = Highlighter();
    });
  }

  Future<EditorState> mountEditor(
    WidgetTester tester,
    InkTimingNote note,
  ) async {
    setUpSettings();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(app(note, key: const ValueKey('a')));
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  /// The editor on screen, found without the tester (the replay asks from
  /// its timers, inside a pump).
  EditorState? editorOnScreen(WidgetTester tester) {
    final element = find.byType(Editor).evaluate().singleOrNull;
    return (element as StatefulElement?)?.state as EditorState?;
  }

  /// Starts the replay of [note] with [editor] as the editor on screen, and
  /// moves the test's clock on until it logs its end; gives its
  /// `PIV_REPLAY` lines. [after] runs once, [at] into the replay.
  Future<List<String>> play(
    WidgetTester tester,
    InkTimingReplay replay,
    InkTimingNote note,
    EditorState? Function() editor, {
    Duration? at,
    Future<void> Function()? after,
  }) async {
    final lines = <String>[];
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null && message.startsWith('PIV_REPLAY')) {
        lines.add(message);
      }
    };
    try {
      expect(
        replay.noteLoaded(
          title: note.title,
          folderId: folderId,
          editor: editor,
        ),
        isTrue,
      );
      const step = Duration(milliseconds: 100);
      for (var i = 0; i < 3000; i++) {
        await tester.pump(step);
        if (at != null && after != null && step * (i + 1) == at) {
          await after();
        }
        if (lines.any(
          (line) =>
              line.startsWith('PIV_REPLAY ${note.name} ') &&
              !line.endsWith(' start'),
        )) {
          return lines;
        }
      }
      fail('the replay did not end: $lines');
    } finally {
      debugPrint = print;
    }
  }

  testWidgets('on the empty note each pen draws one long stroke, undone after; '
      'the pen in hand and every setting come back', (tester) async {
    late EditorState editor;
    final drawn = <(String, ToolId, KitPenDash, int)>[];
    // what a start after a kill would put back, read while it plays
    final restore = File('${temp.path}/ink-timing/restore.json');
    final kept = <Object?>[];
    final replay = await replayFor(tester, (name) async {
      kept.add(jsonDecode(restore.readAsStringSync()));
      final stroke = editor.coreInfo.pages.first.strokes.single;
      drawn.add((
        name,
        stroke.toolId,
        stroke.style.lineStyle,
        stroke.points.length,
      ));
    });
    editor = await mountEditor(tester, InkTimingNote.empty);
    // the eraser in hand, settings that are not the defaults, and a stylus
    // that switches finger drawing off when it lands
    editor.currentTool = Eraser();
    stows.lastPenFamily.value = ToolId.ballpointPen;
    stows.lastHighlighterKind.value = KitPenKind.highlighterRound.previewId;
    stows.finePenLineStyle.value = KitPenDash.dot;
    stows.straightLineByPen.value = {'pen': true, 'hlchisel': true};
    stows.editorFingerDrawing.value = true;
    stows.autoDisableFingerDrawingWhenStylusDetected.value = true;
    stows.hideFingerDrawingToggle.value = false;
    final inHand = editor.currentTool;
    final beforeEraser = editor.lastNonEraserTool;
    final before = _settings();
    var lineWrites = 0, straightWrites = 0;
    void lineWritten() => lineWrites++;
    void straightWritten() => straightWrites++;
    stows.finePenLineStyle.addListener(lineWritten);
    stows.straightLineByPen.addListener(straightWritten);
    addTearDown(() {
      stows.finePenLineStyle.removeListener(lineWritten);
      stows.straightLineByPen.removeListener(straightWritten);
    });
    // the replay's stylus events, in the order they came
    final times = <Duration>[];
    void route(PointerEvent event) {
      if (event.kind == PointerDeviceKind.stylus) times.add(event.timeStamp);
    }

    GestureBinding.instance.pointerRouter.addGlobalRoute(route);
    addTearDown(
      () => GestureBinding.instance.pointerRouter.removeGlobalRoute(route),
    );

    final lines = await play(tester, replay, InkTimingNote.empty, () => editor);

    expect(lines, ['PIV_REPLAY empty start', 'PIV_REPLAY empty done']);
    expect(
      [for (final (name, tool, line, _) in drawn) (name, tool, line)],
      [
        ('draw-fountain', ToolId.fountainPen, KitPenDash.solid),
        ('draw-calli', ToolId.calligraphyPen, KitPenDash.solid),
        ('draw-brush', ToolId.brush, KitPenDash.solid),
        ('draw-pen-dash', ToolId.ballpointPen, KitPenDash.dash),
        ('draw-hlchisel', ToolId.highlighter, KitPenDash.solid),
      ],
    );
    // the whole stroke, not a line from 「멈추면 직선」 or the straight line
    for (final (name, _, _, points) in drawn) {
      expect(points, greaterThan(2900), reason: name);
    }
    expect(editor.coreInfo.pages.first.strokes, isEmpty);
    expect(identical(editor.currentTool, inHand), isTrue);
    // the eraser gives back the tool before it, not a replay pen
    expect(identical(editor.lastNonEraserTool, beforeEraser), isTrue);
    expect(_settings(), before);
    // at each of the five pens, the settings from before the first
    expect(
      kept,
      List.filled(5, {
        'lastTool': 'eraser',
        'lastPenFamily': 'ballpointPen',
        'lastHighlighterKind': 'hlround',
        'editorFingerDrawing': true,
      }),
    );
    expect(restore.existsSync(), isFalse);
    // the dashed line and the freehand highlighter are the replay's own
    // pens: the fine pen's line and the straight lines are never written
    expect(lineWrites, 0);
    expect(straightWrites, 0);
    // the event times only go forward, from one stroke to the next too
    expect(times.length, greaterThan(5 * 2900));
    for (var i = 1; i < times.length; i++) {
      expect(times[i], greaterThan(times[i - 1]), reason: 'event $i');
    }
  });

  testWidgets('after the replay the calligraphy pen and the brush picked in '
      'that editor are the user\'s own', (tester) async {
    final replay = await replayFor(tester, (_) async {});
    stows.floatingBarPosition.value = 'top';
    stows.lastCalligraphyPenOptions.value = Pen.calligraphyPenOptions.copyWith(
      size: 12,
    );
    stows.lastBrushOptions.value = Pen.brushPenOptions.copyWith(size: 22);
    addTearDown(() {
      for (final stow in [
        stows.floatingBarPosition,
        stows.lastCalligraphyPenOptions,
        stows.lastBrushOptions,
      ]) {
        stow.value = stow.defaultValue;
      }
    });
    final editor = await mountEditor(tester, InkTimingNote.empty);
    Finder key(String k) => find.byKey(ValueKey(k));

    await play(tester, replay, InkTimingNote.empty, () => editor);
    await tester.pumpAndSettle();

    await tester.tap(key('floating-bar-pen-brush'));
    await tester.pumpAndSettle();
    expect((editor.currentTool as Pen).options.size, 22);
    expect(identical(Pen.currentPen, editor.currentTool), isTrue);
    // the calligraphy pen from the pen panel (the chosen pen opens it)
    await tester.tap(key('floating-bar-pen-brush'));
    await tester.pumpAndSettle();
    await tester.tap(key('pen-panel-pen-${KitPenKind.calligraphy.previewId}'));
    await tester.pumpAndSettle();
    expect(editor.currentTool.toolId, ToolId.calligraphyPen);
    expect((editor.currentTool as Pen).options.size, 12);
    expect(identical(Pen.currentPen, editor.currentTool), isTrue);
    editor.cancelAutosaveAndMarkSaved();
  });

  for (final at in const [Duration(seconds: 1), Duration(seconds: 5)]) {
    testWidgets('another note opened ${at.inSeconds} s into the replay stops '
        'it and gets no stroke', (tester) async {
      final replay = await replayFor(tester, (_) async {});
      await mountEditor(tester, InkTimingNote.empty);
      final before = _settings();
      late EditorState other;
      late Object otherInHand;
      final lines = await play(
        tester,
        replay,
        InkTimingNote.empty,
        () => editorOnScreen(tester),
        at: at,
        after: () async {
          // the workspace puts another note's editor where this one was
          await tester.pumpWidget(
            app(InkTimingNote.empty, key: const ValueKey('b')),
          );
          await tester.pump();
          other = editorOnScreen(tester)!;
          otherInHand = other.currentTool;
        },
      );

      printOnFailure('$lines');
      expect(lines.first, 'PIV_REPLAY empty start');
      expect(lines.last, startsWith('PIV_REPLAY empty stopped: '));
      // nothing of the replay in the other note, also after more time
      await tester.pump(const Duration(seconds: 30));
      expect(other.coreInfo.pages.first.strokes, isEmpty);
      expect(identical(other.currentTool, otherInHand), isTrue);
      expect(
        tester
            .widget<InteractiveCanvasViewer>(
              find.byType(InteractiveCanvasViewer),
            )
            .transformationController!
            .value,
        Matrix4.identity(),
      );
      expect(_settings(), before);
    });
  }

  testWidgets('a replay stops once the editor on screen is another, also while '
      'its own is still there', (tester) async {
    final replay = await replayFor(tester, (_) async {});
    final editor = await mountEditor(tester, InkTimingNote.empty);
    final before = _settings();
    final inHand = editor.currentTool;
    // the host now gives an editor that is not the one the replay started in
    final another = Editor(path: '/another').createState() as EditorState;
    EditorState? onScreen = editor;
    final lines = await play(
      tester,
      replay,
      InkTimingNote.empty,
      () => onScreen,
      at: const Duration(seconds: 5),
      after: () async => onScreen = another,
    );

    expect(lines, [
      'PIV_REPLAY empty start',
      'PIV_REPLAY empty stopped: the note closed during draw-fountain',
    ]);
    await tester.pump(const Duration(seconds: 30));
    // the stroke under way was cut short and taken away, the pen is back
    expect(editor.coreInfo.pages.first.strokes, isEmpty);
    expect(identical(editor.currentTool, inHand), isTrue);
    expect(_settings(), before);
  });

  testWidgets('the strokes note pans down and back at 100% and 300%', (
    tester,
  ) async {
    final written = <String>[];
    final replay = await replayFor(tester, (name) async => written.add(name));
    final editor = await mountEditor(tester, InkTimingNote.strokes);
    final transform = tester
        .widget<InteractiveCanvasViewer>(find.byType(InteractiveCanvasViewer))
        .transformationController!;
    var deepest = 0.0;
    var largest = 0.0;
    void track() {
      deepest = min(deepest, transform.value.getTranslation().y);
      largest = max(largest, transform.value.getMaxScaleOnAxis());
    }

    transform.addListener(track);
    addTearDown(() => transform.removeListener(track));
    final lines = await play(
      tester,
      replay,
      InkTimingNote.strokes,
      () => editor,
    );

    expect(lines, ['PIV_REPLAY strokes start', 'PIV_REPLAY strokes done']);
    expect(written, ['pan-strokes-100', 'pan-strokes-300']);
    // three pages of about 1,400 each, three times as tall at 300%
    expect(deepest, lessThan(-3 * 3 * 1400 + 1600 + 100));
    expect(largest, 3);
    expect(transform.value, Matrix4.identity());
  });

  testWidgets('in single page view the replay stops and measures nothing', (
    tester,
  ) async {
    final written = <String>[];
    final replay = await replayFor(tester, (name) async => written.add(name));
    final editor = await mountEditor(tester, InkTimingNote.strokes);
    expect(
      tester
          .state<CanvasGestureDetectorState>(find.byType(CanvasGestureDetector))
          .setSinglePageMode(true),
      isTrue,
    );
    await tester.pump();
    final lines = await play(
      tester,
      replay,
      InkTimingNote.strokes,
      () => editor,
    );

    expect(lines, [
      'PIV_REPLAY strokes start',
      'PIV_REPLAY strokes stopped: single page view',
    ]);
    expect(written, isEmpty);
  });
}
