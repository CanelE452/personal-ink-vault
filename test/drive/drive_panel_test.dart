import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/drive/drive_panel.dart';
import 'package:saber/data/drive/drive_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> flushIo(
    WidgetTester tester, {
    bool Function()? until,
    String? reason,
  }) async {
    if (until != null) await tester.pump();
    final attempts = until == null ? 10 : 400;
    for (var i = 0; i < attempts; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      if (until != null && until()) return;
    }
    if (until != null) expect(until(), isTrue, reason: reason);
  }

  late Directory dir;
  late NoteRepository repo;
  late DriveConnectionController connection;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('drive-panel-test-');
    repo = await NoteRepository.open(Directory('${dir.path}/vault'));
    connection = DriveConnectionController(
      repository: () => repo,
      onRepositoryChanged: (_) async {},
      onRemoteUpdated: () async {},
      onResumeReload: () async {},
      directoryProvider: () async => Directory('${dir.path}/drive'),
    );
  });
  tearDown(() async {
    await repo.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final owned = await dir.resolveSymbolicLinks();
    expect(
      owned,
      startsWith('$root${Platform.pathSeparator}drive-panel-test-'),
    );
    await Directory(owned).delete(recursive: true);
  });

  Future<void> withPanel(
    WidgetTester tester,
    Future<void> Function() verify,
  ) async {
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DrivePanel(controller: connection)),
        ),
      );
      unawaited(connection.initialize());
      await verify();
    } finally {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      unawaited(connection.close().then((_) => closed = true));
      await flushIo(
        tester,
        until: () => closed,
        reason: 'Drive must finish closing in its widget test zone.',
      );
    }
  }

  testWidgets(
    'unconfigured Drive renders offline without pretending connected',
    (tester) async {
      await withPanel(tester, () async {
        await flushIo(
          tester,
          until: () => connection.ready && !connection.busy,
          reason: 'The offline settings should load.',
        );
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Drive 반영 완료'), findsNothing);
      });
    },
  );
  testWidgets(
    'settings error can retry or explicitly recover without file deletion',
    (tester) async {
      final settings = File('${dir.path}/drive/connection.json');
      await tester.runAsync(() async {
        await settings.parent.create(recursive: true);
        await settings.writeAsString('broken-settings');
      });
      await withPanel(tester, () async {
        final errorButton = find.widgetWithText(TextButton, 'Drive 연결 확인 필요');
        await flushIo(
          tester,
          until: () =>
              errorButton.evaluate().isNotEmpty &&
              tester.widget<TextButton>(errorButton).onPressed != null,
          reason: 'Initial settings load must show an enabled error button.',
        );
        expect(tester.takeException(), isNull);
        final button = tester.widget<TextButton>(find.byType(TextButton).first);
        expect(button.onPressed, isNotNull);
        await tester.tap(find.text('Drive 연결 확인 필요'));
        await tester.pumpAndSettle();
        expect(find.text('설정 다시 읽기'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed,
          isNull,
        );
        expect(
          await tester.runAsync(() => settings.readAsString()),
          'broken-settings',
        );
        await tester.tap(find.text('설정 다시 읽기'));
        await flushIo(
          tester,
          until: () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
          reason:
              'Settings retry must finish its I/O before settling animations.',
        );
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
        await flushIo(
          tester,
          until: () =>
              find.text('설정 다시 읽기').evaluate().isEmpty &&
              find.text('연결 설정 복구').evaluate().isEmpty &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
          reason:
              'Settings recovery must finish and remove its error controls.',
        );
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
            () =>
                File('${backups!.single.path}/connection.json').readAsString(),
          ),
          'broken-settings',
        );
        expect(
          tester
              .widget<FilledButton>(find.byType(FilledButton).first)
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.text('닫기'));
        await tester.pumpAndSettle();
      });
    },
  );
}
