import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_synced_reference.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';
import 'package:saber/pages/workspace/synced_block_view.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  testWidgets(
    'Study edits one original through two synced pages and keeps a stale draft',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await _io(tester, _Fixture.create);
      final c = fixture.controller;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _io(tester, fixture.close);
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: StudyWorkspace(controller: c)),
        ),
      );
      final page = find.byType(BlockPageEditor);
      await _wait(tester, () => page.evaluate().length == 1);
      expect(c.notes.map((note) => note.title), ['연결 페이지 A']);
      await tester.tap(find.byTooltip('블록 추가'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('동기화 블록'));
      await _wait(tester, () => find.text('원본 페이지 선택').evaluate().isNotEmpty);
      final dialog = find.byType(AlertDialog);
      Finder choice(String label) =>
          find.descendant(of: dialog, matching: find.text(label));
      expect(choice('연결 페이지 A'), findsNothing);
      await tester.tap(choice('원본 페이지'));
      await _wait(tester, () => find.text('원본 블록 선택').evaluate().isNotEmpty);
      await tester.tap(choice('원본 내용'));
      final view = find.byType(SyncedBlockView);
      Finder inside(String label) => find.descendant(
        of: view,
        matching: find.text(label, findRichText: true),
      );
      await _wait(
        tester,
        () =>
            inside('원본 블록 편집').evaluate().length == 1 &&
            inside('원본 내용').evaluate().length == 1,
      );
      await tester.tap(inside('원본 블록 편집'));
      await tester.pump();
      final draft = find.descendant(of: view, matching: find.byType(TextField));
      await tester.enterText(draft, '원본 내용 업데이트');
      await tester.pump();
      await tester.tap(inside('원본 블록 저장'));
      await _wait(
        tester,
        () => !c.dirty && inside('원본 내용 업데이트').evaluate().length == 1,
      );
      final sourceAfter = await _io(tester, () => fixture.read(fixture.source));
      final hostAAfter = await _io(tester, () => fixture.read(fixture.first));
      expect(sourceAfter.blocks.single.text, '원본 내용 업데이트');
      expect(
        sourceAfter.blocks.single.inlineText!.segments.first.marks,
        contains(InlineMark.bold),
      );
      expect(sourceAfter.blocks.single.children.single.text, '원본 하위 문단');
      expect(
        hostAAfter.blocks.single.syncedBlock!.sourceNoteId,
        fixture.source.id,
      );
      expect(
        hostAAfter.blocks.single.syncedBlock!.sourceBlockId,
        fixture.original.id,
      );
      expect(hostAAfter.blocks.single.children, isEmpty);

      await _io(tester, () => c.openNote(fixture.second));
      await _wait(tester, () => inside('원본 내용 업데이트').evaluate().length == 1);
      await _io(tester, () => fixture.updateSource('원본 내용이 다른 기기에서 변경됨'));
      await _wait(
        tester,
        () => inside('원본 내용이 다른 기기에서 변경됨').evaluate().length == 1,
      );
      await tester.tap(inside('원본 블록 편집'));
      await tester.pump();
      await tester.enterText(draft, '보존할 초안');
      await _io(tester, () => fixture.updateSource('원본 최신 본문'));
      await tester.tap(inside('원본 블록 저장'));
      await _wait(
        tester,
        () => find.textContaining('원본 블록을 처리할 수 없습니다').evaluate().isNotEmpty,
      );
      expect(tester.widget<TextField>(draft).controller!.text, '보존할 초안');
      expect(c.activeSession?.note.id, fixture.second.id);
      expect(c.dirty, isTrue);
      final editorBack = find.descendant(
        of: page,
        matching: find.byTooltip('문서 목록으로'),
      );
      await tester.tap(editorBack);
      await tester.pump();
      final discard = find.descendant(
        of: view,
        matching: find.widgetWithText(TextButton, '초안 버리기…'),
      );
      await _wait(
        tester,
        () =>
            discard.evaluate().length == 1 &&
            tester.widget<TextButton>(discard).onPressed != null,
      );
      expect(c.activeSession?.note.id, fixture.second.id);
      expect(tester.widget<TextField>(draft).controller!.text, '보존할 초안');

      await tester.ensureVisible(discard);
      expect(discard.hitTestable(), findsOneWidget);
      expect(tester.widget<TextButton>(discard).onPressed, isNotNull);
      await tester.tap(discard);
      await _wait(
        tester,
        () => find.text('동기화 블록 다시 읽기').evaluate().length == 1,
        failure: () =>
            'Discard confirmation missing. Visible text: '
            '${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
      );
      final confirm = find.widgetWithText(FilledButton, '초안 버리기');
      await tester.runAsync(() => tester.tap(confirm));
      await _wait(
        tester,
        () => !c.dirty && inside('원본 최신 본문').evaluate().length == 1,
      );
      expect(
        (await _io(
          tester,
          () => fixture.read(fixture.source),
        )).blocks.single.text,
        '원본 최신 본문',
      );
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );

  testWidgets(
    'Study detaches one saved occurrence and reopens it as independent content',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = await _io(
        tester,
        () => _Fixture.create(attachFirst: true),
      );
      final c = fixture.controller;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _io(tester, fixture.close);
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: StudyWorkspace(controller: c)),
        ),
      );

      final sourceHead = await _io(tester, () => fixture.head(fixture.source));
      final hostHead = await _io(tester, () => fixture.head(fixture.first));
      final otherHead = await _io(tester, () => fixture.head(fixture.second));
      final linked = (await _io(
        tester,
        () => fixture.read(fixture.first),
      )).blocks.single;
      final page = find.byType(BlockPageEditor);
      final view = find.byType(SyncedBlockView);
      final action = find.byKey(ValueKey('synced-block-detach-${linked.id}'));
      final confirm = find.byKey(
        ValueKey('synced-block-detach-confirm-${linked.id}'),
      );
      final input = find.byKey(ValueKey('block-text-${linked.id}'));
      final dialog = find.byType(AlertDialog);
      Finder inView(String label) => find.descendant(
        of: view,
        matching: find.text(label, findRichText: true),
      );
      Finder editorButton(String label) =>
          find.descendant(of: page, matching: find.byTooltip(label));
      bool detachEnabled() =>
          tester
              .widgetList<ButtonStyleButton>(action)
              .singleOrNull
              ?.onPressed !=
          null;

      await _wait(tester, detachEnabled);
      await tester.tap(inView('원본 블록 편집'));
      await tester.pump();
      await tester.enterText(
        find.descendant(of: view, matching: find.byType(TextField)),
        '원본에 저장하지 않은 초안',
      );
      await tester.pump();
      expect(c.dirty, isTrue);
      expect(detachEnabled(), isFalse);
      await tester.tap(inView('초안 버리기…'));
      await _wait(
        tester,
        () =>
            find.widgetWithText(FilledButton, '초안 버리기').evaluate().length == 1,
      );
      await tester.runAsync(
        () => tester.tap(find.widgetWithText(FilledButton, '초안 버리기')),
      );
      await _wait(tester, () => !c.dirty && detachEnabled());

      await tester.tap(action);
      await _wait(tester, () => confirm.evaluate().length == 1);
      await tester.tap(find.descendant(of: dialog, matching: find.text('취소')));
      await _wait(tester, () => dialog.evaluate().isEmpty);
      expect(view, findsOneWidget);
      expect(
        (await _io(tester, () => fixture.head(fixture.first))).revisionId,
        hostHead.revisionId,
      );

      await tester.tap(action);
      await _wait(tester, () => confirm.evaluate().length == 1);
      await tester.runAsync(() => tester.tap(confirm));
      await _wait(tester, () => input.evaluate().length == 1 && !c.dirty);
      expect(view, findsNothing);
      final detachedHead = await _io(tester, () => fixture.head(fixture.first));
      expect(detachedHead.parentRevisionIds, [hostHead.revisionId]);
      final detached = (await _io(
        tester,
        () => fixture.read(fixture.first),
      )).blocks.single;
      expect(detached.id, linked.id);
      expect(detached.syncedBlock, isNull);
      expect(detached.text, fixture.original.text);
      expect(
        detached.inlineText!.segments.first.marks,
        contains(InlineMark.bold),
      );
      expect(
        detached.children.single.text,
        fixture.original.children.single.text,
      );
      expect(
        detached.children.single.id,
        isNot(fixture.original.children.single.id),
      );

      await tester.tap(editorButton('실행 취소'));
      await _wait(tester, () => view.evaluate().length == 1);
      await tester.tap(editorButton('저장'));
      await _wait(tester, () => !c.dirty);
      final restored = await _io(tester, () => fixture.read(fixture.first));
      expect(
        restored.blocks.single.syncedBlock!.sourceBlockId,
        fixture.original.id,
      );
      await tester.tap(editorButton('다시 실행'));
      await _wait(tester, () => input.evaluate().length == 1);

      await tester.enterText(input, '독립 복사본의 편집 내용');
      await tester.pump();
      await tester.tap(editorButton('저장'));
      await _wait(tester, () => !c.dirty);
      expect(
        (await _io(tester, () => fixture.head(fixture.source))).revisionId,
        sourceHead.revisionId,
      );
      expect(
        (await _io(tester, () => fixture.head(fixture.second))).revisionId,
        otherHead.revisionId,
      );

      await tester.tap(editorButton('문서 목록으로'));
      await _wait(tester, () => page.evaluate().isEmpty);
      await _io(tester, () => c.openNote(fixture.first));
      await _wait(tester, () => input.evaluate().length == 1);
      expect(tester.widget<TextField>(input).controller!.text, '독립 복사본의 편집 내용');
      await _io(tester, () => fixture.updateSource('연결된 복사본만 보는 새 원본'));
      await _io(tester, () => c.openNote(fixture.second));
      await _wait(
        tester,
        () => inView('연결된 복사본만 보는 새 원본').evaluate().length == 1,
      );
      await _io(tester, () => c.openNote(fixture.first));
      await _wait(tester, () => input.evaluate().length == 1);
      expect(tester.widget<TextField>(input).controller!.text, '독립 복사본의 편집 내용');
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}

