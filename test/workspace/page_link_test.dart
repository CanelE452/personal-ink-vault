import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/note_link.dart';

void main() {
  const id = '12345678-1234-4234-8234-123456789abc';
  const edition = '12345678-1234-4234-8234-123456789abd';
  const binding = '12345678-1234-4234-8234-123456789abe';
  const page = '12345678-1234-4234-8234-123456789abf';
  const officeUrl =
      'inkvault://note/$id?edition=$edition&pdf=$binding&page=$page';

  test('Office link keeps the page scoped to one original and PDF binding', () {
    const OfficePageTarget target = (
      sourceRevisionId: edition,
      pdfBindingId: binding,
      pageId: page,
    );
    final link = NoteLink.parse(officeUrl);
    expect(link?.noteId, id);
    expect(link?.officePageTarget, target);
    expect(link?.pageId, isNull);
    expect(link?.isMarkdown, isFalse);
    expect(link?.markdownAnchor, isNull);
    expect(link.toString(), officeUrl);
    expect(const NoteLink.officePage(id, target).toString(), officeUrl);
    expect(
      NoteLink.parse(
        'inkvault://note/$id?page=$page&pdf=$binding&edition=$edition',
      ).toString(),
      officeUrl,
    );
  });

  test(
    'Office link requires exactly one valid value for each of its fields',
    () {
      for (final value in [
        'inkvault://note/$id?edition=$edition&page=$page',
        'inkvault://note/$id?pdf=$binding&page=$page',
        'inkvault://note/$id?edition=$edition&pdf=$binding',
        'inkvault://note/$id?edition=bad&pdf=$binding&page=$page',
        'inkvault://note/$id?edition=$edition&pdf=&page=$page',
        'inkvault://note/$id?edition=$edition&pdf=$binding&page=bad',
        'inkvault://note/no?edition=$edition&pdf=$binding&page=$page',
        '$officeUrl&edition=$edition',
        '$officeUrl&pdf=$binding',
        '$officeUrl&%70age=$page',
        '$officeUrl&view=markdown',
        '$officeUrl&unknown=$id',
        '$officeUrl#',
        '$officeUrl#Heading',
      ]) {
        expect(NoteLink.parse(value), isNull, reason: value);
      }
    },
  );

  test('stable link accepts a note and optional page UUID', () {
    final link = NoteLink.parse('inkvault://note/$id?page=$id');
    expect(link?.noteId, id);
    expect(link?.pageId, id);
    expect(link?.officePageTarget, isNull);
    expect(link.toString(), 'inkvault://note/$id?page=$id');
    expect(
      NoteLink.parse('inkvault://note/$id')?.toString(),
      'inkvault://note/$id',
    );
  });
  test('unsafe and malformed links are rejected', () {
    for (final value in [
      'javascript:alert(1)',
      'file:///private',
      'inkvault://note/no',
      'inkvault://note/$id?page=no',
      'inkvault://note/$id?other=x',
    ]) {
      expect(NoteLink.parse(value), isNull);
      expect(isSafeExternalLink(value), isFalse);
    }
    expect(isSafeExternalLink('https://example.com'), isTrue);
  });

  test('stable Markdown links keep an independently decoded heading or block fragment', () {
    final link = NoteLink.parse(
      'inkvault://note/$id?view=markdown#Parent%20Heading%23%5Eblock%2520',
    );
    expect(link, isNotNull);
    final dynamic markdown = link;
    expect(markdown.isMarkdown, true);
    expect(markdown.markdownAnchor, 'Parent Heading#^block%20');
    expect(link!.pageId, null);
    final dynamic repeated = NoteLink.parse(link.toString());
    expect(repeated.markdownAnchor, markdown.markdownAnchor);
  });

  test(
    'stable Markdown mode without a fragment is distinct from a PDF page',
    () {
      final dynamic link = NoteLink.parse('inkvault://note/$id?view=markdown');
      expect(link, isNotNull);
      expect(link.isMarkdown, true);
      expect(link.markdownAnchor, null);
      expect(link.toString(), 'inkvault://note/$id?view=markdown');
      final dynamic fragment = NoteLink.parse(
        'inkvault://note/$id#%5Esection-1',
      );
      expect(fragment.isMarkdown, true);
      expect(fragment.markdownAnchor, '^section-1');
      final dynamic legacy = NoteLink.parse('inkvault://note/$id?page=$id');
      expect(legacy.isMarkdown, false);
      expect(legacy.pageId, id);
    },
  );

  test('stable Markdown links reject mixed views controls and ambiguous query fields', () {
    for (final value in [
      'inkvault://note/$id?view=markdown&page=$id',
      'inkvault://note/$id?page=$id#Heading',
      'inkvault://note/$id?view=html',
      'inkvault://note/$id?view=markdown&view=markdown',
      'inkvault://note/$id?view=markdown#unsafe%00anchor',
      'inkvault://note/$id?view=markdown#unsafe%0Aanchor',
      'inkvault://note/$id?view=markdown#${'x' * 2049}',
    ]) {
      expect(NoteLink.parse(value), null, reason: value);
    }
  });
}
