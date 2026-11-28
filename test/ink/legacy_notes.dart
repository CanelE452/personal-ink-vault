import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show Document, QuillController;
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_circle_stroke.dart';
import 'package:saber/components/canvas/_rectangle_stroke.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_clipboard.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/note_page_marks.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/tool_id.dart';

/// The notes the stage-2 tasks must keep opening and drawing as before. They
/// are made once, from the tree before any stage-2 change (build 234 code),
/// by `PIV_MAKE_LEGACY=1 flutter test test/ink/legacy_notes_test.dart`, and
/// stored in `test/ink/legacy/`. Never make them again after a later task.
const legacyNoteNames = [
  'tools_five',
  'circle_rect',
  'highlighters_colours',
  'pencil',
  'page_text_empty',
  'page_text',
  'photo',
  'forty_strokes',
  'own_pattern_v20',
  'side_files_three',
  'pasted_page',
  'lasso_duplicated',
  'forty_colours',
];

/// Names whose saved bytes are only compared with the `.saved.sbn2` (opening
/// sorts their strokes, which changes the order the file had).
const legacyUnsortedNames = [
  'lasso_duplicated',
  'forty_strokes',
  'forty_colours',
];

const legacyPageSize = Size(600, 848);
const legacyPhotoRect = Rect.fromLTWH(330, 560, 220, 160);

/// The side files of `side_files_three`, by the name they have in the
/// bundle (`side_files_three.<name>`).
const legacySideFileNames = [
  'page-marks.json',
  'quick-note.json',
  'quick-note.sbn2',
  'recording.json',
  'audio.m4a',
];

String _pageId(int note, int page) =>
    '00000000-0000-4000-8000-${(note * 16 + page).toRadixString(16).padLeft(12, '0')}';

/// A wavy line from [from] to [to], the same every run.
List<(Offset, double)> _wave(
  Offset from,
  Offset to, {
  double amplitude = 14,
  int steps = 40,
}) => [
  for (var i = 0; i <= steps; i++)
    (
      Offset.lerp(from, to, i / steps)! +
          Offset(0, amplitude * sin(i / steps * 4 * pi)),
      0.3 + 0.5 * sin(i / steps * pi),
    ),
];

StrokeOptions _optionsOf(ToolId tool) => switch (tool) {
  ToolId.highlighter => StrokeOptions(size: 40),
  ToolId.pencil => StrokeOptions(
    size: 5,
    streamline: 0.1,
    start: StrokeEndOptions.start(taperEnabled: true, customTaper: 1),
    end: StrokeEndOptions.end(taperEnabled: true, customTaper: 1),
  ),
  ToolId.shapePen => StrokeOptions(size: 5, smoothing: 0, streamline: 0),
  ToolId.ballpointPen => StrokeOptions(size: 5),
  _ => StrokeOptions(size: 6),
};

Stroke _stroke(
  EditorPage page,
  ToolId tool,
  int color,
  List<(Offset, double)> points,
) {
  final pressureEnabled = tool != ToolId.highlighter && tool != ToolId.shapePen;
  final stroke = Stroke(
    color: Color(color),
    pressureEnabled: pressureEnabled,
    options: _optionsOf(tool),
    pageIndex: 0,
    page: page,
    toolId: tool,
  );
  for (final (point, pressure) in points) {
    stroke.addPoint(point, pressure);
  }
  return stroke;
}

/// A small picture made here, so the bundle needs no file outside the repo.
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

EditorPage _newPage(int note, int index, {CanvasBackgroundPattern? pattern}) =>
    EditorPage(
      pageId: _pageId(note, index),
      size: legacyPageSize,
      backgroundPattern: pattern,
    );

EditorCoreInfo _newNote(
  String name, {
  CanvasBackgroundPattern pattern = CanvasBackgroundPattern.lined,
}) {
  final core = EditorCoreInfo(filePath: '/legacy/$name');
  core.backgroundPattern = pattern;
  core.lineHeight = 40;
  core.lineThickness = 3;
  return core;
}

