import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/notion_export_csv.dart';

Uint8List _csv(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('reads a UTF-8 BOM and preserves Unicode, quotes and line endings', () {
    final table = parseNotionCsv(
      _csv(
        '\uFEFF이름,"메모, 원문",값\r\n'
        '첫 번째 😀," 첫 줄, 값\r\n두 번째 ""인용""\n세 번째\r끝 ",001\r\n'
        '둘째,e\u0301,=SUM(A1:A2)\n',
      ),
    );

    expect(table.headers, ['이름', '메모, 원문', '값']);
    expect(table.rows, [
      ['첫 번째 😀', ' 첫 줄, 값\r\n두 번째 "인용"\n세 번째\r끝 ', '001'],
      ['둘째', 'e\u0301', '=SUM(A1:A2)'],
    ]);
  });

  test(
    'preserves empty and duplicate headers and leading or trailing cells',
    () {
      final table = parseNotionCsv(_csv(',값,값,\n,"",  ,\n끝,,,"마지막"'));

      expect(table.headers, ['', '값', '값', '']);
      expect(table.rows, [
        ['', '', '  ', ''],
        ['끝', '', '', '마지막'],
      ]);
    },
  );

  test('accepts a header alone and keeps real empty single-column records', () {
    expect(parseNotionCsv(_csv('제목')).rows, isEmpty);
    expect(parseNotionCsv(_csv('제목\r\n')).rows, isEmpty);
    expect(parseNotionCsv(_csv('제목\n\n""\n')).rows, [
      [''],
      [''],
    ]);
    expect(parseNotionCsv(_csv('제목\n\uFEFF본문')).rows, [
      ['\uFEFF본문'],
    ]);
  });

  test('returns an immutable table and immutable individual rows', () {
    final table = parseNotionCsv(_csv('이름,값\n노트,내용'));

    expect(() => table.headers.add('다른 제목'), throwsUnsupportedError);
    expect(() => table.rows.clear(), throwsUnsupportedError);
    expect(() => table.rows.single[1] = '수정', throwsUnsupportedError);
  });

  test('rejects invalid UTF-8, a missing header and NUL', () {
    for (final bytes in <Uint8List>[
      Uint8List(0),
      _csv('\uFEFF'),
      Uint8List.fromList([0xef, 0xbb]),
      Uint8List.fromList([0x4e, 0x0a, 0xc0, 0xaf]),
      Uint8List.fromList([0x4e, 0x0a, 0xed, 0xa0, 0x80]),
      _csv('이름\n"내용\u0000"'),
    ]) {
      expect(() => parseNotionCsv(bytes), throwsFormatException);
    }
  });

  test('rejects bad quote syntax, bare CR and ragged records', () {
    for (final source in [
      '이름,값\n노트,"닫히지 않음',
      '이름,값\n노트,인"용',
      '이름,값\n노트,"인용" ',
      '이름,값\n노트,"인용"뒤',
      '이름,값\r노트,내용',
      '이름,값\n노트,내용\r',
      '이름,값\n노트',
      '이름,값\n노트,내용,추가',
      '이름,값\n\n',
    ]) {
      expect(
        () => parseNotionCsv(_csv(source)),
        throwsFormatException,
        reason: source,
      );
    }
  });

  test('enforces file, row, column and decoded cell size limits', () {
    final maxHeader = List.filled(128, '열').join(',');
    expect(parseNotionCsv(_csv(maxHeader)).headers, hasLength(128));
    expect(parseNotionCsv(_csv('이름\n${'값\n' * 2000}')).rows, hasLength(2000));
    final maxQuoted = '""' * (64 * 1024);
    expect(
      parseNotionCsv(_csv('제목\n"$maxQuoted"')).rows.single.single,
      hasLength(64 * 1024),
    );

    for (final bytes in [
      Uint8List(8 * 1024 * 1024 + 1),
      _csv('$maxHeader,추가'),
      _csv('이름\n${'값\n' * 2001}'),
      _csv('제목\n${'x' * (64 * 1024 + 1)}'),
      _csv('제목\n"$maxQuoted"""'),
    ]) {
      expect(() => parseNotionCsv(bytes), throwsFormatException);
    }
  });
}
