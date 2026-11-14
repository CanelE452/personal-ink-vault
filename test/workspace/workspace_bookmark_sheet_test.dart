import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_bookmarks.dart';
import 'package:saber/pages/workspace/workspace_bookmark_sheet.dart';

Finder key(String value) => find.byKey(ValueKey(value));

const folder = WorkspaceBookmark(
  id: 'group',
  revisionId: 'g1',
  spec: WorkspaceBookmarkSpec(kind: .group, title: '수업 자료'),
);

const noteId = '01234567-89ab-4cde-8123-456789abcdef';
const noteTarget = WorkspaceBookmarkSpec(
  kind: .note,
  target: 'inkvault://note/$noteId',
);

Future<void> mount(
  WidgetTester tester,
  void Function(BuildContext) open,
) async {
  await tester.binding.setSurfaceSize(const Size(340, 540));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('adds and opens a note under a collapsible group on a phone', (
    tester,
  ) async {
    final saved = [folder];
    WorkspaceBookmarkSpec? opened;
    await mount(
      tester,
      (context) => showWorkspaceBookmarkSheet(
        context,
        load: () async => saved,
        currentTargets: const [noteTarget],
        label: (spec) => spec.title ?? '강의 노트',
        add: (spec) async => saved.add(
          WorkspaceBookmark(id: 'note', revisionId: 'n1', spec: spec),
        ),
        update: (_, _) async {},
        remove: (_) async {},
        resolve: (_) async {},
        open: (spec) => opened = spec,
      ),
    );
    await tester.tap(key('workspace-bookmark-add-current'));
    await tester.pumpAndSettle();
    await tester.tap(key('workspace-bookmark-target-0'));
    await tester.pumpAndSettle();
    await tester.tap(key('workspace-bookmark-group-picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('수업 자료').last);
    await tester.pumpAndSettle();
    await tester.tap(key('workspace-bookmark-confirm'));
    await tester.pumpAndSettle();

    expect(saved.last.spec.groupId, 'group');
    expect(saved.last.spec.target, noteTarget.target);
    expect(key('workspace-bookmark-open-note-n1'), findsOneWidget);
    await tester.tap(key('workspace-bookmark-group-group-g1'));
    await tester.pumpAndSettle();
    expect(key('workspace-bookmark-open-note-n1'), findsNothing);
    await tester.tap(key('workspace-bookmark-group-group-g1'));
    await tester.pumpAndSettle();
    await tester.tap(key('workspace-bookmark-open-note-n1'));
    await tester.pumpAndSettle();
    expect(opened?.target, noteTarget.target);
    expect(key('workspace-bookmark-sheet'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses the resolver index and offers a qualified heading anchor', (
    tester,
  ) async {
    String? selected;
    await mount(tester, (context) async {
      selected = await showMarkdownBookmarkAnchorChooser(
        context,
        source:
            '# 첫 단원\n\n## 실습\n\n# 둘째 단원\n\n## 실습\n\n'
            '본문 ^target\n\n```\n# 가짜 제목\n```',
        resolveAnchor: (fragment, candidates) {
          expect(candidates.map((c) => c['text'] ?? c['id']), [
            '첫 단원',
            '실습',
            '둘째 단원',
            '실습',
            'target',
          ]);
          return switch (fragment) {
            '실습' => 1,
            '둘째 단원#실습' => 3,
            _ => null,
          };
        },
      );
    });
    expect(find.text('가짜 제목'), findsNothing);
    expect(find.text('^target'), findsOneWidget);
    await tester.tap(key('workspace-bookmark-markdown-anchor-3'));
    await tester.pumpAndSettle();
    expect(selected, '둘째 단원#실습');
    final link = NoteLink.markdown(noteId, selected);
    expect(NoteLink.parse(link.toString())?.markdownAnchor, selected);
    expect(tester.takeException(), isNull);
  });
}
