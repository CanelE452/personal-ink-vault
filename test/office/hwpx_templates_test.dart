import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:xml/xml.dart';

const _paragraph = 'http://www.hancom.co.kr/hwpml/2011/paragraph';
const _section = 'http://www.hancom.co.kr/hwpml/2011/section';
const _head = 'http://www.hancom.co.kr/hwpml/2011/head';
const _opf = 'http://www.idpf.org/2007/opf/';

OfficeStarterFile _create(String title) => OfficeTemplates.create(
  OfficeTemplateKind.values.byName('hwpx'),
  title: title,
);

Archive _archive(OfficeStarterFile starter) {
  final archive = ZipDecoder().decodeBytes(starter.bytes, verify: true);
  addTearDown(archive.clearSync);
  return archive;
}

String _part(Archive archive, String name) {
  final file = archive.findFile(name);
  expect(file, isNotNull, reason: 'Missing HWPX package entry $name');
  return utf8.decode(file!.content);
}

XmlDocument _xml(Archive archive, String name) =>
    XmlDocument.parse(_part(archive, name));

String _nodeText(XmlNode node) {
  if (node is XmlElement && node.namespaceUri == _paragraph) {
    if (node.name.local == 'tab') return '\t';
    if (node.name.local == 'lineBreak') return '\n';
  }
  if (node is XmlText) return node.value;
  return node.children.map(_nodeText).join();
}

String _text(Archive archive) => _xml(
  archive,
  'Contents/section0.xml',
).findAllElements('t', namespace: _paragraph).map(_nodeText).join();

void main() {
  test(
    'HWPX uses a first uncompressed mimetype and a complete bounded package',
    () {
      final starter = _create('한글 문서');
      expect(starter.fileName, '한글 문서.hwpx');
      final header = ByteData.sublistView(starter.bytes);
      expect(header.getUint32(0, Endian.little), 0x04034b50);
      expect(header.getUint16(8, Endian.little), 0);
      expect(
        utf8.decode(
          starter.bytes.sublist(30, 30 + header.getUint16(26, Endian.little)),
        ),
        'mimetype',
      );
      final archive = _archive(starter);
      expect(archive.first.name, 'mimetype');
      expect(_part(archive, 'mimetype'), 'application/hwp+zip');
      final names = archive.map((part) => part.name).toSet();
      expect(names.length, archive.length);
      expect(
        names,
        containsAll([
          'version.xml',
          'META-INF/container.xml',
          'META-INF/manifest.xml',
          'META-INF/container.rdf',
          'Contents/content.hpf',
          'Contents/header.xml',
          'Contents/section0.xml',
          'settings.xml',
          'Preview/PrvText.txt',
        ]),
      );
      expect(starter.bytes.length, lessThan(64 * 1024));
      for (final name in names) {
        expect(name.startsWith('/'), isFalse);
        expect(name.contains('\\'), isFalse);
        expect(name.split('/'), isNot(contains('..')));
        if (name.endsWith('.xml') ||
            name.endsWith('.hpf') ||
            name.endsWith('.rdf')) {
          final source = _part(archive, name);
          expect(source.toUpperCase(), isNot(contains('<!DOCTYPE')));
          expect(() => XmlDocument.parse(source), returnsNormally);
        }
      }
      final content = _xml(archive, 'Contents/content.hpf');
      for (final item in content.findAllElements('item', namespace: _opf)) {
        expect(names, contains(item.getAttribute('href')));
      }
      expect(
        names.any((name) => name.endsWith('.pdf') || name.contains('Scripts/')),
        isFalse,
      );
    },
  );

  test('HWPX starts with one editable paragraph and a portrait page', () {
    final archive = _archive(_create('연구 계획'));
    final section = _xml(archive, 'Contents/section0.xml');
    expect(section.rootElement.name.local, 'sec');
    expect(section.rootElement.namespaceUri, _section);
    expect(section.findAllElements('p', namespace: _paragraph), hasLength(1));
    expect(_text(archive), '연구 계획');
    final page = section
        .findAllElements('pagePr', namespace: _paragraph)
        .single;
    expect(int.parse(page.getAttribute('width')!), greaterThan(0));
    expect(
      int.parse(page.getAttribute('height')!),
      greaterThan(int.parse(page.getAttribute('width')!)),
    );
    final head = _xml(archive, 'Contents/header.xml');
    expect(head.findAllElements('charPr', namespace: _head), isNotEmpty);
    expect(head.findAllElements('paraPr', namespace: _head), isNotEmpty);
    expect(
      section.findAllElements('linesegarray', namespace: _paragraph),
      isEmpty,
    );
  });

  test('HWPX title stays literal in body metadata and preview', () {
    const title = '  # 한글 🖋️ & <계획> "v1" \'검토\' **원문**  ';
    final archive = _archive(_create(title));
    expect(_text(archive), title);
    final metadata = _xml(archive, 'Contents/content.hpf');
    expect(
      metadata.findAllElements('title', namespace: _opf).single.innerText,
      title,
    );
    expect(_part(archive, 'Preview/PrvText.txt'), '$title\n');
    expect(
      _part(archive, 'Contents/section0.xml'),
      isNot(contains('PIV_HWPX_TITLE_MARKER')),
    );
  });

  test('HWPX maps title whitespace to standard inline controls', () {
    const title = '한글\t문서\n다음 줄\r끝';
    final archive = _archive(_create(title));
    expect(_text(archive), title.replaceAll('\r', '\n'));
    final section = _xml(archive, 'Contents/section0.xml');
    expect(section.findAllElements('tab', namespace: _paragraph), hasLength(1));
    expect(
      section.findAllElements('lineBreak', namespace: _paragraph),
      hasLength(2),
    );
  });

  test('blank HWPX title has a usable default paragraph and file name', () {
    final blank = _create(' \t\n ');
    expect(blank.fileName, 'Document.hwpx');
    expect(_text(_archive(blank)), 'Document');
  });

  test('HWPX file names cannot become paths or Windows device names', () {
    expect(_create(' ..\\자료/새:문서? ').fileName, '_자료_새_문서_.hwpx');
    expect(_create('CON').fileName, '_CON.hwpx');
    expect(_create('NUL.txt').fileName, '_NUL.txt.hwpx');
    expect(_create('a' * 500).fileName.length, lessThanOrEqualTo(105));
  });

  for (final invalid in [
    'bad\u0000title',
    'bad\u0001title',
    'bad\ud800title',
  ]) {
    test('HWPX rejects XML-invalid title ${invalid.codeUnits}', () {
      expect(() => _create(invalid), throwsFormatException);
    });
  }

  test('HWPX starter bytes are independent and immutable', () {
    final first = _create('한글');
    final before = Uint8List.fromList(first.bytes);
    final second = _create('다른 문서');
    expect(() => first.bytes[0] = 0, throwsUnsupportedError);
    expect(first.bytes, before);
    expect(_text(_archive(second)), '다른 문서');
    expect(_text(_archive(first)), '한글');
  });
}
