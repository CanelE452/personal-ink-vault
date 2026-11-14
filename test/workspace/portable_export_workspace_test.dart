import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/card_canvas.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  final nativePath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  late Directory directory;
  late _Controller controller;
  late FilePickerPlatform previousPicker;
  late _Picker picker;
  var closed = false;
  Future<void>? closing;

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    directory = await Directory.systemTemp.createTemp('portable-export-ui-');
    closed = false;
    closing = null;
    controller = _Controller(
      await NoteRepository.open(
        Directory('${directory.path}/vault'),
        createFormatVersion: 2,
      ),
      Directory('${directory.path}/support'),
    );
    await controller.refresh();
    previousPicker = FilePickerPlatform.instance;
    picker = _Picker();
    FilePickerPlatform.instance = picker;
  });
  Future<void> closeOwned() async {
    if (closed) return;
    controller.dispose();
    await controller.repository.close().timeout(const Duration(seconds: 20));
    if (!directory.absolute.path.startsWith(
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}',
    )) {
      throw StateError('Fixture directory escaped its temporary parent');
    }
    await directory
        .delete(recursive: true)
        .timeout(const Duration(seconds: 20));
    closed = true;
  }

  Future<void> close() => closing ??= closeOwned();

  tearDown(() async {
    FilePickerPlatform.instance = previousPicker;
    controller.failFlush = false;
    await close();
  });

  Future<void> wait(WidgetTester tester, bool Function() done) async {
    final elapsed = Stopwatch()..start();
    while (!done()) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (elapsed.elapsed > const Duration(seconds: 20))
        fail('Export did not finish: ${controller.error}');
    }
  }

  Future<void> mount(WidgetTester tester, {Finder? ready}) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StudyWorkspace(controller: controller)),
      ),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var done = false;
      Object? failure;
      await tester.runAsync(() async {
        close().then(
          (_) {
            done = true;
          },
          onError: (Object error) {
            failure = error;
            done = true;
          },
        );
      });
      await wait(tester, () => done);
      if (failure != null) throw failure!;
    });
    await wait(
      tester,
      () => (ready ?? find.byKey(const ValueKey('portable-export-menu')))
          .evaluate()
          .isNotEmpty,
    );
  }

  Future<String> page() async {
    await controller.createNote('한글 페이지', documentKind: VaultDocumentKind.page);
    final block = BlockPageBlock.create(text: '저장 전 본문');
    await controller.saveBlockPage(
      const BlockPageDocument.empty().copyWith(blocks: [block]),
      session: controller.activeSession!,
    );
    return block.id;
  }

  Future<void> reopenWithNative() async {
    final previous = controller.repository;
    controller.dispose();
    await previous.close();
    controller = _Controller(
      await NoteRepository.open(previous.root),
      Directory('${directory.path}/support'),
      native: InkVaultNative.open(libraryPath: nativePath!),
    );
    await controller.refresh();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const ValueKey('portable-export-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is PopupMenuItem &&
            widget.child is Text &&
            (widget.child as Text).data == label,
      ),
    );
    await tester.pump();
    await wait(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
  }

  testWidgets(
    '320px export saves pending page input and writes the selected Markdown revision ZIP',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final id = await tester.runAsync(page);
      await mount(tester);
      await wait(
        tester,
        () => find.byKey(ValueKey('block-text-$id')).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(ValueKey('block-text-$id')),
        '방금 입력한 한글 본문',
      );
      await choose(tester, 'Markdown');
      expect(picker.calls, 1);
      expect(picker.mimeType, 'application/zip');
      expect(picker.fileName, endsWith('.zip'));
      final archive = ZipDecoder().decodeBytes(picker.bytes!);
      final report = jsonDecode(
        utf8.decode(archive.findFile('export-report.json')!.content),
      ) as Map;
      final main = archive.files.singleWhere(
        (file) => file.name.endsWith('.md') && !file.name.startsWith('source/'),
      );
      expect(utf8.decode(main.content), contains('방금 입력한 한글 본문'));
      expect(
        report.toString(),
        contains(controller.activeSession!.inkParents.single),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Canvas export saves pending edits and bundles only referenced files',
    (tester) async {
      await tester.runAsync(() async {
        final previous = controller.repository;
        controller.dispose();
        await previous.close();
        controller = _Controller(
          await NoteRepository.open(previous.root),
          Directory('${directory.path}/support'),
          native: InkVaultNative.open(libraryPath: nativePath!),
        );
        final target = await controller.store.createMarkdown(
          '연결 문서',
          Uint8List.fromList(utf8.encode('# 연결한 본문')),
        );
        await controller.store.createMarkdown(
          '내보내지 않을 개인 문서',
          Uint8List.fromList(utf8.encode('보관함에만 남겨야 하는 내용')),
        );
        await controller.createNote(
          '보드',
          documentKind: VaultDocumentKind.canvas,
        );
        await controller.saveCardCanvas(
          const CardCanvasDocument.empty().copyWith(
            nodes: [
              CardCanvasNode.note(
                id: newId(),
                noteId: target.id,
                title: target.title,
                x: 30,
                y: 30,
              ),
            ],
          ),
          session: controller.activeSession!,
        );
      });
      await mount(tester, ready: find.byType(CardCanvas));
      await tester.tap(find.byTooltip('텍스트 카드 추가'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('card-canvas-text')),
        '아직 저장하지 않은 카드',
      );
      expect(controller.dirty, isTrue);
      expect(
        find.byKey(const ValueKey('portable-export-menu')),
        findsOneWidget,
      );
      await choose(tester, 'Obsidian Canvas ZIP');

      expect(controller.dirty, isFalse);
      final messages = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(SnackBar),
              matching: find.byType(Text),
            ),
          )
          .map((widget) => widget.data)
          .toList();
      expect(
        picker.calls,
        1,
        reason:
            'Export messages: $messages, controller error: ${controller.error}',
      );
      expect(picker.fileName, endsWith('.zip'));
      expect(picker.mimeType, 'application/zip');
      final archive = ZipDecoder().decodeBytes(picker.bytes!);
      final board = archive.files.singleWhere(
        (file) => file.name.endsWith('.canvas'),
      );
      final body = jsonDecode(utf8.decode(board.content)) as Map;
      final nodes = (body['nodes'] as List).cast<Map>();
      final link = nodes.singleWhere((node) => node['type'] == 'file');
      final linkedDocument = archive.findFile(link['file'] as String);
      expect(linkedDocument, isNotNull);
      expect(utf8.decode(linkedDocument!.content), '# 연결한 본문');
      expect(
        nodes.singleWhere((node) => node['type'] == 'text')['text'],
        '아직 저장하지 않은 카드',
      );
      expect(
        archive.files.where((file) => file.name.endsWith('.md')),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
    skip: nativePath == null,
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  for (final (platform, width, menuKey) in const [
    (TargetPlatform.android, 360.0, 'workspace-more-actions'),
    (TargetPlatform.android, 1100.0, 'portable-export-menu'),
    (TargetPlatform.windows, 1100.0, 'portable-export-menu'),
  ]) {
    testWidgets(
      'editor Obsidian vault ZIP includes active draft at ${width.toInt()}px',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          await reopenWithNative();
          final folder = await controller.createFolder('다른 폴더');
          await controller.store.createMarkdown(
            '다른 노트',
            Uint8List.fromList(utf8.encode('# 다른 폴더 본문')),
            folderId: folder.id,
          );
          await controller.createNote(
            '활성 노트',
            documentKind: VaultDocumentKind.markdown,
          );
        });
        await mount(tester, ready: find.byTooltip('원문 편집'));
        await tester.tap(find.byTooltip('원문 편집'));
        await tester.pump();
        await tester.enterText(
          find.byWidgetPredicate(
            (widget) => widget is TextField && widget.expands,
          ),
          '# 아직 저장하지 않은 Markdown',
        );
        expect(controller.dirty, isTrue);
        final repository = controller.repository;
        final session = controller.activeSession;
        final menu = find.byKey(ValueKey(menuKey));
        expect(menu, findsOneWidget);
        await tester.tap(menu);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 550));
        final vaultExport = find.byKey(
          const ValueKey('workspace-vault-export'),
        );
        expect(vaultExport, findsOneWidget);
        expect(
          find.descendant(
            of: vaultExport,
            matching: find.text('Obsidian 보관함 ZIP'),
          ),
          findsOneWidget,
        );
        expect(vaultExport.hitTestable(), findsOneWidget);
        expect(tester.widget<PopupMenuItem<void>>(vaultExport).enabled, isTrue);
        expect(controller.activeSession, same(session));
        expect(controller.canCreateDocument, isFalse);
        expect(picker.calls, 0);
        await tester.tap(vaultExport);
        await tester.pump();
        await wait(tester, () => picker.calls == 1);
        await wait(
          tester,
          () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
        );
        expect(picker.calls, 1);
        expect(picker.mimeType, 'application/zip');
        expect(picker.fileName, 'personal-ink-vault-obsidian.zip');
        final archive = ZipDecoder().decodeBytes(picker.bytes!);
        expect(
          utf8.decode(archive.findFile('활성 노트.md')!.content),
          '# 아직 저장하지 않은 Markdown',
        );
        expect(
          utf8.decode(archive.findFile('다른 폴더/다른 노트.md')!.content),
          '# 다른 폴더 본문',
        );
        expect(controller.dirty, isFalse);
        expect(controller.repository, same(repository));
        expect(controller.activeSession, same(session));
        expect(tester.takeException(), isNull);
      },
      skip: nativePath == null,
      variant: TargetPlatformVariant({platform}),
    );
  }

  testWidgets(
    'narrow library Obsidian ZIP cancellation leaves the original vault open',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await reopenWithNative();
        await controller.store.createMarkdown(
          '원본',
          Uint8List.fromList(utf8.encode('원본 본문')),
        );
        await controller.refresh();
      });
      final repository = controller.repository;
      final revisions = await tester.runAsync(repository.revisions);
      picker.result = null;
      final drawer = find.byType(DrawerButton);
      await mount(tester, ready: drawer);
      await tester.tap(drawer);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Obsidian 보관함 ZIP'));
      await tester.pump();
      await wait(tester, () => picker.calls == 1);
      await wait(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(controller.repository, same(repository));
      final after = await tester.runAsync(repository.revisions);
      expect(
        after!.map((revision) => revision.revisionId),
        unorderedEquals(revisions!.map((revision) => revision.revisionId)),
      );
      expect(find.textContaining('내보냈습니다'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    skip: nativePath == null,
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'cancelled destination is not reported as exported and leaves the saved revision intact',
    (tester) async {
      await tester.runAsync(page);
      picker.result = null;
      final revision = controller.activeSession!.inkParents.single;
      await mount(tester);
      await choose(tester, 'HTML');
      expect(picker.calls, 1);
      expect(controller.activeSession!.inkParents, [revision]);
      expect(find.textContaining('내보냈습니다'), findsNothing);
    },
  );

  testWidgets('save failure prevents export and keeps pending page text', (
    tester,
  ) async {
    final id = await tester.runAsync(page);
    await mount(tester);
    await wait(
      tester,
      () => find.byKey(ValueKey('block-text-$id')).evaluate().isNotEmpty,
    );
    await tester.enterText(find.byKey(ValueKey('block-text-$id')), '보존할 내용');
    controller.failFlush = true;
    await choose(tester, 'Markdown');
    expect(picker.calls, 0);
    expect(find.textContaining('synthetic flush failure'), findsOneWidget);
    expect(find.text('보존할 내용'), findsOneWidget);
  });

  testWidgets('database offers CSV with row body and page does not offer CSV', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await controller.createNote(
        '연구 표',
        documentKind: VaultDocumentKind.database,
      );
      final db = (await controller.loadDatabaseSnapshot(
        session: controller.activeSession!,
      )).database;
      final row = DatabaseRow.create(
        values: {db.properties.single.id: '행 제목'},
        body: const BlockPageDocument.empty()
            .copyWith(blocks: [BlockPageBlock.create(text: '행 본문')])
            .toJson(),
      );
      await controller.saveDatabase(
        db.copyWith(rows: [row]),
        session: controller.activeSession!,
      );
    });
    await mount(tester);
    await choose(tester, 'CSV');
    expect(picker.calls, 1);
    final archive = ZipDecoder().decodeBytes(picker.bytes!);
    expect(
      archive.files.where((file) => file.name.endsWith('.csv')),
      hasLength(1),
    );
    expect(
      archive.files.where(
        (file) => file.name.startsWith('rows/') && file.name.endsWith('.md'),
      ),
      hasLength(1),
    );
  });

  testWidgets(
    'PDF export uses the packaged Korean font and includes a searchable PDF',
    (tester) async {
      await tester.runAsync(page);
      await mount(tester);
      await choose(tester, 'PDF');
      expect(picker.calls, 1);
      final archive = ZipDecoder().decodeBytes(picker.bytes!);
      final pdf = archive.files.singleWhere(
        (file) => file.name.endsWith('.pdf'),
      );
      final syntax = latin1.decode(pdf.content);
      expect(syntax, startsWith('%PDF-'));
      expect(syntax, contains('/ToUnicode'));
      expect(syntax, contains('/FontFile2'));
      expect(archive.findFile('source/page.json'), isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'destination failure reports the error and preserves the saved document',
    (tester) async {
      await tester.runAsync(page);
      final revision = controller.activeSession!.inkParents.single;
      picker.failure = const FileSystemException(
        'synthetic destination failure',
      );
      await mount(tester);
      await choose(tester, 'HTML');
      expect(picker.calls, 1);
      expect(
        find.textContaining('synthetic destination failure'),
        findsOneWidget,
      );
      expect(find.textContaining('내보냈습니다'), findsNothing);
      expect(controller.activeSession!.inkParents, [revision]);
    },
  );
}

class _Controller extends WorkspaceController {
  new(super.repository, Directory support, {super.native})
    : super(directoryProvider: () async => support);
  var failFlush = false;
  @override
  Future<void> flush() {
    if (failFlush) throw StateError('synthetic flush failure');
    return super.flush();
  }
}

class _Picker extends FilePickerPlatform {
  var calls = 0;
  String? fileName, mimeType;
  Uint8List? bytes;
  Uri? result = Uri.file('E:/synthetic-export.zip');
  Object? failure;
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
    calls++;
    this.fileName = fileName;
    this.mimeType = mimeType;
    this.bytes = Uint8List.fromList(bytes);
    if (failure != null) throw failure!;
    return result;
  }
}
