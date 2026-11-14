import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_history.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/block_page_history_sheet.dart';

const _restoreKey = ValueKey('page-history-restore');

Finder _revision(RevisionRecord revision) =>
    find.byKey(ValueKey('history-revision-${revision.revisionId}'));

Finder _markdown(BlockPageDocument document) => find.byWidgetPredicate(
  (widget) =>
      widget is SelectableText &&
      widget.data == document.toMarkdown().trimRight(),
);

Future<void> _tick(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 150 && !ready(); attempt++) {
    await _tick(tester);
  }
  expect(
    ready(),
    isTrue,
    reason: 'The asynchronous UI operation did not finish',
  );
}

Future<T> _readWhilePumping<T>(
  WidgetTester tester,
  Future<T> Function() operation,
) async {
  var done = false;
  T? value;
  Object? failure;
  StackTrace? trace;
  await tester.runAsync(() async {
    operation().then(
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
  await _until(tester, () => done);
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return value as T;
}

Future<void> _withFixture(
  WidgetTester tester,
  Future<void> Function(_HistoryFixture) body, {
  double width = 1000,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 820));
  final fixture = await _readWhilePumping(tester, _HistoryFixture.create);
  try {
    await body(fixture);
  } finally {
    await tester.pumpWidget(const SizedBox());
    fixture.reader.releaseAll();
    await _until(tester, () => fixture.reader.activeReads == 0);
    await _readWhilePumping(tester, fixture.dispose);
    await tester.binding.setSurfaceSize(null);
  }
}

Future<void> _open(
  WidgetTester tester,
  _HistoryFixture fixture, {
  required Future<void> Function(RevisionRecord) onRestore,
  bool Function()? isCurrent,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              await showDialog<void>(
                context: context,
                builder: (_) => BlockPageHistorySheet(
                  snapshot: fixture.snapshot,
                  onRestore: onRestore,
                  isCurrent: isCurrent ?? () => true,
                ),
              );
            },
            child: const Text('Open history'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open history'));
  await tester.pumpAndSettle();
}

Future<void> _selectOld(WidgetTester tester, _HistoryFixture fixture) async {
  await tester.ensureVisible(_revision(fixture.old));
  await tester.tap(_revision(fixture.old));
  await _until(tester, () => _markdown(fixture.before).evaluate().isNotEmpty);
}

bool _restoreEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(_restoreKey)).onPressed != null;

void main() {
  testWidgets(
    'failed restore retains the chosen preview and retries at 320 px',
    (tester) => _withFixture(tester, (fixture) async {
      final attempts = <String>[];
      await _open(
        tester,
        fixture,
        onRestore: (revision) async {
          attempts.add(revision.revisionId);
          if (attempts.length == 1) throw StateError('Delivery failed');
        },
      );
      await _selectOld(tester, fixture);
      await tester.tap(find.byKey(_restoreKey));
      await _until(
        tester,
        () => find.textContaining('복원하지 못했습니다.').evaluate().isNotEmpty,
      );

      expect(find.byType(BlockPageHistorySheet), findsOneWidget);
      expect(tester.widget<ListTile>(_revision(fixture.old)).selected, isTrue);
      expect(_markdown(fixture.before), findsOneWidget);
      expect(_markdown(fixture.after), findsOneWidget);
      expect(_restoreEnabled(tester), isTrue);
      expect(fixture.session.inkParents, [fixture.current.revisionId]);
      expect(
        (await _readWhilePumping(
          tester,
          () => fixture.repository.heads(fixture.session.note.inkEntityId),
        )).single.revisionId,
        fixture.current.revisionId,
      );

      await tester.tap(find.byKey(_restoreKey));
      await _until(
        tester,
        () => find.byType(BlockPageHistorySheet).evaluate().isEmpty,
      );
      expect(attempts, [fixture.old.revisionId, fixture.old.revisionId]);
      expect(find.text('Open history'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, width: 320),
  );

  testWidgets(
    'pending restore blocks dismissal selection and duplicate submission',
    (tester) => _withFixture(tester, (fixture) async {
      final pending = Completer<void>();
      var calls = 0;
      try {
        await _open(
          tester,
          fixture,
          onRestore: (_) async {
            calls++;
            await pending.future;
          },
        );
        await _selectOld(tester, fixture);
        await tester.tap(find.byKey(_restoreKey));
        await tester.tap(find.byKey(_restoreKey));
        await tester.pump();

        expect(calls, 1);
        expect(_restoreEnabled(tester), isFalse);
        expect(
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
              .onPressed,
          isNull,
        );
        expect(
          tester.widget<ListTile>(_revision(fixture.current)).enabled,
          isFalse,
        );
        await tester.tap(_revision(fixture.current));
        await tester.tap(find.byTooltip('닫기'));
        await tester.tapAt(const Offset(3, 3));
        await tester.binding.handlePopRoute();
        await tester.pump();

        expect(find.byType(BlockPageHistorySheet), findsOneWidget);
        expect(
          tester.widget<ListTile>(_revision(fixture.old)).selected,
          isTrue,
        );
        expect(_markdown(fixture.before), findsOneWidget);
        expect(calls, 1);

        pending.complete();
        await _until(
          tester,
          () => find.byType(BlockPageHistorySheet).evaluate().isEmpty,
        );
        expect(find.text('Open history'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete();
      }
    }),
  );

  testWidgets(
    'current and deleted revisions cannot be restored',
    (tester) => _withFixture(tester, (fixture) async {
      var calls = 0;
      await _open(
        tester,
        fixture,
        onRestore: (_) async {
          calls++;
        },
      );
      expect(
        tester.widget<ListTile>(_revision(fixture.current)).selected,
        isTrue,
      );
      expect(_restoreEnabled(tester), isFalse);
      await tester.tap(find.byKey(_restoreKey));

      final readsBefore = fixture.reader.readRevisionIds.length;
      await tester.ensureVisible(_revision(fixture.deleted));
      await tester.tap(_revision(fixture.deleted));
      await tester.pump();
      expect(find.text('삭제된 판본은 본문 비교와 복원을 지원하지 않습니다.'), findsOneWidget);
      expect(_restoreEnabled(tester), isFalse);
      expect(fixture.reader.readRevisionIds.length, readsBefore);
      await tester.tap(find.byKey(_restoreKey));
      expect(calls, 0);
      expect(fixture.session.inkParents, [fixture.current.revisionId]);
    }),
  );

  testWidgets(
    'a slower old read cannot replace a more recent selection',
    (tester) => _withFixture(tester, (fixture) async {
      final gate = fixture.reader.hold(fixture.old);
      await _open(tester, fixture, onRestore: (_) async {});
      await tester.tap(_revision(fixture.old));
      await _until(tester, () => gate.started.isCompleted);
      await tester.tap(_revision(fixture.current));
      await _until(
        tester,
        () => _markdown(fixture.after).evaluate().length == 2,
      );
      gate.release.complete();
      await _until(tester, () => gate.finished.isCompleted);
      await _tick(tester);

      expect(
        tester.widget<ListTile>(_revision(fixture.current)).selected,
        isTrue,
      );
      expect(_markdown(fixture.before), findsNothing);
      expect(_markdown(fixture.after), findsNWidgets(2));
      expect(_restoreEnabled(tester), isFalse);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'scope change before preview completion rejects the old result',
    (tester) => _withFixture(tester, (fixture) async {
      final gate = fixture.reader.hold(fixture.old);
      var current = true;
      var calls = 0;
      await _open(
        tester,
        fixture,
        onRestore: (_) async {
          calls++;
        },
        isCurrent: () => current,
      );
      await tester.tap(_revision(fixture.old));
      await _until(tester, () => gate.started.isCompleted);
      current = false;
      gate.release.complete();
      await _until(
        tester,
        () => find.textContaining('열린 페이지가 바뀌었습니다.').evaluate().isNotEmpty,
      );

      expect(find.byType(BlockPageHistorySheet), findsOneWidget);
      expect(_markdown(fixture.before), findsNothing);
      expect(_restoreEnabled(tester), isFalse);
      expect(
        tester.widget<ListTile>(_revision(fixture.current)).enabled,
        isFalse,
      );
      expect(calls, 0);
      expect(fixture.session.inkParents, [fixture.current.revisionId]);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'restore checks scope again when the action is pressed',
    (tester) => _withFixture(tester, (fixture) async {
      var current = true;
      var calls = 0;
      await _open(
        tester,
        fixture,
        onRestore: (_) async {
          calls++;
        },
        isCurrent: () => current,
      );
      await _selectOld(tester, fixture);
      expect(_restoreEnabled(tester), isTrue);
      current = false;
      await tester.tap(find.byKey(_restoreKey));
      await tester.pump();

      expect(calls, 0);
      expect(find.textContaining('열린 페이지가 바뀌었습니다.'), findsOneWidget);
      expect(find.byType(BlockPageHistorySheet), findsOneWidget);
      expect(_restoreEnabled(tester), isFalse);
      expect(fixture.session.inkParents, [fixture.current.revisionId]);
    }),
  );

  testWidgets(
    'preview finishing after disposal does not update a removed sheet',
    (tester) => _withFixture(tester, (fixture) async {
      final gate = fixture.reader.hold(fixture.old);
      await _open(tester, fixture, onRestore: (_) async {});
      await tester.tap(_revision(fixture.old));
      await _until(tester, () => gate.started.isCompleted);
      await tester.pumpWidget(
        const MaterialApp(
          key: ValueKey('replacement'),
          home: Text('Replacement page'),
        ),
      );
      gate.release.complete();
      await _until(tester, () => gate.finished.isCompleted);
      await _tick(tester);

      expect(find.byType(BlockPageHistorySheet), findsNothing);
      expect(find.text('Replacement page'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }),
  );

  testWidgets(
    'restore finishing after disposal cannot pop the replacement page',
    (tester) => _withFixture(tester, (fixture) async {
      final pending = Completer<void>();
      try {
        await _open(tester, fixture, onRestore: (_) => pending.future);
        await _selectOld(tester, fixture);
        await tester.tap(find.byKey(_restoreKey));
        await tester.pump();
        await tester.pumpWidget(
          const MaterialApp(
            key: ValueKey('replacement'),
            home: Text('Replacement page'),
          ),
        );
        pending.complete();
        await _tick(tester);

        expect(find.byType(BlockPageHistorySheet), findsNothing);
        expect(find.text('Replacement page'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!pending.isCompleted) pending.complete();
      }
    }),
  );

  testWidgets(
    '320 px preview exposes moved block positions and unknown attributes',
    (tester) => _withFixture(tester, (fixture) async {
      await _open(tester, fixture, onRestore: (_) async {});
      await _selectOld(tester, fixture);
      expect(_markdown(fixture.before), findsOneWidget);
      expect(_markdown(fixture.after), findsOneWidget);
      expect(find.text('페이지 속성이 바뀌었습니다.'), findsOneWidget);

      final moved = find.ancestor(
        of: find.text('블록 ${fixture.childId.substring(0, 8)}'),
        matching: find.byType(ExpansionTile),
      );
      await tester.ensureVisible(moved);
      expect(
        find.descendant(of: moved, matching: find.textContaining('이동')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: moved, matching: find.textContaining('추가 속성')),
        findsOneWidget,
      );
      await tester.tap(moved);
      await tester.pumpAndSettle();

      expect(
        find.text(
          '블록 ${fixture.oldParentId.substring(0, 8)} · 1번째'
          ' → 블록 ${fixture.newParentId.substring(0, 8)} · 1번째',
        ),
        findsOneWidget,
      );
      final rawBlocks = tester
          .widgetList<SelectableText>(
            find.descendant(of: moved, matching: find.byType(SelectableText)),
          )
          .map((widget) => widget.data!)
          .toList();
      expect(rawBlocks, hasLength(2));
      expect(jsonDecode(rawBlocks.first)['futureColor'], 'red');
      expect(jsonDecode(rawBlocks.last)['futureColor'], 'blue');
      expect(fixture.session.inkParents, [fixture.current.revisionId]);
      expect(tester.takeException(), isNull);
    }, width: 320),
  );
}

class _HistoryFixture {
  new(
    this.directory,
    this.repository,
    this.reader,
    this.session,
    this.snapshot,
    this.old,
    this.deleted,
    this.current,
    this.before,
    this.after,
    this.childId,
    this.oldParentId,
    this.newParentId,
  );

  final Directory directory;
  final NoteRepository repository;
  final _GatedRepository reader;
  final NoteSession session;
  final BlockPageHistorySnapshot snapshot;
  final RevisionRecord old;
  final RevisionRecord deleted;
  final RevisionRecord current;
  final BlockPageDocument before;
  final BlockPageDocument after;
  final String childId;
  final String oldParentId;
  final String newParentId;

  static Future<_HistoryFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'page-history-sheet-',
    );
    final repository = await NoteRepository.open(
      directory,
      createFormatVersion: 2,
    );
    final note = await WorkspaceStore(repository)
        .create('History page', documentKind: VaultDocumentKind.page);
    final oldParentId = newId(), newParentId = newId(), childId = newId();
    Map<String, dynamic> child(String color) => {
      'id': childId,
      'type': 'paragraph',
      'text': 'Nested body',
      'futureColor': color,
    };
    Map<String, dynamic> block(String id, String text, List<Object> children) =>
        {'id': id, 'type': 'paragraph', 'text': text, 'children': children};
    final before = BlockPageDocument.fromJson({
      'version': 1,
      'futurePage': 'old layout',
      'blocks': [
        block(oldParentId, 'Original page A', [child('red')]),
        block(newParentId, 'Destination', []),
      ],
    });
    final after = BlockPageDocument.fromJson({
      'version': 1,
      'futurePage': 'new layout',
      'blocks': [
        block(oldParentId, 'Current page B', []),
        block(newParentId, 'Destination', [child('blue')]),
      ],
    });
    Future<RevisionRecord> commit(
      BlockPageDocument page,
      List<String> parents, {
      bool deleted = false,
    }) => repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: {
        'page.json': Uint8List.fromList(utf8.encode(jsonEncode(page.toJson()))),
      },
      parentRevisionIds: parents,
      deleted: deleted,
    );
    final old = await commit(before, []);
    final deleted = await commit(before, [old.revisionId], deleted: true);
    final current = await commit(after, [deleted.revisionId]);
    final reader = _GatedRepository(repository);
    final session = NoteSession(reader, note, [current], []);
    final snapshot = await BlockPageHistorySnapshot.read(session);
    return _HistoryFixture(
      directory,
      repository,
      reader,
      session,
      snapshot,
      old,
      deleted,
      current,
      before,
      after,
      childId,
      oldParentId,
      newParentId,
    );
  }

  Future<void> dispose() async {
    await repository.close();
    await directory.delete(recursive: true);
  }
}

class _ReadGate {
  final started = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
}

class _GatedRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  final _gates = <String, _ReadGate>{};
  final readRevisionIds = <String>[];
  var activeReads = 0;

  _ReadGate hold(RevisionRecord revision) =>
      _gates.putIfAbsent(revision.revisionId, _ReadGate.new);

  void releaseAll() {
    for (final gate in _gates.values) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
  }

  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<List<RevisionRecord>> heads(String entityId) => inner.heads(entityId);
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord revision) =>
      inner.readFiles(revision);
  @override
  Future<Uint8List> readRevisionFile(
    RevisionRecord revision,
    String name,
  ) async {
    activeReads++;
    readRevisionIds.add(revision.revisionId);
    final gate = _gates[revision.revisionId];
    try {
      if (gate != null) {
        if (!gate.started.isCompleted) gate.started.complete();
        await gate.release.future;
      }
      return await inner.readRevisionFile(revision, name);
    } finally {
      activeReads--;
      if (gate != null && !gate.finished.isCompleted) gate.finished.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
