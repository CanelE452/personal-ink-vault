import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/note_link.dart';

void main() {
  const id = '12345678-1234-4234-8234-123456789abc';
  test('stable link accepts a note and optional page UUID', () {
    final link = NoteLink.parse('inkvault://note/$id?page=$id');
    expect(link?.noteId, id);
    expect(link?.pageId, id);
    expect(link.toString(), 'inkvault://note/$id?page=$id');
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
}