/// Five tools on one page, inserted the way the editor does (sorted).
EditorPage _fiveTools(int note) {
  final page = _newPage(note, 0);
  page.insertStroke(
    _stroke(
      page,
      ToolId.highlighter,
      0xFFFFEB3B,
      _wave(const Offset(60, 330), const Offset(540, 330), amplitude: 6),
    ),
  );
  page.insertStroke(
    _stroke(
      page,
      ToolId.fountainPen,
      0xFF000000,
      _wave(const Offset(60, 90), const Offset(540, 90)),
    ),
  );
  page.insertStroke(
    _stroke(
      page,
      ToolId.ballpointPen,
      0xFF1565C0,
      _wave(const Offset(60, 170), const Offset(540, 170)),
    ),
  );
  page.insertStroke(
    _stroke(
      page,
      ToolId.pencil,
      0xFF424242,
      _wave(const Offset(60, 250), const Offset(540, 250)),
    ),
  );
  page.insertStroke(
    _stroke(page, ToolId.shapePen, 0xFFC62828, [
      for (final p in const [
        Offset(60, 420),
        Offset(260, 420),
        Offset(260, 520),
        Offset(60, 520),
        Offset(60, 420),
      ])
        (p, 0.5),
    ]),
  );
  return page;
}

/// [note] with [pages] and an empty page last, as the editor saves it.
EditorCoreInfo _noteOf(
  String name,
  int note,
  List<EditorPage> pages, {
  CanvasBackgroundPattern pattern = CanvasBackgroundPattern.lined,
}) {
  final core = _newNote(name, pattern: pattern);
  core.pages.addAll(pages);
  core.pages.add(_newPage(note, pages.length));
  return core;
}

EditorPage _sevenStrokePage(int note) {
  final page = _newPage(note, 0);
  for (var i = 0; i < 4; i++) {
    page.insertStroke(
      _stroke(
        page,
        ToolId.fountainPen,
        0xFF000000 + i * 0x101010,
        _wave(
          Offset(60, 80.0 + i * 40),
          Offset(540, 80.0 + i * 40),
          amplitude: 8,
        ),
      ),
    );
  }
  for (var i = 0; i < 3; i++) {
    page.insertStroke(
      _stroke(
        page,
        ToolId.ballpointPen,
        0xFF1565C0 + i * 0x001010,
        _wave(
          Offset(60, 280.0 + i * 40),
          Offset(540, 280.0 + i * 40),
          amplitude: 8,
        ),
      ),
    );
  }
  return page;
}

/// 40 strokes of one pen and 8 of others, added in an order the sort changes.
EditorPage _fortyStrokesPage(int note) {
  final page = _newPage(note, 0);
  final others = <(ToolId, int)>[
    (ToolId.highlighter, 0xFFFFEB3B),
    (ToolId.ballpointPen, 0xFF1565C0),
    (ToolId.highlighter, 0xFF4CAF50),
    (ToolId.pencil, 0xFF424242),
    (ToolId.highlighter, 0xFFFF80AB),
    (ToolId.ballpointPen, 0xFFC62828),
    (ToolId.highlighter, 0xFF4CAF50),
    (ToolId.pencil, 0xFF212121),
  ];
  var other = 0;
  for (var i = 0; i < 48; i++) {
    final isOther = i % 6 == 5;
    final spec = isOther
        ? others[other++]
        : (ToolId.fountainPen, 0xFF000000 + (i % 3) * 0x111111);
    final y = 30.0 + i * 16;
    page.strokes.add(
      _stroke(
        page,
        spec.$1,
        spec.$2,
        _wave(Offset(40, y), Offset(560, y), amplitude: 4, steps: 20),
      ),
    );
  }
  return page;
}

/// 40 strokes of one pen in 40 colours and 4 pencil strokes among them.
EditorPage _fortyColoursPage(int note) {
  final page = _newPage(note, 0);
  var pencil = 0;
  for (var i = 0; i < 44; i++) {
    final isPencil = i % 11 == 10;
    final y = 30.0 + i * 17;
    page.strokes.add(
      _stroke(
        page,
        isPencil ? ToolId.pencil : ToolId.fountainPen,
        isPencil
            ? 0xFF424242 + pencil++
            : 0xFF000000 + ((39 - i) * 0x060301 & 0xFFFFFF),
        _wave(Offset(40, y), Offset(560, y), amplitude: 4, steps: 20),
      ),
    );
  }
  return page;
}

