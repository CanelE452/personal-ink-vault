import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

void main() {
  test('Word exposes actual mixed body order and paragraph editing metadata', () {
    final snapshot = WindowsOfficeSnapshot.fromJson({
      'kind': 'word', 'sourceSha256': 'a' * 64,
      'paragraphs': [
        {
          'id': 'paragraph-0', 'text': 'BEFORE',
          'paragraphFormat': {
            'styleName': 'Heading 1', 'alignment': 'center',
            'listKind': 'number', 'listLevel': 2, 'pageBreakBefore': true,
          },
          'structure': {
            'canSplit': true, 'canDelete': false, 'canInsertBefore': true,
            'canInsertAfter': true, 'canJoinNext': false,
          },
        },
        {'id': 'paragraph-1', 'text': 'AFTER'},
      ],
      'tables': [
        {'id': 'Table1', 'cells': {'A1': 'CELL'}},
      ],
      'slides': [],
      'blocks': [
        {'kind': 'paragraph', 'id': 'paragraph-0'},
        {'kind': 'table', 'id': 'Table1'},
        {'kind': 'opaque', 'id': 'opaque-0'},
        {'kind': 'paragraph', 'id': 'paragraph-1'},
      ],
      'paragraphStyles': [
        {'name': 'Heading 1', 'displayName': '제목 1'},
        {'name': 'Text body', 'displayName': '본문'},
      ],
    });
    final dynamic word = snapshot;
    expect([for (final dynamic block in word.blocks) '${block.kind}:${block.id}'], [
      'paragraph:paragraph-0', 'table:Table1', 'opaque:opaque-0', 'paragraph:paragraph-1',
    ]);
    final dynamic paragraph = snapshot.paragraphs.first;
    expect(paragraph.paragraphFormat.styleName, 'Heading 1');
    expect(paragraph.paragraphFormat.alignment, 'center');
    expect(paragraph.paragraphFormat.listKind, 'number');
    expect(paragraph.paragraphFormat.listLevel, 2);
    expect(paragraph.paragraphFormat.pageBreakBefore, isTrue);
    expect(paragraph.structure.canSplit, isTrue);
    expect(paragraph.structure.canDelete, isFalse);
    expect(paragraph.structure.canInsertBefore, isTrue);
    expect(paragraph.structure.canInsertAfter, isTrue);
    expect(paragraph.structure.canJoinNext, isFalse);
    expect(word.paragraphStyles[0].name, 'Heading 1');
    expect(word.paragraphStyles[0].displayName, '제목 1');
  });

  test('legacy HWP snapshots do not invent body order or structural capabilities', () {
    final snapshot = WindowsOfficeSnapshot.fromJson({
      'kind': 'word', 'sourceSha256': 'a' * 64,
      'paragraphs': [{'id': 's0:p0', 'text': 'legacy'}],
      'tables': [{'id': 's0:p1:t0', 'cells': {'0,0': 'cell'}}],
      'slides': [],
    });
    final dynamic word = snapshot;
    final dynamic paragraph = snapshot.paragraphs.single;
    expect(word.blocks, isNull);
    expect(word.paragraphStyles, isEmpty);
    expect(paragraph.paragraphFormat, isNull);
    expect(paragraph.structure, isNull);
  });

  test('unknown paragraph formatting remains unknown instead of becoming left or unlisted', () {
    final snapshot = WindowsOfficeSnapshot.fromJson({
      'kind': 'word', 'sourceSha256': 'a' * 64,
      'paragraphs': [{
        'id': 'paragraph-0', 'text': 'opaque list',
        'paragraphFormat': {'styleName': 'Custom', 'alignment': 'other',
          'listKind': 'other', 'listLevel': 3, 'pageBreakBefore': null},
        'structure': {'canSplit': false, 'canDelete': false,
          'canInsertBefore': false, 'canInsertAfter': false, 'canJoinNext': false},
      }],
      'tables': [], 'slides': [], 'blocks': [{'kind': 'paragraph', 'id': 'paragraph-0'}],
      'paragraphStyles': [{'name': 'Custom', 'displayName': 'Custom'}],
    });
    final dynamic paragraph = snapshot.paragraphs.single;
    expect(paragraph.paragraphFormat.alignment, 'other');
    expect(paragraph.paragraphFormat.listKind, 'other');
    expect(paragraph.paragraphFormat.pageBreakBefore, isNull);
    expect(paragraph.structure.canSplit, isFalse);
  });
}
