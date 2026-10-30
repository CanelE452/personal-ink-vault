import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/drive/drive_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> flushIo(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }
  }

  late Directory dir;
  late NoteRepository repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('drive-panel-test-');
    repo = await NoteRepository.open(Directory('${dir.path}/vault'));
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await repo.close();
    await dir.delete(recursive: true);
  });
  testWidgets(
    'unconfigured Drive renders offline without pretending connected',
    (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => dir.path,
          );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DrivePanel(
              repository: () => repo,
              onRepositoryChanged: (_) async {},
              onRemoteUpdated: () async {},
              onResumeReload: () async {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Drive 반영 완료'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'settings error can retry or explicitly recover without file deletion',
    (tester) async {
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await flushIo(tester);
      });
      final settings = File('${dir.path}/drive/connection.json');
      await tester.runAsync(() async {
        await settings.parent.create(recursive: true);
        await settings.writeAsString('broken-settings');
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => dir.path,
          );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DrivePanel(
              repository: () => repo,
              onRepositoryChanged: (_) async {},
              onRemoteUpdated: () async {},
              onResumeReload: () async {},
            ),
          ),
        ),
      );
      await flushIo(tester);
      expect(tester.takeException(), isNull);
      final button = tester.widget<TextButton>(find.byType(TextButton).first);
      expect(button.onPressed, isNotNull);
      await tester.tap(find.text('Drive 연결 확인 필요'));
      await tester.pumpAndSettle();
      expect(find.text('설정 다시 읽기'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
        isNull,
      );
      expect(
        await tester.runAsync(() => settings.readAsString()),
        'broken-settings',
      );
      await tester.tap(find.text('설정 다시 읽기'));
      await flushIo(tester);
      await tester.pumpAndSettle();
      expect(find.text('설정 다시 읽기'), findsOneWidget);
      expect(
        await tester.runAsync(() => settings.readAsString()),
        'broken-settings',
      );
      expect(find.text('연결 설정 복구'), findsOneWidget);
      await tester.tap(find.text('연결 설정 복구'));
      await tester.pumpAndSettle();
      expect(find.textContaining('기존 Drive vault를 다시 연결'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(() => settings.readAsString()),
        'broken-settings',
      );
      expect(
        await tester.runAsync(
          () async => settings.parent
              .listSync()
              .whereType<Directory>()
              .where((entry) => entry.path.contains('connection-backup-'))
              .length,
        ),
        0,
      );
      await tester.tap(find.text('연결 설정 복구'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('원본 보관 후 복구'));
      await flushIo(tester);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('설정 다시 읽기'), findsNothing);
      expect(find.text('연결 설정 복구'), findsNothing);
      final backups = await tester.runAsync(
        () async => settings.parent
            .listSync()
            .whereType<Directory>()
            .where((entry) => entry.path.contains('connection-backup-'))
            .toList(),
      );
      expect(backups, hasLength(1));
      expect(
        await tester.runAsync(
          () => File('${backups!.single.path}/connection.json').readAsString(),
        ),
        'broken-settings',
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton).first).onPressed,
        isNotNull,
      );
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
