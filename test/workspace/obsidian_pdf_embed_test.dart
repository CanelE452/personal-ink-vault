import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgyL8NAAG9AUuTi58rAAAAAElFTkSuQmCC',
);

Widget _preview({
  required String source,
  required Future<Uint8List?> Function(
    String,
    String,
    int,
    ValueListenable<bool>,
  )
  loadPdf,
  void Function(String, String)? openLink,
  Future<VaultMarkdownEmbed?> Function(String, String)? loadNote,
  Object? scope,
}) => MaterialApp(
  home: Scaffold(
    body: MarkdownPreview(
      source: source,
      onOpenLink: (_) {},
      vaultImageScope: scope,
      vaultEmbeds: VaultMarkdownEmbedAccess(
        sourceNoteId: 'host',
        load: loadNote ?? (_, _) async => null,
        openLink: openLink ?? (_, _) {},
        loadImage: (_, _) async => null,
        loadPdf: loadPdf,
      ),
    ),
  ),
);

Finder _previewImage(String label) => find.byWidgetPredicate(
  (widget) => widget is Image && widget.semanticLabel == label,
);

void main() {
  testWidgets('PDF embeds render requested page and open the same ink page', (
    tester,
  ) async {
    final loads = <(String, String, int)>[];
    final opens = <(String, String)>[];
    await tester.pumpWidget(
      _preview(
        source: '![[./Handout.pdf#height=320&page=2|Source page]]',
        loadPdf: (href, origin, page, _) async {
          loads.add((href, origin, page));
          return _pixel;
        },
        openLink: (href, origin) => opens.add((href, origin)),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, [
      ('inkwiki:.%2FHandout.pdf#height%3D320%26page%3D2', 'host', 2),
    ]);
    final image = tester.widget<Image>(_previewImage('Source page'));
    expect(image.height, 320);
    await tester.tap(find.widgetWithText(TextButton, 'PDF 필기 열기 · 2쪽'));
    expect(opens, [('inkwiki:.%2FHandout.pdf#page%3D2', 'host')]);
  });

  testWidgets(
    'PDF inside a note embed loads and opens relative to its source',
    (tester) async {
      final loads = <(String, String, int)>[];
      final opens = <(String, String)>[];
      await tester.pumpWidget(
        _preview(
          source: '![[Inner]]',
          loadNote: (_, _) async => const VaultMarkdownEmbed(
            noteId: 'inside',
            title: 'Inner',
            source: '![[Handout.pdf|Nested page]]',
          ),
          loadPdf: (href, origin, page, _) async {
            loads.add((href, origin, page));
            return _pixel;
          },
          openLink: (href, origin) => opens.add((href, origin)),
        ),
      );
      await tester.pumpAndSettle();

      expect(loads, [('inkwiki:Handout.pdf', 'inside', 1)]);
      expect(_previewImage('Nested page'), findsOneWidget);
      final open = find.widgetWithText(TextButton, 'PDF 필기 열기 · 1쪽');
      await tester.ensureVisible(open);
      await tester.tap(open);
      expect(opens, [('inkwiki:Handout.pdf#page%3D1', 'inside')]);
    },
  );

  testWidgets(
    'PDF previews reject malformed or nonlocal targets and cap reads',
    (tester) async {
      final loads = <String>[];
      final source = [
        '[[Plain.pdf#page=2]]',
        '![[Repeat.pdf#page=2&page=3]]',
        '![[Zero.pdf#page=0]]',
        '![[Invalid.pdf#height=wide]]',
        '![[https://example.test/Remote.pdf#page=1]]',
        for (var i = 0; i < 8; i++) '![[Page$i.pdf#page=2]]',
      ].join('\n\n');
      await tester.pumpWidget(
        _preview(
          source: source,
          loadPdf: (href, _, _, _) async {
            loads.add(Uri.parse(href).path);
            return null;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(loads, [for (var i = 0; i < 6; i++) 'Page$i.pdf']);
    },
  );

  testWidgets('a stale PDF read cannot repaint a replacement vault scope', (
    tester,
  ) async {
    final old = Completer<Uint8List?>();
    ValueListenable<bool>? cancelled;
    await tester.pumpWidget(
      _preview(
        source: '![[Handout.pdf|PDF page]]',
        scope: 1,
        loadPdf: (_, _, _, signal) {
          cancelled = signal;
          return old.future;
        },
      ),
    );
    await tester.pump();
    expect(cancelled?.value, isFalse);
    await tester.pumpWidget(
      _preview(
        source: '![[Handout.pdf|PDF page]]',
        scope: 2,
        loadPdf: (_, _, _, _) async => null,
      ),
    );
    await tester.pumpAndSettle();
    expect(cancelled?.value, isTrue);
    old.complete(_pixel);
    await tester.pumpAndSettle();
    expect(_previewImage('PDF page'), findsNothing);
    expect(find.text('PDF 페이지를 미리 볼 수 없습니다.'), findsOneWidget);
  });
}
