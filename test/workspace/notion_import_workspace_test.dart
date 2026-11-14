import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/database_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockWindowManager();
  final nativePath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  final hasNative = nativePath != null && File(nativePath).existsSync();
  const platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });

  testWidgets(
    'Notion ZIP opens a separate vault with the page and database row',
    (tester) async {
      final archive = Archive()
        ..addFile(
          ArchiveFile.string(
            '연구 8b58ff11bdbc4ba1abb039f9d124de52.md',
            '# 연구\n\n가져온 본문\n\n'
                '[Open task grid](Tasks%20e03ef649153648f589a814e139f97d37.csv)',
          ),
        )
        ..addFile(
          ArchiveFile.string(
            'Tasks e03ef649153648f589a814e139f97d37.csv',
            'Name,Code\r\nA,001\r\n',
          ),
        );
      final bytes = ZipEncoder().encode(archive);
      final file = _ZipFile(bytes);
      final picker = _Picker(file);
      await _withWorkspace(tester, picker, nativePath, (fixture) async {
        final controller = fixture.controller;
        final original = controller.repository;
        await _openImport(tester);
        await _waitUntil(
          tester,
          () =>
              !identical(controller.repository, original) &&
              controller.notes.length == 2 &&
              find.textContaining('데이터베이스 1개').evaluate().isNotEmpty,
          reason: () => controller.error,
        );
        expect(picker.fileRequests, 1);
        expect(picker.folderRequests, 0);
        expect(file.streamRead, isTrue);
        expect(find.text('연구'), findsOneWidget);
        expect(find.text('Tasks'), findsOneWidget);
        expect(find.textContaining('데이터베이스 1개'), findsOneWidget);

        await _whilePumping(
          tester,
          'Inspect imported and original vaults',
          () async {
            final notes = await controller.store.list();
            final page = notes.singleWhere((note) => note.title == '연구');
            expect(
              await (await controller.store.open(page)).readMarkdown(),
              contains('가져온 본문'),
            );
            final database = notes.singleWhere(
              (note) => note.documentKind == VaultDocumentKind.database,
            );
            final head = (await controller.repository.heads(
              database.inkEntityId,
            )).single;
            final databaseBytes = await controller.repository.readRevisionFile(
              head,
              'database.json',
            );
            final model = WorkspaceDatabase.fromJson(
              jsonDecode(utf8.decode(databaseBytes)) as Map<String, dynamic>,
            );
            expect(model.id, database.id);
            expect(model.rows.single.values.values, containsAll(['A', '001']));
            final old = await NoteRepository.open(fixture.originalDirectory);
            try {
              expect(
                (await WorkspaceStore(old).list()).single.title,
                'Original',
              );
            } finally {
              await old.close();
            }
          },
        );

        await tester.runAsync(() => tester.tap(find.text('연구').hitTestable()));
        final ready = find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.tooltip == '문서 목록으로' &&
              widget.onPressed != null,
        );
        await _waitUntil(tester, () => ready.evaluate().length == 1);
        await _tapMarkdownLink(tester, 'Open task grid');
        await _waitUntil(
          tester,
          () => find.byType(DatabaseEditor).evaluate().length == 1,
          reason: () =>
              'Active: ${controller.activeSession?.note.title}, '
              'Markdown: ${controller.navigation.current.markdown}, '
              'error: ${controller.error}',
        );
        expect(controller.activeSession?.note.title, 'Tasks');
      });
    },
    skip: !hasNative,
    variant: platforms,
  );

  testWidgets(
    'Notion ZIP refuses an oversized file before opening its stream',
    (tester) async {
      final file = _ZipFile(const [], length: 129 * 1024 * 1024);
      final picker = _Picker(file);
      await _withWorkspace(tester, picker, null, (fixture) async {
        final original = fixture.controller.repository;
        await _openImport(tester);
        await _waitUntil(
          tester,
          () => find.textContaining('128 MiB').evaluate().isNotEmpty,
        );
        expect(picker.fileRequests, 1);
        expect(picker.folderRequests, 0);
        expect(file.streamRead, isFalse);
        expect(fixture.controller.repository, same(original));
        expect(fixture.controller.notes.single.title, 'Original');
      });
    },
    variant: platforms,
  );
}

