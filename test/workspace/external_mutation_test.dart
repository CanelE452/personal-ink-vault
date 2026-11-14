import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

class _RefreshGateController extends WorkspaceController {
  new(super.repository);
  var holdRefresh = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> refresh() async {
    if (holdRefresh) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await super.refresh();
  }
}

class _OverlappingRefreshController extends WorkspaceController {
  new(super.repository);
  var blockRefresh = false;
  final entered = [Completer<void>(), Completer<void>()];
  final release = [Completer<void>(), Completer<void>()];
  var next = 0;
  @override
  Future<void> refresh() async {
    if (blockRefresh && next < entered.length) {
      final index = next++;
      entered[index].complete();
      await release[index].future;
    }
    await super.refresh();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('external mutation keeps the repository and active document stable while its writer runs', () async {
    final root = await Directory.systemTemp.createTemp(
      'external-workspace-writer-',
    );
    final c = WorkspaceController(
      await NoteRepository.open(
        Directory('${root.path}/first'),
        createFormatVersion: 2,
      ),
    );
    final next = await NoteRepository.open(
      Directory('${root.path}/second'),
      createFormatVersion: 2,
    );
    final started = Completer<void>(), release = Completer<void>();
    try {
      final note = await c.createNote(
        'A',
        documentKind: VaultDocumentKind.markdown,
      );
      final session = c.activeSession;
      final operation = c.externalMutation((repo) async {
        started.complete();
        await release.future;
        expect(repo, same(c.repository));
        return 'committed';
      });
      await started.future;
      expect(c.externalBusy, isTrue);
      await expectLater(c.openNote(note), throwsStateError);
      await expectLater(c.replaceRepository(next), throwsStateError);
      expect(c.activeSession, same(session));
      release.complete();
      expect(await operation, 'committed');
      expect(c.externalBusy, isFalse);
      await c.openNote(note);
      c.editMarkdown('Unsaved');
      var invoked = false;
      await expectLater(
        c.externalMutation((_) async {
          invoked = true;
        }),
        throwsStateError,
      );
      expect(invoked, false);
      await c.flush();
    } finally {
      if (!release.isCompleted) release.complete();
      c.dispose();
      await c.repository.close();
      await next.close();
      await root.delete(recursive: true);
    }
  });

  for (final outcome in ['success', 'failure']) {
    test(
      'external $outcome keeps input protected until published body refresh finishes',
      () async {
        final temp = await Directory.systemTemp.createTemp('external-refresh-');
        final c = _RefreshGateController(
          await NoteRepository.open(temp, createFormatVersion: 2),
        );
        Future<void>? settled;
        try {
          await c.createNote('A', documentKind: VaultDocumentKind.markdown);
          final session = c.activeSession!;
          Object? failure;
          final operation = c.externalMutation((repo) async {
            await (await WorkspaceStore(repo).open(session.note))
                .saveMarkdown('Published body');
            c.holdRefresh = true;
            if (outcome == 'failure')
              throw StateError('Failure after a real body publication');
            return 'committed';
          });
          settled = operation.then<void>(
            (_) {},
            onError: (Object error, StackTrace _) {
              failure = error;
            },
          );
          final refreshing = await Future.any([
            c.entered.future.then((_) => true),
            settled.then((_) => false),
          ]).timeout(const Duration(seconds: 8));

          expect(
            refreshing,
            isTrue,
            reason: 'The post-publication refresh must also run after a failed writer',
          );
          expect(
            c.externalBusy,
            isTrue,
            reason: 'The old editor buffer must stay protected while new heads are loading',
          );
          c.holdRefresh = false;
          c.release.complete();
          await settled.timeout(const Duration(seconds: 8));
          expect(c.externalBusy, isFalse);
          expect(failure, outcome == 'failure' ? isStateError : isNull);
          expect(c.markdown, 'Published body');
          expect(session.markdownParents, [
            (await c.repository.heads(session.note.markdownEntityId))
                .single
                .revisionId,
          ]);
        } finally {
          c.holdRefresh = false;
          if (!c.release.isCompleted) c.release.complete();
          await settled?.timeout(const Duration(seconds: 8));
          await c.flush();
          c.dispose();
          await c.repository.close();
          final actual = await temp.resolveSymbolicLinks();
          final parent = await Directory.systemTemp.resolveSymbolicLinks();
          expect(
            actual,
            startsWith('$parent${Platform.pathSeparator}external-refresh-'),
          );
          await Directory(actual).delete(recursive: true);
        }
      },
    );
  }

  test('one external mutation cannot unlock input while another refresh still owns it', () async {
    final temp = await Directory.systemTemp.createTemp('external-overlap-');
    final c = _OverlappingRefreshController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    Future<int>? first, second;
    try {
      await c.refresh();
      first = c.externalMutation((_) async {
        c.blockRefresh = true;
        return 1;
      });
      await c.entered[0].future.timeout(const Duration(seconds: 8));
      second = c.externalMutation((_) async => 2);
      await c.entered[1].future.timeout(const Duration(seconds: 8));
      expect(c.externalBusy, isTrue);
      c.release[0].complete();
      expect(await first, 1);

      expect(
        c.externalBusy,
        isTrue,
        reason: 'The second mutation still owns its post-publication refresh',
      );

      c.release[1].complete();
      expect(await second, 2);
      expect(c.externalBusy, isFalse);
    } finally {
      c.blockRefresh = false;
      for (final gate in c.release) if (!gate.isCompleted) gate.complete();
      await first?.timeout(const Duration(seconds: 8));
      await second?.timeout(const Duration(seconds: 8));
      c.dispose();
      await c.repository.close();
      final actual = await temp.resolveSymbolicLinks();
      final parent = await Directory.systemTemp.resolveSymbolicLinks();
      expect(
        actual,
        startsWith('$parent${Platform.pathSeparator}external-overlap-'),
      );
      await Directory(actual).delete(recursive: true);
    }
  });
}
