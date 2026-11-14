import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  testWidgets(
    'Study saves page, block and quoted discussions for the active page',
    (tester) async {
      final phone = defaultTargetPlatform == TargetPlatform.android;
      await tester.binding.setSurfaceSize(Size(phone ? 390 : 1400, 920));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await _io(tester, () async {
        final root = await Directory.systemTemp.createTemp('study-discussion-');
        await FileManager.init(
          documentsDirectory: p.join(root.path, 'documents'),
          shouldWatchRootDirectory: false,
        );
        final repository = await NoteRepository.open(
          Directory(p.join(root.path, 'vault')),
          createFormatVersion: 2,
        );
        final controller = WorkspaceController(
          repository,
          directoryProvider: () async =>
              Directory(p.join(root.path, 'support')),
        );
        final note = await controller.createNote(
          'Discussion study',
          documentKind: VaultDocumentKind.page,
        );
        final block = phone
            ? BlockPageBlock.fromJson({
                'id': newId(),
                'type': 'paragraph',
                'text': '첫 문단',
                'inlineData': {
                  'format': BlockInlineText.format,
                  'opaque': true,
                },
              })
            : BlockPageBlock.create(text: '첫 문단');
        await controller.saveBlockPage(
          const BlockPageDocument.empty().copyWith(blocks: [block]),
          session: controller.activeSession!,
        );
        return (root, repository, controller, note, block);
      });
      final (root, repository, controller, note, block) = fixture;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _io(tester, () async {
          controller.dispose();
          await repository.close();
          final resolved = await root.resolveSymbolicLinks();
          expect(
            p.dirname(resolved),
            await Directory.systemTemp.resolveSymbolicLinks(),
          );
          expect(p.basename(resolved), startsWith('study-discussion-'));
          await Directory(resolved).delete(recursive: true);
        });
      });

      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: StudyWorkspace(controller: controller)),
        ),
      );
      await _wait(
        tester,
        () => find.byType(BlockPageEditor).evaluate().isNotEmpty,
      );
      final composer = find.byKey(const Key('discussion-new-body'));
      final submit = find.byKey(const Key('discussion-create'));
      Future<void> post(String message) async {
        await _wait(
          tester,
          () =>
              composer.evaluate().length == 1 &&
              tester.widget<TextField>(composer).enabled == true,
        );
        await tester.pump(const Duration(milliseconds: 350));
        await tester.enterText(composer, message);
        await _wait(
          tester,
          () => tester.widget<FilledButton>(submit).onPressed != null,
        );
        await tester.ensureVisible(submit);
        await tester.tap(submit);
        await _wait(
          tester,
          () =>
              find.text(message).evaluate().any((node) => node.widget is Text),
        );
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pump(const Duration(milliseconds: 350));
        await _wait(tester, () => composer.evaluate().isEmpty);
      }

      await tester.tap(find.byTooltip('페이지 댓글'));
      await post('페이지 검토');

      await tester.tap(find.byKey(ValueKey('block-actions-${block.id}')));
      await tester.pump();
      final blockComment = find.widgetWithText(
        PopupMenuItem<String>,
        '이 블록에 댓글',
      );
      await _wait(
        tester,
        () => blockComment.hitTestable().evaluate().length == 1,
      );
      await tester.tap(blockComment);
      await post('문단 검토');

      final field = find.byKey(ValueKey('block-text-${block.id}'));
      await tester.enterText(field, '수업 자료를 다시 읽기');
      tester.widget<TextField>(field).controller!.selection =
          const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.pump();
      if (phone) expect(find.byTooltip('굵게'), findsNothing);
      final quoteComment = find.byTooltip('선택 문구에 댓글');
      await _wait(
        tester,
        () => quoteComment.hitTestable().evaluate().length == 1,
      );
      await tester.tap(quoteComment);
      await post('인용 검토');

      final events = await _io(tester, () async {
        final entries = <String, Map<String, dynamic>>{};
        for (final record in await repository.revisions()) {
          if (!record.blobs.containsKey('discussion-event.json')) continue;
          expect(record.ownerNoteId, note.id);
          final bytes = await repository.readRevisionFile(
            record,
            'discussion-event.json',
          );
          final event = jsonObject(jsonDecode(utf8.decode(bytes)));
          entries[event['body'] as String] = jsonObject(event['anchor']);
        }
        return entries;
      });
      expect(events['페이지 검토']?['kind'], 'page');
      expect(events['문단 검토']?['blockId'], block.id);
      expect(events['인용 검토']?['kind'], 'quote');
      expect(events['인용 검토']?['quote'], '수업 자료');
      expect(events['인용 검토']?['blockId'], block.id);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 55)),
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}

Future<void> _wait(WidgetTester tester, bool Function() done) async {
  final timer = Stopwatch()..start();
  while (!done()) {
    if (timer.elapsed > const Duration(seconds: 12)) {
      fail('Discussion workflow did not reach the expected state');
    }
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump();
}

Future<T> _io<T>(WidgetTester tester, Future<T> Function() action) async {
  var done = false;
  T? value;
  (Object, StackTrace)? failure;
  await tester.runAsync(() async {
    unawaited(
      action().then<void>(
        (result) {
          value = result;
          done = true;
        },
        onError: (Object error, StackTrace trace) {
          failure = (error, trace);
          done = true;
        },
      ),
    );
  });
  await _wait(tester, () => done);
  if (failure case final error?) Error.throwWithStackTrace(error.$1, error.$2);
  return value as T;
}
