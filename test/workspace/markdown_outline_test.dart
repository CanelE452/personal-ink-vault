import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

const _outline = ValueKey('markdown-outline');

Finder _heading(int index) =>
    find.byKey(ValueKey('markdown-outline-heading-$index'));

Finder _rendered(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is SelectableText &&
      (widget.data ?? widget.textSpan?.toPlainText()) == label,
);

Finder get _sourceEditor => find.descendant(
  of: find.byType(TextField),
  matching: find.byType(EditableText),
);

Widget _editor(
  String source, {
  required List<String> changes,
  required VoidCallback onSave,
  bool readOnly = false,
}) => MarkdownEditor(
  source: source,
  readOnly: readOnly,
  dirty: true,
  onChanged: changes.add,
  onSave: onSave,
  onOpenLink: (_) => fail('Outline navigation opened an external link'),
);

void main() {
  const platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });

  testWidgets('outline selects the exact repeated heading in preview', (
    tester,
  ) async {
    final gap = List.generate(48, (index) => '중간 문단 $index\n\n').join();
    final changes = <String>[];
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _editor(
            '# 상위 제목\n\n## 반복 제목\n\n$gap'
            '## 반복 제목\n\n두 번째 절\n\n$gap',
            changes: changes,
            onSave: () => saves++,
          ),
        ),
      ),
    );

    final viewport = find.descendant(
      of: find.byType(MarkdownPreview),
      matching: find.byType(SingleChildScrollView),
    );
    final duplicate = _rendered('반복 제목');
    expect(duplicate, findsNWidgets(2));
    expect(
      tester.getTopLeft(duplicate.last).dy,
      greaterThan(tester.getBottomLeft(viewport).dy),
    );

    await tester.tap(find.byKey(_outline));
    await tester.pumpAndSettle();
    expect(_heading(1), findsOneWidget);
    expect(_heading(2), findsOneWidget);
    await tester.tap(_heading(2));
    await tester.pumpAndSettle();

    final top = tester.getTopLeft(viewport).dy;
    final bottom = tester.getBottomLeft(viewport).dy;
    expect(tester.getBottomLeft(duplicate.first).dy, lessThan(top));
    expect(tester.getTopLeft(duplicate.last).dy, inInclusiveRange(top, bottom));
    expect(tester.getBottomLeft(_rendered('두 번째 절')).dy, lessThan(bottom));
    expect(find.byType(TextField), findsNothing);
    expect(changes, isEmpty);
    expect(saves, 0);
  }, variant: platforms);

  testWidgets('outline moves the source caret to the UTF-16 heading position', (
    tester,
  ) async {
    final prefix =
        '# 처음 😀\r\n\r\n'
        '${List.generate(60, (index) => '문단 $index\r\n\r\n').join()}';
    final source = '$prefix' '아래 제목\r\n====\r\n\r\n내용';
    final changes = <String>[];
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _editor(source, changes: changes, onSave: () => saves++),
        ),
      ),
    );
    await tester.tap(find.byTooltip('원문 편집'));
    await tester.pumpAndSettle();
    expect(
      tester
          .state<EditableTextState>(_sourceEditor)
          .renderEditable
          .offset
          .pixels,
      0,
    );

    await tester.tap(find.byKey(_outline));
    await tester.pumpAndSettle();
    await tester.tap(_heading(1));
    await tester.pumpAndSettle();

    final editable = tester.state<EditableTextState>(_sourceEditor);
    final render = editable.renderEditable;
    final position = TextPosition(offset: prefix.length);
    expect(
      editable.widget.controller.selection,
      TextSelection.fromPosition(position),
    );
    expect(editable.widget.controller.text, source);
    expect(render.offset.pixels, greaterThan(0));
    expect(
      render.getLocalRectForCaret(position).center.dy,
      inInclusiveRange(0.0, render.size.height),
    );
    expect(find.byType(MarkdownPreview), findsNothing);
    expect(changes, isEmpty);
    expect(saves, 0);
  }, variant: platforms);

  testWidgets('a changed source invalidates an open outline', (tester) async {
    var source = '# 이전 첫 제목\n\n## 이전 두 번째 제목\n\n본문';
    late StateSetter refresh;
    final changes = <String>[];
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              refresh = setState;
              return _editor(source, changes: changes, onSave: () => saves++);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('원문 편집'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_outline));
    await tester.pumpAndSettle();

    refresh(() => source = '# 새 문서\n\n${'기존 데이터 ' * 24}');
    await tester.pump();
    await tester.tap(_heading(1));
    await tester.pumpAndSettle();

    final controller = tester.widget<EditableText>(_sourceEditor).controller;
    expect(controller.text, source);
    expect(
      controller.selection,
      TextSelection.collapsed(offset: source.length),
    );
    expect(changes, isEmpty);
    expect(saves, 0);
  });

  testWidgets('outline is available for a read-only note with no headings', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _editor(
            '일반 문단\n\n```text\n# 코드 예제\n```',
            changes: [],
            readOnly: true,
            onSave: () => fail('Read-only outline saved the document'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(_outline));
    await tester.pumpAndSettle();
    expect(find.text('이 문서에 제목이 없습니다.'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownPreview), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
