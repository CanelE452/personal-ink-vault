import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:saber/pages/workspace/markdown_editor.dart';

typedef _AnchorResolver = int? Function(
  String anchor,
  List<Map<String, Object?>> candidates,
);

Widget _preview({
  required String source,
  required ValueChanged<String> onOpenLink,
  String? targetAnchor,
  int anchorRequest = 0,
  _AnchorResolver? anchorResolver,
  ValueChanged<String>? onAnchorUnavailable,
}) {
  return MarkdownPreview(
    key: const ValueKey('anchor-preview'),
    source: source,
    onOpenLink: onOpenLink,
    targetAnchor: targetAnchor,
    anchorRequest: anchorRequest,
    anchorResolver: anchorResolver,
    onAnchorUnavailable: onAnchorUnavailable,
  );
}

Widget _editor({
  required String source,
  String? targetAnchor,
  int anchorRequest = 0,
  _AnchorResolver? anchorResolver,
}) {
  return MarkdownEditor(
    key: const ValueKey('anchor-editor'),
    source: source,
    readOnly: false,
    dirty: false,
    onChanged: (_) {},
    onSave: () {},
    onOpenLink: (_) {},
    targetAnchor: targetAnchor,
    anchorRequest: anchorRequest,
    anchorResolver: anchorResolver,
  );
}

Finder _renderedText(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is SelectableText &&
      (widget.data ?? widget.textSpan?.toPlainText()) == text,
);

int? _exactResolver(String anchor, List<Map<String, Object?>> candidates) {
  final index = candidates.indexWhere(
    (candidate) => anchor.startsWith('^')
        ? candidate['kind'] == 'block' && candidate['id'] == anchor.substring(1)
        : candidate['kind'] == 'heading' && candidate['text'] == anchor,
  );
  return index < 0 ? null : index;
}

