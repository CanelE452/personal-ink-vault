import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/database_forms.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/database_editor.dart';
import 'package:saber/pages/workspace/database_forms_editor.dart';

const _revision = '00000000-0000-4000-8000-000000000001';
const _nextRevision = '00000000-0000-4000-8000-000000000002';

void main() {
  late WorkspaceDatabase original;
  late String titleId;
  setUp(() {
    original = WorkspaceDatabase.empty();
    titleId = original.properties.single.id;
    original = DatabaseForms(original).putForm(
      DatabaseForm.create(
        title: '연구 접수',
        questions: [
          DatabaseFormQuestion.create(
            propertyId: titleId,
            label: '제목',
            required: true,
          ),
        ],
      ),
    );
  });

  Future<GlobalKey<DatabaseEditorState>> mount(
    WidgetTester tester, {
    Future<void> Function(WorkspaceDatabase)? save,
    ValueChanged<bool>? dirty,
    ValueChanged<bool>? busy,
    String Function()? currentRevision,
  }) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<DatabaseEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabaseEditor(
            key: key,
            initialDatabase: original,
            onSave: save ?? (_) async {},
            currentRevision: currentRevision ?? () => _revision,
            onDirtyChanged: dirty,
            onBusyChanged: busy,
            onBack: () {},
          ),
        ),
      ),
    );
    return key;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> flush(WidgetTester tester, DatabaseEditorState state) async {
    final saved = state.save();
    await tester.pumpAndSettle();
    await saved;
    await tester.pumpAndSettle();
  }

  testWidgets(
    'database opens forms and parent save drains definition then reopens it',
    (tester) async {
      WorkspaceDatabase? saved;
      final key = await mount(tester, save: (db) async => saved = db);
      await tester.tap(find.byTooltip('입력 폼'));
      await tester.pumpAndSettle();
      expect(find.byType(DatabaseFormsPanel), findsOneWidget);
      await tap(tester, 'forms-create');
      final fields = find.byType(TextField);
      await tester.enterText(fields.first, '논문 신청');
      await tester.pump();
      await flush(tester, key.currentState!);
      expect(find.byType(DatabaseFormsPanel), findsNothing);
      expect(
        DatabaseForms(saved!).forms.map((f) => f.title),
        contains('논문 신청'),
      );
      expect(key.currentState!.database.toJson(), saved!.toJson());
      await tester.tap(find.byTooltip('입력 폼'));
      await tester.pumpAndSettle();
      final panel = tester.state<DatabaseFormsPanelState>(
        find.byType(DatabaseFormsPanel),
      );
      expect(
        DatabaseForms(panel.database).forms.map((f) => f.title),
        contains('논문 신청'),
      );
      await flush(tester, key.currentState!);
    },
  );

  testWidgets(
    'pending form response blocks parent save and explicit cancel preserves database',
    (tester) async {
      var saves = 0;
      var dirty = false;
      var busy = false;
      final key = await mount(
        tester,
        save: (_) async => saves++,
        dirty: (value) => dirty = value,
        busy: (value) => busy = value,
      );
      await tester.tap(find.byTooltip('입력 폼'));
      await tester.pumpAndSettle();
      expect(
        busy,
        isTrue,
        reason: 'An open form owns its input revision until it closes.',
      );
      await tap(tester, 'forms-respond');
      await tester.enterText(
        find.byKey(ValueKey('forms-answer-$titleId')),
        '미제출',
      );
      await tester.pump();
      expect(dirty, isTrue);
      await expectLater(key.currentState!.save(), throwsStateError);
      expect(find.byType(DatabaseFormsPanel), findsOneWidget);
      expect(saves, 0);
      await tap(tester, 'forms-cancel-response');
      await flush(tester, key.currentState!);
      expect(find.byType(DatabaseFormsPanel), findsNothing);
      expect(key.currentState!.database.rows, isEmpty);
      expect(saves, 0);
      expect(dirty, isFalse);
      expect(busy, isFalse);
      expect(find.text('저장하지 못했습니다. 편집 내용은 남아 있습니다.'), findsNothing);
    },
  );

  testWidgets(
    'form submission writes row with current revision and parent retains it',
    (tester) async {
      var current = _revision;
      final writes = <WorkspaceDatabase>[];
      final key = await mount(
        tester,
        currentRevision: () => current,
        save: (db) async {
          writes.add(db);
          current = _nextRevision;
        },
      );
      await tester.tap(find.byTooltip('입력 폼'));
      await tester.pumpAndSettle();
      current = _nextRevision;
      await tap(tester, 'forms-respond');
      await tester.enterText(
        find.byKey(ValueKey('forms-answer-$titleId')),
        '실제 접수',
      );
      await tester.pump();
      await tap(tester, 'forms-submit');
      expect(writes, hasLength(1));
      expect(writes.single.rows.single.values[titleId], '실제 접수');
      expect(
        DatabaseForms(writes.single).submissions.single.inputRevision,
        _nextRevision,
      );
      await flush(tester, key.currentState!);
      expect(key.currentState!.database.rows.single.values[titleId], '실제 접수');
      expect(writes, hasLength(1));
      expect(find.text('실제 접수'), findsWidgets);
    },
  );

  testWidgets('disposing a database owner removes its own open forms route', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    var busy = false;
    addTearDown(active.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, value, _) => value
                ? DatabaseEditor(
                    initialDatabase: original,
                    currentRevision: () => _revision,
                    onSave: (_) async {},
                    onBusyChanged: (value) => busy = value,
                    onBack: () {},
                  )
                : const Text('다음 문서'),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('입력 폼'));
    await tester.pumpAndSettle();
    expect(find.byType(DatabaseFormsPanel), findsOneWidget);
    expect(busy, isTrue);
    active.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(DatabaseFormsPanel), findsNothing);
    expect(find.text('다음 문서'), findsOneWidget);
    expect(busy, isFalse);
    expect(tester.takeException(), isNull);
  });
}
