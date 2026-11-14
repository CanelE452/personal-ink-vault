import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/discussion_anchor.dart';
import 'package:saber/data/vault/discussion_store.dart';
import 'package:saber/pages/workspace/page_discussion_sheet.dart';

final _newBody = find.byKey(const Key('discussion-new-body'));
final _create = find.byKey(const Key('discussion-create'));
Finder _by(String key) => find.byKey(Key(key));
Finder _rendered(String body) =>
    find.byWidgetPredicate((w) => w is Text && w.data == body);

void main() {
  testWidgets('narrow composer keeps the exact draft after a failed save', (
    tester,
  ) async {
    await _withFixture(tester, (fixture) async {
      var writes = 0;
      await _open(
        tester,
        fixture,
        pageForWrite: () async {
          if (++writes == 1) throw StateError('Save did not complete');
          return fixture.page;
        },
      );

      const body = ' <b>댓글</b>\n한글 😀 ';
      await tester.enterText(_newBody, body);
      await _tap(tester, _create);
      await _until(
        tester,
        () => _by('discussion-write-error').evaluate().isNotEmpty,
      );
      expect(tester.widget<TextField>(_newBody).controller?.text, body);
      await _until(tester, () => _enabled(tester, _create));
      await _tap(tester, _create);
      await _until(tester, () => _rendered(body).evaluate().isNotEmpty);
      expect(tester.widget<TextField>(_newBody).controller?.text, '');
      final threads = await tester.runAsync(fixture.threads);
      expect(threads!.single.root.body, body);
      expect(writes, 2);
      expect(tester.takeException(), isNull);
    }, size: const Size(320, 700));
  });

  testWidgets('selected quote can get a reply and reports a changed anchor', (
    tester,
  ) async {
    await _withFixture(tester, (fixture) async {
      final id = fixture.block.id;
      final anchor = DiscussionAnchor.quote(
        pageId: fixture.page.entityId,
        document: fixture.document,
        blockId: id,
        startUtf16: 0,
        endUtf16: 2,
      );
      await _open(tester, fixture, initialAnchor: anchor);
      expect(find.text('선택 문구'), findsOneWidget);
      await tester.enterText(_newBody, '선택 문구에 대한 댓글');
      await _tap(tester, _create);
      await _until(
        tester,
        () => _rendered('선택 문구에 대한 댓글').evaluate().isNotEmpty,
      );
      final thread = (await tester.runAsync(fixture.threads))!.single;
      expect(thread.anchor.quoteText, '선택');
      final threadId = thread.id;
      await _tap(tester, _by('discussion-reply-to-$threadId'));
      await tester.enterText(_by('discussion-reply-body'), '답글 원문');
      await _tap(tester, _by('discussion-reply-submit'));
      await _until(tester, () => _rendered('답글 원문').evaluate().isNotEmpty);
      expect(
        (await tester.runAsync(fixture.threads))!
            .single
            .replies
            .single
            .replyToId,
        threadId,
      );

      await tester.runAsync(
        () => fixture.save(
          fixture.document.copyWith(
            blocks: [fixture.block.copyWith(text: '선택 문구 변경')],
          ),
        ),
      );
      await _until(
        tester,
        () => find.text('원래 선택 문구가 바뀌었습니다.').evaluate().isNotEmpty,
      );
      expect(_rendered('선택 문구에 대한 댓글'), findsOneWidget);
    });
  });

  testWidgets('conflict uses the shown head set and waits for a fresh choice', (
    tester,
  ) async {
    await _withFixture(tester, (fixture) async {
      final thread = await tester.runAsync(fixture.makeConflict);
      final id = thread!.id;
      var race = true;
      await _open(
        tester,
        fixture,
        pageForWrite: () async {
          if (race) {
            race = false;
            await fixture.store.setResolved(
              page: fixture.page,
              threadId: id,
              resolved: false,
              expectedStatusIds: thread.statusHeadIds,
            );
          }
          return fixture.page;
        },
      );
      expect(find.text('상태 충돌'), findsOneWidget);
      await _tap(tester, _by('discussion-resolve-$id'));
      await _until(
        tester,
        () => _by('discussion-write-error').evaluate().isNotEmpty,
      );
      await _until(tester, () => find.text('열림').evaluate().isNotEmpty);
      expect(
        (await tester.runAsync(fixture.threads))!.single.status,
        DiscussionThreadStatus.open,
      );

      await _tap(tester, _by('discussion-resolve-$id'));
      await _until(tester, () => find.text('해결됨').evaluate().isNotEmpty);
      await _tap(tester, _by('discussion-reopen-$id'));
      await _until(tester, () => find.text('열림').evaluate().isNotEmpty);
      expect(
        (await tester.runAsync(fixture.threads))!.single.status,
        DiscussionThreadStatus.open,
      );
    });
  });

  testWidgets('dismissing while page save is pending never sends a comment', (
    tester,
  ) async {
    await _withFixture(tester, (fixture) async {
      final pending = Completer<RevisionRecord>();
      var started = false;
      await _open(
        tester,
        fixture,
        pageForWrite: () {
          started = true;
          return pending.future;
        },
      );
      await tester.enterText(_newBody, '닫은 뒤에는 쓰지 않음');
      await _tap(tester, _create);
      await _until(tester, () => started);
      await tester.tap(find.byTooltip('댓글 닫기'));
      await tester.pump();
      pending.complete(fixture.page);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_newBody, findsNothing);
      expect(await tester.runAsync(fixture.threads), isEmpty);
      expect(tester.takeException(), isNull);
    });
  });
}

