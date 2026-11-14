import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  final library = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];

  testWidgets(
    'Study note embed uses its own folder for navigation, image and refresh',
    (tester) async {
      tester.view.physicalSize = const Size(1060, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await _io(tester, () => _Fixture.create(library!));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _io(tester, fixture.close);
      });

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: StudyWorkspace(controller: fixture.controller),
          ),
        ),
      );
      final markdown = find.byType(MarkdownEditor);
      await _wait(
        tester,
        () =>
            find
                .text('Inside source body', findRichText: true)
                .evaluate()
                .length ==
            1,
        'The actual Study note did not render its embedded heading section',
      );
      expect(
        find.text('Outside source body', findRichText: true),
        findsNothing,
      );
      expect(find.text('Embedded reference'), findsOneWidget);
      expect(tester.widget<MarkdownEditor>(markdown).source, _Fixture.hostText);
      final raster = find.descendant(
        of: markdown,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Image && widget.semanticLabel == 'Source-local image',
        ),
      );
      await _wait(
        tester,
        () => raster.evaluate().length == 1,
        'The embedded Markdown image did not resolve from the source folder',
      );
      final rasterWidget = tester.widget<Image>(raster);
      expect(rasterWidget.width, 120.0);
      expect(rasterWidget.height, 60.0);
      final resized = rasterWidget.image as ResizeImage;
      final provider = resized.imageProvider as MemoryImage;
      expect(provider.bytes, fixture.sourceImage);
      expect(provider.bytes, isNot(fixture.hostImage));

      final access = tester.widget<MarkdownEditor>(markdown).vaultEmbeds!;
      await _io(tester, () async {
        expect(await access.load('inkwiki:Oversized', fixture.host.id), isNull);
        expect(
          await access.load('inkwiki:Conflicted', fixture.host.id),
          isNull,
        );
        expect(await access.load('inkwiki:Host', newId()), isNull);
        await fixture.updateEmbed();
      });
      await _wait(
        tester,
        () =>
            find
                .text('Updated source body', findRichText: true)
                .evaluate()
                .length ==
            1,
        'A clean embed did not refresh after the repository changed',
      );
      expect(
        await _io(
          tester,
          () => access.load('inkwiki:Source%2FEmbed', fixture.host.id),
        ),
        isNull,
        reason: 'An older preview scope must not read the new repository generation.',
      );
      expect(fixture.controller.activeSession!.note.id, fixture.host.id);

      await _tapLink(tester, 'Open source-local note');
      await _wait(
        tester,
        () =>
            fixture.controller.activeSession?.note.id ==
                fixture.sourceLocal.id &&
            markdown.evaluate().length == 1 &&
            tester.widget<MarkdownEditor>(markdown).source ==
                'Correct source-local page',
        'Clicking the nested link did not navigate from the embedded note',
      );
      expect(
        fixture.controller.activeSession?.note.id,
        isNot(fixture.hostLocal.id),
      );
      expect(
        tester.widget<MarkdownEditor>(markdown).source,
        'Correct source-local page',
      );
      expect(tester.takeException(), isNull);
    },
    skip: library == null || !File(library).existsSync(),
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Study keeps the original heading and block embeds visible after rename and move',
    (tester) async {
      tester.view.physicalSize = const Size(1060, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const original =
          '# Host\n\n![[Source/Embed#Inside|요약]]\n\n![[Source/Embed#^item]]\n';
      final fixture = await _io(
        tester,
        () => _Fixture.create(
          library!,
          hostMarkdown: original,
          embeddedMarkdown:
              '# Outside\n\nOutside source body\n\n'
              '- Selected source block ^item\n\n'
              '# Inside\n\nInside source body\n',
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _io(tester, fixture.close);
      });
      final controller = fixture.controller;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: StudyWorkspace(controller: controller)),
        ),
      );
      final markdown = find.byType(MarkdownEditor);
      final heading = find.text('Inside source body', findRichText: true);
      final block = find.text('Selected source block', findRichText: true);
      bool showsEmbeddedContent() =>
          heading.evaluate().length == 1 && block.evaluate().length == 1;
      await _wait(
        tester,
        showsEmbeddedContent,
        'The heading and block must both render before the path changes',
      );
      expect(tester.widget<MarkdownEditor>(markdown).source, original);

      final bound =
          '# Host\n\n![[${fixture.embedded.id}#Inside|요약]]\n\n'
          '![[${fixture.embedded.id}#^item|Source/Embed#^item]]\n';
      await _io(tester, () async {
        final store = controller.store;
        await store.rename(fixture.embedded, 'Renamed');
        final renamed = (await store.list()).singleWhere(
          (note) => note.id == fixture.embedded.id,
        );
        await store.moveNote(renamed, fixture.host.folderId);
        await store.createMarkdown(
          'Embed',
          Uint8List.fromList(
            utf8.encode('# Inside\n\nDecoy at the old path\n\nDecoy ^item'),
          ),
          folderId: fixture.embedded.folderId,
        );
        expect(await (await store.open(fixture.host)).readMarkdown(), bound);
        await controller.refresh();
      });

      await _wait(
        tester,
        () =>
            markdown.evaluate().length == 1 &&
            tester.widget<MarkdownEditor>(markdown).source == bound &&
            showsEmbeddedContent(),
        'The saved embed must resolve both anchors after the old path is reused',
      );
      expect(find.text('Outside source body', findRichText: true), findsNothing);
      expect(find.text('Decoy at the old path', findRichText: true), findsNothing);
      expect(controller.activeSession?.note.id, fixture.host.id);
      expect(tester.takeException(), isNull);
    },
    skip: library == null || !File(library).existsSync(),
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Study refuses to retarget an embedded link when its origin moves during save',
    (tester) async {
      tester.view.physicalSize = const Size(1060, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await _io(tester, () => _Fixture.create(library!));
      final controller = fixture.controller;
      addTearDown(() async {
        controller.releaseFlush();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _io(tester, fixture.close);
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: StudyWorkspace(controller: controller)),
        ),
      );
      final held = controller.holdNextFlush();
      await _tapLink(tester, 'Open source-local note');
      await _io(tester, () => held);

      String? resolveRelative() => controller.knowledge
          ?.resolveMarkdownLink('./Local.md', fromNoteId: fixture.embedded.id)
          ?.noteId;
      expect(resolveRelative(), fixture.sourceLocal.id);
      await _io(tester, fixture.receiveEmbedMove);
      expect(
        resolveRelative(),
        fixture.hostLocal.id,
        reason: 'The received move makes the same href resolve to the decoy.',
      );
      expect(controller.activeSession?.note.id, fixture.host.id);
      controller.releaseFlush();

      final failure = find.textContaining('연결 대상이 바뀌었습니다.');
      await _wait(
        tester,
        () =>
            failure.evaluate().isNotEmpty ||
            controller.activeSession?.note.id != fixture.host.id,
        'The blocked link should either safely fail or exhibit the old navigation.',
      );
      expect(
        controller.activeSession?.note.id,
        fixture.host.id,
        reason: 'The clicked link must never open the post-move decoy.',
      );
      expect(failure, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    skip: library == null || !File(library).existsSync(),
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

Future<void> _tapLink(WidgetTester tester, String label) async {
  final text = find.byWidgetPredicate(
    (widget) =>
        widget is SelectableText &&
        (widget.data ?? widget.textSpan?.toPlainText()) == label,
  );
  final link = find.descendant(of: text, matching: find.byType(EditableText));
  await _wait(
    tester,
    () => link.evaluate().length == 1,
    'Link missing: $label',
  );
  await tester.ensureVisible(text);
  await tester.pump();
  final editable = tester.state<EditableTextState>(link).renderEditable;
  final glyph = editable
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1))
      .first;
  final position = editable.localToGlobal(glyph.toRect().center);
  expect(
    tester
        .hitTestOnBinding(position)
        .path
        .any((entry) => identical(entry.target, editable)),
    isTrue,
  );
  await tester.runAsync(() => tester.tapAt(position));
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() done,
  String reason,
) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 4)),
    );
    if (watch.elapsed > const Duration(seconds: 15)) fail(reason);
  }
  await tester.pump();
}

