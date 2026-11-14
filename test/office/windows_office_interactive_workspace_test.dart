import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_edit_recovery.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/office/office_workspace.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

import '../utils/test_mock_channel_handlers.dart';
import 'annotation_store_test.dart' show annotationOfficeFile, annotationPdf;

Future<void> _tick(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pump(const Duration(milliseconds: 20));
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String reason,
) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await _tick(tester);
  }
  expect(condition(), isTrue, reason: reason);
}

Future<T> _read<T>(WidgetTester tester, Future<T> Function() operation) async {
  var done = false;
  T? value;
  Object? error;
  StackTrace? stack;
  await tester.runAsync(() async {
    operation().then(
      (result) {
        value = result;
        done = true;
      },
      onError: (Object failure, StackTrace trace) {
        error = failure;
        stack = trace;
        done = true;
      },
    );
  });
  await _until(tester, () => done, 'The captured repository I/O must finish');
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value as T;
}

class _Launch {
  new(this.request, this.directory, Future<void> cancellation) {
    unawaited(
      cancellation.then<void>((_) {
        cancelled = true;
      }),
    );
  }

  final Map<String, Object?> request;
  final Directory directory;
  final response = Completer<Map<String, dynamic>>();
  var cancelled = false;

  String get id => request['sessionId'] as String;
  File get working =>
      File(p.join(directory.parent.path, request['workingFileName'] as String));
  File get source => File(
    p.join(directory.path, 'edited${p.extension(working.path).toLowerCase()}'),
  );
  File get pdf => File(p.join(directory.path, 'preview.pdf'));

  Map<String, dynamic> common(String status) => {
    'version': 1,
    'sessionId': id,
    'controlNonce': request['controlNonce'],
    'inputSourceSha256': request['inputSourceSha256'],
    'status': status,
    'engineVersion': 'LibreOffice26.8.2.2',
  };

  Future<Uint8List> finishSaved(String label) async {
    final original = p.extension(working.path).toLowerCase() == '.pptx'
        ? OfficeTemplates.create(
            OfficeTemplateKind.presentation,
            title: label,
          ).bytes
        : annotationOfficeFile(label);
    final preview = annotationPdf(label);
    await working.writeAsBytes(original, flush: true);
    await source.writeAsBytes(original, flush: true);
    await pdf.writeAsBytes(preview, flush: true);
    response.complete({
      ...common('saved'),
      'sourcePath': source.path,
      'pdfPath': pdf.path,
      'sourceSha256': sha256.convert(original).toString(),
      'pdfSha256': sha256.convert(preview).toString(),
      'pdfPageCount': 1,
    });
    return original;
  }

  Future<void> finishCancelled({String? savedWorking}) async {
    if (savedWorking != null) {
      await working.writeAsBytes(
        annotationOfficeFile(savedWorking),
        flush: true,
      );
    }
    response.complete(common('cancelled'));
  }
}

class _Fixture {
  new(this.temporary, this.repository, this.note, this.original);

  final Directory temporary;
  final NoteRepository repository;
  final VaultNote note;
  final Uint8List original;
  final key = GlobalKey<OfficeWorkspaceState>();
  OfficeWorkspaceState? _lastMountedState;
  final launches = <_Launch>[];
  final busy = <bool>[];
  var structuredRequests = 0;
  late WindowsOfficeEngine engine;

  OfficeDocumentStore get documents => OfficeDocumentStore(repository);
  OfficeEditRecoveryStore get recovery => OfficeEditRecoveryStore(repository);
  bool get isBusy => busy.isNotEmpty && busy.last;

