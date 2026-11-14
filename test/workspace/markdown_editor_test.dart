import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

void main() {
  testWidgets('preview routes extensionless vault paths only', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(
            source:
                '[note](Note)\n\n'
                '[relative](../Topics.v2/Other#Heading)\n\n'
                '[explicit](Note.md)\n\n'
                '[attachment](document.pdf)\n\n'
                '[encoded scheme](javascript%3Aalert)\n\n'
                '[encoded authority](%2F%2Fhost/Note)',
            onOpenLink: opened.add,
          ),
        ),
      ),
    );
    for (final label in [
      'note',
      'relative',
      'explicit',
      'attachment',
      'encoded scheme',
      'encoded authority',
    ]) {
      final text = find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data ?? widget.textSpan?.toPlainText()) == label,
      );
      final editable = find.descendant(
        of: text,
        matching: find.byType(EditableText),
      );
      final render = tester.state<EditableTextState>(editable).renderEditable;
      final box = render
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: 1),
          )
          .first;
      await tester.tapAt(render.localToGlobal(box.toRect().center));
      await tester.pump();
    }
    expect(opened, ['Note', '../Topics.v2/Other#Heading', 'Note.md']);
  });

  testWidgets(
    'preview renders math and blocks remote images and unsafe links',
    (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              source:
                  r'$x^2$ ![private](https://example.com/tracker.png)'
                  '\n\n[unsafe](javascript:alert)\n\n<script>alert(1)</script>',
              onOpenLink: opened.add,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('이미지'), findsOneWidget);
      expect(find.byType(Math), findsOneWidget);
      await tester.tap(find.text('unsafe', findRichText: true).last);
      await tester.pump();
      expect(opened, isEmpty);
    },
  );

  testWidgets('vault raster scope ignores old loads and rejects other images', (
    tester,
  ) async {
    const source =
        '![Local](Media/Pixel.png)\n\n'
        '![Web](https://example.invalid/tracker.png)\n\n'
        '![File](file:///Users/sample.png)\n\n'
        '![Encoded authority](%2F%2Fexample.invalid/tracker.png)\n\n'
        '![[Slides/Brief.pptx|Open slides]]';
    final opened = <String>[];
    final loaded = <String>[];
    final before = Completer<Uint8List?>();
    final after = Completer<Uint8List?>();
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQKNj3H4QZYAwATRAJNQkgY7wAAAAASUVORK5CYII=',
    );

    Widget view(int scope, Completer<Uint8List?> pending) => MaterialApp(
      home: Scaffold(
        body: MarkdownPreview(
          source: source,
          onOpenLink: opened.add,
          loadVaultImage: (href) {
            loaded.add(href);
            return pending.future;
          },
          vaultImageScope: scope,
        ),
      ),
    );

    await tester.pumpWidget(view(1, before));
    expect(loaded, ['Media/Pixel.png']);
    await tester.pumpWidget(view(2, after));
    before.complete(png);
    await tester.pumpAndSettle();
    expect(loaded, ['Media/Pixel.png', 'Media/Pixel.png']);
    expect(find.byType(Image), findsNothing);
    after.complete(png);
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);

    final slide = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          (widget.data ?? widget.textSpan?.toPlainText()) == 'Open slides',
    );
    final editable = find.descendant(
      of: slide,
      matching: find.byType(EditableText),
    );
    final renderer = tester.state<EditableTextState>(editable).renderEditable;
    final box = renderer
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .first;
    await tester.tapAt(renderer.localToGlobal(box.toRect().center));
    expect(opened, ['inkwiki:Slides%2FBrief.pptx']);
  });

  testWidgets('Obsidian image dimensions preserve labels and vault paths', (
    tester,
  ) async {
    final loaded = <String>[];
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQKNj3H4QZYAwATRAJNQkgY7wAAAAASUVORK5CYII=',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(
            source:
                '![[Media/Pixel.png|120]]\n\n'
                '![[Media/Pixel.png|A|B|160 x 80]]\n\n'
                '![Local|100x40](Media/Pixel.png)\n\n'
                '![[Media/Pixel.png|Bad size|120x]]\n\n'
                '![[Media/Pixel.png|0x32]]\n\n'
                '![120](Media/Pixel.png)\n\n'
                '![Web|120](https://example.invalid/tracker.png)',
            onOpenLink: (_) {},
            loadVaultImage: (href) async {
              loaded.add(href);
              return png;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(
      images.map((image) => (image.semanticLabel, image.width, image.height)),
      [
        ('Pixel.png', 120.0, null),
        ('A|B', 160.0, 80.0),
        ('Local', 100.0, 40.0),
        ('Bad size|120x', null, null),
        ('Pixel.png', null, 32.0),
        ('120', null, null),
      ],
    );
    expect(loaded, ['inkwiki:Media%2FPixel.png', 'Media/Pixel.png']);
  });
}
