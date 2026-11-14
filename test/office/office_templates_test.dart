import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:xml/xml.dart';

const _wordNs = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _presentationNs =
    'http://schemas.openxmlformats.org/presentationml/2006/main';
const _drawingNs = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _relationshipNs =
    'http://schemas.openxmlformats.org/package/2006/relationships';
const _officeRelationshipNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

Archive _unzip(OfficeStarterFile file) {
  expect(file.bytes.take(4), [0x50, 0x4b, 0x03, 0x04]);
  final archive = ZipDecoder().decodeBytes(file.bytes, verify: true);
  addTearDown(archive.clearSync);
  return archive;
}

XmlDocument _xml(Archive archive, String path) {
  final part = archive.findFile(path);
  expect(part, isNotNull, reason: 'Missing OpenXML part $path');
  return XmlDocument.parse(utf8.decode(part!.content));
}

XmlElement _element(XmlDocument xml, String name, String namespace) =>
    xml.findAllElements(name, namespace: namespace).single;

String _editableText(Archive archive, OfficeTemplateKind kind) {
  final document = kind == OfficeTemplateKind.document;
  final xml = _xml(
    archive,
    document ? 'word/document.xml' : 'ppt/slides/slide1.xml',
  );
  return xml
      .findAllElements('t', namespace: document ? _wordNs : _drawingNs)
      .map((element) => element.innerText)
      .join();
}

