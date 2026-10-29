import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/flavor_config.dart';
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
    c = WorkspaceController(await NoteRepository.open(temp));
  });
  tearDown(() async {
    await c.saveMarkdown();
    await c.repository.close();
    c.dispose();
    await temp.delete(recursive: true);
  });
  testWidgets(
    'Windows close waits for durable save and keeps failed work open for retry',
    (tester) async {
      final note = await tester.runAsync(() => c.store.create('Close me'));
      await tester.runAsync(() => c.openNote(note!));
      final session = (await tester.runAsync(
        () async => FailingSession(c.activeSession!),
      ))!;
      c.activeSession = session;
      var destroyed = 0;
      final closed = (await tester.runAsync(() async => Completer<void>()))!;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            if (call.method == 'destroy') {
              destroyed++;
              closed.complete();
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
      });
      await tester.pump();
      expect(destroyed, 0);
      expect(c.markdownDirty, isTrue);
      await tester.runAsync(() async {
        session.release.complete();
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(destroyed, 0);
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
      expect(destroyed, 1);
      expect(await tester.runAsync(session.readMarkdown), 'must survive close');
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
      var destroyed = 0;
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        (call) async {
          if (call.method == 'destroy') destroyed++;
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
      expect(destroyed, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

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
  Future<void> saveMarkdown(String text) async {
    if (first) {
      first = false;
      entered.complete();
      await release.future;
      throw const FileSystemException('disk unavailable');
    }
    await super.saveMarkdown(text);
  }
}
