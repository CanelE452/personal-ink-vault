import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';
import 'annotation_store_test.dart' show annotationOfficeFile, annotationPdf;

class _UnavailableOffice extends AndroidOfficeEngine {
  @override
  Future<AndroidOfficeCapabilities> capabilities() async =>
      const AndroidOfficeCapabilities(
        available: false,
        engineVersion: 'view-fixture',
        editableFormats: [],
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late NoteRepository repository;
  late OfficeDocumentStore documents;
  late VaultNote note;
  late OfficeEdition first;
  late OfficeEdition latest;
  late String secondPageId;

  File viewFile() =>
      File('${repository.root.path}/.workspace/office-views/${note.id}.json');

  Map<String, Object?> view({
    OfficeEdition? edition,
    bool pdf = false,
    String? page,
  }) {
    final selected = edition ?? first;
    return {
      'version': 1,
      'vaultId': repository.vaultId,
      'noteId': note.id,
      'sourceRevisionId': selected.revision.revisionId,
      'bindingId': selected.bindingId,
      'pdfMode': pdf,
      'pageId': page,
    };
  }

  Future<void> writeView(Map<String, Object?> value) async {
    await viewFile().parent.create(recursive: true);
    await viewFile().writeAsString(jsonEncode(value));
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('office-view-');
    await FileManager.init(
      documentsDirectory: '${temp.path}/documents',
      shouldWatchRootDirectory: false,
    );
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    documents = OfficeDocumentStore(repository);
    note = await documents.importDocument(
      title: 'Saved view',
      fileName: 'saved.docx',
      bytes: annotationOfficeFile('imported'),
    );
    first = await documents.commitEdited(
      await documents.beginEdit(note),
      originalBytes: annotationOfficeFile('first'),
      pdfBytes: annotationPdf('first'),
      engineVersion: 'view-fixture',
      pageCount: 2,
    );
    latest = await documents.commitEdited(
      await documents.beginEdit(note),
      originalBytes: annotationOfficeFile('latest'),
      pdfBytes: annotationPdf('latest'),
      engineVersion: 'view-fixture',
      pageCount: 1,
    );
    final annotation = await OfficeAnnotationStore(repository)
        .open(note, first);
    final core = EditorCoreInfo(filePath: annotation.workingPath)
      ..pages = [EditorPage(), EditorPage()]
      ..initialPageIndex = 0;
    secondPageId = core.pages[1].pageId;
    await annotation.saveSnapshot(core, 0);
    core.dispose();
  });

