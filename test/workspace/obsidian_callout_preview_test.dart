import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

Finder _text(String value, {bool skipOffstage = true}) =>
    find.text(value, findRichText: true, skipOffstage: skipOffstage);

Future<void> _mount(
  WidgetTester tester,
  String source, {
  ValueChanged<String>? onOpenLink,
  String? targetAnchor,
  ValueChanged<String>? onAnchorUnavailable,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MarkdownPreview(
          source: source,
          onOpenLink: onOpenLink ?? (_) {},
          targetAnchor: targetAnchor,
          anchorResolver: (anchor, candidates) {
            final index = candidates.indexWhere(
              (candidate) =>
                  candidate['kind'] == 'heading' && candidate['text'] == anchor,
            );
            return index < 0 ? null : index;
          },
          onAnchorUnavailable: onAnchorUnavailable,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'callout fold markers control the body and title-only stays static',
    (tester) async {
      await _mount(
        tester,
        '> [!warning]- Folded notice\n'
        '> Hidden **detail**\n\n'
        '> [!TIP]+ Expanded notice\n'
        '> Initially visible\n\n'
        '> [!Custom Type|payload]\n'
        '> Always visible\n\n'
        '> [!example]- Title only',
      );

      expect(_text('Folded notice'), findsOneWidget);
      expect(_text('Hidden detail'), findsNothing);
      expect(_text('Hidden detail', skipOffstage: false), findsOneWidget);
      expect(_text('Initially visible'), findsOneWidget);
      expect(_text('Custom type'), findsOneWidget);
      expect(_text('Always visible'), findsOneWidget);
      expect(_text('Title only'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);

      await tester.tap(_text('Folded notice'));
      await tester.pumpAndSettle();
      expect(_text('Hidden detail'), findsOneWidget);
      final body = tester.widget<SelectableText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              widget.textSpan?.toPlainText() == 'Hidden detail',
        ),
      );
      expect(
        body.textSpan!.children!.whereType<TextSpan>().any(
          (span) =>
              span.text == 'detail' &&
              span.style?.fontWeight == FontWeight.bold,
        ),
        isTrue,
      );

      await tester.tap(_text('Expanded notice'));
      await tester.pumpAndSettle();
      expect(_text('Initially visible'), findsNothing);
      expect(_text('Hidden detail'), findsOneWidget);
      await tester.tap(_text('Folded notice'));
      await tester.pumpAndSettle();
      expect(_text('Hidden detail'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nested callout preserves the normal vault link action', (
    tester,
  ) async {
    final opened = <String>[];
    await _mount(
      tester,
      '> [!note]+ Outer\n'
      '>\n'
      '> > [!tip]- Inner\n'
      '> > [[Folder/Note|Open note]]',
      onOpenLink: opened.add,
    );
    expect(_text('Outer'), findsOneWidget);
    expect(_text('Inner'), findsOneWidget);
    expect(_text('Open note'), findsNothing);
    await tester.tap(_text('Inner'));
    await tester.pumpAndSettle();
    final label = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          widget.textSpan?.toPlainText() == 'Open note',
    );
    final editable = find.descendant(
      of: label,
      matching: find.byType(EditableText),
    );
    final render = tester.state<EditableTextState>(editable).renderEditable;
    final box = render
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .first;
    await tester.tapAt(render.localToGlobal(box.toRect().center));
    expect(opened, ['inkwiki:Folder%2FNote']);
  });

  testWidgets('escaped, malformed and later quote markers stay literal', (
    tester,
  ) async {
    await _mount(
      tester,
      r'> \[!note]- Escaped marker'
      '\n\n'
      '> [!note]No spacing\n\n'
      '> [!tip]++ Double fold\n\n'
      '> Ordinary quote\n'
      '> [!note]- Later marker\n\n'
      '```md\n> [!note]- In code\n```',
    );
    for (final text in [
      '[!note]- Escaped marker',
      '[!note]No spacing',
      '[!tip]++ Double fold',
      'Ordinary quote',
      '[!note]- Later marker',
      '[!note]- In code',
    ]) {
      expect(find.textContaining(text, findRichText: true), findsOneWidget);
    }
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('heading link unfolds every callout on a narrow screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final unavailable = <String>[];
    final source = [
      '> [!note]- Outer',
      '>',
      '> > [!tip]- Inner',
      '> >',
      for (var i = 0; i < 40; i++) ...['> > Prelude $i', '> >'],
      '> > ## **Nested** heading',
      '> >',
      '> > Target body',
    ].join('\n');
    await _mount(
      tester,
      source,
      targetAnchor: 'Nested heading',
      onAnchorUnavailable: unavailable.add,
    );
    expect(unavailable, isEmpty);
    final heading = _text('Nested heading');
    expect(heading, findsOneWidget);
    final rect = tester.getRect(heading);
    expect(rect.bottom, greaterThan(0));
    expect(rect.top, lessThan(420));
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