void main() {
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(720, 440));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }

  void expectVisible(WidgetTester tester, String text) {
    final finder = _renderedText(text);
    expect(finder, findsOneWidget);
    final rect = tester.getRect(finder);
    expect(rect.bottom, greaterThan(0));
    expect(rect.top, lessThan(440));
  }

  testWidgets('Markdown block wrapper preserves default nested rich content', (
    tester,
  ) async {
    Widget wrapper(md.Element node, Widget child) => KeyedSubtree(
      key: ValueKey('wrapped-${node.tag}-${node.textContent}'),
      child: child,
    );
    const source =
        '> ## **Nested** heading\n>\n> paragraph with [reference][r]\n\n'
        '- first\n- **second**\n\n| A | B |\n| - | - |\n| one | two |\n\n'
        '[r]: https://example.invalid/reference';
    final body = MarkdownBody(
      data: source,
      selectable: true,
      blockWrapper: wrapper,
    );
    await mount(tester, SingleChildScrollView(child: body));
    expect(
      find.byKey(const ValueKey('wrapped-h2-Nested heading')),
      findsOneWidget,
    );
    expect(_renderedText('Nested heading'), findsOneWidget);
    expect(_renderedText('second'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    final nested = tester.widget<SelectableText>(
      _renderedText('Nested heading'),
    );
    expect(nested.textSpan!.toPlainText(), 'Nested heading');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Markdown anchor reveals a heading inside a long quote', (
    tester,
  ) async {
    final source = [
      '> # Quote start',
      '> ',
      for (var i = 0; i < 65; i++) ...['> quote paragraph $i', '> '],
      '> ## **Nested** target',
      '> ',
      '> reference [link][reference] and math \$x^2\$',
      '',
      '[reference]: https://example.invalid/reference',
    ].join('\n');
    await mount(
      tester,
      _preview(
        source: source,
        onOpenLink: (_) {},
        targetAnchor: 'Nested target',
        anchorRequest: 1,
        anchorResolver: _exactResolver,
      ),
    );
    expectVisible(tester, 'Nested target');
    expect(find.byType(Math), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Markdown anchor reveals an exact nested list block', (
    tester,
  ) async {
    final source = [
      '- List start',
      '',
      for (var i = 0; i < 65; i++) ...['  list paragraph $i', ''],
      '  **Target** block body ^focus',
    ].join('\n');
    await mount(
      tester,
      _preview(
        source: source,
        onOpenLink: (_) {},
        targetAnchor: '^focus',
        anchorRequest: 1,
        anchorResolver: _exactResolver,
      ),
    );
    expectVisible(tester, 'Target block body');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Markdown candidates preserve AST order and standalone block ownership',
    (tester) async {
      List<Map<String, Object?>>? actual;
      const source =
          '# **Parent**\n\n## Child\n\n'
          '```\n# Fake heading\nFake block ^code\n```\n\n'
          '<div>\n# HTML fake\n^html\n</div>\n\n'
          '`inline ^not-a-block`\n\nBody **real** ^real\n\n^standalone';
      await mount(
        tester,
        _preview(
          source: source,
          onOpenLink: (_) {},
          targetAnchor: '^standalone',
          anchorRequest: 1,
          anchorResolver: (anchor, candidates) {
            actual = candidates;
            return _exactResolver(anchor, candidates);
          },
        ),
      );
      expect(actual, [
        {'kind': 'heading', 'text': 'Parent', 'level': 1},
        {'kind': 'heading', 'text': 'Child', 'level': 2},
        {'kind': 'block', 'id': 'real'},
        {'kind': 'block', 'id': 'standalone'},
      ]);
      expectVisible(tester, 'Body real');
      expect(_renderedText('^standalone'), findsNothing);
    },
  );

  testWidgets(
    'Markdown anchor reports unsupported and missing targets explicitly',
    (tester) async {
      final errors = <String>[];
      await mount(
        tester,
        _preview(
          source: '# Known',
          onOpenLink: (_) {},
          targetAnchor: 'Known',
          anchorRequest: 1,
          onAnchorUnavailable: errors.add,
        ),
      );
      expect(errors, ['Known']);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _preview(
              source: '# Known',
              onOpenLink: (_) {},
              targetAnchor: 'Missing',
              anchorRequest: 2,
              anchorResolver: _exactResolver,
              onAnchorUnavailable: errors.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(errors, ['Known', 'Missing']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Markdown repeated anchor request repositions without a source change',
    (tester) async {
      final source = [
        for (var i = 0; i < 65; i++) 'paragraph $i\n',
        '# Destination',
      ].join('\n');
      Widget preview(int request) => _preview(
        source: source,
        onOpenLink: (_) {},
        targetAnchor: 'Destination',
        anchorRequest: request,
        anchorResolver: _exactResolver,
      );
      await mount(tester, preview(1));
      expectVisible(tester, 'Destination');
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scroll.position.jumpTo(0);
      await tester.pump();
      expect(
        tester.getTopLeft(_renderedText('Destination')).dy,
        greaterThan(440),
      );
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: preview(2))));
      await tester.pumpAndSettle();
      expectVisible(tester, 'Destination');
    },
  );

  testWidgets(
    'Markdown editor anchor request leaves source mode for the target preview',
    (tester) async {
      final source = [
        for (var i = 0; i < 45; i++) 'paragraph $i\n',
        '# Destination',
      ].join('\n');
      await mount(tester, _editor(source: source));
      await tester.tap(find.byTooltip('원문 편집'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _editor(
              source: source,
              targetAnchor: 'Destination',
              anchorRequest: 1,
              anchorResolver: _exactResolver,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expectVisible(tester, 'Destination');
    },
  );

  testWidgets(
    'Markdown local links forward while unsafe URI and image guards remain',
    (tester) async {
      final opened = <String>[];
      const source =
          '[relative](../Notes/Target.md#Heading)\n\n'
          '[root](/Notes/Target.md#Heading)\n\n'
          '[same](#Heading)\n\n[web](https://example.invalid/)\n\n'
          '[file](file:///private.txt)\n\n[remote](//example.invalid/path)\n\n'
          '![image](https://example.invalid/image.png)';
      await mount(tester, _preview(source: source, onOpenLink: opened.add));
      for (final label in [
        'relative',
        'root',
        'same',
        'web',
        'file',
        'remote',
      ]) {
        await tester.tap(find.text(label, findRichText: true).last);
        await tester.pump();
      }
      expect(opened, [
        '../Notes/Target.md#Heading',
        '/Notes/Target.md#Heading',
        '#Heading',
        'https://example.invalid/',
      ]);
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('이미지 비활성화'), findsOneWidget);
    },
  );

  testWidgets('Markdown disposed target requests do not call a stale host', (
    tester,
  ) async {
    final errors = <String>[];
    final source = [
      for (var i = 0; i < 65; i++) 'paragraph $i\n',
      '# Destination',
    ].join('\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _preview(
            source: source,
            onOpenLink: (_) {},
            targetAnchor: 'Destination',
            anchorRequest: 1,
            anchorResolver: _exactResolver,
            onAnchorUnavailable: errors.add,
          ),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(errors, isEmpty);
  });

  testWidgets('closed initial frontmatter contributes no anchors', (
    tester,
  ) async {
    List<Map<String, Object?>>? actual;
    const source =
        '\uFEFF---\n# Fake YAML heading\nvalue: ^fake\n...\n\n'
        '^unattached\n\n# Real body\n\nParagraph ^real';
    await mount(
      tester,
      _preview(
        source: source,
        onOpenLink: (_) {},
        targetAnchor: '^real',
        anchorRequest: 1,
        anchorResolver: (anchor, candidates) {
          actual = candidates;
          return _exactResolver(anchor, candidates);
        },
      ),
    );
    expect(actual, [
      {'kind': 'heading', 'text': 'Real body', 'level': 1},
      {'kind': 'block', 'id': 'real'},
    ]);
    expect(find.text('^unattached'), findsOneWidget);
    expect(
      find.textContaining('# Fake YAML heading', findRichText: true),
      findsWidgets,
    );
    expectVisible(tester, 'Paragraph');
  });

  testWidgets('wiki targets encode literal percent and hashes exactly once', (
    tester,
  ) async {
    final opened = <String>[];
    await mount(
      tester,
      _preview(
        source: '[[100%20 note#Heading%20#Child|literal]]',
        onOpenLink: opened.add,
      ),
    );
    await tester.tap(find.text('literal', findRichText: true).last);
    expect(opened, ['inkwiki:100%2520%20note#Heading%2520%23Child']);
    final uri = Uri.parse(opened.single);
    expect(Uri.decodeComponent(uri.path), '100%20 note');
    expect(Uri.decodeComponent(uri.fragment), 'Heading%20#Child');
  });
}
