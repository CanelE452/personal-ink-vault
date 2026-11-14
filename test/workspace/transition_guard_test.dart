import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

class DelayedOpenController extends WorkspaceController {
  late final delayedStore = DelayedOpenStore(repository);
  new(super.repository);
  @override
  WorkspaceStore get store => delayedStore;
}

class DelayedOpenStore extends WorkspaceStore {
  var block = false;
  final entered = Completer<void>();
  final release = Completer<void>();
  new(super.repository);
  @override
  Future<NoteSession> open(VaultNote note) async {
    if (block) {
      entered.complete();
      await release.future;
    }
    return super.open(note);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed selection write restores the original working repository',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'transition-selection-',
      );
      final blocked = File('${temp.path}/blocked');
      await blocked.writeAsString('preserve');
      final old = await NoteRepository.open(
        Directory('${temp.path}/old'),
        createFormatVersion: 2,
      );
      final next = await NoteRepository.open(
        Directory('${temp.path}/new'),
        createFormatVersion: 2,
      );
      final c = WorkspaceController(
        old,
        directoryProvider: () async => Directory(blocked.path),
      );
      await c.createNote('Original', documentKind: VaultDocumentKind.markdown);
      final session = c.activeSession;
      await expectLater(
        c.replaceRepository(next),
        throwsA(isA<FileSystemException>()),
      );
      expect(c.repository, same(old));
      expect(c.activeSession, same(session));
      c.editMarkdown('Still writable');
      await c.flush();
      expect(await session!.readMarkdown(), 'Still writable');
      expect(await blocked.readAsString(), 'preserve');
      c.dispose();
      await old.close();
      await next.close();
      await temp.delete(recursive: true);
    },
  );
  test('typing while B loads preserves session A and its new input', () async {
    final temp = await Directory.systemTemp.createTemp('transition-open-');
    final c = DelayedOpenController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    final a = await c.store.create(
      'A',
      documentKind: VaultDocumentKind.markdown,
    );
    final b = await c.store.create(
      'B',
      documentKind: VaultDocumentKind.markdown,
    );
    await c.openNote(a);
    final original = c.activeSession;
    c.delayedStore.block = true;
    final opening = c.openNote(b);
    await c.delayedStore.entered.future;
    c.editMarkdown('Keep A');
    c.delayedStore.release.complete();
    Object? failure;
    try {
      await opening;
    } catch (e) {
      failure = e;
    }
    final preserved =
        identical(c.activeSession, original) && c.markdown == 'Keep A';
    await c.flush();
    c.dispose();
    await c.repository.close();
    await temp.delete(recursive: true);
    expect(preserved, isTrue);
    expect(failure, isStateError);
  });
  test(
    'typing during repository switch keeps original repository and session',
    () async {
      final temp = await Directory.systemTemp.createTemp('transition-vault-');
      final repo = await NoteRepository.open(
        Directory('${temp.path}/old'),
        createFormatVersion: 2,
      );
      final next = await NoteRepository.open(
        Directory('${temp.path}/new'),
        createFormatVersion: 2,
      );
      final c = WorkspaceController(repo);
      await c.createNote('A', documentKind: VaultDocumentKind.markdown);
      final original = c.activeSession;
      final switching = c.replaceRepository(next);
      c.editMarkdown('Keep old input');
      Object? failure;
      try {
        await switching;
      } catch (e) {
        failure = e;
      }
      final preserved =
          identical(c.repository, repo) &&
          identical(c.activeSession, original) &&
          c.markdown == 'Keep old input';
      await c.flush();
      c.dispose();
      await repo.close();
      await next.close();
      await temp.delete(recursive: true);
      expect(preserved, isTrue);
      expect(failure, isStateError);
    },
  );
}