/// A page the lasso's copy path made: the copies are added at the end
/// (`page.strokes.addAll`), so the pen types are not grouped any more.
EditorPage _lassoDuplicatedPage(int note) {
  final page = _fiveTools(note);
  final selected = [
    for (final s in page.strokes)
      if (s.toolId == ToolId.fountainPen || s.toolId == ToolId.highlighter) s,
  ];
  page.strokes.addAll([
    for (final s in selected) s.copy()..shift(const Offset(25, -25)),
  ]);
  return page;
}

NotePageMarksBytes _sideFiles(String pageId) {
  final marks = NotePageMarks()
    ..addFavorite(pageId, at: DateTime.utc(2026, 11, 28, 1))
    ..addOutline(pageId, 'Intro', at: DateTime.utc(2026, 11, 28, 2));
  return marks.encode();
}

typedef NotePageMarksBytes = Uint8List;

Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Future<void> _writeNote(
  Directory out,
  String name,
  EditorCoreInfo core,
) async {
  final (bson, assets) = core.saveToBinary(currentPageIndex: null);
  await File('${out.path}/$name.sbn2').writeAsBytes(bson, flush: true);
  for (var i = 0; i < assets.length; i++) {
    final bytes = await assets.getBytes(i);
    await File('${out.path}/$name.sbn2.$i').writeAsBytes(bytes, flush: true);
  }
}