  static Future<_Fixture> create({bool presentation = false}) async {
    final temporary = await Directory.systemTemp.createTemp(
      'office-gui-widget-',
    );
    final repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'vault')),
      createFormatVersion: 2,
    );
    try {
      await FileManager.init(
        documentsDirectory: p.join(temporary.path, 'documents'),
        shouldWatchRootDirectory: false,
      );
      final original = presentation
          ? OfficeTemplates.create(
              OfficeTemplateKind.presentation,
              title: 'original',
            ).bytes
          : annotationOfficeFile('original');
      final note = await OfficeDocumentStore(repository).importDocument(
        title: 'Native Office',
        fileName: presentation ? 'native.pptx' : 'native.docx',
        bytes: original,
      );
      final fixture = _Fixture(temporary, repository, note, original);
      try {
        fixture.engine = Function.apply(WindowsOfficeEngine.new, const [], {
          #runner: fixture.structured,
          #interactiveRunner: fixture.interactive,
        }) as WindowsOfficeEngine;
      } on NoSuchMethodError catch (error) {
        fail('The Windows engine must accept the interactive runner: $error');
      }
      return fixture;
    } catch (_) {
      await repository.close();
      await temporary.delete(recursive: true);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> interactive(
    Map<String, Object?> request,
    Directory directory,
    Future<void> cancellation,
  ) {
    final launch = _Launch(Map.of(request), directory, cancellation);
    launches.add(launch);
    return launch.response.future;
  }

  Future<Map<String, dynamic>> structured(Map<String, Object?> request) async {
    structuredRequests++;
    expect(request['mode'], 'inspect');
    final input = await File(request['sourcePath'] as String).readAsBytes();
    final preview = File(p.join(temporary.path, 'structured-preview.pdf'));
    await preview.writeAsBytes(annotationPdf('structured'));
    return {
      'snapshot': {
        'kind': 'word',
        'sourceSha256': sha256.convert(input).toString(),
        'paragraphs': [
          {'id': 'p0', 'text': 'Original paragraph'},
        ],
        'tables': [],
        'slides': [],
        'previewPdfPath': preview.path,
        'previewPageCount': 1,
      },
    };
  }

  Future<void> mount(
    WidgetTester tester, {
    VaultNote? selected,
    NoteRepository? mountedRepository,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: OfficeWorkspace(
              key: key,
              repository: mountedRepository ?? repository,
              note: selected ?? note,
              windowsEngine: engine,
              onBusyChanged: busy.add,
              onBack: () {},
            ),
          ),
        ),
      ),
    );
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('office-edit-original'))
          .evaluate()
          .isNotEmpty,
      'The selected Office edition must load',
    );
    _lastMountedState = key.currentState;
  }

  Future<_Launch> start(WidgetTester tester, {bool duplicate = false}) async {
    expect(
      find.byKey(const ValueKey('office-edit-structured')),
      findsOneWidget,
    );
    final count = launches.length;
    await tester.runAsync(() async {
      final action = find.byKey(const ValueKey('office-edit-original'));
      if (duplicate) {
        final pressed = tester.widget<FilledButton>(action).onPressed!;
        pressed();
        pressed();
      } else {
        await tester.tap(action);
      }
    });
    await _until(
      tester,
      () => launches.length == count + 1,
      'The primary action must start the full Office session',
    );
    return launches.last;
  }

  Future<void> saved(WidgetTester tester) => _until(
    tester,
    () => !isBusy && find.text('원본과 PDF를 저장했습니다.').evaluate().isNotEmpty,
    'The source/PDF pair and durable receipt must finish publishing',
  );

  Future<void> close(WidgetTester tester) async {
    final state = key.currentState ?? _lastMountedState;
    await tester.pumpWidget(const SizedBox());
    await _read(tester, () async {
      for (final launch in launches) {
        if (!launch.response.isCompleted) await launch.finishCancelled();
      }
    });
    if (state != null) {
      await _read(tester, () async {
        try {
          await state.save();
        } catch (_) {
          // The test body asserts operation failures; teardown only drains I/O.
        }
      });
    }
    await _read(tester, repository.close);
    await _read(tester, () async {
      final resolved = await temporary.resolveSymbolicLinks();
      final parent = await Directory.systemTemp.resolveSymbolicLinks();
      expect(p.dirname(resolved), parent);
      expect(p.basename(resolved), startsWith('office-gui-widget-'));
      await Directory(resolved).delete(recursive: true);
    });
  }
}

