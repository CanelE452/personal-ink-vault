import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

int? _anchor(String value, List<Map<String, Object?>> candidates) {
  final position = candidates.indexWhere(
    (candidate) => value.startsWith('^')
        ? candidate['id'] == value.substring(1)
        : candidate['text'] == value,
  );
  return position < 0 ? null : position;
}

Widget _preview({
  required String source,
  required Future<VaultMarkdownEmbed?> Function(String, String) load,
  void Function(String, String)? onOpen,
  Object? scope,
  String? targetAnchor,
}) => MaterialApp(
  home: Scaffold(
    body: MarkdownPreview(
      source: source,
      onOpenLink: (_) {},
      anchorResolver: _anchor,
      targetAnchor: targetAnchor,
      vaultImageScope: scope,
      vaultEmbeds: VaultMarkdownEmbedAccess(
        sourceNoteId: 'host',
        load: load,
        openLink: onOpen ?? (_, _) {},
        loadImage: (_, _) async => null,
      ),
    ),
  ),
);

Finder _shown(String text) => find.text(text, findRichText: true);

void main() {
  testWidgets(
    'Obsidian note, heading and list block embeds render scoped content',
    (tester) async {
      final requests = <(String, String)>[];
      final opened = <(String, String)>[];
      const note =
          '---\ncategory: hidden-meta\n---\n# First heading\n\n'
          'hidden first\n\n## Wanted\n\n**keep this**\n\n### Child\n\n'
          'nested text\n\n## Next\n\nexclude from section\n\n'
          '- first item\n- selected list item ^pick\n- third item';
      await tester.pumpWidget(
        _preview(
          source: '![[Notes/Target#Wanted]]\n\n![[Notes/Target#^pick]]\n\n![[Whole]]',
          load: (href, from) async {
            requests.add((href, from));
            final uri = Uri.parse(href);
            if (uri.path == 'Whole')
              return const VaultMarkdownEmbed(
                noteId: 'whole',
                title: 'Whole',
                source: '## Whole title\n\nwhole body',
              );
            return VaultMarkdownEmbed(
              noteId: 'target',
              title: 'Target',
              source: note,
              anchor: Uri.decodeComponent(uri.fragment),
            );
          },
          onOpen: (href, origin) => opened.add((href, origin)),
        ),
      );
      await tester.pumpAndSettle();
      for (final text in [
        'Wanted',
        'keep this',
        'Child',
        'nested text',
        'selected list item',
        'whole body',
      ]) {
        expect(_shown(text), findsOneWidget, reason: text);
      }
      for (final text in [
        'hidden first',
        'Next',
        'exclude from section',
        'first item',
        'third item',
        'hidden-meta',
      ]) {
        expect(_shown(text), findsNothing, reason: text);
      }
      expect(requests.map((item) => item.$2).toSet(), {'host'});
      await tester.tap(_shown('원본 열기 · Notes/Target#Wanted'));
      expect(opened, [('inkwiki:Notes%2FTarget#Wanted', 'host')]);
    },
  );

  testWidgets('embedded heading keeps its original ordered list number', (
    tester,
  ) async {
    await tester.pumpWidget(
      _preview(
        source: '![[Target#Wanted]]',
        load: (_, _) async => const VaultMarkdownEmbed(
          noteId: 'target',
          title: 'Target',
          source: '5. first item\n6. ## Wanted\n\n   selected body',
          anchor: 'Wanted',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_shown('Wanted'), findsOneWidget);
    expect(_shown('selected body'), findsOneWidget);
    expect(_shown('first item'), findsNothing);
    expect(_shown('5.'), findsNothing);
    expect(_shown('6.'), findsOneWidget);
  });

  testWidgets(
    'nested embeds resolve in the embedded note and cycles do not grow',
    (tester) async {
      final requests = <(String, String)>[];
      await tester.pumpWidget(
        _preview(
          source: '![[Outer]]\n\n```md\n![[Ignored]]\n```',
          load: (href, origin) async {
            requests.add((href, origin));
            return switch (href) {
              'inkwiki:Outer' => const VaultMarkdownEmbed(
                noteId: 'outer',
                title: 'Outer',
                source: 'outer content\n\n![[Inner]]',
              ),
              'inkwiki:Inner' => const VaultMarkdownEmbed(
                noteId: 'inner',
                title: 'Inner',
                source: 'inner content\n\n![[Root]]',
              ),
              'inkwiki:Root' => const VaultMarkdownEmbed(
                noteId: 'host',
                title: 'Root',
                source: '![[Outer]]',
              ),
              _ => null,
            };
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(_shown('outer content'), findsOneWidget);
      expect(_shown('inner content'), findsOneWidget);
      expect(_shown('순환 포함을 건너뛰었습니다.'), findsOneWidget);
      expect(requests, [
        ('inkwiki:Outer', 'host'),
        ('inkwiki:Inner', 'outer'),
        ('inkwiki:Root', 'inner'),
      ]);
    },
  );

  testWidgets(
    'embed reloads on vault scope change without showing stale content',
    (tester) async {
      final old = Completer<VaultMarkdownEmbed?>();
      await tester.pumpWidget(
        _preview(source: '![[Note]]', scope: 1, load: (_, _) => old.future),
      );
      await tester.pump();
      await tester.pumpWidget(
        _preview(
          source: '![[Note]]',
          scope: 2,
          load: (_, _) async => const VaultMarkdownEmbed(
            noteId: 'new',
            title: 'Note',
            source: 'current source',
          ),
        ),
      );
      await tester.pumpAndSettle();
      old.complete(
        const VaultMarkdownEmbed(
          noteId: 'old',
          title: 'Note',
          source: 'stale source',
        ),
      );
      await tester.pumpAndSettle();
      expect(_shown('current source'), findsOneWidget);
      expect(_shown('stale source'), findsNothing);
    },
  );
  testWidgets('embed size budget follows document order with delayed reads', (
    tester,
  ) async {
    final pending = {
      for (final name in ['A', 'B', 'C'])
        name: Completer<VaultMarkdownEmbed?>(),
    };
    await tester.pumpWidget(
      _preview(
        source: '![[A]]\n\n![[B]]\n\n![[C]]',
        load: (href, _) => pending[Uri.parse(href).path]!.future,
      ),
    );
    for (final name in ['C', 'B', 'A']) {
      pending[name]!.complete(
        VaultMarkdownEmbed(
          noteId: name,
          title: name,
          source: '---\n${'x' * (400 * 1024)}\n---\n\nbody $name',
        ),
      );
      await tester.pumpAndSettle();
    }
    expect(_shown('body A'), findsOneWidget);
    expect(_shown('body B'), findsOneWidget);
    expect(_shown('body C'), findsNothing);
    expect(_shown('포함할 수 있는 본문 크기를 넘었습니다.'), findsOneWidget);
  });

  testWidgets('anchor below a delayed embed remains within the viewport', (
    tester,
  ) async {
    final pending = Completer<VaultMarkdownEmbed?>();
    await tester.pumpWidget(
      _preview(
        source: '![[Long]]\n\n## Destination\n\n${'After\n\n' * 40}',
        targetAnchor: 'Destination',
        load: (_, _) => pending.future,
      ),
    );
    await tester.pumpAndSettle();
    pending.complete(
      VaultMarkdownEmbed(
        noteId: 'long',
        title: 'Long',
        source: 'Included paragraph\n\n' * 80,
      ),
    );
    await tester.pumpAndSettle();
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    expect(viewport.contains(tester.getCenter(_shown('Destination'))), isTrue);
  });

  testWidgets('large and excessive embeds use bounded fallback links', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      _preview(
        source: List.generate(27, (index) => '![[Item$index]]').join('\n\n'),
        load: (href, _) async {
          loads++;
          return VaultMarkdownEmbed(
            noteId: href,
            title: href,
            source: href.endsWith('Item0')
                ? 'x' * (512 * 1024 + 1)
                : 'body $href',
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(loads, 24);
    expect(_shown('포함할 수 있는 본문 크기를 넘었습니다.'), findsOneWidget);
    expect(_shown('포함할 수 있는 노트 수를 넘었습니다.'), findsNWidgets(3));
  });
}
