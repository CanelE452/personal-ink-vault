import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';

void main() {
  Future<GlobalKey<BlockPageEditorState>> mount(
    WidgetTester tester, {
    required BlockPageDocument initial,
    Future<void> Function(BlockPageDocument)? save,
    Future<void> Function(BlockPageDocument, Map<String, Uint8List>)? saveMedia,
    Future<Uint8List> Function(BlockPageMedia)? read,
    Future<BlockPageMediaAsset?> Function(bool image)? pick,
    Future<void> Function(BlockPageMedia, Uint8List)? export,
    ValueChanged<bool>? busy,
    ValueChanged<bool>? dirty,
    VoidCallback? back,
  }) async {
    final key = GlobalKey<BlockPageEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockPageEditor(
            key: key,
            initialDocument: initial,
            onSave: save ?? (_) async {},
            onBack: back ?? () {},
            onSaveWithMedia: saveMedia,
            onReadMedia: read,
            onPickMedia: pick,
            onExportMedia: export,
            onBusyChanged: busy,
            onDirtyChanged: dirty,
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    );
    return key;
  }

  BlockPageDocument withMedia(
    BlockPageBlock block,
    BlockPageMediaAsset asset,
  ) => const BlockPageDocument.empty().copyWith(
    blocks: [block],
    media: {block.id: asset.reference},
  );

  testWidgets(
    'registered attachment displays its file and retains it while editing the caption',
    (tester) async {
      final asset = BlockPageMediaAsset.attachment(
        name: '강의 자료.pdf',
        bytes: Uint8List.fromList([37, 80, 68, 70, 45, 49]),
        mimeType: 'application/pdf',
      );
      final block = BlockPageBlock.create(type: 'attachment', text: '수업 자료');
      BlockPageDocument? saved;
      final key = await mount(
        tester,
        initial: withMedia(block, asset),
        save: (document) async => saved = document,
      );

      expect(find.text('강의 자료.pdf'), findsOneWidget);
      await tester.enterText(
        find.byKey(ValueKey('block-text-${block.id}')),
        '자료에 대한 설명',
      );
      await key.currentState!.save();

      expect(saved!.blocks.single.text, '자료에 대한 설명');
      expect(saved!.media[block.id]!.name, '강의 자료.pdf');
      expect(saved!.media[block.id]!.byteLength, 6);
      expect(saved!.version, 2);
    },
  );

  testWidgets(
    'registered image exposes an editable caption instead of an unsupported block',
    (tester) async {
      final asset = BlockPageMediaAsset.image(
        name: '실험 도표.png',
        bytes: im.encodePng(im.Image(width: 12, height: 8)),
      );
      final block = BlockPageBlock.create(type: 'image', text: '실험 결과');
      final key = await mount(tester, initial: withMedia(block, asset));

      expect(find.text('실험 도표.png'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('block-text-${block.id}')))
            .controller!
            .text,
        '실험 결과',
      );
      expect(key.currentState!.document.media[block.id]!.width, 12);
      expect(key.currentState!.document.media[block.id]!.height, 8);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy opaque image JSON stays opaque after an unrelated text edit',
    (tester) async {
      final opaqueId = newId();
      final paragraph = BlockPageBlock.create(text: '기존 내용');
      final opaque = <String, dynamic>{
        'id': opaqueId,
        'type': 'image',
        'text': '',
        'source': {
          'future': ['unrecognized'],
          'uri': 'future://original',
        },
      };
      final raw = <String, dynamic>{
        'version': 1,
        'blockMedia': {
          'future': ['keep this opaque extension'],
        },
        'blocks': [opaque, paragraph.toJson()],
      };
      BlockPageDocument? saved;
      final key = await mount(
        tester,
        initial: BlockPageDocument.fromJson(raw),
        save: (document) async => saved = document,
      );

      expect(find.text('지원하지 않는 블록 · 원본 보관됨'), findsOneWidget);
      expect(find.byKey(ValueKey('block-text-$opaqueId')), findsNothing);
      await tester.enterText(
        find.byKey(ValueKey('block-text-${paragraph.id}')),
        '수정된 본문',
      );
      await key.currentState!.save();

      expect(saved!.version, 1);
      expect(saved!.media, isEmpty);
      expect((saved!.toJson()['blocks'] as List).first, opaque);
      expect(saved!.toJson()['blockMedia'], raw['blockMedia']);
    },
  );

  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'media captions and long attachment names fit a $width pixel editor',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final asset = BlockPageMediaAsset.attachment(
          name: '한글과 띄어쓰기가 있는 아주 긴 강의 첨부 자료 이름 2026-11-06.pdf',
          bytes: [1, 2, 3, 4],
        );
        final block = BlockPageBlock.create(type: 'attachment', text: '첨부 설명');
        await mount(tester, initial: withMedia(block, asset));
        await tester.pump();

        expect(
          find.text('한글과 띄어쓰기가 있는 아주 긴 강의 첨부 자료 이름 2026-11-06.pdf'),
          findsOneWidget,
        );
        expect(find.byKey(ValueKey('block-text-${block.id}')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  Future<void> settleMedia(WidgetTester tester) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 10));
      final pending =
          find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      if (!pending) break;
      if (elapsed.elapsed > const Duration(seconds: 15)) {
        fail('The actual media worker did not finish within 15 seconds.');
      }
    }
    await tester.pumpAndSettle();
  }

  Future<void> addMedia(
    WidgetTester tester,
    String label, {
    bool waitForWork = true,
  }) async {
    await tester.tap(find.byTooltip('블록 추가'));
    await tester.pumpAndSettle();
    final item = find.text(label).last;
    await tester.ensureVisible(item);
    await tester.tap(item);
    await tester.pump();
    if (waitForWork) {
      await settleMedia(tester);
    } else {
      await tester.pump(const Duration(milliseconds: 250));
    }
  }

  Future<void> action(WidgetTester tester, String id, String label) async {
    await tester.tap(find.byKey(ValueKey('block-actions-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pump();
    await settleMedia(tester);
  }

  testWidgets(
    'picking an image saves its caption and exact bytes with the page',
    (tester) async {
      final png = im.encodePng(im.Image(width: 7, height: 4));
      final asset = BlockPageMediaAsset.image(name: '표본.png', bytes: png);
      final paragraph = BlockPageBlock.create(text: '기존 본문');
      BlockPageDocument? saved;
      Map<String, Uint8List>? payload;
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [paragraph]),
        pick: (image) async {
          expect(image, isTrue);
          return asset;
        },
        saveMedia: (document, files) async {
          saved = document;
          payload = files;
        },
      );

      await addMedia(tester, '이미지');
      final added = key.currentState!.document.blocks.last;
      expect(find.text('표본.png'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
      await tester.enterText(
        find.byKey(ValueKey('block-text-${added.id}')),
        '그래프 설명',
      );
      await key.currentState!.save();

      expect(saved!.blocks.first.text, '기존 본문');
      expect(saved!.blocks.last.text, '그래프 설명');
      expect(saved!.version, 2);
      expect(payload!.keys, [asset.reference.path]);
      expect(payload![asset.reference.path], orderedEquals(png));
    },
  );

  testWidgets(
    'replacing a file keeps its block identity and caption through undo redo',
    (tester) async {
      final first = BlockPageMediaAsset.attachment(
        name: '첫째.txt',
        bytes: [1, 2],
      );
      final second = BlockPageMediaAsset.attachment(
        name: '둘째.txt',
        bytes: [3, 4, 5],
      );
      final picks = [first, second];
      final writes = <Map<String, Uint8List>>[];
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty(),
        pick: (image) async {
          expect(image, isFalse);
          return picks.removeAt(0);
        },
        saveMedia: (_, files) async => writes.add(files),
      );

      await addMedia(tester, '파일 첨부');
      final id = key.currentState!.document.blocks.single.id;
      await tester.enterText(find.byKey(ValueKey('block-text-$id')), '참고 자료');
      await action(tester, id, '파일 바꾸기');
      expect(key.currentState!.document.blocks.single.id, id);
      expect(key.currentState!.document.blocks.single.text, '참고 자료');
      expect(key.currentState!.document.media[id]!.name, '둘째.txt');

      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(key.currentState!.document.media[id]!.name, '첫째.txt');
      await tester.tap(find.byTooltip('다시 실행'));
      await tester.pump();
      expect(key.currentState!.document.media[id]!.name, '둘째.txt');
      await key.currentState!.save();
      expect(writes.single.keys, [second.reference.path]);
      expect(writes.single[second.reference.path], orderedEquals([3, 4, 5]));

      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      await key.currentState!.save();
      expect(writes.last.keys, [first.reference.path]);
      expect(writes.last[first.reference.path], orderedEquals([1, 2]));
    },
  );

  testWidgets('delete then undo retains an unsaved attachment payload', (
    tester,
  ) async {
    final asset = BlockPageMediaAsset.attachment(
      name: '보관.txt',
      bytes: [9, 8, 7],
    );
    Map<String, Uint8List>? saved;
    final key = await mount(
      tester,
      initial: const BlockPageDocument.empty(),
      pick: (_) async => asset,
      saveMedia: (_, files) async => saved = files,
    );

    await addMedia(tester, '파일 첨부');
    final id = key.currentState!.document.blocks.single.id;
    await action(tester, id, '삭제');
    expect(key.currentState!.document.blocks, isEmpty);
    await tester.tap(find.byTooltip('실행 취소'));
    await tester.pump();
    await key.currentState!.save();

    expect(key.currentState!.document.blocks.single.id, id);
    expect(saved![asset.reference.path], orderedEquals([9, 8, 7]));
  });

  testWidgets('moving media blocks retains each file association', (
    tester,
  ) async {
    final first = BlockPageMediaAsset.attachment(name: '앞.txt', bytes: [1]);
    final second = BlockPageMediaAsset.attachment(name: '뒤.txt', bytes: [2]);
    final picks = [first, second];
    final key = await mount(
      tester,
      initial: const BlockPageDocument.empty(),
      pick: (_) async => picks.removeAt(0),
      saveMedia: (_, _) async {},
    );

    await addMedia(tester, '파일 첨부');
    await addMedia(tester, '파일 첨부');
    final before = key.currentState!.document.blocks.map((b) => b.id).toList();
    await action(tester, before.last, '위로 이동');

    expect(key.currentState!.document.blocks.map((b) => b.id), before.reversed);
    expect(key.currentState!.document.media[before.first]!.name, '앞.txt');
    expect(key.currentState!.document.media[before.last]!.name, '뒤.txt');
  });

  testWidgets(
    'a failed save cannot mutate pending bytes and back retries the same draft',
    (tester) async {
      final asset = BlockPageMediaAsset.attachment(
        name: '원본.txt',
        bytes: [1, 2, 3],
      );
      final attempts = <List<int>>[];
      final busy = <bool>[];
      var fail = true, backs = 0;
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty(),
        pick: (_) async => asset,
        busy: busy.add,
        back: () => backs++,
        saveMedia: (_, files) async {
          attempts.add(List.of(files[asset.reference.path]!));
          if (fail) {
            files[asset.reference.path]![0] = 255;
            throw StateError('disk full');
          }
        },
      );

      await addMedia(tester, '파일 첨부');
      final id = key.currentState!.document.blocks.single.id;
      busy.clear();
      await tester.tap(find.byTooltip('문서 목록으로'));
      await tester.pumpAndSettle();
      expect(backs, 0);
      expect(key.currentState!.document.blocks.single.id, id);
      expect(key.currentState!.document.media[id]!.name, '원본.txt');
      expect(find.text('저장하지 못했습니다. 작업 내용은 열려 있습니다.'), findsOneWidget);

      fail = false;
      await tester.tap(find.byTooltip('문서 목록으로'));
      await tester.pumpAndSettle();
      expect(backs, 1);
      expect(attempts, [
        [1, 2, 3],
        [1, 2, 3],
      ]);
      expect(busy, [true, false, true, false]);
    },
  );

  testWidgets(
    'a caption entered during media save is drained without resending committed bytes',
    (tester) async {
      final asset = BlockPageMediaAsset.attachment(
        name: '자료.txt',
        bytes: [3, 1, 4],
      );
      final entered = Completer<void>(), release = Completer<void>();
      final writes = <(BlockPageDocument, Map<String, Uint8List>)>[];
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty(),
        pick: (_) async => asset,
        saveMedia: (document, files) async {
          writes.add((document, files));
          if (writes.length == 1) {
            entered.complete();
            await release.future;
          }
        },
      );

      await addMedia(tester, '파일 첨부');
      final id = key.currentState!.document.blocks.single.id;
      final saving = key.currentState!.save();
      await entered.future;
      await tester.enterText(
        find.byKey(ValueKey('block-text-$id')),
        '저장 중 새 설명',
      );
      release.complete();
      await saving;

      expect(writes.length, 2);
      expect(writes.first.$2[asset.reference.path], orderedEquals([3, 1, 4]));
      expect(writes.last.$1.blocks.single.text, '저장 중 새 설명');
      expect(writes.last.$2, isEmpty);
    },
  );

  testWidgets(
    'canceling a picker clears busy without making or saving a block',
    (tester) async {
      final selection = Completer<BlockPageMediaAsset?>();
      final busy = <bool>[], dirty = <bool>[];
      var writes = 0, backs = 0;
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty(),
        pick: (_) => selection.future,
        busy: busy.add,
        dirty: dirty.add,
        back: () => backs++,
        saveMedia: (_, _) async => writes++,
      );

      await addMedia(tester, '파일 첨부', waitForWork: false);
      expect(busy, [true]);
      expect(key.currentState!.document.blocks, isEmpty);
      final backButton = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '문서 목록으로',
        ),
      );
      expect(backButton.onPressed, isNull);
      await expectLater(key.currentState!.save(), throwsStateError);
      selection.complete(null);
      await settleMedia(tester);

      expect(busy, [true, false]);
      expect(dirty, isEmpty);
      expect(writes, 0);
      expect(backs, 0);
      expect(key.currentState!.document.blocks, isEmpty);
    },
  );

  testWidgets('picker failure keeps the draft and a later pick can succeed', (
    tester,
  ) async {
    final asset = BlockPageMediaAsset.attachment(name: '다시.txt', bytes: [6]);
    final busy = <bool>[];
    var attempt = 0;
    final paragraph = BlockPageBlock.create(text: '기존 기록');
    final key = await mount(
      tester,
      initial: const BlockPageDocument.empty().copyWith(blocks: [paragraph]),
      busy: busy.add,
      pick: (_) async {
        if (attempt++ == 0) throw StateError('picker failed');
        return asset;
      },
      saveMedia: (_, _) async {},
    );

    await addMedia(tester, '파일 첨부');
    expect(key.currentState!.document.blocks.single.text, '기존 기록');
    expect(key.currentState!.document.media, isEmpty);
    await addMedia(tester, '파일 첨부');

    expect(key.currentState!.document.blocks.first.text, '기존 기록');
    expect(key.currentState!.document.media.values.single.name, '다시.txt');
    expect(busy, [true, false, true, false]);
  });

  testWidgets(
    'disposing during a picker discards its late result and releases busy',
    (tester) async {
      final selection = Completer<BlockPageMediaAsset?>();
      final busy = <bool>[], dirty = <bool>[];
      var writes = 0;
      await mount(
        tester,
        initial: const BlockPageDocument.empty(),
        pick: (_) => selection.future,
        busy: busy.add,
        dirty: dirty.add,
        saveMedia: (_, _) async => writes++,
      );

      await addMedia(tester, '파일 첨부', waitForWork: false);
      await tester.pumpWidget(const SizedBox());
      selection.complete(
        BlockPageMediaAsset.attachment(name: '늦게.txt', bytes: [8]),
      );
      await tester.pump();

      expect(busy, [true, false]);
      expect(dirty, isEmpty);
      expect(writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'export reads owned media and gives the consumer a defensive payload',
    (tester) async {
      final bytes = Uint8List.fromList([7, 8, 9]);
      final asset = BlockPageMediaAsset.attachment(
        name: '내 자료.bin',
        bytes: bytes,
      );
      final block = BlockPageBlock.create(type: 'attachment');
      String? exportedName;
      List<int>? exported;
      final busy = <bool>[];
      await mount(
        tester,
        initial: withMedia(block, asset),
        busy: busy.add,
        read: (_) async => bytes,
        export: (reference, payload) async {
          exportedName = reference.name;
          exported = List.of(payload);
          payload[0] = 0;
        },
      );

      await tester.tap(find.byKey(ValueKey('block-media-export-${block.id}')));
      await settleMedia(tester);

      expect(exportedName, '내 자료.bin');
      expect(exported, [7, 8, 9]);
      expect(bytes, orderedEquals([7, 8, 9]));
      expect(busy, [true, false]);
    },
  );

  testWidgets(
    'a failed image read can retry and display the real image bytes',
    (tester) async {
      final png = im.encodePng(im.Image(width: 10, height: 6));
      final asset = BlockPageMediaAsset.image(name: '다시 보기.png', bytes: png);
      final block = BlockPageBlock.create(type: 'image');
      var fail = true;
      final retryRead = Completer<Uint8List>();
      await mount(
        tester,
        initial: withMedia(block, asset),
        read: (_) async {
          if (fail) throw StateError('temporarily unavailable');
          return retryRead.future;
        },
      );
      await settleMedia(tester);
      expect(find.byType(Image), findsNothing);

      fail = false;
      await tester.tap(find.byKey(ValueKey('block-media-retry-${block.id}')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      retryRead.complete(Uint8List.fromList(png));
      await settleMedia(tester);

      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a text-only owner cannot add binary blocks without an atomic media writer',
    (tester) async {
      await mount(tester, initial: const BlockPageDocument.empty());
      await tester.tap(find.byTooltip('블록 추가'));
      await tester.pumpAndSettle();

      expect(find.text('이미지'), findsNothing);
      expect(find.text('파일 첨부'), findsNothing);
      expect(find.text('문단'), findsOneWidget);
    },
  );

  testWidgets(
    'default file save uses a safe basename while retaining the original label',
    (tester) async {
      final picker = _SavePicker();
      final previous = FilePickerPlatform.instance;
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = previous);
      final asset = BlockPageMediaAsset.attachment(
        name: '../folder\\한글:자료?.PPTX',
        bytes: [1, 2, 3],
      );
      final block = BlockPageBlock.create(type: 'attachment');
      await mount(
        tester,
        initial: withMedia(block, asset),
        read: (_) async => Uint8List.fromList([1, 2, 3]),
      );

      await tester.tap(find.byKey(ValueKey('block-media-export-${block.id}')));
      await settleMedia(tester);

      expect(picker.fileName, '한글_자료_.PPTX');
      expect(picker.savedBytes, orderedEquals([1, 2, 3]));
      expect(find.text('../folder\\한글:자료?.PPTX'), findsOneWidget);
    },
  );
}

final class _SavePicker extends FilePickerPlatform {
  String? fileName;
  Uint8List? savedBytes;

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
    this.fileName = fileName;
    savedBytes = Uint8List.fromList(bytes);
    return Uri.file('E:/owned-synthetic-output.bin');
  }
}