Future<void> _withWorkspace(
  WidgetTester tester,
  _Picker picker,
  String? nativePath,
  Future<void> Function(_Fixture) body,
) async {
  final oldPicker = FilePickerPlatform.instance;
  final oldPaths = PathProviderPlatform.instance;
  final caches = <ThumbnailCache>[];
  _Fixture? fixture;
  Directory? temp;
  try {
    await tester.runAsync(() async {
      final owned = temp = await Directory.systemTemp.createTemp('notion-ui-');
      final support = Directory(p.join(owned.path, 'support'));
      final original = Directory(p.join(owned.path, 'original'));
      final repository = await NoteRepository.open(
        original,
        createFormatVersion: 2,
      );
      final controller = WorkspaceController(
        repository,
        native: nativePath == null
            ? null
            : InkVaultNative.open(libraryPath: nativePath),
        directoryProvider: () async => support,
      );
      fixture = _Fixture(controller, original);
      await controller.store.createMarkdown(
        'Original',
        Uint8List.fromList(utf8.encode('Existing notes')),
      );
      await controller.refresh();
      await FileManager.init(
        documentsDirectory: p.join(owned.path, 'documents'),
        shouldWatchRootDirectory: false,
      );
      FilePickerPlatform.instance = picker;
      PathProviderPlatform.instance = _Paths(support.path);
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: StudyWorkspace(
            controller: fixture!.controller,
            thumbnailCacheFactory: (root) {
              final cache = ThumbnailCache(root);
              caches.add(cache);
              return cache;
            },
          ),
        ),
      ),
    );
    await body(fixture!);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    FilePickerPlatform.instance = oldPicker;
    PathProviderPlatform.instance = oldPaths;
    await _whilePumping(tester, 'Close Notion test vault', () async {
      await Future.wait(caches.map((cache) => cache.retire()));
      final controller = fixture?.controller;
      if (controller != null) {
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
      }
      final directory = temp;
      if (directory != null) {
        final resolved = await directory.resolveSymbolicLinks();
        final system = await Directory.systemTemp.resolveSymbolicLinks();
        expect(p.isWithin(system, resolved), isTrue);
        expect(p.basename(resolved), startsWith('notion-ui-'));
        await Directory(resolved).delete(recursive: true);
      }
    });
  }
}

Future<void> _openImport(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-create-button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  final action = find.text('Notion ZIP 가져오기').hitTestable();
  expect(action, findsOneWidget);
  await tester.runAsync(() => tester.tap(action));
}

Future<void> _tapMarkdownLink(WidgetTester tester, String label) async {
  final text = find.byWidgetPredicate(
    (widget) =>
        widget is SelectableText &&
        (widget.data ?? widget.textSpan?.toPlainText()) == label,
  );
  final link = find.descendant(of: text, matching: find.byType(EditableText));
  await _waitUntil(tester, () => link.evaluate().length == 1);
  await tester.ensureVisible(text);
  await tester.pump();
  final editable = tester.state<EditableTextState>(link).renderEditable;
  final glyph = editable
      .getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 1))
      .first;
  final position = editable.localToGlobal(glyph.toRect().center);
  expect(
    tester
        .hitTestOnBinding(position)
        .path
        .any((entry) => identical(entry.target, editable)),
    isTrue,
    reason: 'The rendered Markdown link must receive the tap.',
  );
  await tester.runAsync(() => tester.tapAt(position));
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() done, {
  String? Function()? reason,
}) async {
  final elapsed = Stopwatch()..start();
  while (!done() && elapsed.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
  }
  expect(done(), isTrue, reason: reason?.call());
}

Future<void> _whilePumping(
  WidgetTester tester,
  String phase,
  Future<void> Function() action,
) async {
  var complete = false;
  (Object, StackTrace)? failure;
  await tester.runAsync(() async {
    unawaited(
      action()
          .timeout(const Duration(seconds: 10))
          .then<void>(
            (_) => complete = true,
            onError: (Object error, StackTrace stack) {
              failure = (error, stack);
              complete = true;
            },
          ),
    );
  });
  await _waitUntil(tester, () => complete, reason: () => phase);
  final error = failure;
  if (error != null) Error.throwWithStackTrace(error.$1, error.$2);
}

final class _Fixture {
  const new(this.controller, this.originalDirectory);
  final WorkspaceController controller;
  final Directory originalDirectory;
}

final class _Paths extends PathProviderPlatform {
  new(this.support);
  final String support;

  @override
  Future<String?> getApplicationSupportPath() async => support;
}

final class _Picker extends FilePickerPlatform {
  new(this.file);
  final PlatformFile file;
  var fileRequests = 0;
  var folderRequests = 0;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    fileRequests++;
    expect(dialogTitle, contains('Notion'));
    expect(type, FileType.custom);
    expect(allowedExtensions, ['zip']);
    return file;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    folderRequests++;
    return null;
  }
}

final class _ZipFile extends PlatformFile {
  new(this.contents, {int? length})
    : reportedLength = length ?? contents.length;

  final List<int> contents;
  final int reportedLength;
  var streamRead = false;

  @override
  String get name => 'notion-export.zip';

  @override
  Future<int?> length() async => reportedLength;

  @override
  Stream<Uint8List> readAsByteStream() {
    streamRead = true;
    return Stream.value(Uint8List.fromList(contents));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected picker access: ${invocation.memberName}');
}