bool _enabled(WidgetTester tester, Finder finder) =>
    finder.evaluate().isNotEmpty &&
    tester.widget<FilledButton>(finder).onPressed != null;

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 180 && !ready(); attempt++) {
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue, reason: 'The discussion operation did not finish');
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _until(tester, () => finder.evaluate().isNotEmpty);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _open(
  WidgetTester tester,
  _Fixture fixture, {
  DiscussionAnchor? initialAnchor,
  Future<RevisionRecord> Function()? pageForWrite,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(
              showPageDiscussionSheet(
                context: context,
                store: fixture.store,
                pageId: fixture.page.entityId,
                pageForWrite: pageForWrite ?? () async => fixture.page,
                initialAnchor: initialAnchor,
              ),
            ),
            child: const Text('Open discussions'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open discussions'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _until(
    tester,
    () =>
        _newBody.evaluate().isNotEmpty &&
        tester.widget<TextField>(_newBody).enabled == true,
  );
}

Future<void> _withFixture(
  WidgetTester tester,
  Future<void> Function(_Fixture) body, {
  Size size = const Size(650, 850),
}) async {
  await tester.binding.setSurfaceSize(size);
  final fixture = (await tester.runAsync(_Fixture.create))!;
  try {
    await body(fixture);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(fixture.dispose);
    await tester.binding.setSurfaceSize(null);
  }
}

Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

final class _Fixture {
  new(this.directory, this.repository, this.page, this.inkId, this.block)
    : store = DiscussionStore(repository);
  final Directory directory;
  final NoteRepository repository;
  final RevisionRecord page;
  final String inkId;
  final BlockPageBlock block;
  final DiscussionStore store;

  BlockPageDocument get document =>
      const BlockPageDocument.empty().copyWith(blocks: [block]);

  static Future<_Fixture> create() async {
    final directory = await Directory.systemTemp.createTemp('piv-comments-');
    final repo = await NoteRepository.open(
      Directory(p.join(directory.path, 'one')),
      createFormatVersion: 2,
    );
    final pageId = newId(), inkId = newId(), markdownId = newId();
    await repo.commit(
      entityId: markdownId,
      kind: EntityKind.markdown,
      ownerNoteId: pageId,
      files: {'summary.md': Uint8List(0)},
      parentRevisionIds: [],
    );
    final page = await repo.commit(
      entityId: pageId,
      kind: EntityKind.metadata,
      files: {
        'note.json': _json({
          'title': 'Page',
          'inkEntityId': inkId,
          'markdownEntityId': markdownId,
          'documentKind': 'page',
          'folderId': null,
        }),
      },
      parentRevisionIds: [],
    );
    final fixture = _Fixture(
      directory,
      repo,
      page,
      inkId,
      BlockPageBlock.create(text: '선택 문구 뒤'),
    );
    await fixture.save(fixture.document);
    return fixture;
  }

  Future<void> save(BlockPageDocument document) async {
    await repository.commit(
      entityId: inkId,
      kind: EntityKind.ink,
      ownerNoteId: page.entityId,
      files: {'page.json': _json(document.toJson())},
      parentRevisionIds: (await repository.heads(inkId))
          .map((head) => head.revisionId)
          .toList(),
    );
  }

  Future<List<DiscussionThread>> threads() => store.listThreads(page.entityId);

  Future<DiscussionThread> makeConflict() async {
    final id = await store.createThread(
      page: page,
      anchor: DiscussionAnchor.page(pageId: page.entityId),
      body: '상태를 선택할 댓글',
    );
    final peer = await NoteRepository.open(
      Directory(p.join(directory.path, 'two')),
      createFormatVersion: 2,
      vaultId: repository.vaultId,
    );
    try {
      for (final record in await repository.revisions()) {
        await _replicate(repository, peer, record);
      }
      await store.setResolved(
        page: page,
        threadId: id,
        resolved: true,
        expectedStatusIds: [id],
      );
      final peerEvent = await DiscussionStore(peer).setResolved(
        page: page,
        threadId: id,
        resolved: false,
        expectedStatusIds: [id],
      );
      await _replicate(peer, repository, (await peer.heads(peerEvent)).single);
      return (await threads()).single;
    } finally {
      await peer.close();
    }
  }

  Future<void> dispose() async {
    await repository.close();
    await directory.delete(recursive: true);
  }
}

Future<void> _replicate(
  NoteRepository source,
  NoteRepository target,
  RevisionRecord record,
) async => target.importRevision(
  record,
  blobsByHash: {
    for (final blob in record.blobs.values)
      blob.hash: await source.readBlob(blob.hash),
  },
);
