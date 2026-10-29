import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/main.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import 'utils/test_mock_channel_handlers.dart';

void main() {
  testWidgets('startup and legacy routes enter the offline workspace', (
    tester,
  ) async {
    FlavorConfig.setup();
    setupMockWindowManager();
    setupMockFlutterSecureStorage();
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('workspace-routes-'),
    ))!;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => temp.path,
        );
    await tester.pumpWidget(TranslationProvider(child: const App()));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(StudyWorkspace), findsOneWidget);
    final context = tester.element(find.byType(StudyWorkspace));
    final router = GoRouter.of(context);
    expect(router.routeInformationProvider.value.uri.path, '/workspace');
    for (final path in ['/home/settings', '/edit?path=/old', '/login']) {
      router.go(path);
      await tester.pump();
      expect(router.routeInformationProvider.value.uri.path, '/workspace');
      expect(find.byType(StudyWorkspace), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.runAsync(() => temp.delete(recursive: true));
  });
}