Future<T> _io<T>(WidgetTester tester, Future<T> Function() action) async {
  var done = false;
  T? result;
  (Object, StackTrace)? error;
  await tester.runAsync(() async {
    unawaited(
      action()
          .timeout(const Duration(seconds: 12))
          .then<void>(
            (value) {
              result = value;
              done = true;
            },
            onError: (Object failure, StackTrace trace) {
              error = (failure, trace);
              done = true;
            },
          ),
    );
  });
  await _wait(tester, () => done, 'Workspace test IO did not finish');
  final failure = error;
  if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  return result as T;
}

class _Fixture {
  new(
    this.directory,
    this.repository,
    this.controller,
    this.host,
    this.embedded,
    this.sourceLocal,
    this.hostLocal,
    this.sourceImage,
    this.hostImage,
  );

  static const hostText = '# Host\n\n![[Source/Embed#Inside]]\n';
  static const embedText =
      '# Outside\n\nOutside source body\n\n'
      '> [!tip]- Embedded reference\n'
      '> ## Inside\n>\n'
      '> Inside source body\n>\n'
      '> [Open source-local note](./Local.md)\n>\n'
      '> ![Source-local image|120x60](./Pixel.png)\n';
  final Directory directory;
  final NoteRepository repository;
  final _HeldFlushController controller;
  final VaultNote host, embedded, sourceLocal, hostLocal;
  final Uint8List sourceImage, hostImage;

