import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

Finder get _editable => find.descendant(
  of: find.byType(TextField),
  matching: find.byType(EditableText),
);

Widget _view({
  required String source,
  required ({int start, int end, String text}) hit,
  required List<String> changes,
  required VoidCallback onSave,
  int request = 1,
  bool readOnly = false,
}) => MaterialApp(
  home: Scaffold(
    body: MarkdownEditor(
      source: source,
      readOnly: readOnly,
      dirty: false,
      onChanged: changes.add,
      onSave: onSave,
      onOpenLink: (_) => fail('Search selection opened a link'),
      searchSelection: hit,
      searchSelectionRequest: request,
    ),
  ),
);

void main() {
  const platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });

  testWidgets('reveals and selects a search hit below the source viewport', (
    tester,
  ) async {
    final prefix = '# 시작 😀\r\n${List.generate(75, (i) => '문단 $i\r\n').join()}';
    const match = '일치한 😀 문장';
    final source = '$prefix$match\r\n나머지 내용';
    final changes = <String>[];
    var saves = 0;
    await tester.pumpWidget(
      _view(
        source: source,
        hit: (
          start: prefix.length,
          end: prefix.length + match.length,
          text: match,
        ),
        changes: changes,
        onSave: () => saves++,
      ),
    );
    await tester.pumpAndSettle();

    final editor = tester.state<EditableTextState>(_editable);
    final selection = editor.widget.controller.selection;
    final render = editor.renderEditable;
    expect(selection.baseOffset, prefix.length);
    expect(selection.textInside(source), match);
    expect(editor.widget.focusNode.hasFocus, isTrue);
    expect(editor.widget.controller.text, source);
    expect(render.offset.pixels, greaterThan(0));
    expect(
      render.getLocalRectForCaret(selection.extent).center.dy,
      inInclusiveRange(0.0, render.size.height),
    );
    expect(changes, isEmpty);
    expect(saves, 0);
  }, variant: platforms);

  testWidgets('only a new search request reopens source mode', (tester) async {
    final changes = <String>[];
    var saves = 0;
    const source = '첫 번째 줄\n본문 검색';
    final start = source.indexOf('검색');
    Widget view(int request, {String text = source}) => _view(
      source: text,
      hit: (start: start, end: source.length, text: '검색'),
      changes: changes,
      onSave: () => saves++,
      request: request,
    );

    await tester.pumpWidget(view(1));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('미리보기'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(view(1));
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(view(2));
    await tester.pumpAndSettle();
    final controller = tester.widget<EditableText>(_editable).controller;
    expect(controller.selection.textInside(source), '검색');

    const updated = '$source\n원격 수정';
    await tester.pumpWidget(view(2, text: updated));
    expect(controller.text, updated);
    expect(
      controller.selection,
      const TextSelection.collapsed(offset: updated.length),
    );
    expect(changes, isEmpty);
    expect(saves, 0);
  });

  testWidgets('rejects a stale substring and read-only search selection', (
    tester,
  ) async {
    final changes = <String>[];
    var saves = 0;
    for (final (source, readOnly, request) in [
      ('수정', false, 1),
      ('검색', true, 2),
    ]) {
      await tester.pumpWidget(
        _view(
          source: source,
          hit: (start: 0, end: 2, text: '검색'),
          changes: changes,
          onSave: () => saves++,
          request: request,
          readOnly: readOnly,
        ),
      );
      expect(find.byType(TextField), findsNothing);
    }
    expect(changes, isEmpty);
    expect(saves, 0);
  });
}
