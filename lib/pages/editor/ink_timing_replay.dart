import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/ink/ink_timing.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

/// The vault folder a measurement build puts its notes in.
const inkTimingFolder = '측정';

/// The notes of tablet measurement 1, made in [inkTimingFolder] the first
/// time a measurement build starts. Opening one plays its input.
enum InkTimingNote {
  /// Pages of 1,500 pen strokes each: panned at 100% and 300%.
  strokes('측정 1 · 획 1500'),

  /// Pages of flat highlighter strokes in 10 (colour, opacity) layers each:
  /// panned at 100%.
  highlighters('측정 1 · 형광펜 층 10'),

  /// One empty page: each measured pen draws one long stroke on it.
  empty('측정 1 · 빈 쪽');

  new(this.title);

  final String title;

  static InkTimingNote? ofTitle(String title) =>
      values.firstWhereOrNull((note) => note.title == title);
}

/// The pages of [note]. The pen strokes use only the fountain pen and the
/// ballpoint pen, which 232 has too, so a 234 build can make the same page.
EditorCoreInfo buildTimingNote(InkTimingNote note, {required String filePath}) {
  final core = EditorCoreInfo(filePath: filePath);
  switch (note) {
    case InkTimingNote.strokes:
      for (var i = 0; i < _pages; i++) {
        core.pages.add(_strokesPage(i));
      }
    case InkTimingNote.highlighters:
      for (var i = 0; i < _pages; i++) {
        core.pages.add(_highlightersPage(i));
      }
    case InkTimingNote.empty:
      core.pages.add(EditorPage());
  }
  return core;
}

/// Pages of the panned notes: enough to pan at 100% on a tablet.
const _pages = 3;

EditorPage _strokesPage(int pageIndex) {
  final page = EditorPage();
  final random = Random(pageIndex + 1);
  const columns = 30, rows = 50;
  final cell = Size(page.size.width / columns, page.size.height / rows);
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      final fountain = (row + column).isEven;
      final start = Offset(
        column * cell.width + 4,
        row * cell.height + cell.height / 2,
      );
      final phase = random.nextDouble() * pi * 2;
      final stroke = Stroke(
        color: fountain ? const Color(0xff1a1a1a) : const Color(0xff1f3a8a),
        pressureEnabled: fountain,
        options: (fountain ? Pen.fountainPenOptions : Pen.ballpointPenOptions)
            .copyWith(size: 2.5, streamline: 0, isComplete: false),
        pageIndex: pageIndex,
        page: page,
        toolId: fountain ? ToolId.fountainPen : ToolId.ballpointPen,
      );
      for (var i = 0; i < 20; i++) {
        stroke.addPoint(
          start + Offset(i * 1.3, sin(phase + i * 0.6) * cell.height * 0.3),
          fountain ? 0.4 + 0.3 * sin(i * 0.3) : null,
        );
      }
      page.strokes.add(_finished(stroke));
    }
  }
  return page;
}

/// The highlighter colours and opacities: 5 x 2 layers.
const _highlighterColours = [
  Color(0xffffeb3b),
  Color(0xff8bc34a),
  Color(0xfff48fb1),
  Color(0xff64b5f6),
  Color(0xffffb74d),
];
const _highlighterAlphas = [90, 160];

EditorPage _highlightersPage(int pageIndex) {
  final page = EditorPage();
  const perLayer = 24;
  final layers = _highlighterColours.length * _highlighterAlphas.length;
  final gap = (page.size.height - 60) / (layers * perLayer);
  for (var k = 0; k < layers * perLayer; k++) {
    final layer = k ~/ perLayer;
    final stroke = Stroke(
      color: _highlighterColours[layer % _highlighterColours.length],
      pressureEnabled: false,
      options: Pen.highlighterOptions.copyWith(size: 20, isComplete: false),
      pageIndex: pageIndex,
      page: page,
      toolId: ToolId.highlighter,
      style: StrokeStyle(
        alpha: _highlighterAlphas[layer ~/ _highlighterColours.length],
        nib: InkNib.chisel,
      ),
    );
    final y = 30 + k * gap;
    for (var i = 0; i < 40; i++) {
      stroke.addPoint(Offset(60 + i * 22, y + sin(k + i * 0.4) * 3));
    }
    page.strokes.add(_finished(stroke));
  }
  return page;
}

Stroke _finished(Stroke stroke) => stroke
  ..options.isComplete = true
  ..markPolygonNeedsUpdating();

