import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/database_editor.dart';

const _row = '00000000-0000-4000-8000-000000000011';
const _other = '00000000-0000-4000-8000-000000000012';
const _title = '00000000-0000-4000-8000-000000000001';

WorkspaceDatabase _database({BlockPageDocument? body}) {
  final database = WorkspaceDatabase.empty().copyWith(
    properties: [
      DatabaseProperty.create(id: _title, name: '이름', type: 'title'),
    ],
    rows: [
      DatabaseRow.create(
        id: _row,
        values: {_title: '자료'},
        body: body?.toJson(),
      ),
      DatabaseRow.create(
        id: _other,
        values: {_title: '원본 유지'},
        body: {
          'version': 1,
          'blocks': <dynamic>[],
          'blockMedia': {
            'future': ['opaque data'],
          },
          'futureBody': {'keep': true},
        },
      ),
    ],
  );
  return database;
}

void main() {
  late FilePickerPlatform previousPicker;
  setUp(() => previousPicker = FilePickerPlatform.instance);
  tearDown(() => FilePickerPlatform.instance = previousPicker);

  Future<GlobalKey<DatabaseEditorState>> mount(
    WidgetTester tester, {
    WorkspaceDatabase? initial,
    required Future<void> Function(WorkspaceDatabase, Map<String, Uint8List>)
    save,
    Future<Uint8List> Function(String, BlockPageMedia)? read,
  }) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<DatabaseEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabaseEditor(
            key: key,
            initialDatabase: initial ?? _database(),
            onSave: (_) async =>
                fail('Media-aware database writes must retain their file map'),
            onSaveWithMedia: save,
            onReadRowMedia: read,
            onBack: () {},
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    );
    return key;
  }

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    final watch = Stopwatch()..start();
    while (!done()) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 10));
      if (watch.elapsed > const Duration(seconds: 20)) {
        fail('The real editor/media worker did not finish');
      }
    }
    await tester.pump();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('db-row-open-$_row')));
    await tester.pump();
    await waitFor(
      tester,
      () =>
          find.byType(BlockPageEditor).evaluate().length == 1 &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.byType(BlockPageEditor), findsOneWidget);
  }

  BlockPageEditorState body(WidgetTester tester) =>
      tester.state<BlockPageEditorState>(find.byType(BlockPageEditor));

  Future<void> pick(WidgetTester tester, String label, int count) async {
    await tester.tap(find.byTooltip('블록 추가'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(label).last);
    await tester.tap(find.text(label).last);
    await tester.pump();
    await waitFor(
      tester,
      () =>
          body(tester).document.media.length == count &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
  }

  testWidgets(
    'an image in a new template row reads after publication even before autosave',
    (tester) async {
      const imageId = '00000000-0000-4000-8000-000000000031';
      const templateId = '00000000-0000-4000-8000-000000000032';
      final image = BlockPageMediaAsset.image(
        name: '도표.png',
        bytes: im.encodePng(im.Image(width: 5, height: 3)),
      );
      final initial = _database(
        body: const BlockPageDocument.empty().copyWith(
          blocks: [
            BlockPageBlock.fromJson({
              'id': imageId,
              'type': 'image',
              'text': '도표',
            }),
          ],
          media: {imageId: image.reference},
        ),
      ).captureRowTemplate(rowId: _row, templateId: templateId, name: '이미지 양식');
      var stored = initial;
      final publishedAtRead = <bool>[];
      final key = await mount(
        tester,
        initial: initial,
        save: (value, _) async => stored = value,
        read: (rowId, media) async {
          publishedAtRead.add(stored.rows.any((row) => row.id == rowId));
          expect(media.toJson(), image.reference.toJson());
          return image.bytes;
        },
      );
      await tester.tap(find.text('항목 추가'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('이미지 양식'));
      await tester.pumpAndSettle();
      final created = key.currentState!.database.rows.singleWhere(
        (row) => row.id != _row && row.id != _other,
      );
      expect(stored.rows, hasLength(2));
      await tester.tap(find.byKey(ValueKey('db-row-open-${created.id}')));
      await waitFor(tester, () => publishedAtRead.isNotEmpty);
      expect(publishedAtRead, [true]);
      final copiedBlock = BlockPageDocument.fromJson(created.body)
          .media
          .keys
          .single;
      await waitFor(
        tester,
        () => find
            .byKey(ValueKey('block-media-image-$copiedBlock'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(ValueKey('block-media-image-$copiedBlock')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'row picker media, captions, undo and back preserve another opaque row',
    (tester) async {
      final png = Uint8List.fromList(
        im.encodePng(im.Image(width: 9, height: 5)),
      );
      final attachment = Uint8List.fromList([37, 80, 68, 70, 45, 49, 10]);
      FilePickerPlatform.instance = _Picker([
        Future.value(_ChosenFile('도표.png', png)),
        Future.value(_ChosenFile('강의.pdf', attachment)),
      ]);
      final initial = _database();
      final originalOther = initial.rows.last.toJson();
      var stored = initial;
      final files = <String, Uint8List>{};
      final key = await mount(
        tester,
        initial: initial,
        save: (value, added) async {
          stored = value;
          files.addAll(added);
        },
        read: (rowId, media) async {
          expect(rowId, _row);
          return files[media.path]!;
        },
      );
      await open(tester);
      await pick(tester, '이미지', 1);
      final imageId = body(tester).document.media.keys.single;
      await tester.enterText(
        find.byKey(ValueKey('block-text-$imageId')),
        '그림 설명',
      );
      await pick(tester, '파일 첨부', 2);
      final attachmentId = body(tester).document.media.keys
          .firstWhere((id) => id != imageId);
      await tester.enterText(
        find.byKey(ValueKey('block-text-$attachmentId')),
        '첨부 설명',
      );
      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(body(tester).document.blocks.last.text, '');
      await tester.tap(find.byTooltip('다시 실행'));
      await tester.pump();
      final saved = key.currentState!.save();
      await waitFor(
        tester,
        () => find.byType(BlockPageEditor).evaluate().isEmpty,
      );
      await saved;
      final document = BlockPageDocument.fromJson(stored.rows.first.body);
      expect(
        document.blocks.where((b) => b.id == imageId).single.text,
        '그림 설명',
      );
      expect(
        document.blocks.where((b) => b.id == attachmentId).single.text,
        '첨부 설명',
      );
      expect(files[document.media[imageId]!.path], orderedEquals(png));
      expect(
        files[document.media[attachmentId]!.path],
        orderedEquals(attachment),
      );
      expect(stored.rows.last.toJson(), originalOther);
      await open(tester);
      await waitFor(
        tester,
        () => find
            .byKey(ValueKey('block-media-image-$imageId'))
            .evaluate()
            .isNotEmpty,
      );
      final displayed = tester.widget<Image>(
        find.byKey(ValueKey('block-media-image-$imageId')),
      );
      expect((displayed.image as MemoryImage).bytes, orderedEquals(png));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'failed row save retains pending bytes and retry acknowledges the same media',
    (tester) async {
      final bytes = Uint8List.fromList([11, 22, 33, 44]);
      FilePickerPlatform.instance = _Picker([
        Future.value(_ChosenFile('자료.bin', bytes)),
      ]);
      var attempts = 0;
      final payloads = <Map<String, Uint8List>>[];
      WorkspaceDatabase? stored;
      final key = await mount(
        tester,
        save: (value, files) async {
          payloads.add({
            for (final entry in files.entries)
              entry.key: Uint8List.fromList(entry.value),
          });
          if (++attempts == 1) throw StateError('disk write failed');
          stored = value;
        },
      );
      await open(tester);
      await pick(tester, '파일 첨부', 1);
      final id = body(tester).document.media.keys.single;
      await tester.enterText(find.byKey(ValueKey('block-text-$id')), '재시도할 설명');
      await expectLater(key.currentState!.save(), throwsStateError);
      await tester.pump();
      expect(find.byType(BlockPageEditor), findsOneWidget);
      expect(body(tester).document.blocks.last.text, '재시도할 설명');
      final retry = key.currentState!.save();
      await waitFor(
        tester,
        () => find.byType(BlockPageEditor).evaluate().isEmpty,
      );
      await retry;
      expect(payloads, hasLength(2));
      expect(payloads.first.keys, payloads.last.keys);
      expect(payloads.first.values.single, orderedEquals(bytes));
      expect(payloads.last.values.single, orderedEquals(bytes));
      expect(
        BlockPageDocument.fromJson(stored!.rows.first.body)
            .media[id]!
            .byteLength,
        4,
      );
    },
  );

  testWidgets(
    'edits during a pending generation save the later caption without losing binary',
    (tester) async {
      final bytes = Uint8List.fromList([9, 8, 7]);
      FilePickerPlatform.instance = _Picker([
        Future.value(_ChosenFile('대기.bin', bytes)),
      ]);
      final firstAck = Completer<void>();
      addTearDown(() {
        if (!firstAck.isCompleted) firstAck.complete();
      });
      final written = <WorkspaceDatabase>[];
      final binary = <String, Uint8List>{};
      final key = await mount(
        tester,
        save: (database, files) async {
          written.add(database);
          if (written.length == 1) await firstAck.future;
          binary.addAll(files);
        },
      );
      await open(tester);
      await pick(tester, '파일 첨부', 1);
      final id = body(tester).document.media.keys.single;
      await tester.enterText(find.byKey(ValueKey('block-text-$id')), '첫 설명');
      final saving = key.currentState!.save();
      await tester.pump();
      expect(written, hasLength(1));
      await tester.enterText(find.byKey(ValueKey('block-text-$id')), '두 번째 설명');
      await tester.pump();
      firstAck.complete();
      await waitFor(
        tester,
        () => find.byType(BlockPageEditor).evaluate().isEmpty,
      );
      await saving;
      expect(written, hasLength(2));
      expect(
        BlockPageDocument.fromJson(written.first.rows.first.body)
            .blocks
            .last
            .text,
        '첫 설명',
      );
      final latest = BlockPageDocument.fromJson(written.last.rows.first.body);
      expect(latest.blocks.last.text, '두 번째 설명');
      expect(binary[latest.media[id]!.path], orderedEquals(bytes));
    },
  );

  testWidgets(
    'late picker completion after editor disposal does not save a row',
    (tester) async {
      final picked = Completer<PlatformFile?>();
      FilePickerPlatform.instance = _Picker([picked.future]);
      var writes = 0;
      await mount(
        tester,
        save: (_, _) async {
          writes++;
        },
      );
      await open(tester);
      await tester.tap(find.byTooltip('블록 추가'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('파일 첨부').last);
      await tester.tap(find.text('파일 첨부').last);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      picked.complete(_ChosenFile('늦은 첨부.bin', Uint8List.fromList([1, 2, 3])));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'archiving a row while its picker waits rejects the late body save',
    (tester) async {
      final picked = Completer<PlatformFile?>();
      FilePickerPlatform.instance = _Picker([picked.future]);
      var writes = 0;
      final key = await mount(
        tester,
        save: (_, _) async {
          writes++;
        },
      );
      await open(tester);
      await tester.tap(find.byTooltip('블록 추가'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('파일 첨부').last);
      await tester.tap(find.text('파일 첨부').last);
      await tester.pump();
      final action = tester.widget<PopupMenuButton<String>>(
        find
            .descendant(
              of: find.byType(DatabaseEditor, skipOffstage: false),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is PopupMenuButton<String> &&
                    widget.tooltip == '항목 메뉴',
                skipOffstage: false,
              ),
              skipOffstage: false,
            )
            .first,
      );
      action.onSelected!('archive');
      await tester.pump();
      picked.complete(_ChosenFile('보관된 행.bin', Uint8List.fromList([4, 5])));
      await waitFor(
        tester,
        () =>
            body(tester).document.media.length == 1 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      await expectLater(key.currentState!.save(), throwsStateError);
      expect(key.currentState!.database.rows.first.archived, true);
      expect(writes, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'undo after saving a row media deletion can export retained bytes before another save',
    (tester) async {
      final bytes = Uint8List.fromList([71, 72, 73, 74]);
      final asset = BlockPageMediaAsset.attachment(
        name: '보존한 원본.bin',
        bytes: bytes,
      );
      final block = BlockPageBlock.create(type: 'attachment', text: '되돌릴 첨부');
      final document = const BlockPageDocument.empty().copyWith(
        blocks: [block],
        media: {block.id: asset.reference},
      );
      final picker = _Picker([]);
      FilePickerPlatform.instance = picker;
      var stored = _database(body: document);
      await mount(
        tester,
        initial: stored,
        save: (value, files) async {
          stored = value;
        },
        read: (rowId, media) async {
          expect(rowId, _row);
          expect(media.path, asset.reference.path);
          return Uint8List.fromList(bytes);
        },
      );
      await open(tester);
      await tester.tap(find.byKey(ValueKey('block-actions-${block.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제').last);
      await tester.pumpAndSettle();
      await body(tester).save();
      await tester.pump();
      expect(BlockPageDocument.fromJson(stored.rows.first.body).media, isEmpty);
      expect(find.byType(BlockPageEditor), findsOneWidget);
      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(body(tester).document.media[block.id], isNotNull);
      expect(BlockPageDocument.fromJson(stored.rows.first.body).media, isEmpty);
      await tester.tap(find.byKey(ValueKey('block-media-export-${block.id}')));
      await waitFor(
        tester,
        () =>
            picker.savedBytes != null ||
            find.text('파일을 저장하지 못했습니다. 다시 시도하세요.').evaluate().isNotEmpty,
      );
      expect(picker.savedBytes, orderedEquals(bytes));
      expect(BlockPageDocument.fromJson(stored.rows.first.body).media, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'ordinary database metadata saves keep registered row media and use the media-aware writer',
    (tester) async {
      final asset = BlockPageMediaAsset.attachment(
        name: '기존.bin',
        bytes: Uint8List.fromList([6, 7, 8]),
      );
      final block = BlockPageBlock.create(type: 'attachment', text: '기존 첨부');
      final doc = const BlockPageDocument.empty().copyWith(
        blocks: [block],
        media: {block.id: asset.reference},
      );
      WorkspaceDatabase? saved;
      Map<String, Uint8List>? added;
      final key = await mount(
        tester,
        initial: _database(body: doc),
        save: (value, files) async {
          saved = value;
          added = files;
        },
      );
      await tester.tap(find.byKey(const ValueKey('db-cell-$_row-$_title')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('db-cell-input')),
        '새 제목',
      );
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await key.currentState!.save();
      expect(saved!.rows.first.values[_title], '새 제목');
      expect(saved!.rows.first.body, doc.toJson());
      expect(added, isEmpty);
    },
  );
}

final class _Picker extends FilePickerPlatform {
  new(this.results);
  final List<Future<PlatformFile?>> results;
  Uint8List? savedBytes;
  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) => results.removeAt(0);

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    savedBytes = Uint8List.fromList(bytes);
    return Uri.parse('memory://saved/output.bin');
  }
}

final class _ChosenFile extends PlatformFile {
  new(this.name, this.bytes);
  @override
  final String name;
  final Uint8List bytes;
  @override
  Uri get uri => Uri.parse('memory://picked/$name');
  @override
  Never get xFile => throw UnsupportedError('Use the bounded picker stream');
  @override
  int lengthSync() => bytes.length;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList(bytes);
  @override
  Stream<Uint8List> readAsByteStream() =>
      Stream.value(Uint8List.fromList(bytes));
}
