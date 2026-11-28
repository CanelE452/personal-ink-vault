import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bson/bson.dart';
import 'package:collection/collection.dart' show mergeSort;
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/inner_canvas.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/note_page_marks.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

import '../utils/test_mock_channel_handlers.dart';
import '../workspace/infinite_canvas_harness.dart';
import 'legacy_notes.dart';

/// The reference every stage-2 task re-runs: notes made once by the build 234
/// code (see legacy_notes.dart) must open, draw and save as they did. The
/// pictures were made on Windows: other systems draw text and curves a little
/// differently.
final _make = Platform.environment['PIV_MAKE_LEGACY'] == '1';
final _skipPictures = !Platform.isWindows;
final _bundle = Directory('test/ink/legacy');

Uint8List _bytes(String file) =>
    Uint8List.fromList(File('${_bundle.path}/$file').readAsBytesSync());

int _colour(Object? value) => value is Int64 ? value.toInt() : value! as int;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  late Directory temp;

  setUpAll(() async {
    await PencilShader.init();
  });

  setUp(() async {
    setupMockPathProvider();
    temp = await Directory.systemTemp.createTemp('piv-legacy-');
    EditorImage.shouldLoadOutImmediately = true;
    await FileManager.init(
      documentsDirectory: '${temp.path}/working',
      shouldWatchRootDirectory: false,
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  /// Copies the note's files into the documents folder and opens it.
  Future<EditorCoreInfo> open(String name) async {
    final dir = Directory('${FileManager.documentsDirectory}/legacy');
    await dir.create(recursive: true);
    for (final file in _bundle.listSync().whereType<File>()) {
      final base = file.uri.pathSegments.last;
      if (base == '$name.sbn2' || RegExp('^$name\\.sbn2\\.\\d+\$').hasMatch(base)) {
        await File('${dir.path}/$base').writeAsBytes(file.readAsBytesSync());
      }
    }
    return EditorCoreInfo.loadFromFileContents(
      bsonBytes: _bytes('$name.sbn2'),
      path: '/legacy/$name',
      onlyFirstPage: false,
    );
  }

  Future<void> drawPage(
    WidgetTester tester,
    EditorCoreInfo core, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = legacyPageSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A picture is drawn from its bytes: reading its file inside the test's
    // fake clock never finishes (same pixels, so the picture is the same).
    for (final image in core.pages.first.images) {
      if (image is PngEditorImage && image.imageProvider is FileImage) {
        image.imageProvider = MemoryImage(
          (image.imageProvider as FileImage).file.readAsBytesSync(),
        );
      }
    }
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: const [FlutterQuillLocalizations.delegate],
        home: Center(
          child: RepaintBoundary(
            key: const ValueKey('render-under-test'),
            child: SizedBox.fromSize(
              size: legacyPageSize,
              child: InnerCanvas(
                pageIndex: 0,
                width: legacyPageSize.width,
                height: legacyPageSize.height,
                showPageIndicator: false,
                coreInfo: core,
                currentStroke: null,
                currentStrokeDetectedShape: null,
                currentSelection: null,
                currentToolIsSelect: false,
                currentScale: scale,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      for (final image in core.pages.first.images) {
        await image
            .precache(tester.element(find.byType(InnerCanvas)))
            .timeout(const Duration(seconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('writes the legacy bundle', (tester) async {
    await tester.runAsync(() => writeLegacyNotes(_bundle));
  }, skip: !_make);

  for (final name in legacyNoteNames.where((n) => n != 'pencil')) {
    testWidgets('legacy $name renders the same', (tester) async {
      final core = await tester.runAsync(() => open(name));
      await drawPage(tester, core!);
      await expectLater(
        find.byKey(const ValueKey('render-under-test')),
        matchesGoldenFile('goldens/legacy/$name.png'),
      );
      await tester.pumpWidget(const SizedBox());
      core.dispose();
    }, skip: _make || _skipPictures);
  }

  testWidgets('legacy pencil renders the same with and without the shader', (
    tester,
  ) async {
    // 1.0 uses the pencil shader, 0.5 does not (shouldUsePencilShader).
    for (final (scale, file) in const [
      (1.0, 'pencil_shader'),
      (0.5, 'pencil_flat'),
    ]) {
      final core = await tester.runAsync(() => open('pencil'));
      await drawPage(tester, core!, scale: scale);
      await expectLater(
        find.byKey(const ValueKey('render-under-test')),
        matchesGoldenFile('goldens/legacy/$file.png'),
      );
      await tester.pumpWidget(const SizedBox());
      core.dispose();
    }
  }, skip: _make || _skipPictures);

  testWidgets('legacy infinite_v1 renders the same', (tester) async {
    final document = InfiniteDocument.fromJson(
      jsonDecode(utf8.decode(_bytes('infinite_v1.json')))
          as Map<String, dynamic>,
    );
    await mount(tester, initial: document, size: legacyPageSize);
    await expectLater(
      find.byKey(const ValueKey('infinite-strokes')),
      matchesGoldenFile('goldens/legacy/infinite_v1.png'),
    );
  }, skip: _make || _skipPictures);

  for (final name in legacyNoteNames) {
    test('legacy $name opens and saves the same bytes and version', () async {
      final core = await open(name);
      final (json, assets) = core.toJson();
      final saved = BsonCodec.serialize(json).byteList;
      final expectedVersion = name == 'own_pattern_v20' ? 20 : 19;
      expect(json['v'], expectedVersion);
      expect(
        BsonCodec.deserialize(BsonBinary.from(_bytes('$name.sbn2')))['v'],
        expectedVersion,
      );
      expect(saved, _bytes('$name.saved.sbn2'));
      if (!legacyUnsortedNames.contains(name)) {
        expect(saved, _bytes('$name.sbn2'));
      }
      for (var i = 0; i < assets.length; i++) {
        expect(
          Uint8List.fromList(await assets.getBytes(i)),
          _bytes('$name.sbn2.$i'),
        );
      }
      core.dispose();
    }, skip: _make);
  }

  test('legacy side_files_three side files name the first page of the note', () async {
    // The marks name pages by id: the id in them must be the id the note
    // has, in the stored bytes and after opening and saving with today's code.
    final marks = NotePageMarks.decode(
      _bytes('side_files_three.page-marks.json'),
    );
    final stored = BsonCodec.deserialize(
      BsonBinary.from(_bytes('side_files_three.sbn2')),
    );
    final firstId = ((stored['z'] as List).first as Map)['pageId'] as String;
    expect(marks.favorites, [firstId]);
    expect(marks.liveOutline.map((row) => row.pageId), [firstId]);
    final opened = await open('side_files_three');
    expect(opened.pages.first.pageId, firstId);
    final (savedJson, _) = opened.toJson();
    expect(((savedJson['z'] as List).first as Map)['pageId'], firstId);
    opened.dispose();
  }, skip: _make);

  test('legacy side_files_three attachments survive in a vault while the note is opened and saved', () async {
    final repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    try {
      final note = await WorkspaceStore(repository).create('Side files');
      final side = NoteSideStore(repository);
      final files = {
        NoteSideKind.pageMarks: ['page-marks.json'],
        NoteSideKind.quickNote: ['quick-note.json', 'quick-note.sbn2'],
        NoteSideKind.recording: ['recording.json', 'audio.m4a'],
      };
      for (final entry in files.entries) {
        await side.write(note.id, entry.key, {
          for (final file in entry.value)
            file: _bytes('side_files_three.$file'),
        });
      }

      final core = await open('side_files_three');
      final (json, _) = core.toJson();
      expect(BsonCodec.serialize(json).byteList, _bytes('side_files_three.saved.sbn2'));
      core.dispose();

      for (final entry in files.entries) {
        final found = (await side.list(note.id, entry.key)).single;
        final read = await side.read(found);
        expect(read.keys.toSet(), entry.value.toSet());
        for (final file in entry.value) {
          expect(read[file], _bytes('side_files_three.$file'), reason: file);
        }
      }
    } finally {
      await repository.close().timeout(const Duration(seconds: 30));
    }
  }, skip: _make);

  test('legacy infinite_v1 opens and saves as version 1 with the same bytes', () {
    final bytes = _bytes('infinite_v1.json');
    final document = InfiniteDocument.fromJson(
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
    );
    final json = document.toJson();
    expect(json['version'], 1);
    expect(Uint8List.fromList(utf8.encode(jsonEncode(json))), bytes);
  }, skip: _make);

  // Records, without failing, whether the old comparison orders the strokes
  // differently under List.sort (what the code does) and under a stable
  // mergeSort. The baseline is the List.sort result.
  test('legacy sort order: List.sort against mergeSort is recorded', () {
    for (final name in legacyUnsortedNames) {
      final json = BsonCodec.deserialize(BsonBinary.from(_bytes('$name.sbn2')));
      final pages = json['z'] as List;
      for (final (pageNo, page) in pages.indexed) {
        final strokes = (page as Map)['s'] as List? ?? const [];
        final keys = [
          for (final s in strokes) ((s as Map)['ty'] as String, _colour(s['c'])),
        ];
        int compare(int a, int b) {
          final type = keys[a].$1.compareTo(keys[b].$1);
          if (type != 0) return type;
          if (keys[a].$1 != 'Highlighter') return 0;
          return keys[a].$2.compareTo(keys[b].$2);
        }

        final list = List.generate(keys.length, (i) => i)..sort(compare);
        final merged = List.generate(keys.length, (i) => i);
        mergeSort(merged, compare: compare);
        final differing = [
          for (var i = 0; i < list.length; i++)
            if (list[i] != merged[i]) i,
        ];
        // ignore: avoid_print
        print(
          'SORTCMP $name page ${pageNo + 1}: ${keys.length} strokes, '
          '${differing.isEmpty ? "same order" : "differs at sorted positions $differing"}',
        );
      }
    }
  }, skip: _make);
}
