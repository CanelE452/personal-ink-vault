import 'package:flutter_test/flutter_test.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

void main() {
  test(
    'preserves exact heading indexes with repeated titles and block IDs',
    () {
      const source =
          '# 첫 단원 ^chapter\n\n'
          '본문 ^note\n\n'
          '### 반복\n\n'
          '### 반복\n\n'
          '## 다른 단락\n\n'
          '# 마지막';

      final headings = MarkdownOutlineHeading.parse(source);

      expect(headings.map((heading) => heading.title), [
        '첫 단원',
        '반복',
        '반복',
        '다른 단락',
        '마지막',
      ]);
      expect(headings.map((heading) => heading.candidateIndex), [
        0,
        3,
        4,
        5,
        6,
      ]);
      expect(headings.map((heading) => heading.level), [1, 3, 3, 2, 1]);
      expect(headings.map((heading) => heading.depth), [0, 1, 1, 1, 0]);
      expect(headings[1].offset, source.indexOf('### 반복'));
      expect(headings[2].offset, source.lastIndexOf('### 반복'));
    },
  );

  test('uses the rendered Setext heading and its first source line', () {
    const source =
        '도입\n\n'
        '**제목**과 [자료](file.md)\n'
        '다음 줄\n'
        '===\n\n'
        '  ## [[note|별칭]]과 `코드` ##\n';

    final headings = MarkdownOutlineHeading.parse(source);

    expect(headings.map((heading) => heading.title), ['제목과 자료 다음 줄', '별칭과 코드']);
    expect(headings.map((heading) => heading.offset), [
      source.indexOf('**제목**'),
      source.indexOf('  ##'),
    ]);
    expect(headings.map((heading) => heading.line), [3, 7]);
    expect(headings.map((heading) => heading.depth), [0, 1]);
  });

  test('keeps UTF-16 line offsets across CRLF, CR and LF', () {
    const source =
        '본문 🧪\r\n\r'
        '# 제목 🧬\r'
        '\n# 둘째\n'
        '마지막\r\n'
        '---';

    final headings = MarkdownOutlineHeading.parse(source);

    expect(headings.map((heading) => heading.offset), [
      source.indexOf('# 제목'),
      source.indexOf('# 둘째'),
      source.indexOf('마지막'),
    ]);
    expect(headings.map((heading) => heading.line), [3, 4, 5]);
    expect(headings.map((heading) => heading.level), [1, 1, 2]);
  });

  test('excludes frontmatter, fenced code and nested block headings', () {
    const source =
        '---\n'
        '# 속성 안의 제목\n'
        'tag: note\n'
        '---\n\n'
        '# 실제 제목\n\n'
        '```markdown\n'
        '## 코드 안의 제목\n'
        '```\n\n'
        '> ## 인용 안의 제목\n\n'
        '- ## 목록 안의 제목\n\n'
        '```dataview\n'
        '## 쿼리 안의 제목\n'
        '```\n\n'
        '## 마지막';

    final headings = MarkdownOutlineHeading.parse(source);

    expect(headings.map((heading) => heading.title), ['실제 제목', '마지막']);
    expect(headings.map((heading) => heading.depth), [0, 1]);
    expect(headings.last.offset, source.indexOf('## 마지막'));
  });

  test('retains GFM table precedence over heading-shaped table cells', () {
    const source =
        '# 첫 열 | 둘째 열\n'
        '--- | ---\n'
        'A | B\n\n'
        '# 제목';

    final headings = MarkdownOutlineHeading.parse(source);

    expect(headings.map((heading) => heading.title), ['제목']);
    expect(headings.single.line, 5);
  });
}