/// The points of one long stroke inside [area], [step] apart on screen:
/// across and back in rows 24 px apart, turning back up at the bottom. It
/// never stops, so 「멈추면 직선」 does not make it a line.
List<Offset> longStrokePoints(Rect area, {int count = 3000, double step = 4}) {
  const gap = 24.0;
  var x = area.left, y = area.top;
  var across = 1.0, downwards = 1.0;
  var toNextRow = 0.0;
  final points = [Offset(x, y)];
  while (points.length < count) {
    if (toNextRow > 0) {
      final move = min(step, toNextRow);
      y += downwards * move;
      toNextRow -= move;
    } else {
      final room = across > 0 ? area.right - x : x - area.left;
      if (room <= 0) {
        across = -across;
        final next = y + downwards * gap;
        if (next > area.bottom || next < area.top) downwards = -downwards;
        toNextRow = gap;
        continue;
      }
      x += across * min(step, room);
    }
    points.add(Offset(x, y));
  }
  return points;
}

/// How far down the page is moved at each 120 Hz step: down to [range] and
/// back up in [step]s, again until there are [minSteps]. Empty when the
/// pages do not reach past the screen.
List<double> panOffsets(double range, {double step = 20, int minSteps = 600}) {
  if (range <= 0) return const [];
  final down = <double>[for (var y = 0.0; y < range; y += step) y, range];
  final once = [...down, ...down.reversed.skip(1)];
  final offsets = [...once];
  while (offsets.length < minSteps) {
    offsets.addAll(once.skip(1));
  }
  return offsets;
}

/// The page area of an open editor: its transform and its box on screen.
typedef _PageArea = ({
  TransformationController transform,
  RenderBox box,
  bool singlePage,
});

/// Plays the measurement input in a measurement build ([inkTimingOn]): makes
/// the [InkTimingNote]s, and when one opens moves the stylus or the page at
/// 120 Hz while a [FrameTimingRecorder] records, then writes each result
/// ([writeTimingResult]). Each step logs `PIV_REPLAY <note> ...` as well.
///
/// A replay that is not [enabled] makes no notes and plays nothing.
class InkTimingReplay {
  new({this.enabled = inkTimingOn, this.write = writeTimingResult});

  final bool enabled;

  /// Where each result goes: [writeTimingResult] (a test keeps them).
  final Future<void> Function(InkTimingResult result) write;

  static final _log = Logger('InkTimingReplay');

  /// Waits before the first measurement, for the note to settle after
  /// opening, and around each measurement, for the engine to hand over the
  /// frame times of the frames before it ([FrameTimingRecorder]).
  static const _settle = Duration(seconds: 2);
  static const _flush = Duration(milliseconds: 1500);

  static const _inputHz = 120;
  static const _tick = Duration(milliseconds: 4);

  /// The stylus the replay draws with, apart from any real one.
  static const _device = 0x7e57;
  static const _pressure = 0.5;

  /// The pens measured while drawing, the old drawing (펜(가는 촉)) first.
  static const _pens = [
    (KitPenKind.fountain, KitPenDash.solid),
    (KitPenKind.calligraphy, KitPenDash.solid),
    (KitPenKind.brush, KitPenDash.solid),
    (KitPenKind.finePen, KitPenDash.dash),
    (KitPenKind.highlighterChisel, KitPenDash.solid),
  ];

  late final _recorder = FrameTimingRecorder(enabled: enabled);

  /// The [inkTimingFolder] of the vault, once [seedNotes] found or made it.
  String? _folderId;

  /// The app's own folder [seedNotes] used: the replay keeps there the
  /// settings it changes ([_keepSettings]).
  Directory? _directory;

  var _running = false;
  var _generation = 0;
  var _nextPointer = 1 << 30;
  var _eventTime = Duration.zero;
  Timer? _timer;
  Completer<bool>? _waiting;

