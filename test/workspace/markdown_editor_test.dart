import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

void main() {
  testWidgets(
    'preview renders math and blocks remote images and unsafe links',
    (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              source: r'$x^2$ ![private](https://example.com/tracker.png) [unsafe](javascript:alert) <script>alert(1)</script>',
              onOpenLink: opened.add,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('이미지'), findsOneWidget);
      expect(find.byType(Math), findsOneWidget);
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).onTapLink!(
        'unsafe',
        'javascript:alert',
        '',
      );
      expect(opened, isEmpty);
    },
  );
}