Future<void> _withFixture(
  WidgetTester tester,
  Future<void> Function(_Fixture fixture) body, {
  bool presentation = false,
}) async {
  final fixture = await _read(
    tester,
    () => _Fixture.create(presentation: presentation),
  );
  try {
    await body(fixture);
  } finally {
    await fixture.close(tester);
  }
}

Future<void> _openPreserved(WidgetTester tester) async {
  final title = find.text('보관한 편집 작업 (1)');
  await tester.ensureVisible(title);
  await tester.tap(title);
  await tester.pumpAndSettle();
}

Future<void> _tapRecovery(WidgetTester tester, String id, String action) async {
  final finder = find.byKey(ValueKey('office-recovery-$action-$id'));
  await tester.ensureVisible(finder);
  await tester.runAsync(() async {
    await tester.tap(finder);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  testWidgets(
    'the full Office primary journals before launch and publishes one source/PDF pair',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        final first = await _read(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        await fixture.mount(tester);
        final launch = await fixture.start(tester, duplicate: true);
        expect(fixture.structuredRequests, 0);
        expect(find.byType(WindowsOfficeEditor), findsNothing);
        final entries = await _read(
          tester,
          () => fixture.recovery.list(fixture.note),
        );
        expect(entries, hasLength(1));
        expect(entries.single.sessionId, launch.id);
        expect(entries.single.stage, OfficeEditRecoveryStage.started);
        expect(
          p.equals(entries.single.workingPath, launch.working.path),
          isTrue,
        );
        expect(
          launch.request['inputSourceSha256'],
          sha256.convert(fixture.original).toString(),
        );
        expect(
          await _read(tester, launch.working.readAsBytes),
          fixture.original,
        );
        final primary = tester.widget<FilledButton>(
          find.byKey(const ValueKey('office-edit-original')),
        );
        expect(primary.onPressed, isNull);
        expect(
          find.byKey(const ValueKey('office-interactive-cancel')),
          findsOneWidget,
        );
        expect(
          tester
              .widget<ButtonStyleButton>(
                find.byKey(const ValueKey('office-interactive-cancel')),
              )
              .onPressed,
          isNotNull,
        );
        expect(
          (await _read(
            tester,
            () => fixture.documents.readEditions(fixture.note),
          )),
          hasLength(1),
        );
        await _read(tester, () => launch.finishSaved('GUI edited'));
        await fixture.saved(tester);
        final latest = await _read(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        expect(latest.revision.parentRevisionIds, [first.revision.revisionId]);
        expect(latest.originalBytes, annotationOfficeFile('GUI edited'));
        expect(latest.pdfBytes, annotationPdf('GUI edited'));
        expect(
          (await _read(
            tester,
            () => fixture.documents.readLatest(
              fixture.note,
              revisionId: first.revision.revisionId,
            ),
          )).originalBytes,
          fixture.original,
        );
        expect(
          await _read(
            tester,
            () => fixture.documents.readEditions(fixture.note),
          ),
          hasLength(2),
        );
        expect(
          (await _read(
            tester,
            () => fixture.recovery.list(fixture.note),
          )).single.stage,
          OfficeEditRecoveryStage.completed,
        );
        expect(
          await _read(tester, launch.directory.exists),
          isFalse,
          reason: 'Native output cleanup follows durable copying',
        );
        expect(fixture.launches, hasLength(1));
      });
    },
  );

  testWidgets(
    'a PPTX full Office session preserves its previous source and publishes the matching PDF',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        final first = await _read(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        await fixture.mount(tester);
        final launch = await fixture.start(tester);
        expect(launch.request['workingFileName'], 'original.pptx');
        expect(fixture.structuredRequests, 0);
        final expected = await _read(
          tester,
          () => launch.finishSaved('PPTX GUI saved'),
        );
        await fixture.saved(tester);
        final latest = await _read(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        expect(latest.originalFileName, 'native.pptx');
        expect(latest.originalBytes, expected);
        expect(latest.pdfBytes, annotationPdf('PPTX GUI saved'));
        expect(latest.revision.parentRevisionIds, [first.revision.revisionId]);
        expect(
          (await _read(
            tester,
            () => fixture.documents.readLatest(
              fixture.note,
              revisionId: first.revision.revisionId,
            ),
          )).originalBytes,
          fixture.original,
        );
        expect(
          await _read(
            tester,
            () => fixture.documents.readEditions(fixture.note),
          ),
          hasLength(2),
        );
      }, presentation: true);
    },
  );

  testWidgets(
    'the secondary item editor remains available beside the full Office action',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        await fixture.mount(tester);
        final secondary = find.byKey(const ValueKey('office-edit-structured'));
        expect(secondary, findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(secondary);
        });
        await _until(
          tester,
          () => find.byType(WindowsOfficeEditor).evaluate().isNotEmpty,
          'The existing item editor must still open',
        );
        expect(fixture.structuredRequests, 1);
        expect(fixture.launches, isEmpty);
      });
    },
  );

  testWidgets(
    'publication cancellation preserves a saved working copy and resumes the same session',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        final first = await _read(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        await fixture.mount(tester);
        final launch = await fixture.start(tester);
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('office-interactive-cancel')),
          );
        });
        await _until(
          tester,
          () => launch.cancelled,
          'Cancellation must reach the running session',
        );
        expect(find.textContaining('닫아'), findsWidgets);
        expect(fixture.isBusy, isTrue);
        await _read(
          tester,
          () => launch.finishCancelled(savedWorking: 'Last GUI save'),
        );
        await _until(
          tester,
          () => !fixture.isBusy,
          'The user closing the cancelled editor must finish',
        );
        expect(
          (await _read(
            tester,
            () => fixture.documents.readLatest(fixture.note),
          )).revision.revisionId,
          first.revision.revisionId,
        );
        final entry = (await _read(
          tester,
          () => fixture.recovery.list(fixture.note),
        )).single;
        expect(entry.stage, OfficeEditRecoveryStage.preserved);
        expect(entry.resumableStage, OfficeEditRecoveryStage.started);
        expect(
          await _read(tester, launch.working.readAsBytes),
          annotationOfficeFile('Last GUI save'),
        );
        await _openPreserved(tester);
        await _tapRecovery(tester, launch.id, 'resume');
        await _until(
          tester,
          () => fixture.launches.length == 2,
          'The preserved Windows working file must reopen',
        );
        final resumed = fixture.launches.last;
        expect(resumed.id, launch.id);
        expect(resumed.working.path, launch.working.path);
        expect(
          resumed.request['inputSourceSha256'],
          launch.request['inputSourceSha256'],
        );
        expect(
          resumed.request['expectedWorkingSha256'],
          sha256.convert(annotationOfficeFile('Last GUI save')).toString(),
        );
        await _read(tester, () => resumed.finishSaved('Resumed GUI save'));
        await fixture.saved(tester);
        expect(
          (await _read(
            tester,
            () => fixture.documents.readLatest(fixture.note),
          )).originalBytes,
          annotationOfficeFile('Resumed GUI save'),
        );
        expect(
          await _read(
            tester,
            () => fixture.documents.readEditions(fixture.note),
          ),
          hasLength(2),
        );
      });
    },
  );

  testWidgets(
    'a saved response racing cancellation is preserved before output release and needs explicit resume',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        final first = await _read(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        await fixture.mount(tester);
        final launch = await fixture.start(tester);
        await tester.runAsync(() async {
          await tester.tap(
            find.byKey(const ValueKey('office-interactive-cancel')),
          );
        });
        await _until(
          tester,
          () => launch.cancelled,
          'The cancellation boundary must be reached',
        );
        await _read(
          tester,
          () => launch.finishSaved('Saved before cancel reached native'),
        );
        await _until(
          tester,
          () => !fixture.isBusy,
          'The late saved pair must finish being retained',
        );
        expect(
          (await _read(
            tester,
            () => fixture.documents.readLatest(fixture.note),
          )).revision.revisionId,
          first.revision.revisionId,
        );
        final restored = await _read(
          tester,
          () => fixture.recovery.read(fixture.note, launch.id),
        );
        expect(restored.entry.stage, OfficeEditRecoveryStage.preserved);
        expect(
          restored.entry.resumableStage,
          OfficeEditRecoveryStage.nativeSaved,
        );
        expect(restored.nativeResult, isNotNull);
        expect(
          await _read(
            tester,
            () => File(restored.nativeResult!.sourcePath!).readAsBytes(),
          ),
          annotationOfficeFile('Saved before cancel reached native'),
        );
        expect(
          await _read(
            tester,
            () => File(restored.nativeResult!.pdfPath!).readAsBytes(),
          ),
          annotationPdf('Saved before cancel reached native'),
        );
        expect(await _read(tester, launch.directory.exists), isFalse);
        await _openPreserved(tester);
        await _tapRecovery(tester, launch.id, 'save');
        await fixture.saved(tester);
        expect(
          fixture.launches,
          hasLength(1),
          reason: 'The already retained pair must not reopen an editor',
        );
        expect(
          await _read(
            tester,
            () => fixture.documents.readEditions(fixture.note),
          ),
          hasLength(2),
        );
      });
    },
  );

  testWidgets(
    'cancellation while the recovery source copy is pending preserves the saved pair without publishing',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        final first = await _read(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        await fixture.mount(tester);
        expect(
          find.byKey(const ValueKey('office-edit-structured')),
          findsOneWidget,
        );
        late Completer<void> entered;
        late Completer<void> release;
        String? blockedPath;
        await tester.runAsync(() async {
          entered = Completer<void>();
          release = Completer<void>();
          final outer = Zone.current;
          IOOverrides.runZoned(
            () {
              tester
                  .widget<FilledButton>(
                    find.byKey(const ValueKey('office-edit-original')),
                  )
                  .onPressed!();
            },
            createFile: (path) {
              final actual = outer.run(() => File(path));
              if (blockedPath != null &&
                  p.equals(p.absolute(path), blockedPath)) {
                return _BlockedRecoverySource(actual, entered, release);
              }
              return actual;
            },
          );
        });
        try {
          await _until(
            tester,
            () => fixture.launches.length == 1,
            'The bound GUI session must start',
          );
          final launch = fixture.launches.single;
          blockedPath = launch.source.absolute.path;
          await _read(
            tester,
            () => launch.finishSaved('Saved pair during copy cancellation'),
          );
          await _until(
            tester,
            () => entered.isCompleted,
            'The real durable recovery source read must reach its bounded stream',
          );
          expect(fixture.isBusy, isTrue);
          expect(
            (await _read(
              tester,
              () => fixture.documents.readLatest(fixture.note),
            )).revision.revisionId,
            first.revision.revisionId,
          );
          final cancel = find.byKey(
            const ValueKey('office-interactive-cancel'),
          );
          expect(tester.widget<ButtonStyleButton>(cancel).onPressed, isNotNull);
          await tester.runAsync(() async {
            await tester.tap(cancel);
          });
          await _until(
            tester,
            () => launch.cancelled,
            'Cancellation must remain available while durable copying waits',
          );
          release.complete();
          await _until(
            tester,
            () => !fixture.isBusy,
            'The cancelled durable copy must finish retaining its result',
          );
          final restored = await _read(
            tester,
            () => fixture.recovery.read(fixture.note, launch.id),
          );
          expect(restored.entry.stage, OfficeEditRecoveryStage.preserved);
          expect(
            restored.entry.resumableStage,
            OfficeEditRecoveryStage.nativeSaved,
          );
          expect(restored.nativeResult, isNotNull);
          expect(
            await _read(
              tester,
              () => File(restored.nativeResult!.sourcePath!).readAsBytes(),
            ),
            annotationOfficeFile('Saved pair during copy cancellation'),
          );
          expect(
            await _read(
              tester,
              () => File(restored.nativeResult!.pdfPath!).readAsBytes(),
            ),
            annotationPdf('Saved pair during copy cancellation'),
          );
          expect(
            (await _read(
              tester,
              () => fixture.documents.readLatest(fixture.note),
            )).revision.revisionId,
            first.revision.revisionId,
          );
          expect(await _read(tester, launch.directory.exists), isFalse);
        } finally {
          if (!release.isCompleted) release.complete();
        }
      });
    },
  );

  testWidgets(
    'a stopped GUI worker leaves a resumable journal instead of a phantom edition',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        await fixture.mount(tester);
        final launch = await fixture.start(tester);
        await tester.runAsync(() async {
          launch.response.completeError(
            StateError('Controlled GUI worker stopped'),
          );
        });
        await _until(
          tester,
          () => !fixture.isBusy,
          'The worker failure must leave the workspace usable',
        );
        expect(
          await _read(
            tester,
            () => fixture.documents.readEditions(fixture.note),
          ),
          hasLength(1),
        );
        final entry = (await _read(
          tester,
          () => fixture.recovery.list(fixture.note),
        )).single;
        expect(entry.sessionId, launch.id);
        expect(entry.resumableStage, OfficeEditRecoveryStage.started);
        expect(await _read(tester, launch.working.exists), isTrue);
        await _tapRecovery(tester, launch.id, 'resume');
        await _until(
          tester,
          () => fixture.launches.length == 2,
          'The same durable session must be retried',
        );
        expect(fixture.launches.last.id, launch.id);
        await _read(
          tester,
          () => fixture.launches.last.finishSaved('Retry succeeded'),
        );
        await fixture.saved(tester);
        expect(
          await _read(
            tester,
            () => fixture.documents.readEditions(fixture.note),
          ),
          hasLength(2),
        );
      });
    },
  );

  for (final unmount in [false, true]) {
    testWidgets(
      'a late GUI save after ${unmount ? 'unmount' : 'note replacement'} stays in the captured recovery',
      (tester) async {
        await _withFixture(tester, (fixture) async {
          final first = await _read(
            tester,
            () => fixture.documents.readLatest(fixture.note),
          );
          await fixture.mount(tester);
          final launch = await fixture.start(tester);
          VaultNote? other;
          OfficeEdition? otherFirst;
          if (unmount) {
            await tester.pumpWidget(const SizedBox());
          } else {
            other = await _read(
              tester,
              () => fixture.documents.importDocument(
                title: 'Other',
                fileName: 'other.docx',
                bytes: annotationOfficeFile('Other original'),
              ),
            );
            otherFirst = await _read(
              tester,
              () => fixture.documents.readLatest(other!),
            );
            await fixture.mount(tester, selected: other);
          }
          await _until(
            tester,
            () => launch.cancelled,
            'Leaving the captured document must cancel its running editor',
          );
          await _read(
            tester,
            () => launch.finishSaved('Late captured GUI save'),
          );
          await _until(
            tester,
            () => !fixture.isBusy || unmount,
            'The detached editor must finish',
          );
          await _read(tester, () async {
            for (var i = 0; i < 100; i++) {
              final saved = await fixture.recovery.read(
                fixture.note,
                launch.id,
              );
              if (saved.nativeResult != null &&
                  saved.entry.stage == OfficeEditRecoveryStage.preserved)
                return;
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            fail(
              'The original recovery must retain the detached native result',
            );
          });
          final restored = await _read(
            tester,
            () => fixture.recovery.read(fixture.note, launch.id),
          );
          expect(restored.nativeResult, isNotNull);
          expect(restored.entry.stage, OfficeEditRecoveryStage.preserved);
          expect(
            await _read(
              tester,
              () => File(restored.nativeResult!.sourcePath!).readAsBytes(),
            ),
            annotationOfficeFile('Late captured GUI save'),
          );
          expect(
            (await _read(
              tester,
              () => fixture.documents.readLatest(fixture.note),
            )).revision.revisionId,
            first.revision.revisionId,
          );
          if (other != null) {
            expect(
              (await _read(
                tester,
                () => fixture.documents.readLatest(other!),
              )).revision.revisionId,
              otherFirst!.revision.revisionId,
            );
            expect(
              await _read(tester, () => fixture.recovery.list(other!)),
              isEmpty,
            );
          }
          expect(await _read(tester, launch.directory.exists), isFalse);
        });
      },
    );
  }

  for (final beforePublish in [false, true]) {
    testWidgets(
      'GUI publication retry keeps its edition after ${beforePublish ? 'a pre-publication failure' : 'a lost response'}',
      (tester) async {
        await _withFixture(tester, (fixture) async {
          final guarded = _ResponseLossRepository(
            fixture.repository,
            beforePublish,
          );
          await fixture.mount(tester, mountedRepository: guarded);
          final launch = await fixture.start(tester);
          await _read(tester, () => launch.finishSaved('GUI retry pair'));
          await _until(
            tester,
            () => !fixture.isBusy && find.text('저장 재시도').evaluate().isNotEmpty,
            'The captured prepared result must offer retry',
          );
          expect(guarded.attempts, hasLength(1));
          final attempted = guarded.attempts.single.revisionId;
          final retained = await _read(
            tester,
            () =>
                OfficeEditRecoveryStore(guarded).read(fixture.note, launch.id),
          );
          expect(retained.nativeResult, isNotNull);
          expect(retained.preparedEdition, isNotNull);
          expect(await _read(tester, launch.directory.exists), isFalse);
          await tester.runAsync(() async {
            await tester.tap(find.text('저장 재시도'));
          });
          await fixture.saved(tester);
          expect(
            guarded.attempts.every((record) => record.revisionId == attempted),
            isTrue,
          );
          expect(fixture.launches, hasLength(1));
          final latest = await _read(
            tester,
            () => fixture.documents.readLatest(fixture.note),
          );
          expect(latest.revision.revisionId, attempted);
          expect(latest.originalBytes, annotationOfficeFile('GUI retry pair'));
          expect(latest.pdfBytes, annotationPdf('GUI retry pair'));
          expect(
            await _read(
              tester,
              () => fixture.documents.readEditions(fixture.note),
            ),
            hasLength(2),
          );
        });
      },
    );
  }
}

