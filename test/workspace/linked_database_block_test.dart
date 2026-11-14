import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';

void main() {
  testWidgets(
    'a linked database without source access is explicitly unavailable',
    (tester) async {
      final document = BlockPageDocument.fromJson({
        'version': 1,
        'blocks': [
          {
            'id': '00000000-0000-4000-8000-000000000101',
            'type': 'linkedDatabase',
            'text': '연구 자료',
            'linkedDatabaseData': {
              'format': 'personal-ink-linked-database-1',
              'noteId': '00000000-0000-4000-8000-000000000102',
              'view': DatabaseView.create().toJson(),
            },
          },
        ],
      });
      var saved = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockPageEditor(
              initialDocument: document,
              onSave: (_) async => saved++,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('연결된 데이터베이스를 열 수 없습니다'), findsOneWidget);
      expect(saved, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
