import 'dart:io';
import 'dart:typed_data';

import 'package:bson/bson.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/data/audio/recording_entry.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/quick_note.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:saber/data/vault/note_page_marks.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/read_only_reason.dart';
import 'package:sbn/tool_id.dart';

/// The newest note version Android 232 and Windows 226 read: their
/// `EditorCoreInfo.sbnVersion` (editor_core_info.dart:51 at 1c85dcd and at
/// v0.2.0-android.226), and they open a newer note read-only.
const _newestIn232 = 19;

/// The keys 232 reads and writes in a note body and in a page (`toJson` and
/// `fromJson` of editor_core_info.dart and page.dart at 1c85dcd). `a` holds
/// the inline assets `saveToBinary` adds.
const _noteKeysIn232 = {'v', 'ni', 'b', 'p', 'l', 'lt', 'z', 'c', 'a'};
const _pageKeysIn232 = {'pageId', 'w', 'h', 's', 'i', 'q', 'b', 'lk'};

/// How 232 judges a note body (editor_core_info.dart:129-131 at 1c85dcd).
ReadOnlyReason? _readIn232(Map<String, dynamic> body) =>
    (body['v'] as int? ?? 0) > _newestIn232
    ? ReadOnlyReason.versionTooNew
    : null;

Pen _pen([ToolId tool = ToolId.ballpointPen]) => Pen(
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

/// A finished stroke along a row of whole page units.
void _drawOn(EditorPage page, [ToolId tool = ToolId.ballpointPen]) {
  final stroke = _pen(tool).createStroke(page, 0);
  for (var i = 0; i <= 10; i++) {
    stroke.addPoint(Offset(40 + 10.0 * i, 60), null);
  }
  stroke
    ..options.isComplete = true
    ..markPolygonNeedsUpdating();
  page.insertStroke(stroke);
}

Map<String, dynamic> _body(Uint8List bytes) =>
    BsonCodec.deserialize(BsonBinary.from(bytes));

/// Notes made by this app (233) open in the apps people use now (Android 232,
/// Windows 226) unless a page has its own pattern. Favourites, the outline,
/// the quick note and recordings sit in attachments beside the note, so the
/// note body stays version 19. With `PIV_COMPAT_OUT` set, each vault is
/// written under that folder (`a`, `b`) for a one-off check with 232's code.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  StrokeOptionsExtension.setDefaults();

  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('piv-old-app-');
    await FileManager.init(
      documentsDirectory: '${temp.path}/working',
      shouldWatchRootDirectory: false,
    );
  });
  tearDown(() async {
    Pen.currentStroke = null;
    await temp.delete(recursive: true);
  });

  Future<NoteRepository> openVault(String name) async {
    final out = Platform.environment['PIV_COMPAT_OUT'];
    final repository = await NoteRepository.open(
      Directory(out == null ? '${temp.path}/vault' : '$out/$name'),
      createFormatVersion: 2,
    );
    addTearDown(() => repository.close().timeout(const Duration(seconds: 30)));
    return repository;
  }

  /// A lined note of two pages, the first with a stroke and [firstPattern].
  Future<(VaultNote, EditorCoreInfo)> createNote(
    NoteRepository repository,
    String title, {
    required CanvasBackgroundPattern firstPattern,
    ToolId tool = ToolId.ballpointPen,
  }) async {
    final workspace = WorkspaceStore(repository);
    final note = await workspace.create(title);
    final core = EditorCoreInfo(filePath: '/old-app/$title')
      ..backgroundPattern = .lined
      ..pages.addAll([
        EditorPage(backgroundPattern: firstPattern),
        EditorPage(),
      ]);
    _drawOn(core.pages.first, tool);
    final session = await workspace.open(note);
    await session.saveInk(await SaberInkAdapter.capture(core, 0));
    return (note, core);
  }

  Future<(RevisionRecord, Map<String, dynamic>)> inkOf(
    NoteRepository repository,
    VaultNote note,
  ) async {
    final ink = (await repository.heads(note.inkEntityId)).single;
    final files = await repository.readFiles(ink);
    return (ink, _body(files['main.sbn2']!));
  }

  test('a note with favourites, an outline, a quick note and a recording '
      'stays version 19, its attachments outside the note body', () async {
    final repository = await openVault('a');
    final side = NoteSideStore(repository);
    // every page says the note's pattern (lined), one of them out loud
    final (note, core) = await createNote(
      repository,
      'Attachments',
      firstPattern: .lined,
    );
    final first = core.pages[0].pageId;
    final second = core.pages[1].pageId;
    core.dispose();
    final (inkBefore, _) = await inkOf(repository, note);

    final marks = NotePageMarks()
      ..addFavorite(first)
      ..addOutline(second, 'Chapter 1');
    await side.write(note.id, NoteSideKind.pageMarks, {
      NoteSideKind.pageMarks.markerFile: marks.encode(),
    });
    final quick = await QuickNote.open(
      side,
      note.id,
      saveDelay: const Duration(hours: 1),
    );
    quick.penDown(const Offset(20, 20), _pen(), null);
    for (var i = 1; i <= 10; i++) {
      quick.penMove(Offset(20 + 10.0 * i, 20), null);
    }
    quick.penUp();
    await quick.flush();
    expect(quick.hasUnsavedChanges, isFalse);
    quick.dispose();
    await NoteRecordings(side).add(
      note.id,
      audio: Uint8List.fromList(List.generate(64, (i) => i)),
      duration: const Duration(seconds: 3),
      createdAt: DateTime.utc(2026, 11, 27, 9),
    );

    // The note body is the one saved before the attachments, and holds only
    // what 232 knows.
    final (ink, body) = await inkOf(repository, note);
    expect(ink.revisionId, inkBefore.revisionId);
    expect(ink.blobs.keys, ['main.sbn2']);
    expect(body['v'], 19);
    expect(_noteKeysIn232.containsAll(body.keys), isTrue, reason: '$body');
    for (final page in (body['z'] as List).cast<Map>()) {
      expect(page.containsKey('bp'), isFalse);
      expect(_pageKeysIn232.containsAll(page.keys), isTrue, reason: '$page');
    }
    expect(_readIn232(body), isNull);

    // Each attachment is an entity of its own, owned by the note.
    const files = {
      NoteSideKind.pageMarks: {'page-marks.json'},
      NoteSideKind.quickNote: {'quick-note.json', 'quick-note.sbn2'},
      NoteSideKind.recording: {'recording.json', 'audio.m4a'},
    };
    for (final MapEntry(key: kind, value: names) in files.entries) {
      final head = (await side.list(note.id, kind)).single.heads.single;
      expect(head.kind, EntityKind.attachment);
      expect(head.ownerNoteId, note.id);
      expect(head.entityId, isNot(note.inkEntityId));
      expect(head.blobs.keys.toSet(), names, reason: kind.name);
    }

    // and this app opens it as before
    final opened = await SaberInkAdapter.load(repository, ink);
    expect(opened.readOnlyReason, isNull);
    expect(opened.pages.first.strokes, hasLength(1));
    opened.dispose();
  });

  test('only a note with a page of another pattern is version 20, which 232 '
      'does not open', () async {
    final repository = await openVault('b');
    final (note, core) = await createNote(
      repository,
      'Mixed patterns',
      firstPattern: .dots,
    );
    core.dispose();

    final (ink, body) = await inkOf(repository, note);
    expect(ink.blobs.keys, ['main.sbn2']);
    expect(body['v'], 20);
    expect(body['p'], 'lined');
    final pages = (body['z'] as List).cast<Map>();
    expect(pages.map((page) => page['bp']), ['dots', null]);
    expect(_readIn232(body), ReadOnlyReason.versionTooNew);

    // this app opens it to write in
    final opened = await SaberInkAdapter.load(repository, ink);
    expect(opened.readOnlyReason, isNull);
    expect(opened.pages.first.backgroundPattern, CanvasBackgroundPattern.dots);
    opened.dispose();
  });

  test('a note with a brush stroke is version 21, which 232 does not open, '
      'and this app opens to write in', () async {
    final repository = await openVault('c');
    final (note, core) = await createNote(
      repository,
      'Brush',
      firstPattern: .lined,
      tool: ToolId.brush,
    );
    core.dispose();

    final (ink, body) = await inkOf(repository, note);
    expect(body['v'], 21);
    expect(_readIn232(body), ReadOnlyReason.versionTooNew);

    final opened = await SaberInkAdapter.load(repository, ink);
    expect(opened.readOnlyReason, isNull);
    expect(opened.pages.first.strokes.single.toolId, ToolId.brush);
    opened.dispose();
  });
}
