import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/block_page_history_sheet.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 18; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
    }
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 40 && !ready(); i++) {
      await drain(tester);
    }
    expect(ready(), isTrue);
  }

  Future<T> readWhilePumping<T>(
    WidgetTester tester,
    Future<T> Function() read,
  ) async {
    var done = false;
    T? value;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      read().then(
        (result) {
          value = result;
          done = true;
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
          trace = stack;
          done = true;
        },
      );
    });
    await until(tester, () => done);
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return value as T;
  }

  for (final width in [1000.0, 320.0]) {
    testWidgets(
      'page history compares and restores original content at $width px',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final prepared = await tester.runAsync(() async {
          await FileManager.init(shouldWatchRootDirectory: false);
          final root = await Directory.systemTemp.createTemp(
            'page-history-study-',
          );
          final controller = WorkspaceController(
            await NoteRepository.open(root, createFormatVersion: 2),
          );
          await controller.refresh();
          final note = await controller.createNote(
            'History page',
            documentKind: VaultDocumentKind.page,
          );
          final session = controller.activeSession!;
          final block = BlockPageBlock.fromJson({
            'id': newId(),
            'type': 'paragraph',
            'text': 'Original page A',
            'custom': {'color': 'retained'},
          });
          final first = BlockPageDocument.fromJson({
            'version': 1,
            'customPage': {'keep': true},
            'blocks': [block.toJson()],
          });
          await controller.saveBlockPage(first, session: session);
          final firstRevision = (await controller.repository.heads(
            note.inkEntityId,
          )).single;
          final originalFiles = await controller.repository.readFiles(
            firstRevision,
          );
          final second = first.copyWith(
            blocks: [block.copyWith(text: 'Changed page B')],
          );
          await controller.saveBlockPage(second, session: session);
          final secondRevision = (await controller.repository.heads(
            note.inkEntityId,
          )).single;
          controller.editMarkdown('Separate personal summary');
          await controller.flush();
          return (
            root,
            controller,
            note,
            session,
            block,
            first,
            firstRevision,
            secondRevision,
            originalFiles,
          );
        });
        final (
          root,
          controller,
          note,
          session,
          block,
          first,
          firstRevision,
          secondRevision,
          originalFiles,
        ) = prepared!;
        try {
          await tester.pumpWidget(
            TranslationProvider(
              child: MaterialApp(home: StudyWorkspace(controller: controller)),
            ),
          );
          await drain(tester);
          expect(
            find.byKey(ValueKey('block-text-${block.id}')),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip('페이지 저장 이력'));
          await until(
            tester,
            () => find
                .byKey(ValueKey('history-revision-${firstRevision.revisionId}'))
                .evaluate()
                .isNotEmpty,
          );
          final selected = find.byKey(
            ValueKey('history-revision-${firstRevision.revisionId}'),
          );
          await tester.ensureVisible(selected);
          await tester.tap(selected);
          await until(
            tester,
            () => find.text('Original page A').evaluate().isNotEmpty,
          );
          expect(find.text('과거 판본'), findsOneWidget);
          expect(find.text('현재 저장본'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(BlockPageHistorySheet),
              matching: find.text('Original page A'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byType(BlockPageHistorySheet),
              matching: find.text('Changed page B'),
            ),
            findsOneWidget,
          );
          expect(
            session.inkParents,
            [secondRevision.revisionId],
            reason:
                'Read-only preview must not select a historical writer parent',
          );
          await tester.ensureVisible(
            find.byKey(const ValueKey('page-history-restore')),
          );
          await tester.tap(find.byKey(const ValueKey('page-history-restore')));
          await until(
            tester,
            () => find
                .byKey(const ValueKey('page-history-restore'))
                .evaluate()
                .isEmpty,
          );
          final latest = (await readWhilePumping(
            tester,
            () => controller.repository.heads(note.inkEntityId),
          )).single;
          expect(latest.revisionId, isNot(firstRevision.revisionId));
          expect(latest.revisionId, isNot(secondRevision.revisionId));
          expect(latest.parentRevisionIds, [secondRevision.revisionId]);
          expect(
            await readWhilePumping(
              tester,
              () => controller.repository.readFiles(firstRevision),
            ),
            originalFiles,
          );
          expect(
            (await readWhilePumping(
              tester,
              () =>
                  controller.loadBlockPage(session: controller.activeSession!),
            )).toJson(),
            first.toJson(),
          );
          expect(controller.markdown, 'Separate personal summary');
          await until(tester, () {
            final editor = find.byKey(ValueKey('block-text-${block.id}'));
            return editor.evaluate().length == 1 &&
                tester.widget<TextField>(editor).controller!.text ==
                    'Original page A';
          });
          expect(
            tester
                .widget<TextField>(
                  find.byKey(ValueKey('block-text-${block.id}')),
                )
                .controller!
                .text,
            'Original page A',
          );
          await tester.pumpWidget(const SizedBox());
          final reopened = await readWhilePumping(tester, () async {
            await controller.closeNote(session: controller.activeSession!);
            await controller.openNote(
              (await controller.store.list()).singleWhere(
                (item) => item.id == note.id,
              ),
            );
            return controller.loadBlockPage(session: controller.activeSession!);
          });
          expect(reopened.toJson(), first.toJson());
          expect(controller.markdown, 'Separate personal summary');
          await tester.pumpWidget(
            TranslationProvider(
              child: MaterialApp(home: StudyWorkspace(controller: controller)),
            ),
          );
          await drain(tester);
          final access = VaultMcpCallContext(
            isActive: () => true,
            canWrite: () => true,
          );
          final service = VaultMcpService(
            controller,
            prepareMutation: controller.flush,
          );
          final comparison = await readWhilePumping(
            tester,
            () async => jsonObject(
              await service.call('compare_page_revision', {
                'noteId': note.id,
                'revisionId': secondRevision.revisionId,
                'expectedRevisionId': latest.revisionId,
              }, context: access),
            ),
          );
          final restoredByMcp = await readWhilePumping(
            tester,
            () async => jsonObject(
              await service.call('restore_page_revision', {
                'noteId': note.id,
                'revisionId': secondRevision.revisionId,
                'expectedRevisionId': latest.revisionId,
                'expectedHeads': comparison['expectedHeads'],
                'requestId': newId(),
              }, context: access),
            ),
          );
          await until(tester, () {
            final editor = find.byKey(ValueKey('block-text-${block.id}'));
            return editor.evaluate().length == 1 &&
                tester.widget<TextField>(editor).controller!.text ==
                    'Changed page B';
          });
          expect(controller.activeSession!.inkParents, [
            restoredByMcp['revisionId'],
          ]);
          expect(controller.markdown, 'Separate personal summary');
        } finally {
          await tester.pumpWidget(const SizedBox());
          debugDefaultTargetPlatformOverride = null;
          await readWhilePumping(tester, () async {
            await controller.flush();
            controller.dispose();
            await controller.repository.close();
            await root.delete(recursive: true);
          });
        }
      },
    );
  }
}
