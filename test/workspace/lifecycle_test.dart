import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/study_workspace.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  late Directory temp;
  late WorkspaceController c;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('workspace-close-');
    c = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
  });
  tearDown(() async {
    await c.saveMarkdown();
    await c.repository.close();
    c.dispose();
    await temp.delete(recursive: true);
  });
  testWidgets('Windows closes after pending thumbnail publication drains', (
    tester,
  ) async {
    final caches = <_PendingThumbnailCache>[];
    final calls = <String>[];
    final firstClose = (await tester.runAsync(() async => Completer<void>()))!;
    final secondClose = (await tester.runAsync(() async => Completer<void>()))!;
    final pending = (await tester.runAsync(
      () async => [
        for (var i = 0; i < 2; i++)
          (retired: Completer<void>(), release: Completer<void>()),
      ],
    ))!;
    var closeAttempts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          final action = _windowAction(call);
          calls.add(action);
          if (action == 'close') {
            if (closeAttempts++ == 0) {
              firstClose.complete();
              throw PlatformException(code: 'window-close-unavailable');
            }
            secondClose.complete();
          }
          return null;
        });
    addTearDown(() async {
      for (final cache in caches) {
        if (!cache.release.isCompleted) cache.release.complete();
      }
      await tester.pumpWidget(const SizedBox());
    });
    await tester.pumpWidget(
      MaterialApp(
        home: StudyWorkspace(
          controller: c,
          thumbnailCacheFactory: (root) {
            final signals = pending[caches.length];
            final cache = _PendingThumbnailCache(
              root,
              signals.retired,
              signals.release,
            );
            caches.add(cache);
            return cache;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final listener =
        tester.state(find.byType(StudyWorkspace)) as WindowListener;
    final first = caches.single;
    await tester.runAsync(() async {
      listener.onWindowClose();
      await first.retired.future.timeout(const Duration(seconds: 5));
    });
    expect(calls, ['setPreventClose:true']);
    await tester.runAsync(() async {
      first.release.complete();
      await firstClose.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('창을 닫지 못했습니다'), findsOneWidget);
    expect(caches, hasLength(2));
    final replacement = caches.last;
    await tester.runAsync(() async {
      listener.onWindowClose();
      await replacement.retired.future.timeout(const Duration(seconds: 5));
    });
    expect(closeAttempts, 1);
    await tester.runAsync(() async {
      replacement.release.complete();
      await secondClose.future.timeout(const Duration(seconds: 5));
    });
    expect(closeAttempts, 2);
  });
  testWidgets(
    'Windows close waits for durable save and keeps failed work open for retry',
    (tester) async {
      final note = await tester.runAsync(
        () => c.store.create(
          'Close me',
          documentKind: VaultDocumentKind.markdown,
        ),
      );
      await tester.runAsync(() => c.openNote(note!));
      final session = (await tester.runAsync(
        () async => FailingSession(c.activeSession!),
      ))!;
      c.activeSession = session;
      final calls = <String>[];
      final closed = (await tester.runAsync(() async => Completer<void>()))!;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            final action = _windowAction(call);
            calls.add(action);
            if (action == 'close' || action == 'destroy') {
              if (!closed.isCompleted) closed.complete();
            }
            return null;
          });
      await tester.pumpWidget(MaterialApp(home: StudyWorkspace(controller: c)));
      await tester.pump();
      c.editMarkdown('must survive close');
      final listener =
          tester.state(find.byType(StudyWorkspace)) as WindowListener;
      await tester.runAsync(() async {
        listener.onWindowClose();
        await session.entered.future;
        listener.onWindowClose();
      });
      await tester.pump();
      expect(calls, ['setPreventClose:true']);
      expect(c.markdownDirty, isTrue);
      await tester.runAsync(() async {
        session.release.complete();
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(calls, ['setPreventClose:true']);
      expect(c.markdown, 'must survive close');
      expect(find.textContaining('닫기 전에 저장하지 못했습니다'), findsOneWidget);
      expect(find.text('다시 저장하고 닫기'), findsOneWidget);
      final retry = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '다시 저장하고 닫기'),
      );
      expect(retry.onPressed, isNotNull);
      await tester.runAsync(() async {
        retry.onPressed!();
        await closed.future;
      });
      await tester.pump();
      expect(calls, ['setPreventClose:true', 'setPreventClose:false', 'close']);
      expect(await tester.runAsync(session.readMarkdown), 'must survive close');
      await tester.runAsync(() async {
        listener.onWindowClose();
        await Future<void>.delayed(Duration.zero);
      });
      expect(calls, ['setPreventClose:true', 'setPreventClose:false', 'close']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Windows close failure restores interception and retries already saved work',
    (tester) async {
      final note = await tester.runAsync(
        () => c.store.create(
          'Retry close',
          documentKind: VaultDocumentKind.markdown,
        ),
      );
      await tester.runAsync(() => c.openNote(note!));
      final session = c.activeSession!;
      final calls = <String>[];
      final settled = (await tester.runAsync(() async => Completer<void>()))!;
      final retried = (await tester.runAsync(() async => Completer<void>()))!;
      var closeAttempts = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            final action = _windowAction(call);
            calls.add(action);
            if (action == 'destroy' ||
                action == 'setPreventClose:true' && closeAttempts == 1) {
              if (!settled.isCompleted) settled.complete();
            }
            if (action == 'close') {
              if (closeAttempts++ == 0) {
                throw PlatformException(code: 'window-close-unavailable');
              }
              retried.complete();
            }
            return null;
          });
      await tester.pumpWidget(MaterialApp(home: StudyWorkspace(controller: c)));
      await tester.pump();
      c.editMarkdown('saved before native close');
      final listener =
          tester.state(find.byType(StudyWorkspace)) as WindowListener;
      await tester.runAsync(() async {
        listener.onWindowClose();
        await settled.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(calls, [
        'setPreventClose:true',
        'setPreventClose:false',
        'close',
        'setPreventClose:true',
      ]);
      expect(c.markdownDirty, isFalse);
      expect(
        await tester.runAsync(session.readMarkdown),
        'saved before native close',
      );
      expect(find.textContaining('창을 닫지 못했습니다'), findsOneWidget);
      final retry = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '다시 저장하고 닫기'),
      );
      expect(retry.onPressed, isNotNull);
      await tester.runAsync(() async {
        retry.onPressed!();
        await retried.future.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      expect(calls, [
        'setPreventClose:true',
        'setPreventClose:false',
        'close',
        'setPreventClose:true',
        'setPreventClose:false',
        'close',
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Windows close remains available after startup directory failure',
    (tester) async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async =>
            throw PlatformException(code: 'support-directory-unavailable'),
      );
      final calls = <String>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          calls.add(_windowAction(call));
          return null;
        },
      );
      await tester.pumpWidget(const MaterialApp(home: StudyWorkspace()));
      await tester.pumpAndSettle();
      expect(find.textContaining('저장소를 열 수 없습니다'), findsOneWidget);
      final listener =
          tester.state(find.byType(StudyWorkspace)) as WindowListener;
      await tester.runAsync(() async {
        listener.onWindowClose();
        await Future<void>.delayed(Duration.zero);
      });
      expect(calls, ['setPreventClose:true', 'setPreventClose:false', 'close']);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _PendingThumbnailCache extends ThumbnailCache {
  new(super.root, this.retired, this.release);

  final Completer<void> retired;
  final Completer<void> release;

  @override
  Future<void> retire() {
    if (!retired.isCompleted) retired.complete();
    return release.future;
  }
}

String _windowAction(MethodCall call) => call.method == 'setPreventClose'
    ? 'setPreventClose:${call.arguments['isPreventClose']}'
    : call.method;

class FailingSession extends NoteSession {
  new(NoteSession source)
    : super(
        source.repository,
        source.note,
        source.inkHeads,
        source.markdownHeads,
      );
  final release = Completer<void>();
  final entered = Completer<void>();
  var first = true;
  @override
  Future<void> saveMarkdown(
    String text, {
    Map<String, List<String>>? expectedHeads,
    void Function()? requireWrite,
  }) async {
    if (first) {
      first = false;
      entered.complete();
      await release.future;
      throw const FileSystemException('disk unavailable');
    }
    await super.saveMarkdown(
      text,
      expectedHeads: expectedHeads,
      requireWrite: requireWrite,
    );
  }
}