Future<void> _wait(
  WidgetTester tester,
  bool Function() done, {
  String Function()? failure,
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 3)),
    );
    if (watch.elapsed > const Duration(seconds: 15)) {
      fail(
        failure?.call() ??
            'Synced block workspace did not reach the expected state.',
      );
    }
  }
  await tester.pump();
}

Future<T> _io<T>(WidgetTester tester, Future<T> Function() action) async {
  var done = false;
  T? result;
  (Object, StackTrace)? failure;
  await tester.runAsync(() async {
    unawaited(
      action()
          .timeout(const Duration(seconds: 12))
          .then<void>(
            (value) {
              result = value;
              done = true;
            },
            onError: (Object error, StackTrace stack) {
              failure = (error, stack);
              done = true;
            },
          ),
    );
  });
  await _wait(tester, () => done);
  final error = failure;
  if (error != null) Error.throwWithStackTrace(error.$1, error.$2);
  return result as T;
}

class _Fixture {
  new(
    this.directory,
    this.repository,
    this.controller,
    this.source,
    this.first,
    this.second,
    this.original,
  );

  final Directory directory;
  final NoteRepository repository;
  final WorkspaceController controller;
  final VaultNote source, first, second;
  final BlockPageBlock original;

  static Future<_Fixture> create({bool attachFirst = false}) async {
    final directory = await Directory.systemTemp.createTemp('synced-study-');
    await FileManager.init(
      documentsDirectory: p.join(directory.path, 'documents'),
      shouldWatchRootDirectory: false,
    );
    final repository = await NoteRepository.open(
      Directory(p.join(directory.path, 'vault')),
      createFormatVersion: 2,
    );
    final c = WorkspaceController(
      repository,
      directoryProvider: () async =>
          Directory(p.join(directory.path, 'support')),
    );
    final source = await c.createNote(
      '원본 페이지',
      documentKind: VaultDocumentKind.page,
    );
    final original = BlockPageBlock.create(text: '원본 내용').copyWith(
      inlineText: BlockInlineText.plain('원본 내용')
          .toggleMark(0, 2, InlineMark.bold),
      children: [BlockPageBlock.create(text: '원본 하위 문단')],
    );
    await c.saveBlockPage(
      const BlockPageDocument.empty().copyWith(blocks: [original]),
      session: c.activeSession!,
    );
    final second = await c.createNote(
      '연결 페이지 B',
      documentKind: VaultDocumentKind.page,
    );
    await c.saveBlockPage(
      const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.createSyncedBlock(
            reference: BlockSyncedReference.create(
              sourceNoteId: source.id,
              sourceBlockId: original.id,
            ),
          ),
        ],
      ),
      session: c.activeSession!,
    );
    final first = await c.createNote(
      '연결 페이지 A',
      documentKind: VaultDocumentKind.page,
    );
    if (attachFirst) {
      await c.saveBlockPage(
        const BlockPageDocument.empty().copyWith(
          blocks: [
            BlockPageBlock.createSyncedBlock(
              reference: BlockSyncedReference.create(
                sourceNoteId: source.id,
                sourceBlockId: original.id,
              ),
            ),
          ],
        ),
        session: c.activeSession!,
      );
    }
    c.query = first.title;
    await c.refresh();
    return _Fixture(directory, repository, c, source, first, second, original);
  }

  Future<RevisionRecord> head(VaultNote note) async =>
      (await repository.heads(note.inkEntityId)).single;

  Future<BlockPageDocument> read(VaultNote note) async {
    final bytes = await repository.readRevisionFile(
      await head(note),
      'page.json',
    );
    return BlockPageDocument.fromJson(
      jsonObject(jsonDecode(utf8.decode(bytes))),
    );
  }

  Future<void> updateSource(String text) async {
    final document = await read(source);
    final next = document.copyWith(
      blocks: [document.blocks.single.copyWith(text: text)],
    );
    final session = await WorkspaceStore(repository).open(source);
    await session.saveInk({
      'page.json': Uint8List.fromList(utf8.encode(jsonEncode(next.toJson()))),
    });
  }

  Future<void> close() async {
    controller.dispose();
    await repository.close();
    final owned = await directory.resolveSymbolicLinks();
    final temporary = await Directory.systemTemp.resolveSymbolicLinks();
    expect(p.dirname(owned), temporary);
    expect(p.basename(owned), startsWith('synced-study-'));
    await Directory(owned).delete(recursive: true);
  }
}
