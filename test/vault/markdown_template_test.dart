import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/markdown_template.dart';
import 'package:yaml/yaml.dart';

void main() {
  final now = DateTime.utc(2026, 11, 8, 15, 6, 7, 123);

  ({String text, int caretOffset}) insert(
    String document,
    String template, {
    int? start,
    int? end,
    String title = '한글 제목',
    String dateFormat = 'YYYY-MM-DD',
    String timeFormat = 'HH:mm',
  }) {
    return applyMarkdownTemplate(
      document: document,
      selectionStart: start ?? document.length,
      selectionEnd: end ?? start ?? document.length,
      template: template,
      title: title,
      now: now,
      dateFormat: dateFormat,
      timeFormat: timeFormat,
    );
  }

  test(
    'expands core variables while replacing only the selected UTF-16 text',
    () {
      const body = '앞😀삭제뒤';
      const replacement = r'값 $& {{date}} 2026-11-08 15:06 {{other}}';
      final result = insert(
        body,
        '{{TITLE}} {{Date}} {{time}} {{other}}',
        start: 3,
        end: 5,
        title: r'값 $& {{date}}',
      );
      expect(
        result.text,
        '앞😀$replacement'
        '뒤',
      );
      expect(result.caretOffset, 3 + replacement.length);
    },
  );

  test('supports configured and inline Moment-style formats', () {
    final result = insert(
      '',
      '{{date}} {{time}} {{time:h:mm:ss A}} '
          '{{date:ddd [week] WW}} {{time:SSS [UTC] Z}}',
      dateFormat: 'DD/MM/YY',
      timeFormat: 'HH.mm',
    );
    expect(result.text, '08/11/26 15.06 3:06:07 PM Sun week 45 123 UTC +00:00');
    expect(result.caretOffset, result.text.length);
  });

  test('expands common Moment presets and respects escaped literals', () {
    final result = insert(
      '',
      r'{{date:L | LL | LLL | LLLL | l | ll | lll | llll}} '
          r'{{time:LT | LTS | [LTS] | \L}}',
    );
    expect(
      result.text,
      '11/08/2026 | November 8, 2026 | November 8, 2026 3:06 PM | '
      'Sunday, November 8, 2026 3:06 PM | '
      '11/8/2026 | Nov 8, 2026 | Nov 8, 2026 3:06 PM | '
      'Sun, Nov 8, 2026 3:06 PM '
      '3:06 PM | 3:06:07 PM | LTS | L',
    );
  });

  test('merges properties and leaves unrelated header bytes untouched', () {
    const document =
        '---\r\n'
        '# existing metadata\r\n'
        'keep: "literal" # leave this comment\r\n'
        'tags:\r\n'
        '  - reading\r\n'
        '# keep before settings\r\n'
        'settings: {level: 1, old: true}\r\n'
        'status: active\r\n'
        'retained: keep\r\n'
        '---\r\n'
        'one REPLACE two';
    const template =
        '---\n'
        'tags: [reading, class]\n'
        'settings: {level: 2, new: true}\n'
        'status: ready\n'
        'retained: null\n'
        'day: "{{date}}"\n'
        '---\n'
        '## {{title}}';
    final start = document.indexOf('REPLACE');
    final result = insert(document, template, start: start, end: start + 7);
    final closing = result.text.indexOf('\r\n---\r\n', 5);
    final properties = loadYaml(result.text.substring(5, closing)) as YamlMap;
    expect(properties['keep'], 'literal');
    expect(properties['tags'], ['reading', 'class']);
    expect(properties['settings'], {'level': 2, 'old': true, 'new': true});
    expect(properties['status'], 'ready');
    expect(properties['retained'], 'keep');
    expect(properties['day'], '2026-11-08');
    expect(
      result.text,
      contains(
        '# existing metadata\r\nkeep: "literal" # leave this comment\r\n',
      ),
    );
    expect(result.text, contains('# keep before settings\r\n'));
    expect(result.text, endsWith('one ## 한글 제목 two'));
    expect(result.text.substring(result.caretOffset), ' two');
  });

  test(
    'puts template properties at the top when inserting into plain text',
    () {
      const template = '---\n# from the template\nkind: study\n---\nheading';
      final atStart = insert('body', template, start: 0);
      expect(atStart.text, '${template}body');
      expect(atStart.caretOffset, template.length);

      final midBody = insert('before after', template, start: 7);
      expect(
        midBody.text,
        '---\n# from the template\nkind: study\n---\nbefore headingafter',
      );
      expect(midBody.text.substring(midBody.caretOffset), 'after');
    },
  );

  test('inserts in the body when the cursor is before existing properties', () {
    const document = '---\nkind: study\n---\nbody';
    final result = insert(document, 'heading\n', start: 0);
    expect(result.text, '---\nkind: study\n---\nheading\nbody');
    expect(result.text.substring(result.caretOffset), 'body');
  });

  test('keeps an end-of-file YAML delimiter on its own line', () {
    const header = '---\nkind: study\n---';
    expect(insert('', header).text, header);
    expect(insert('body', header, start: 0).text, '$header\nbody');
    final result = insert(header, 'body');
    expect(result.text, '$header\nbody');
    expect(result.caretOffset, result.text.length);
  });

  test('fills empty YAML properties without removing comments', () {
    const document = '---\nkind: # keep\ncategory:\n---\nbody';
    const template = '---\nkind: study\ncategory: class\n---\n';
    final result = insert(document, template);
    expect(
      result.text,
      '---\nkind: "study" # keep\ncategory: "class"\n---\nbody',
    );
  });

  test(
    'refuses invalid selections and ambiguous frontmatter without editing',
    () {
      const document = '---\nkind: study\n---\nbody';
      expect(() => insert(document, 'body', start: 4), throwsFormatException);
      expect(() => insert('😀', 'body', start: 1), throwsFormatException);
      expect(
        () => insert('', '---\nkind: [\n---\nbody'),
        throwsFormatException,
      );
      expect(
        () => insert(document, '---\nkind: one\nkind: two\n---\nbody'),
        throwsFormatException,
      );
    },
  );

  test(
    'cannot silently rewrite an anchored value also used by another key',
    () {
      const document = '---\nbase: &base one\nalias: *base\n---\nbody';
      const template = '---\nbase: two\n---\nbody';
      expect(() => insert(document, template), throwsFormatException);
    },
  );
}