  /// The first time a measurement build opens a vault: makes
  /// [inkTimingFolder] at the top of [repository] and the measurement notes
  /// missing from it, then marks that in the app's own folder (or in
  /// [directory]) as `ink-timing/seeded`. Once marked it makes nothing, in
  /// this vault or another, also when the folder or a note was deleted; it
  /// only looks for the folder, for [noteLoaded]. True when it made a note.
  ///
  /// First it puts back the settings a replay cut off while it played (the
  /// app killed) kept there ([_putBackSettings]).
  Future<bool> seedNotes(
    NoteRepository repository, {
    Directory? directory,
  }) async {
    if (!enabled) return false;
    try {
      final root = directory ?? await getApplicationSupportDirectory();
      _directory = root;
      try {
        _putBackSettings(root);
      } catch (e, stackTrace) {
        // the notes are made all the same
        _log.warning('측정 재생이 남긴 설정을 되돌리지 못했습니다', e, stackTrace);
      }
      if (repository.formatVersion < 2) return false;
      final marker = File('${root.path}/ink-timing/seeded');
      final library = LibraryStore(repository);
      final found = (await library.listFolders()).firstWhereOrNull(
        (folder) => folder.parentId == null && folder.title == inkTimingFolder,
      );
      if (marker.existsSync()) {
        _folderId = found?.id;
        return false;
      }
      final folder = found ?? await library.createFolder(inkTimingFolder);
      _folderId = folder.id;
      final store = WorkspaceStore(repository);
      final there = {
        for (final note in await store.list())
          if (note.folderId == folder.id) note.title,
      };
      var made = false;
      for (final kind in InkTimingNote.values) {
        if (there.contains(kind.title)) continue;
        final note = await store.create(kind.title, folderId: folder.id);
        final session = await store.open(note);
        final core = buildTimingNote(
          kind,
          filePath: '/.working/${note.id}/new/main',
        );
        try {
          await session.saveInk(await SaberInkAdapter.capture(core, 0));
        } finally {
          core.dispose();
        }
        made = true;
      }
      await marker.parent.create(recursive: true);
      await marker.writeAsString('${DateTime.now().toIso8601String()}\n');
      return made;
    } catch (e, stackTrace) {
      _log.warning('측정 노트를 만들지 못했습니다', e, stackTrace);
      return false;
    }
  }

  /// A note titled [title] in folder [folderId] opened in the editor
  /// [editor] gives now: a measurement note starts its replay, in that editor
  /// only. [editor] is asked again at each step; once it gives another
  /// editor or none (another note opened, the screen closed) the replay
  /// stops. True when one started.
  bool noteLoaded({
    required String title,
    required String? folderId,
    required EditorState? Function() editor,
  }) {
    if (!enabled || _running) return false;
    final note = InkTimingNote.ofTitle(title);
    final pinned = editor();
    if (note == null ||
        pinned == null ||
        _folderId == null ||
        folderId != _folderId) {
      return false;
    }
    _running = true;
    unawaited(_play(note, pinned, editor).whenComplete(() => _running = false));
    return true;
  }

