import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/hold_to_line.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/ink_timing_replay.dart';
import 'package:sbn/tool_id.dart';

/// The measurement build's replay (stage 2, tablet measurement 1): the three
/// notes it makes in the 「측정」 folder, the input it plays, and that a build
/// without the measurement value does none of it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  group('the 측정 folder', () {
    late Directory temp;
    late NoteRepository repository;

    /// The app's own folder, where the replay marks that it made its notes.
    late Directory app;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('ink-timing-replay-');
      app = Directory('${temp.path}/app');
      repository = await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      );
      await FileManager.init(
        documentsDirectory: '${temp.path}/working',
        shouldWatchRootDirectory: false,
      );
    });
    tearDown(() async {
      await repository.close().timeout(const Duration(seconds: 30));
      await temp.delete(recursive: true);
    });

    /// An editor that is not on screen: what [InkTimingReplay.noteLoaded]
    /// holds on to (the replay stops at once, its editor is not mounted).
    EditorState anEditor() =>
        Editor(path: '/ink-timing-test').createState() as EditorState;

    test('a disabled replay makes no notes and starts on none', () async {
      // a vault that has the folder and notes already
      final enabled = InkTimingReplay(enabled: true);
      await enabled.seedNotes(repository, directory: app);
      final folder = (await LibraryStore(repository).listFolders()).single;
      final other = await NoteRepository.open(
        Directory('${temp.path}/vault-2'),
        createFormatVersion: 2,
      );
      addTearDown(() => other.close().timeout(const Duration(seconds: 30)));

      final replay = InkTimingReplay(enabled: false);
      final fresh = Directory('${temp.path}/app-2');
      expect(await replay.seedNotes(other, directory: fresh), isFalse);
      expect(await LibraryStore(other).listFolders(), isEmpty);
      expect(await WorkspaceStore(other).list(), isEmpty);
      expect(fresh.existsSync(), isFalse);
      expect(await replay.seedNotes(repository, directory: app), isFalse);
      expect(
        replay.noteLoaded(
          title: InkTimingNote.empty.title,
          folderId: folder.id,
          editor: anEditor,
        ),
        isFalse,
      );
    });

    /// The settings a replay puts back, set to [values] or read.
    void setSettings(
      ({ToolId tool, ToolId family, String highlighter, bool finger}) values,
    ) {
      stows.lastTool.value = values.tool;
      stows.lastPenFamily.value = values.family;
      stows.lastHighlighterKind.value = values.highlighter;
      stows.editorFingerDrawing.value = values.finger;
    }

    ({ToolId tool, ToolId family, String highlighter, bool finger})
    settings() => (
      tool: stows.lastTool.value,
      family: stows.lastPenFamily.value,
      highlighter: stows.lastHighlighterKind.value,
      finger: stows.editorFingerDrawing.value,
    );

    void resetSettings() {
      stows.lastTool.value = stows.lastTool.defaultValue;
      stows.lastPenFamily.value = stows.lastPenFamily.defaultValue;
      stows.lastHighlighterKind.value = stows.lastHighlighterKind.defaultValue;
      stows.editorFingerDrawing.value = stows.editorFingerDrawing.defaultValue;
    }

    test('a replay cut off while it played: the next start of a measurement '
        'build puts the settings back from ink-timing/restore.json', () async {
      addTearDown(resetSettings);
      // the notes were made by an earlier start
      final first = InkTimingReplay(enabled: true);
      expect(await first.seedNotes(repository, directory: app), isTrue);
      final restore = File('${app.path}/ink-timing/restore.json');
      restore.writeAsStringSync(
        jsonEncode({
          'lastTool': 'pencil',
          'lastPenFamily': 'ballpointPen',
          'lastHighlighterKind': 'hlround',
          'editorFingerDrawing': false,
        }),
      );
      // what the replay left in hand when the app was killed
      const left = (
        tool: ToolId.highlighter,
        family: ToolId.highlighter,
        highlighter: 'hlchisel',
        finger: true,
      );
      setSettings(left);

      // a build without the measurement value leaves both alone
      expect(
        await InkTimingReplay(enabled: false)
            .seedNotes(repository, directory: app),
        isFalse,
      );
      expect(settings(), left);
      expect(restore.existsSync(), isTrue);

      final next = InkTimingReplay(enabled: true);
      expect(await next.seedNotes(repository, directory: app), isFalse);
      expect(settings(), (
        tool: ToolId.pencil,
        family: ToolId.ballpointPen,
        highlighter: 'hlround',
        finger: false,
      ));
      expect(restore.existsSync(), isFalse);
    });

    test('a restore.json with values it cannot read puts back only the good '
        'ones, and goes', () async {
      addTearDown(resetSettings);
      final restore = File('${app.path}/ink-timing/restore.json');
      const left = (
        tool: ToolId.highlighter,
        family: ToolId.highlighter,
        highlighter: 'hlchisel',
        finger: true,
      );
      for (final (content, want) in [
        ('not json', left),
        ('[1, 2]', left),
        (
          jsonEncode({
            'lastTool': 'nope',
            'lastPenFamily': 'pencil',
            'lastHighlighterKind': 'fountain',
            'editorFingerDrawing': 'no',
          }),
          (
            tool: ToolId.highlighter,
            family: ToolId.pencil,
            highlighter: 'hlchisel',
            finger: true,
          ),
        ),
      ]) {
        setSettings(left);
        restore.parent.createSync(recursive: true);
        restore.writeAsStringSync(content);
        await InkTimingReplay(enabled: true)
            .seedNotes(repository, directory: app);
        expect(settings(), want, reason: content);
        expect(restore.existsSync(), isFalse, reason: content);
      }
    });

    test('a restore.json that cannot be read at all (not UTF-8) goes, and '
        'the notes are still made', () async {
      addTearDown(resetSettings);
      const left = (
        tool: ToolId.highlighter,
        family: ToolId.highlighter,
        highlighter: 'hlchisel',
        finger: true,
      );
      setSettings(left);
      final restore = File('${app.path}/ink-timing/restore.json');
      restore.parent.createSync(recursive: true);
      // reading it as text throws a FileSystemException, not a FormatException
      restore.writeAsBytesSync([0xff, 0xfe, 0xfd]);
      expect(restore.readAsStringSync, throwsA(isA<FileSystemException>()));

      final replay = InkTimingReplay(enabled: true);
      addTearDown(replay.cancel);
      expect(await replay.seedNotes(repository, directory: app), isTrue);
      expect(restore.existsSync(), isFalse);
      expect(settings(), left);
      final folder = (await LibraryStore(repository).listFolders()).single;
      expect(await WorkspaceStore(repository).list(), hasLength(3));
      // and it knows the folder, so a replay can start
      expect(
        replay.noteLoaded(
          title: InkTimingNote.empty.title,
          folderId: folder.id,
          editor: anEditor,
        ),
        isTrue,
      );
    });

    test('an enabled replay makes the three notes once for the app', () async {
      final replay = InkTimingReplay(enabled: true);
      addTearDown(replay.cancel);
      expect(await replay.seedNotes(repository, directory: app), isTrue);
      expect(File('${app.path}/ink-timing/seeded').existsSync(), isTrue);
      final folder = (await LibraryStore(repository).listFolders()).single;
      expect(folder.title, inkTimingFolder);
      expect(folder.parentId, isNull);
      final notes = await WorkspaceStore(repository).list();
      expect(
        {for (final note in notes) note.title},
        {for (final note in InkTimingNote.values) note.title},
      );
      expect(notes.map((note) => note.folderId), everyElement(folder.id));

      // a later start finds them and makes nothing, also when one is gone
      await WorkspaceStore(repository).setDeleted(
        notes.firstWhere((note) => note.title == InkTimingNote.empty.title),
        true,
      );
      final later = InkTimingReplay(enabled: true);
      addTearDown(later.cancel);
      expect(await later.seedNotes(repository, directory: app), isFalse);
      expect(await LibraryStore(repository).listFolders(), hasLength(1));
      expect(await WorkspaceStore(repository).list(), hasLength(2));

      // another vault opened by the same app gets none
      final other = await NoteRepository.open(
        Directory('${temp.path}/vault-2'),
        createFormatVersion: 2,
      );
      addTearDown(() => other.close().timeout(const Duration(seconds: 30)));
      expect(
        await InkTimingReplay(enabled: true).seedNotes(other, directory: app),
        isFalse,
      );
      expect(await LibraryStore(other).listFolders(), isEmpty);
      expect(await WorkspaceStore(other).list(), isEmpty);

      // the saved highlighter note keeps its ten opacities
      final highlighters = notes.singleWhere(
        (note) => note.title == InkTimingNote.highlighters.title,
      );
      final ink = (await repository.heads(highlighters.inkEntityId)).single;
      final core = await SaberInkAdapter.load(repository, ink);
      addTearDown(core.dispose);
      // (the editor opens it with an empty page after the last)
      expect(_layers(core).where((layers) => layers > 0), [10, 10, 10]);

      // a replay starts on the notes of its folder only, in an editor; the
      // ones that may not start come first (a started replay takes no other)
      for (final replay in [replay, later]) {
        expect(
          replay.noteLoaded(
            title: InkTimingNote.strokes.title,
            folderId: 'elsewhere',
            editor: anEditor,
          ),
          isFalse,
        );
        expect(
          replay.noteLoaded(
            title: 'a note',
            folderId: folder.id,
            editor: anEditor,
          ),
          isFalse,
        );
        expect(
          replay.noteLoaded(
            title: InkTimingNote.strokes.title,
            folderId: folder.id,
            editor: () => null,
          ),
          isFalse,
        );
        expect(
          replay.noteLoaded(
            title: InkTimingNote.strokes.title,
            folderId: folder.id,
            editor: anEditor,
          ),
          isTrue,
        );
      }
    });
  });

  test('the measurement notes: 1,500 strokes, 10 highlighter layers, '
      'an empty page', () {
    final strokes = buildTimingNote(InkTimingNote.strokes, filePath: '/s');
    final highlighters = buildTimingNote(
      InkTimingNote.highlighters,
      filePath: '/h',
    );
    final empty = buildTimingNote(InkTimingNote.empty, filePath: '/e');
    addTearDown(() {
      strokes.dispose();
      highlighters.dispose();
      empty.dispose();
    });
    // a few pages, so the pan has a way to go
    expect(strokes.pages.length, greaterThan(1));
    for (final page in strokes.pages) {
      expect(page.strokes, hasLength(1500));
      // the pens 232 has too, so a 234 build can make the same page
      expect(page.strokes.map((s) => s.toolId).toSet(), {
        ToolId.fountainPen,
        ToolId.ballpointPen,
      });
    }
    expect(highlighters.pages.length, greaterThan(1));
    expect(_layers(highlighters), everyElement(10));
    for (final page in highlighters.pages) {
      expect(
        page.strokes.map((s) => s.toolId),
        everyElement(ToolId.highlighter),
      );
      expect(page.strokes.map((s) => s.style.nib), everyElement(InkNib.chisel));
    }
    expect(empty.pages, hasLength(1));
    expect(empty.pages.single.strokes, isEmpty);
  });

  test('the long stroke never stays still long enough to become a line', () {
    const area = Rect.fromLTWH(100, 150, 600, 500);
    final points = longStrokePoints(area);
    expect(points, hasLength(3000));
    expect(points.every((p) => area.inflate(0.01).contains(p)), isTrue);
    // 「멈추면 직선」 waits 0.5 s from each move past the slop: at 120 Hz
    // that is 60 points, so the gap between two such moves (and from the
    // last one to the pen lifting) stays under 60
    final hold = HoldToLine(slop: holdToLineSlop)..start(points.first);
    final pointsInDelay = holdToLineDelay.inMilliseconds * 120 ~/ 1000;
    var last = 0;
    var longest = 0;
    for (var i = 1; i < points.length; i++) {
      expect(points[i], isNot(points[i - 1]));
      if (hold.moved(points[i])) {
        if (i - last > longest) longest = i - last;
        last = i;
      }
    }
    if (points.length - 1 - last > longest) longest = points.length - 1 - last;
    expect(longest, lessThan(pointsInDelay));
  });

  test('the page pan goes down and back without passing the end', () {
    final offsets = panOffsets(1000, step: 20, minSteps: 600);
    expect(offsets.length, greaterThanOrEqualTo(600));
    expect(offsets.first, 0);
    expect(offsets.last, 0);
    expect(offsets.reduce((a, b) => a > b ? a : b), 1000);
    expect(offsets.every((y) => y >= 0 && y <= 1000), isTrue);
    for (var i = 1; i < offsets.length; i++) {
      final step = (offsets[i] - offsets[i - 1]).abs();
      expect(step, greaterThan(0));
      expect(step, lessThanOrEqualTo(20));
    }
    // no room: no pan
    expect(panOffsets(0), isEmpty);
  });
}

/// The number of highlighter layers of each page of [core]: the painter
/// opens one for each run of strokes of one colour and opacity.
List<int> _layers(EditorCoreInfo core) => [
  for (final page in core.pages)
    () {
      var layers = 0;
      (Color, int)? last;
      for (final stroke in page.strokes) {
        final key = (stroke.color.withValues(alpha: 1), stroke.alpha);
        if (key != last) layers++;
        last = key;
      }
      return layers;
    }(),
];