class _BlockedRecoverySource implements File {
  new(this.actual, this.entered, this.release);
  final File actual;
  final Completer<void> entered, release;

  @override
  String get path => actual.path;
  @override
  File get absolute => actual.absolute;
  @override
  Directory get parent => actual.parent;
  @override
  Future<String> resolveSymbolicLinks() => actual.resolveSymbolicLinks();
  @override
  FileStat statSync() => actual.statSync();
  @override
  Future<int> length() => actual.length();
  @override
  Future<Uint8List> readAsBytes() => actual.readAsBytes();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      actual.open(mode: mode);
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => actual.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Stream<List<int>> openRead([int? start, int? end]) async* {
    if (end == 128 * 1024 * 1024 + 1 && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    yield* actual.openRead(start, end);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ResponseLossRepository implements NoteRepository {
  new(this.inner, this.beforePublish);
  final NoteRepository inner;
  final bool beforePublish;
  final attempts = <RevisionRecord>[];
  var failed = false;

  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  Stream<void> get changes => inner.changes;
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) =>
      inner.readFiles(record);
  @override
  Future<Uint8List> readRevisionFile(RevisionRecord record, String name) =>
      inner.readRevisionFile(record, name);
  @override
  PreparedCommit resumePreparedCommit({
    required Map<String, dynamic> descriptor,
    required Map<String, Uint8List> files,
  }) => inner.resumePreparedCommit(descriptor: descriptor, files: files);
  @override
  PreparedCommit prepareCommit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) => inner.prepareCommit(
    entityId: entityId,
    kind: kind,
    files: files,
    parentRevisionIds: parentRevisionIds,
    ownerNoteId: ownerNoteId,
    deleted: deleted,
    baseRefs: baseRefs,
  );
  @override
  Future<RevisionRecord> commitPrepared(PreparedCommit prepared) =>
      _commit(prepared, () => inner.commitPrepared(prepared));
  @override
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) => _commit(
    prepared,
    () => inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    ),
  );

  Future<RevisionRecord> _commit(
    PreparedCommit prepared,
    Future<RevisionRecord> Function() publish,
  ) async {
    attempts.add(prepared.record);
    if (!failed && beforePublish) {
      failed = true;
      throw StateError('Controlled GUI pre-publication failure');
    }
    final result = await publish();
    if (!failed) {
      failed = true;
      throw StateError('Controlled GUI publication response loss');
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