  /// Stops a replay that is playing or waiting.
  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete(false);
  }

  Future<void> _play(
    InkTimingNote note,
    EditorState pinned,
    EditorState? Function() editor,
  ) async {
    final generation = _generation;
    EditorState? open() =>
        generation == _generation &&
            identical(editor(), pinned) &&
            pinned.mounted
        ? pinned
        : null;

    debugPrint('PIV_REPLAY ${note.name} start');
    String? stopped;
    try {
      if (!await _wait(_settle) || open() == null) {
        stopped = 'the note closed';
      } else {
        stopped = switch (note) {
          InkTimingNote.empty => await _drawPens(open),
          InkTimingNote.strokes => await _pan(open, 'pan-strokes', [1, 3]),
          InkTimingNote.highlighters => await _pan(open, 'pan-highlighters', [
            1,
          ]),
        };
      }
    } catch (e, stackTrace) {
      _log.warning('측정 재생이 멈췄습니다', e, stackTrace);
      stopped = '$e';
    }
    final end = stopped == null ? 'done' : 'stopped: $stopped';
    debugPrint('PIV_REPLAY ${note.name} $end');
  }

  /// Each of [_pens] draws one long stroke on the empty page, which is then
  /// undone. The pens are the replay's own, at their default sizes: the
  /// dashed fine pen and the highlighter that never straightens leave the
  /// fine pen's line and the straight lines unwritten. What the editor
  /// writes as it changes pens (the last tool, pen family, highlighter) and
  /// what the stylus switches (finger drawing) are put back after, as is
  /// the pen in hand.
  Future<String?> _drawPens(EditorState? Function() open) async {
    final editor = open()!;
    if (editor.inkBlocked) return 'the note takes no ink';
    final area = _pageAreaOf(editor);
    if (area == null) return 'no page area';
    if (area.singlePage) return 'single page view';
    area.transform.value = Matrix4.identity();
    final rect = _drawRect(editor, area.box.size);
    if (rect.width < 100 || rect.height < 100) return 'the page is too small';
    final points = _startOnCanvas(
      longStrokePoints(rect),
      rect,
      area,
      View.of(editor.context).viewId,
    );
    if (points == null) return 'the stroke start is covered';

    final inHand = editor.currentTool;
    final beforeEraser = editor.lastNonEraserTool;
    final lastTool = stows.lastTool.value;
    final penFamily = stows.lastPenFamily.value;
    final highlighter = stows.lastHighlighterKind.value;
    final fingerDrawing = stows.editorFingerDrawing.value;
    final root = _directory;
    if (root != null) _keepSettings(root);
    try {
      for (final (kind, dash) in _pens) {
        editor.currentTool = _penOf(kind, dash);
        final name =
            'draw-${kind.previewId}'
            '${dash == KitPenDash.solid ? '' : '-${dash.name}'}';
        final page = editor.coreInfo.pages.first;
        final strokes = page.strokes.length;
        final measured = await _measure(
          name,
          open,
          () => _stroke(points, editor, open),
        );
        // the replay's stroke goes again, also one a stop cut short
        final drew = editor.mounted && page.strokes.length > strokes;
        if (drew) editor.undo();
        if (measured != null) return measured;
        if (!drew) return 'no stroke on the page for $name';
      }
      return null;
    } finally {
      if (editor.mounted) {
        // the editor keeps the last calligraphy pen and brush in hand to
        // pick up again: pens with the user's settings, not the replay's
        editor.currentTool = newPenOf(KitPenKind.calligraphy);
        editor.currentTool = newPenOf(KitPenKind.brush);
        // the eraser gives back the tool before it, not a replay pen
        editor.currentTool = beforeEraser;
        editor.currentTool = inHand;
      }
      stows.lastTool.value = lastTool;
      stows.lastPenFamily.value = penFamily;
      stows.lastHighlighterKind.value = highlighter;
      stows.editorFingerDrawing.value = fingerDrawing;
      if (root != null) {
        final kept = _restoreFile(root);
        if (kept.existsSync()) kept.deleteSync();
      }
    }
  }

  static File _restoreFile(Directory root) =>
      File('${root.path}/ink-timing/restore.json');

  /// Keeps the settings [_drawPens] changes in `ink-timing/restore.json`
  /// while it plays, so that [seedNotes] can put them back after a kill.
  /// Written and removed at once (sync), also on a test's clock.
  static void _keepSettings(Directory root) {
    final file = _restoreFile(root);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      jsonEncode({
        'lastTool': stows.lastTool.value.name,
        'lastPenFamily': stows.lastPenFamily.value.name,
        'lastHighlighterKind': stows.lastHighlighterKind.value,
        'editorFingerDrawing': stows.editorFingerDrawing.value,
      }),
    );
  }

  /// Puts back the settings in `ink-timing/restore.json`, when a replay left
  /// one. A value it cannot read (not a tool, not a highlighter, not a
  /// yes/no) is left as it is; the file goes either way, also when it
  /// cannot be read at all (then this throws, and [seedNotes] goes on).
  static void _putBackSettings(Directory root) {
    final file = _restoreFile(root);
    if (!file.existsSync()) return;
    try {
      if (jsonDecode(file.readAsStringSync())
          case final Map<String, Object?> kept) {
        final tools = ToolId.values.asNameMap();
        if (tools[kept['lastTool']] case final tool?) {
          stows.lastTool.value = tool;
        }
        if (tools[kept['lastPenFamily']] case final family?) {
          stows.lastPenFamily.value = family;
        }
        if (kept['lastHighlighterKind'] case final String kind
            when KitPenKind.values.any(
              (k) => k.isHighlighter && k.previewId == kind,
            )) {
          stows.lastHighlighterKind.value = kind;
        }
        if (kept['editorFingerDrawing'] case final bool finger) {
          stows.editorFingerDrawing.value = finger;
        }
      }
    } on FormatException catch (e) {
      _log.warning('측정 재생이 남긴 설정을 읽지 못했습니다', e);
    } finally {
      file.deleteSync();
    }
  }

  /// Pans the pages down and back at each of [scales] (1 is the page fitted
  /// to the width, as the zoom shows 100%), measured as `<name>-<percent>`.
  Future<String?> _pan(
    EditorState? Function() open,
    String name,
    List<double> scales,
  ) async {
    final editor = open()!;
    final area = _pageAreaOf(editor);
    if (area == null) return 'no page area';
    if (area.singlePage) return 'single page view';
    final size = area.box.size;
    final pages = editor.coreInfo.pages;
    final height = CanvasGestureDetector.getTopOfPage(
      pageIndex: pages.length,
      pages: pages,
      screenWidth: size.width,
    );
    try {
      for (final scale in scales) {
        final offsets = panOffsets(height * scale - size.height);
        if (offsets.isEmpty) return 'no room to pan at $scale';
        final x = size.width * (1 - scale) / 2;
        Matrix4 at(double y) =>
            Matrix4.diagonal3Values(scale, scale, 1)
              ..setTranslationRaw(x, -y, 0);
        area.transform.value = at(0);
        final measured = await _measure(
          '$name-${(scale * 100).round()}',
          open,
          () => _at120Hz(
            offsets.length,
            (i) => area.transform.value = at(offsets[i]),
            open,
          ),
        );
        if (measured != null) return measured;
      }
      return null;
    } finally {
      if (open() != null) area.transform.value = Matrix4.identity();
    }
  }

  /// Records the frames of [play] as [name] and writes the result, or says
  /// why it could not.
  Future<String?> _measure(
    String name,
    EditorState? Function() open,
    Future<bool> Function() play,
  ) async {
    if (!await _wait(_flush) || open() == null) return 'the note closed';
    _recorder.start(name);
    InkTimingResult result;
    try {
      if (!await play()) return 'the note closed during $name';
      _recorder.markEnd();
      if (!await _wait(_flush) || open() == null) {
        return 'the note closed during $name';
      }
    } finally {
      result = _recorder.stop();
    }
    await write(result);
    return null;
  }

  /// The stylus down at the first of [points], through each of them at
  /// 120 Hz, and up at the last: the editor's own input path. Stopped
  /// early, the stylus is cancelled while [editor] is still on screen; once
  /// it is gone, nothing more goes to its page.
  Future<bool> _stroke(
    List<Offset> points,
    EditorState editor,
    EditorState? Function() open,
  ) async {
    final pointer = _nextPointer++;
    var last = points.first;
    var down = false;
    // the events of each stroke come after the last stroke's, in order
    final from = _eventTime;
    Duration at(int i) =>
        from +
        Duration(
          microseconds: (i + 1) * Duration.microsecondsPerSecond ~/ _inputHz,
        );
    _eventTime = at(points.length + 2);
    void send(PointerEvent event) =>
        GestureBinding.instance.handlePointerEvent(event);

    send(
      PointerAddedEvent(
        timeStamp: from,
        kind: PointerDeviceKind.stylus,
        device: _device,
        position: last,
      ),
    );
    final played = await _at120Hz(points.length, (i) {
      final point = points[i];
      send(
        i == 0
            ? PointerDownEvent(
                timeStamp: at(i),
                pointer: pointer,
                kind: PointerDeviceKind.stylus,
                device: _device,
                position: point,
                buttons: kPrimaryButton,
                pressure: _pressure,
                pressureMax: 1,
              )
            : PointerMoveEvent(
                timeStamp: at(i),
                pointer: pointer,
                kind: PointerDeviceKind.stylus,
                device: _device,
                position: point,
                delta: point - last,
                buttons: kPrimaryButton,
                pressure: _pressure,
                pressureMax: 1,
              ),
      );
      down = true;
      last = point;
    }, open);
    final end = at(points.length);
    if (played) {
      send(
        PointerUpEvent(
          timeStamp: end,
          pointer: pointer,
          kind: PointerDeviceKind.stylus,
          device: _device,
          position: last,
          pressureMax: 1,
        ),
      );
    } else if (down && editor.mounted) {
      send(
        PointerCancelEvent(
          timeStamp: end,
          pointer: pointer,
          kind: PointerDeviceKind.stylus,
          device: _device,
          position: last,
        ),
      );
    }
    send(
      PointerRemovedEvent(
        timeStamp: at(points.length + 1),
        kind: PointerDeviceKind.stylus,
        device: _device,
        position: last,
      ),
    );
    return played;
  }

  /// Calls [step] for 0 to [count] - 1, each when it is due at 120 Hz from
  /// now. False when the note closed first.
  Future<bool> _at120Hz(
    int count,
    void Function(int index) step,
    EditorState? Function() open,
  ) {
    final done = _waiting = Completer<bool>();
    var next = 0;
    _timer = Timer.periodic(_tick, (timer) {
      if (done.isCompleted) return timer.cancel();
      if (open() == null) {
        timer.cancel();
        return done.complete(false);
      }
      // the tick counts the periods gone by, also those a late timer
      // skipped, so the steps keep to 120 Hz
      final due = min(
        count,
        timer.tick *
                _tick.inMicroseconds *
                _inputHz ~/
                Duration.microsecondsPerSecond +
            1,
      );
      while (next < due) {
        step(next++);
      }
      if (next == count) {
        timer.cancel();
        done.complete(true);
      }
    });
    return done.future;
  }

  /// Waits [duration]; false when [cancel] came first.
  Future<bool> _wait(Duration duration) {
    final done = _waiting = Completer<bool>();
    _timer = Timer(duration, () {
      if (!done.isCompleted) done.complete(true);
    });
    return done.future;
  }

  /// The page area of [editor]'s canvas.
  static _PageArea? _pageAreaOf(EditorState editor) {
    _PageArea? found;
    var singlePage = false;
    void visit(Element element) {
      if (found != null) return;
      if (element case StatefulElement(
        state: final CanvasGestureDetectorState canvas,
      )) {
        singlePage = canvas.singlePageIndex != null;
      }
      final widget = element.widget;
      if (widget is InteractiveCanvasViewer) {
        final box = element.renderObject;
        final transform = widget.transformationController;
        if (box is RenderBox && box.hasSize && transform != null) {
          found = (transform: transform, box: box, singlePage: singlePage);
        }
        return;
      }
      element.visitChildren(visit);
    }

    editor.context.visitChildElements(visit);
    return found;
  }

  /// Where the first page shows in a page area of [size] at 100% from the
  /// top, less a margin, in the page area's own coordinates.
  static Rect _drawRect(EditorState editor, Size size) {
    final pages = editor.coreInfo.pages;
    final page = pages.first.size;
    final width = min(page.width, size.width);
    final top = CanvasGestureDetector.getTopOfPage(
      pageIndex: 0,
      pages: pages,
      screenWidth: size.width,
    );
    return Rect.fromLTWH(
      (size.width - width) / 2,
      top,
      width,
      page.height * width / page.width,
    ).intersect(Offset.zero & size).deflate(48);
  }

  /// [points] (in [rect], the page area's coordinates) on screen, from a
  /// corner of [rect] where the stylus lands on the canvas, not on a window
  /// over it (the floating bar); null when every corner is covered.
  static List<Offset>? _startOnCanvas(
    List<Offset> points,
    Rect rect,
    _PageArea area,
    int viewId,
  ) {
    for (final (flipX, flipY) in const [
      (false, false),
      (true, false),
      (false, true),
      (true, true),
    ]) {
      Offset onScreen(Offset p) => area.box.localToGlobal(
        Offset(
          flipX ? rect.left + rect.right - p.dx : p.dx,
          flipY ? rect.top + rect.bottom - p.dy : p.dy,
        ),
      );
      final start = onScreen(points.first);
      final hit = HitTestResult();
      WidgetsBinding.instance.hitTestInView(hit, start, viewId);
      if (hit.path.any((entry) => identical(entry.target, area.box))) {
        return [for (final p in points) onScreen(p)];
      }
    }
    return null;
  }

  /// A new pen of [kind] at its default size, drawing [dash]: the replay's
  /// own fine pen and highlighter where the user's settings would matter.
  static Pen _penOf(KitPenKind kind, KitPenDash dash) {
    final Pen pen = switch (kind) {
      KitPenKind.finePen => _FinePen(dash),
      KitPenKind.highlighterChisel => _FreehandHighlighter(),
      _ => newPenOf(kind),
    };
    return pen..options = _defaultOptionsOf(kind);
  }

  static StrokeOptions _defaultOptionsOf(KitPenKind kind) => switch (kind) {
    KitPenKind.fountain => Pen.fountainPenOptions,
    KitPenKind.calligraphy => Pen.calligraphyPenOptions,
    KitPenKind.finePen => Pen.ballpointPenOptions,
    KitPenKind.brush => Pen.brushPenOptions,
    KitPenKind.highlighterChisel ||
    KitPenKind.highlighterRound => Pen.highlighterOptions,
    KitPenKind.pencil => Pen.pencilOptions,
  };
}

/// The fine pen drawing [dash] without keeping it as the fine pen's line.
class _FinePen extends Pen {
  new(this.dash) : super.ballpointPen();

  final KitPenDash dash;

  @override
  StrokeStyle get style => StrokeStyle(lineStyle: dash);
}

/// The flat highlighter that draws freehand whatever its straight line is
/// set to (the replay's stroke must be the whole stroke).
class _FreehandHighlighter extends Highlighter {
  @override
  void onDragUpdate(Offset position, double? pressure) =>
      Pen.currentStroke?.addPoint(position, pressure);
}