  tearDown(() async {
    await repository.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final resolved = await temp.resolveSymbolicLinks();
    expect(resolved, startsWith('$root${Platform.pathSeparator}office-view-'));
    await Directory(resolved).delete(recursive: true);
  });

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 12));
      });
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<T> withPumping<T>(
    WidgetTester tester,
    Future<T> Function() operation,
  ) async {
    var done = false;
    T? value;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      operation()
          .timeout(const Duration(seconds: 10))
          .then(
            (result) {
              value = result;
              done = true;
            },
            onError: (Object error, StackTrace stack) {
              failure = error;
              trace = stack;
              done = true;
            },
          );
    });
    for (var i = 0; i < 100 && !done; i++) {
      await drain(tester);
    }
    expect(done, isTrue, reason: 'Office view operation must finish');
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return value as T;
  }

  Future<GlobalKey<OfficeWorkspaceState>> mount(
    WidgetTester tester, {
    bool showBackButton = true,
    double? width,
    NoteRepository? observedRepository,
  }) async {
    final key = GlobalKey<OfficeWorkspaceState>();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              child: SizedBox(
                width: width,
                child: OfficeWorkspace(
                  key: key,
                  repository: observedRepository ?? repository,
                  note: note,
                  engine: _UnavailableOffice(),
                  showBackButton: showBackButton,
                  onBack: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 80; i++) {
      await drain(tester);
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty) {
        break;
      }
    }
    addTearDown(() async {
      final state = key.currentState;
      if (state != null) await withPumping(tester, state.save);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      await withPumping(tester, repository.close);
    });
    return key;
  }

  String? selectedEdition(WidgetTester tester) => tester
      .widget<DropdownButton<String>>(
        find.byKey(const ValueKey('office-edition-selector')),
      )
      .value;

  bool pdfMode(WidgetTester tester) => tester
      .widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>))
      .selected
      .single;

  testWidgets(
    'reads only the selected Office edition payload and reopens its saved ink',
    (tester) async {
      const points = [Offset(40, 60), Offset(100, 120)];
      final savedInk = await withPumping(tester, () async {
        final annotation = await OfficeAnnotationStore(repository)
            .open(note, first);
        final core = await annotation.load();
        try {
          final page = core.pages[1];
          page.strokes.add(
            Stroke(
              color: Colors.blue,
              pressureEnabled: false,
              options: StrokeOptions(size: 5, thinning: 0),
              pageIndex: 1,
              page: page,
              toolId: .ballpointPen,
            )..addPoints(points),
          );
          await annotation.saveSnapshot(core, 0);
          return annotation.revision!.revisionId;
        } finally {
          core.dispose();
        }
      });
      final observed = _ObservedOfficeRepository(repository);
      final previous = first.revision.revisionId;
      final current = latest.revision.revisionId;
      final original = first.revision.parentRevisionIds.single;
      await mount(tester, observedRepository: observed);
      expect(selectedEdition(tester), current);
      expect(
        observed.reads,
        containsAll([
          (current, latest.originalFileName),
          (current, 'preview.pdf'),
        ]),
      );
      expect(
        observed.reads,
        isNot(contains((original, first.originalFileName))),
      );
      expect(
        observed.reads
            .where((read) => read.$1 == previous)
            .map((read) => read.$2),
        everyElement('edition.json'),
      );

      observed.reads.clear();
      final selector = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('office-edition-selector')),
      );
      await tester.runAsync(() async => selector.onChanged!(previous));
      for (var i = 0; i < 80 && selectedEdition(tester) != previous; i++) {
        await drain(tester);
      }
      expect(selectedEdition(tester), previous);
      expect(
        observed.reads,
        containsAll([
          (previous, first.originalFileName),
          (previous, 'preview.pdf'),
        ]),
      );

      await tester.runAsync(() async => tester.tap(find.text('PDF 필기')));
      for (
        var i = 0;
        i < 80 &&
            (find.byType(CanvasGestureDetector).evaluate().isEmpty ||
                find.byType(LinearProgressIndicator).evaluate().isNotEmpty);
        i++
      ) {
        await drain(tester);
      }
      expect(pdfMode(tester), isTrue);
      final editor = tester.state<EditorState>(find.byType(Editor));
      expect(editor.coreInfo.pages[1].pageId, secondPageId);
      expect(
        editor.coreInfo.pages[1].strokes.single.points.map(
          (point) => Offset(point.x, point.y),
        ),
        points,
      );
      final ink = await withPumping(
        tester,
        () => repository.heads(first.bindingId!),
      );
      expect(ink.single.revisionId, savedInk);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reopens the last historical original without changing revisions',
    (tester) async {
      await withPumping(tester, () => writeView(view()));
      final before = (await withPumping(tester, repository.revisions)).length;
      await mount(tester);
      expect(selectedEdition(tester), first.revision.revisionId);
      expect(pdfMode(tester), isFalse);
      expect(find.byType(Editor), findsNothing);
      expect(
        await withPumping(
          tester,
          () async => (await repository.revisions()).length,
        ),
        before,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an unreadable remembered edition falls back to the current one',
    (tester) async {
      await withPumping(tester, () => writeView(view(pdf: true)));
      final observed = _ObservedOfficeRepository(
        repository,
        unreadablePayload: first.revision.revisionId,
      );
      await mount(tester, observedRepository: observed);
      expect(selectedEdition(tester), latest.revision.revisionId);
      expect(pdfMode(tester), isFalse);
      expect(find.textContaining('현재 원본을 엽니다'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restores the exact saved PDF binding and page with no new edition',
    (tester) async {
      await withPumping(
        tester,
        () => writeView(view(pdf: true, page: secondPageId)),
      );
      final before = (await withPumping(tester, repository.revisions)).length;
      final key = await mount(tester);
      expect(selectedEdition(tester), first.revision.revisionId);
      expect(pdfMode(tester), isTrue);
      expect(find.byType(Editor), findsOneWidget);
      final editor = tester.state<EditorState>(find.byType(Editor));
      expect(editor.coreInfo.initialPageIndex, 1);
      expect(editor.coreInfo.pages[1].pageId, secondPageId);
      expect(
        await withPumping(
          tester,
          () async => (await repository.revisions()).length,
        ),
        before,
      );
      await withPumping(tester, key.currentState!.save);
      final saved = await withPumping(
        tester,
        () async =>
            jsonDecode(await viewFile().readAsString()) as Map<String, dynamic>,
      );
      expect(saved['sourceRevisionId'], first.revision.revisionId);
      expect(saved['pdfMode'], isTrue);
      expect(saved['pageId'], secondPageId);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit edition selection persists and survives widget recreation',
    (tester) async {
      final key = await mount(tester);
      final selector = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('office-edition-selector')),
      );
      await tester.runAsync(() async {
        selector.onChanged!(first.revision.revisionId);
      });
      for (
        var i = 0;
        i < 80 && selectedEdition(tester) != first.revision.revisionId;
        i++
      ) {
        await drain(tester);
      }
      await withPumping(tester, key.currentState!.save);
      final saved = await withPumping(
        tester,
        () async =>
            jsonDecode(await viewFile().readAsString()) as Map<String, dynamic>,
      );
      expect(saved['vaultId'], repository.vaultId);
      expect(saved['sourceRevisionId'], first.revision.revisionId);
      expect(saved['pdfMode'], isFalse);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
      await mount(tester);
      expect(selectedEdition(tester), first.revision.revisionId);
      expect(tester.takeException(), isNull);
    },
  );

  for (final invalid in [
    'foreign-vault',
    'missing-edition',
    'mismatched-binding',
    'oversized',
  ]) {
    testWidgets(
      'invalid local view $invalid falls back to the current original',
      (tester) async {
        final saved = view(pdf: true, page: secondPageId);
        switch (invalid) {
          case 'foreign-vault':
            saved['vaultId'] = newId();
          case 'missing-edition':
            saved['sourceRevisionId'] = newId();
          case 'mismatched-binding':
            saved['bindingId'] = newId();
          case 'oversized':
            saved['unexpected'] = 'x' * 17000;
        }
        await withPumping(tester, () => writeView(saved));
        final before = (await withPumping(tester, repository.revisions)).length;
        await mount(tester);
        expect(selectedEdition(tester), latest.revision.revisionId);
        expect(pdfMode(tester), isFalse);
        expect(find.byType(Editor), findsNothing);
        expect(
          await withPumping(
            tester,
            () async => (await repository.revisions()).length,
          ),
          before,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('conflicted source never silently restores a remembered branch', (
    tester,
  ) async {
    await withPumping(
      tester,
      () async => documents.commitEdited(
        await documents.beginEdit(note, revisionId: first.revision.revisionId),
        originalBytes: annotationOfficeFile('concurrent'),
        pdfBytes: annotationPdf('concurrent'),
        engineVersion: 'view-fixture',
        pageCount: 1,
      ),
    );
    await withPumping(
      tester,
      () => writeView(view(pdf: true, page: secondPageId)),
    );
    await mount(tester);
    expect(selectedEdition(tester), isNull);
    expect(find.byType(Editor), findsNothing);
    expect(find.text('서로 다른 원본 버전이 있습니다. 버전을 선택하세요.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'conflicted annotation leaves the remembered edition in original mode',
    (tester) async {
      await withPumping(tester, () async {
        final old = (await repository.heads(first.bindingId!)).single;
        await repository.commit(
          entityId: first.bindingId!,
          ownerNoteId: note.id,
          kind: EntityKind.ink,
          files: await repository.readFiles(old),
          parentRevisionIds: [],
        );
      });
      await withPumping(
        tester,
        () => writeView(view(pdf: true, page: secondPageId)),
      );
      await mount(tester);
      expect(selectedEdition(tester), first.revision.revisionId);
      expect(pdfMode(tester), isFalse);
      expect(find.byType(Editor), findsNothing);
      expect(find.textContaining('이전 PDF 필기 화면을 복원하지 못했습니다'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restores the last viewed Office PDF page before any ink revision',
    (tester) async {
      final edition = await withPumping(tester, () async {
        final pdf = pw.Document()
          ..addPage(pw.Page(build: (_) => pw.Text('First page')))
          ..addPage(pw.Page(build: (_) => pw.Text('Second page')));
        return documents.commitEdited(
          await documents.beginEdit(note),
          originalBytes: annotationOfficeFile('viewed'),
          pdfBytes: await pdf.save(),
          engineVersion: 'view-fixture',
          pageCount: 2,
        );
      });
      final before = (await withPumping(tester, repository.revisions)).length;
      final key = await mount(tester);
      expect(selectedEdition(tester), edition.revision.revisionId);
      expect(pdfMode(tester), isFalse);

      await tester.runAsync(() async {
        await tester.tap(find.text('PDF 필기'));
      });
      for (var i = 0; i < 80; i++) {
        await drain(tester);
        if (find.byType(CanvasGestureDetector).evaluate().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      expect(pdfMode(tester), isTrue);
      final editor = tester.state<EditorState>(find.byType(Editor));
      final secondPage = editor.coreInfo.pages[1];
      expect(
        editor.revealPage(
          secondPage.pageId,
          background: secondPage.backgroundImage!,
        ),
        isTrue,
      );
      await tester.pump();
      expect(editor.currentPageIndex, 1);
      await withPumping(tester, key.currentState!.save);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      await drain(tester);
      CanvasTransformCache.clear();
      await mount(tester);
      expect(selectedEdition(tester), edition.revision.revisionId);
      expect(pdfMode(tester), isTrue);
      final restored = tester.state<EditorState>(find.byType(Editor));
      expect(restored.currentPageIndex, 1);
      expect(restored.coreInfo.pages[1].pageId, secondPage.pageId);
      expect(
        await withPumping(tester, () => repository.heads(edition.bindingId!)),
        isEmpty,
      );
      expect(
        await withPumping(
          tester,
          () async => (await repository.revisions()).length,
        ),
        before,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
      await drain(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a parent toolbar can own the only document back action', (
    tester,
  ) async {
    await mount(tester, showBackButton: false);
    expect(find.byTooltip('문서 목록으로'), findsNothing);
    expect(
      find.byKey(const ValueKey('office-edition-selector')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'damaged saved annotation falls back without creating revisions',
    (tester) async {
      await withPumping(tester, () async {
        final previous = (await repository.heads(first.bindingId!)).single;
        await repository.commit(
          entityId: first.bindingId!,
          kind: EntityKind.ink,
          ownerNoteId: note.id,
          parentRevisionIds: [previous.revisionId],
          files: {
            'main.sbn2': Uint8List.fromList([1, 2, 3]),
          },
        );
        await writeView(view(pdf: true, page: secondPageId));
      });
      final before = (await withPumping(tester, repository.revisions)).length;
      await mount(tester);
      expect(selectedEdition(tester), first.revision.revisionId);
      expect(pdfMode(tester), isFalse);
      expect(find.byType(Editor), findsNothing);
      expect(find.textContaining('이전 PDF 필기 화면을 복원하지 못했습니다'), findsOneWidget);
      expect(
        await withPumping(
          tester,
          () async => (await repository.revisions()).length,
        ),
        before,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [.75, 1.0, 2.0]) {
    testWidgets(
      'current PDF page follows the viewport centre at ${scale}x zoom',
      (tester) async {
        await withPumping(
          tester,
          () => writeView(view(pdf: true, page: secondPageId)),
        );
        await mount(tester);
        final editor = tester.state<EditorState>(find.byType(Editor));
        final detector = tester.state<CanvasGestureDetectorState>(
          find.byType(CanvasGestureDetector),
        );
        final viewer = tester.widget<InteractiveCanvasViewer>(
          find.byType(InteractiveCanvasViewer),
        );
        final top = CanvasGestureDetector.getTopOfPage(
          pageIndex: 1,
          pages: editor.coreInfo.pages,
          screenWidth: MediaQuery.sizeOf(editor.context).width,
        );
        final centre = top + 80;
        viewer.transformationController!.value =
            Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(
              0,
              detector.containerBounds.maxHeight / 2 - scale * centre,
              0,
            );
        await tester.pump();
        expect(editor.currentPageIndex, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('current PDF page uses canvas width beside a library sidebar', (
    tester,
  ) async {
    await withPumping(
      tester,
      () => writeView(view(pdf: true, page: secondPageId)),
    );
    await mount(tester, width: 420);
    final editor = tester.state<EditorState>(find.byType(Editor));
    final detector = tester.state<CanvasGestureDetectorState>(
      find.byType(CanvasGestureDetector),
    );
    final viewer = tester.widget<InteractiveCanvasViewer>(
      find.byType(InteractiveCanvasViewer),
    );
    expect(
      detector.containerBounds.maxWidth,
      lessThan(MediaQuery.sizeOf(editor.context).width),
    );
    final top = CanvasGestureDetector.getTopOfPage(
      pageIndex: 1,
      pages: editor.coreInfo.pages,
      screenWidth: detector.containerBounds.maxWidth,
    );
    viewer.transformationController!.value = Matrix4.translationValues(
      0,
      detector.containerBounds.maxHeight / 2 - (top + 80),
      0,
    );
    await tester.pump();
    expect(editor.currentPageIndex, 1);
    expect(tester.takeException(), isNull);
  });
}

class _ObservedOfficeRepository implements NoteRepository {
  new(this.inner, {this.unreadablePayload});

  final NoteRepository inner;
  final String? unreadablePayload;
  final reads = <(String, String)>[];

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
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<Uint8List> readBlob(String hash) => inner.readBlob(hash);

  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) {
    reads.addAll(record.blobs.keys.map((name) => (record.revisionId, name)));
    if (record.revisionId == unreadablePayload) {
      return Future.error(const FormatException('Unreadable Office payload'));
    }
    return inner.readFiles(record);
  }

  @override
  Future<Uint8List> readRevisionFile(RevisionRecord revision, String name) {
    reads.add((revision.revisionId, name));
    return inner.readRevisionFile(revision, name);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