/// Opens the stored note like the app does and writes what the current code
/// saves back as `<name>.saved.sbn2`. The assets are looked up under the
/// documents folder, where [_writeNote]'s callers copied them.
Future<void> _writeSaved(Directory out, String name, Uint8List bytes) async {
  final core = await EditorCoreInfo.loadFromFileContents(
    bsonBytes: bytes,
    path: '/legacy/$name',
    onlyFirstPage: false,
  );
  final (saved, _) = core.saveToBinary(currentPageIndex: null);
  await File('${out.path}/$name.saved.sbn2').writeAsBytes(saved, flush: true);
  if (!legacyUnsortedNames.contains(name) && !_same(saved, bytes)) {
    throw StateError('$name: saved bytes differ from the written ones');
  }
  core.dispose();
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Makes the whole bundle in [out] with today's code. [FileManager] must be
/// initialised: the notes with assets are opened from its documents folder.
Future<void> writeLegacyNotes(Directory out) async {
  await out.create(recursive: true);
  final docs = Directory('${FileManager.documentsDirectory}/legacy');
  await docs.create(recursive: true);

  final notes = <String, EditorCoreInfo>{};
  var n = 1;

  notes['tools_five'] = _noteOf('tools_five', n++, [_fiveTools(n - 1)]);

  {
    final note = n++;
    final page = _newPage(note, 0);
    final circle = CircleStroke(
      color: const Color(0xFF2E7D32),
      pressureEnabled: false,
      options: StrokeOptions(size: 5, smoothing: 0, streamline: 0),
      pageIndex: 0,
      page: page,
      toolId: ToolId.shapePen,
      center: const Offset(200, 200),
      radius: 90,
    );
    final rect = RectangleStroke(
      color: const Color(0xFF6A1B9A),
      pressureEnabled: false,
      options: StrokeOptions(size: 5, smoothing: 0, streamline: 0),
      pageIndex: 0,
      page: page,
      toolId: ToolId.shapePen,
      rect: const Rect.fromLTWH(300, 300, 220, 140),
    );
    page.insertStroke(circle);
    page.insertStroke(rect);
    notes['circle_rect'] = _noteOf('circle_rect', note, [page]);
  }

  {
    final note = n++;
    final page = _newPage(note, 0);
    for (final (i, color) in const [0xFFFFEB3B, 0xFF4CAF50, 0xFFFF80AB].indexed) {
      page.insertStroke(
        _stroke(
          page,
          ToolId.highlighter,
          color,
          _wave(
            Offset(60, 200.0 + i * 25),
            Offset(540, 260.0 + i * 25),
            amplitude: 10,
          ),
        ),
      );
    }
    notes['highlighters_colours'] = _noteOf(
      'highlighters_colours',
      note,
      [page],
    );
  }

  {
    final note = n++;
    final page = _newPage(note, 0);
    for (var i = 0; i < 4; i++) {
      page.insertStroke(
        _stroke(
          page,
          ToolId.pencil,
          0xFF424242 + i * 0x101010,
          _wave(Offset(60, 120.0 + i * 70), Offset(540, 120.0 + i * 70)),
        ),
      );
    }
    notes['pencil'] = _noteOf('pencil', note, [page]);
  }

  {
    final note = n++;
    notes['page_text_empty'] = _noteOf('page_text_empty', note, [
      _sevenStrokePage(note),
    ]);
  }

  {
    final note = n++;
    final page = _sevenStrokePage(note);
    final text = EditorPage(
      pageId: page.pageId,
      size: legacyPageSize,
      strokes: page.strokes,
      quill: QuillStruct(
        controller: QuillController(
          document: Document.fromJson([
            {'insert': 'Legacy note text\nSecond line of the same note\n'},
          ]),
          selection: const TextSelection.collapsed(offset: 0),
        ),
        focusNode: FocusNode(debugLabel: 'Legacy quill'),
      ),
    );
    notes['page_text'] = _noteOf('page_text', note, [text]);
  }

  {
    final note = n++;
    final page = _newPage(note, 0);
    page.insertStroke(
      _stroke(
        page,
        ToolId.fountainPen,
        0xFF000000,
        _wave(const Offset(60, 90), const Offset(540, 90)),
      ),
    );
    final core = _noteOf('photo', note, [page]);
    page.images.add(
      PngEditorImage(
        id: 0,
        assetCache: core.assetCache,
        extension: '.png',
        imageProvider: MemoryImage(await _photoBytes()),
        pageIndex: 0,
        pageSize: legacyPageSize,
        onMoveImage: null,
        onDeleteImage: null,
        onMiscChange: null,
        newImage: false,
        dstRect: legacyPhotoRect,
        srcRect: const Rect.fromLTWH(0, 0, 44, 32),
        naturalSize: const Size(44, 32),
      ),
    );
    core.nextImageId = 1;
    notes['photo'] = core;
  }

  {
    final note = n++;
    notes['forty_strokes'] = _noteOf('forty_strokes', note, [
      _fortyStrokesPage(note),
    ]);
  }

  {
    final note = n++;
    final page = _sevenStrokePage(note);
    final own = EditorPage(
      pageId: page.pageId,
      size: legacyPageSize,
      strokes: page.strokes,
      backgroundPattern: CanvasBackgroundPattern.grid,
    );
    notes['own_pattern_v20'] = _noteOf('own_pattern_v20', note, [own]);
  }

  {
    final note = n++;
    notes['side_files_three'] = _noteOf('side_files_three', note, [
      _fiveTools(note),
    ]);
  }

  {
    final note = n++;
    final source = _newNote('pasted_source');
    final from = _sevenStrokePage(note);
    final text = EditorPage(
      pageId: from.pageId,
      size: legacyPageSize,
      strokes: from.strokes,
      quill: QuillStruct(
        controller: QuillController(
          document: Document.fromJson([
            {'insert': 'Copied page text\n'},
          ]),
          selection: const TextSelection.collapsed(offset: 0),
        ),
        focusNode: FocusNode(debugLabel: 'Legacy paste quill'),
      ),
    );
    source.pages.add(text);
    final clip = await clipPage(
      text,
      notePattern: source.backgroundPattern,
      assetCache: source.assetCache,
    );
    final target = _newNote('pasted_page');
    final pasted = pastePage(
      clip,
      sbnPath: target.filePath,
      assetCache: target.assetCache,
      notePattern: target.backgroundPattern,
      pageIndex: 0,
    );
    target.pages.add(pasted.copyWith(pageId: _pageId(note, 0)));
    target.pages.add(_newPage(note, 1));
    notes['pasted_page'] = target;
  }

  {
    final note = n++;
    notes['lasso_duplicated'] = _noteOf('lasso_duplicated', note, [
      _lassoDuplicatedPage(note),
    ]);
  }

  {
    final note = n++;
    notes['forty_colours'] = _noteOf('forty_colours', note, [
      _fortyColoursPage(note),
    ]);
  }

  assert(
    notes.keys.toSet().containsAll(legacyNoteNames) &&
        notes.length == legacyNoteNames.length,
  );

  for (final name in legacyNoteNames) {
    final core = notes[name]!;
    await _writeNote(out, name, core);
    // The documents folder gets the same bytes, where the note is opened.
    for (final file in out.listSync().whereType<File>()) {
      final base = file.uri.pathSegments.last;
      if (base.startsWith('$name.sbn2') && !base.contains('.saved.')) {
        await File('${docs.path}/$base').writeAsBytes(file.readAsBytesSync());
      }
    }
    await _writeSaved(
      out,
      name,
      Uint8List.fromList(File('${out.path}/$name.sbn2').readAsBytesSync()),
    );
  }

  // The three side files of `side_files_three`.
  final sidePageId = notes['side_files_three']!.pages.first.pageId;
  final quick = EditorCoreInfo(filePath: '/legacy/quick');
  final quickPage = EditorPage(
    pageId: _pageId(99, 0),
    size: legacyPageSize,
  );
  quickPage.insertStroke(
    _stroke(
      quickPage,
      ToolId.fountainPen,
      0xFF000000,
      _wave(const Offset(60, 90), const Offset(540, 90), steps: 20),
    ),
  );
  quick.pages.add(quickPage);
  final (quickBson, _) = quick.saveToBinary(currentPageIndex: null);
  final sideFiles = <String, Uint8List>{
    'page-marks.json': _sideFiles(sidePageId),
    'quick-note.json': _json({
      'schemaVersion': 1,
      'sbnVersion': 19,
      'width': legacyPageSize.width,
      'height': legacyPageSize.height,
      'updatedAt': '2026-11-28T00:00:00.000Z',
    }),
    'quick-note.sbn2': quickBson,
    'recording.json': _json({
      'schemaVersion': 1,
      'name': 'Lecture',
      'durationMs': 3000,
      'createdAt': '2026-11-28T00:00:00.000Z',
    }),
    'audio.m4a': Uint8List.fromList(List.generate(64, (i) => (i * 5) % 256)),
  };
  assert(sideFiles.keys.toSet().containsAll(legacySideFileNames));
  for (final entry in sideFiles.entries) {
    await File(
      '${out.path}/side_files_three.${entry.key}',
    ).writeAsBytes(entry.value, flush: true);
  }
  quick.dispose();

  for (final core in notes.values) {
    core.dispose();
  }

  // The infinite note, version 1: a pen and a highlighter.
  final infinite = InfiniteDocument(
    strokes: [
      InfiniteStroke(
        id: 'pen-1',
        tool: InfiniteInkTool.pen,
        color: 0xff112233,
        width: 3,
        points: [
          for (var i = 0; i <= 30; i++)
            InfinitePoint(
              60 + i * 16.0,
              200 + 40 * sin(i / 30 * 4 * pi),
              pressure: 0.3 + 0.5 * sin(i / 30 * pi),
            ),
        ],
      ),
      InfiniteStroke(
        id: 'pen-2',
        tool: InfiniteInkTool.pen,
        color: 0xffc62828,
        width: 5,
        points: [
          for (var i = 0; i <= 20; i++)
            InfinitePoint(
              100 + i * 18.0,
              400 + 30 * cos(i / 20 * 3 * pi),
              pressure: 0.6,
            ),
        ],
      ),
      InfiniteStroke(
        id: 'marker-1',
        tool: InfiniteInkTool.highlighter,
        color: 0xffffd400,
        width: 24,
        points: const [InfinitePoint(80, 300), InfinitePoint(500, 320)],
      ),
    ],
  );
  await File(
    '${out.path}/infinite_v1.json',
  ).writeAsBytes(_json(infinite.toJson()), flush: true);
}