  static Future<_Fixture> create(
    String library, {
    String hostMarkdown = hostText,
    String embeddedMarkdown = embedText,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'obsidian-embed-study-',
    );
    await FileManager.init(
      documentsDirectory: p.join(directory.path, 'documents'),
      shouldWatchRootDirectory: false,
    );
    final repository = await NoteRepository.open(
      Directory(p.join(directory.path, 'vault')),
      createFormatVersion: 2,
    );
    final libraryStore = LibraryStore(repository);
    final sourceFolder = await libraryStore.createFolder('Source');
    final hostFolder = await libraryStore.createFolder('HostFolder');
    final store = WorkspaceStore(repository);
    Future<VaultNote> note(String title, String text, String folderId) =>
        store.createMarkdown(
          title,
          Uint8List.fromList(utf8.encode(text)),
          folderId: folderId,
        );
    final host = await note('Host', hostMarkdown, hostFolder.id);
    final embedded = await note('Embed', embeddedMarkdown, sourceFolder.id);
    final sourceLocal = await note(
      'Local',
      'Correct source-local page',
      sourceFolder.id,
    );
    final hostLocal = await note(
      'Local',
      'Host folder decoy page',
      hostFolder.id,
    );
    final sourceImage = image.encodePng(image.Image(width: 3, height: 2));
    final hostImage = image.encodePng(image.Image(width: 7, height: 6));
    for (final (folder, bytes) in [
      (sourceFolder, sourceImage),
      (hostFolder, hostImage),
    ]) {
      await store.createWithSource(
        'Pixel.png',
        fileName: 'Pixel.png',
        bytes: bytes,
        folderId: folder.id,
        documentKind: VaultDocumentKind.image,
        fromObsidian: true,
      );
    }
    await note('Oversized', 'z' * (512 * 1024 + 1), hostFolder.id);
    final conflicted = await note(
      'Conflicted',
      'first markdown branch',
      hostFolder.id,
    );
    final base = (await repository.heads(conflicted.markdownEntityId)).single;
    for (final branch in ['branch A', 'branch B']) {
      await repository.commit(
        entityId: conflicted.markdownEntityId,
        ownerNoteId: conflicted.id,
        kind: EntityKind.markdown,
        files: {'summary.md': Uint8List.fromList(utf8.encode(branch))},
        parentRevisionIds: [base.revisionId],
      );
    }
    final controller = _HeldFlushController(
      repository,
      native: InkVaultNative.open(libraryPath: library),
      directoryProvider: () async =>
          Directory(p.join(directory.path, 'support')),
    );
    await controller.refresh();
    await controller.openNote(host);
    return _Fixture(
      directory,
      repository,
      controller,
      host,
      embedded,
      sourceLocal,
      hostLocal,
      sourceImage,
      hostImage,
    );
  }

  Future<void> updateEmbed() async {
    final session = await WorkspaceStore(repository).open(embedded);
    await session.saveMarkdown(
      embedText.replaceFirst('Inside source body', 'Updated source body'),
    );
  }

  Future<void> receiveEmbedMove() async {
    await repository.commit(
      entityId: embedded.id,
      kind: EntityKind.metadata,
      files: {
        'note.json': Uint8List.fromList(
          utf8.encode(
            jsonEncode({...embedded.json, 'folderId': host.folderId}),
          ),
        ),
      },
      parentRevisionIds: [embedded.revision.revisionId],
    );
    await controller.refresh();
  }

  Future<void> close() async {
    await controller.flush();
    controller.dispose();
    await repository.close();
    final owned = await directory.resolveSymbolicLinks();
    final system = await Directory.systemTemp.resolveSymbolicLinks();
    expect(p.dirname(owned), system);
    expect(p.basename(owned), startsWith('obsidian-embed-study-'));
    await Directory(owned).delete(recursive: true);
  }
}

class _HeldFlushController extends WorkspaceController {
  new(super.repository, {super.native, super.directoryProvider});

  Completer<void>? _flushEntered;
  Completer<void>? _flushResume;

  Future<void> holdNextFlush() {
    _flushResume = Completer<void>();
    return (_flushEntered = Completer<void>()).future;
  }

  void releaseFlush() {
    final resume = _flushResume;
    _flushEntered = null;
    _flushResume = null;
    resume?.complete();
  }

  @override
  Future<void> flush() async {
    final entered = _flushEntered;
    if (entered != null) {
      _flushEntered = null;
      final resume = _flushResume!;
      entered.complete();
      await resume.future;
    }
    await super.flush();
  }
}
