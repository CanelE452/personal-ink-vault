import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/drive/drive_panel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late NoteRepository repo;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('drive-panel-test-');
    repo = await NoteRepository.open(Directory('${dir.path}/vault'));
  });
  tearDown(() async {
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
}