void main() {
  test('DOCX starts with an editable Word paragraph on a portrait page', () {
    final starter = OfficeTemplates.create(
      OfficeTemplateKind.document,
      title: 'Lecture',
    );
    expect(starter.fileName, 'Lecture.docx');
    final archive = _unzip(starter);
    final document = _xml(archive, 'word/document.xml');
    expect(document.rootElement.name.local, 'document');
    expect(document.rootElement.namespaceUri, _wordNs);
    final paragraph = _element(document, 'p', _wordNs);
    final run = paragraph.findElements('r', namespace: _wordNs).single;
    expect(
      run.findElements('t', namespace: _wordNs).single.innerText,
      'Lecture',
    );
    final size = _element(document, 'pgSz', _wordNs);
    final width = int.parse(size.getAttribute('w', namespace: _wordNs)!);
    final height = int.parse(size.getAttribute('h', namespace: _wordNs)!);
    expect(width, greaterThan(0));
    expect(height, greaterThan(width));
    expect(
      document.findAllElements('documentProtection', namespace: _wordNs),
      isEmpty,
    );
  });

  test('PPTX starts with one editable text shape on a widescreen slide', () {
    final starter = OfficeTemplates.create(
      OfficeTemplateKind.presentation,
      title: 'Seminar',
    );
    expect(starter.fileName, 'Seminar.pptx');
    final archive = _unzip(starter);
    final presentation = _xml(archive, 'ppt/presentation.xml');
    expect(presentation.rootElement.name.local, 'presentation');
    expect(presentation.rootElement.namespaceUri, _presentationNs);
    expect(
      presentation.findAllElements('sldId', namespace: _presentationNs),
      hasLength(1),
    );
    final size = _element(presentation, 'sldSz', _presentationNs);
    final width = int.parse(size.getAttribute('cx')!);
    final height = int.parse(size.getAttribute('cy')!);
    expect(width / height, closeTo(16 / 9, 0.00001));
    final slide = _xml(archive, 'ppt/slides/slide1.xml');
    final shape = _element(slide, 'sp', _presentationNs);
    expect(
      shape.findAllElements('t', namespace: _drawingNs).single.innerText,
      'Seminar',
    );
    expect(slide.findAllElements('pic', namespace: _presentationNs), isEmpty);
    expect(slide.findAllElements('spLocks', namespace: _drawingNs), isEmpty);
    expect(
      _xml(archive, 'ppt/slideMasters/slideMaster1.xml').rootElement.name.local,
      'sldMaster',
    );
    expect(
      _xml(archive, 'ppt/slideLayouts/slideLayout1.xml').rootElement.name.local,
      'sldLayout',
    );
    expect(
      _xml(archive, 'ppt/theme/theme1.xml').rootElement.name.local,
      'theme',
    );
    expect(
      _xml(archive, 'ppt/presProps.xml').rootElement.name.local,
      'presentationPr',
    );
  });

  for (final kind in [
    OfficeTemplateKind.document,
    OfficeTemplateKind.presentation,
  ]) {
    test('$kind package has valid XML and complete internal relationships', () {
      final archive = _unzip(OfficeTemplates.create(kind, title: 'Package'));
      final names = archive.map((part) => part.name).toSet();
      expect(names, hasLength(archive.length));
      for (final part in archive) {
        expect(part.isFile, true);
        expect(part.name, isNot(startsWith('/')));
        expect(part.name, isNot(contains('\\')));
        expect(part.name.split('/'), isNot(contains('..')));
        if (part.name.endsWith('.xml') || part.name.endsWith('.rels')) {
          _xml(archive, part.name);
        }
        if (!part.name.endsWith('.rels')) continue;
        final relationships = _xml(
          archive,
          part.name,
        ).findAllElements('Relationship', namespace: _relationshipNs).toList();
        expect(
          relationships.map((r) => r.getAttribute('Id')).toSet(),
          hasLength(relationships.length),
        );
        final sourceDirectory = part.name == '_rels/.rels'
            ? ''
            : part.name.substring(0, part.name.lastIndexOf('/_rels/') + 1);
        final sourceUri = Uri.parse('package:/$sourceDirectory');
        for (final relationship in relationships) {
          expect(relationship.getAttribute('TargetMode'), isNot('External'));
          final target = relationship.getAttribute('Target')!;
          expect(Uri.parse(target).hasScheme, false);
          final resolved = sourceUri.resolve(target).path.substring(1);
          expect(names, contains(resolved), reason: '${part.name}: $target');
        }
      }
      final rootRelationships = _xml(archive, '_rels/.rels');
      final mainRelationship = rootRelationships
          .findAllElements('Relationship', namespace: _relationshipNs)
          .singleWhere(
            (r) =>
                r.getAttribute('Type') ==
                '$_officeRelationshipNs/officeDocument',
          );
      final mainPath = kind == OfficeTemplateKind.document
          ? 'word/document.xml'
          : 'ppt/presentation.xml';
      expect(mainRelationship.getAttribute('Target'), mainPath);
      final types = _xml(archive, '[Content_Types].xml');
      final overrides = types.rootElement.childElements.where(
        (e) => e.name.local == 'Override',
      );
      expect(
        overrides.any((e) => e.getAttribute('PartName') == '/$mainPath'),
        true,
      );
      for (final part in archive.where(
        (p) => p.name.endsWith('.xml') && p.name != '[Content_Types].xml',
      )) {
        expect(
          overrides.any((e) => e.getAttribute('PartName') == '/${part.name}'),
          true,
          reason: 'Missing explicit content type for ${part.name}',
        );
      }
      expect(
        names.any((name) => name.endsWith('.pdf') || name.endsWith('.bin')),
        false,
      );
    });

    test('$kind preserves Unicode, significant spaces and XML characters', () {
      const title = '  한글 🖋️ & <계획> "v1" \'검토\'  ';
      final archive = _unzip(OfficeTemplates.create(kind, title: title));
      expect(_editableText(archive, kind), title);
      final core = _xml(archive, 'docProps/core.xml');
      expect(
        _element(core, 'title', 'http://purl.org/dc/elements/1.1/').innerText,
        title,
      );
      expect(
        _element(core, 'creator', 'http://purl.org/dc/elements/1.1/').innerText,
        isNotEmpty,
      );
      expect(
        _xml(archive, 'docProps/app.xml').rootElement.name.local,
        'Properties',
      );
      if (kind == OfficeTemplateKind.document) {
        final text = _element(_xml(archive, 'word/document.xml'), 't', _wordNs);
        // xml 6.6.1 resolves only explicitly declared prefixes; XML's built-in
        // xml prefix is implicit, so look up its qualified attribute name.
        expect(text.getAttribute('xml:space'), 'preserve');
      }
    });

    test(
      '$kind derives a safe file name while retaining the title content',
      () {
        const title = '../수업: A/B\\C *?<>|"';
        final starter = OfficeTemplates.create(kind, title: title);
        expect(
          starter.fileName,
          isNot(contains(RegExp(r'[<>:"/\\|?*\x00-\x1f]'))),
        );
        expect(starter.fileName, isNot(startsWith('.')));
        expect(starter.fileName, contains('수업'));
        expect(_editableText(_unzip(starter), kind), title);
        final reserved = OfficeTemplates.create(kind, title: 'CON');
        expect(reserved.fileName.split('.').first.toUpperCase(), isNot('CON'));
      },
    );

    test('$kind gives a usable default for an empty or whitespace title', () {
      final defaultTitle = kind == OfficeTemplateKind.document
          ? 'Document'
          : 'Presentation';
      for (final title in ['', ' \t\n ']) {
        final starter = OfficeTemplates.create(kind, title: title);
        expect(starter.fileName, startsWith('$defaultTitle.'));
        expect(_editableText(_unzip(starter), kind), defaultTitle);
      }
    });

    test(
      '$kind rejects XML-invalid characters instead of corrupting the package',
      () {
        for (final title in [
          'bad\u0000text',
          'bad\u000btext',
          'bad\ud800text',
        ]) {
          expect(
            () => OfficeTemplates.create(kind, title: title),
            throwsFormatException,
          );
        }
      },
    );

    test('$kind exposes immutable original bytes', () {
      final starter = OfficeTemplates.create(kind, title: 'Original');
      expect(() => starter.bytes[0] = 0, throwsUnsupportedError);
      expect(_editableText(_unzip(starter), kind), 'Original');
    });
  }
}
