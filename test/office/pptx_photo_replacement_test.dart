import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:path/path.dart' as path;
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/pptx_photo_replacement.dart';
import 'package:xml/xml.dart';

const _slide = 'ppt/slides/slide1.xml';
const _rels = 'ppt/slides/_rels/slide1.xml.rels';
const _sharedMedia = 'ppt/media/shared.png';
const _types = '[Content_Types].xml';
const _relationshipNamespace =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

void main() {
  test('PPTX replaces one picture without changing its geometry or layer', () {
    final source = pptxPhotoFixture(includeExternal: true);
    final original = _entries(source);
    final originalSlide = _parse(original, _slide);
    final originalRelationships = _parse(original, _rels);
    final replacement = pptxReplacementPhoto();
    final photos = listPptxPhotos(source);
    expect(photos.map((photo) => photo.name), [
      'Target photo',
      'Shared relationship',
      'Shared media',
    ]);
    final target = photos.first;
    expect(readPptxPhotoPreview(source, target), original[_sharedMedia]);

    final result = replacePptxPhoto(source, target, replacement);
    final updated = _entries(result);
    final updatedSlide = _parse(updated, _slide);
    final updatedRelationships = _parse(updated, _rels);
    final embed = _embed(_picture(updatedSlide, 'Target photo'))!;
    expect(embed, isNot('rIdPhoto'));
    final relationship = _relationship(updatedRelationships, embed);
    expect(relationship.getAttribute('Type'), '$_relationshipNamespace/image');
    expect(relationship.getAttribute('TargetMode'), isNull);
    final media = _mediaPath(relationship);
    expect(updated.keys.toSet().difference(original.keys.toSet()), {media});
    expect(updated[media], replacement.bytes);
    for (final member in original.keys.where(
      (name) => name != _slide && name != _rels,
    )) {
      expect(updated[member], original[member], reason: member);
    }
    for (final id in ['rId1', 'rIdPhoto', 'rIdSharedMedia', 'rIdExternal']) {
      expect(
        _relationship(updatedRelationships, id).toXmlString(),
        _relationship(originalRelationships, id).toXmlString(),
        reason: id,
      );
    }

    // Restoring the single embed attribute makes every original slide node
    // compare identically, including crop, rotation, placement and sibling order.
    _blip(_picture(updatedSlide, 'Target photo')).attributes
            .singleWhere((attribute) => attribute.name.local == 'embed')
            .value =
        'rIdPhoto';
    expect(updatedSlide.toXmlString(), originalSlide.toXmlString());

    final reopened = listPptxPhotos(result);
    expect(
      reopened.map((photo) => photo.name),
      photos.map((photo) => photo.name),
    );
    expect(readPptxPhotoPreview(result, reopened.first), replacement.bytes);
    for (final photo in reopened.skip(1)) {
      expect(readPptxPhotoPreview(result, photo), original[_sharedMedia]);
    }
    expect(_entries(source)[_sharedMedia], original[_sharedMedia]);
  });

  test('PPTX replacement registers a new JPEG content type', () {
    final source = pptxPhotoFixture();
    final target = listPptxPhotos(source).first;
    final image = im.Image(width: 25, height: 21);
    im.fill(image, color: im.ColorRgb8(85, 205, 95));
    final replacement = WindowsOfficeImageAsset.fromBytes(im.encodeJpg(image));
    final result = replacePptxPhoto(source, target, replacement);
    final entries = _entries(result);
    final updatedSlide = _parse(entries, _slide);
    final embed = _embed(_picture(updatedSlide, 'Target photo'))!;
    final media = _mediaPath(_relationship(_parse(entries, _rels), embed));
    final extension = path.posix.extension(media).substring(1);
    final jpegTypes = _parse(entries, _types).rootElement.childElements.where(
      (element) => element.getAttribute('ContentType') == 'image/jpeg',
    );
    expect(
      jpegTypes.any(
        (element) =>
            element.getAttribute('Extension') == extension ||
            element.getAttribute('PartName') == '/$media',
      ),
      isTrue,
    );
    expect(entries[media], replacement.bytes);
    expect(
      readPptxPhotoPreview(result, listPptxPhotos(result).first),
      replacement.bytes,
    );
  });

  test('PPTX rejects a photo selection from an earlier slide revision', () {
    final source = pptxPhotoFixture();
    final target = listPptxPhotos(source).first;
    final revised = _entries(source);
    revised[_slide] = _text(revised, _slide)
        .replaceFirst('rot="900000"', 'rot="1800000"')
        .replaceFirst('name="Target photo"', 'name="New photo"')
        .toBytes();
    final revisedSource = _zip(revised);
    expect(listPptxPhotos(revisedSource).first.name, 'New photo');
    expect(
      () => readPptxPhotoPreview(revisedSource, target),
      throwsFormatException,
    );
    expect(
      () => replacePptxPhoto(revisedSource, target, pptxReplacementPhoto()),
      throwsFormatException,
    );
  });

  test('PPTX rejects corrupt bytes and malformed relationship XML', () {
    final source = pptxPhotoFixture();
    final target = listPptxPhotos(source).first;
    final broken = _entries(source);
    broken[_rels] = '<Relationships>'.toBytes();
    for (final invalid in [
      Uint8List.fromList([1, 2, 3]),
      _zip(broken),
    ]) {
      expect(() => listPptxPhotos(invalid), throwsFormatException);
      expect(
        () => replacePptxPhoto(invalid, target, pptxReplacementPhoto()),
        throwsFormatException,
      );
    }
  });

  test('PPTX deletes only the selected picture and preserves shared media', () {
    final source = pptxPhotoFixture(includeExternal: true);
    final original = _entries(source);
    final expected = _parse(original, _slide);
    _picture(expected, 'Target photo').remove();
    final target = listPptxDeletablePhotos(source).first;

    final result = deletePptxPhoto(source, target);
    final updated = _entries(result);
    expect(updated.keys, unorderedEquals(original.keys));
    expect(_parse(updated, _slide).toXmlString(), expected.toXmlString());
    for (final name in original.keys.where((name) => name != _slide)) {
      expect(updated[name], original[name], reason: name);
    }
    final survivors = listPptxPhotos(result);
    expect(survivors.map((photo) => photo.name), [
      'Shared relationship',
      'Shared media',
    ]);
    for (final photo in survivors) {
      expect(readPptxPhotoPreview(result, photo), original[_sharedMedia]);
    }
    expect(_entries(source), original);
    expect(() => deletePptxPhoto(result, target), throwsFormatException);
    expect(
      () => deletePptxPhoto(Uint8List.fromList([1, 2, 3]), target),
      throwsFormatException,
    );
  });

  test('PPTX deletion rejects referenced pictures but keeps other choices', () {
    for (final (before, xml) in [
      (
        '</p:sld>',
        '<p:timing><p:tnLst><p:par><p:cTn id="1"><p:stCondLst>'
            '<p:cond evt="onClick"><p:tgtEl><p:spTgt spid="00100"/>'
            '</p:tgtEl></p:cond></p:stCondLst></p:cTn></p:par>'
            '</p:tnLst></p:timing>',
      ),
      (
        '</p:spTree>',
        '<p:cxnSp><p:nvCxnSpPr><p:cNvPr id="104" name="Connector"/>'
            '<p:cNvCxnSpPr><a:stCxn id="100" idx="0"/></p:cNvCxnSpPr>'
            '<p:nvPr/></p:nvCxnSpPr><p:spPr/></p:cxnSp>',
      ),
    ]) {
      final parts = _entries(pptxPhotoFixture());
      parts[_slide] = _text(
        parts,
        _slide,
      ).replaceFirst(before, '$xml$before').toBytes();
      final source = _zip(parts);
      final unsafe = listPptxPhotos(source).first;
      expect(() => deletePptxPhoto(source, unsafe), throwsFormatException);
      final safe = listPptxDeletablePhotos(source);
      expect(safe.map((photo) => photo.name), [
        'Shared relationship',
        'Shared media',
      ]);
      final updated = _entries(deletePptxPhoto(source, safe.first));
      expect(_text(updated, _slide), contains(xml));
    }
  });

  test(
    'PPTX deletion leaves ambiguous slides and non-photo roles unavailable',
    () {
      final placeholder = _editFirstPicture(
        (picture) => _addChild(picture, 'nvPr', XmlElement(XmlName('ph', 'p'))),
      );
      expect(listPptxDeletablePhotos(placeholder).map((photo) => photo.name), [
        'Shared relationship',
        'Shared media',
      ]);
      expect(
        () => deletePptxPhoto(placeholder, listPptxPhotos(placeholder).first),
        throwsFormatException,
      );

      final parts = _entries(pptxPhotoFixture());
      parts[_slide] = _text(parts, _slide)
          .replaceFirst(
            '</p:sld>',
            '<p:extLst><p:ext uri="unknown"><custom:shapeRef '
                'xmlns:custom="urn:test" shapeId="100"/></p:ext></p:extLst></p:sld>',
          )
          .toBytes();
      final ambiguous = _zip(parts);
      expect(listPptxDeletablePhotos(ambiguous), isEmpty);
      expect(
        () => deletePptxPhoto(ambiguous, listPptxPhotos(ambiguous).first),
        throwsFormatException,
      );
    },
  );

  test('PPTX rotates only the selected picture sharing local image data', () {
    final source = pptxPhotoFixture(includeExternal: true);
    final original = _entries(source);
    final originalSlide = _parse(original, _slide);
    final photos = listPptxRotatablePhotos(source);
    expect(photos.map((photo) => photo.name), [
      'Target photo',
      'Shared relationship',
      'Shared media',
    ]);

    final edited = rotatePptxPhoto(source, photos.first);
    final updated = _entries(edited);
    expect(updated.keys, unorderedEquals(original.keys));
    for (final name in original.keys.where((name) => name != _slide)) {
      expect(updated[name], original[name], reason: name);
    }

    final updatedSlide = _parse(updated, _slide);
    final rotated = _transform(_picture(updatedSlide, 'Target photo'));
    expect(rotated.getAttribute('rot'), '6300000');
    rotated.setAttribute('rot', '900000');
    expect(updatedSlide.toXmlString(), originalSlide.toXmlString());
    expect(_entries(source), original);

    final reopened = listPptxRotatablePhotos(edited);
    expect(
      reopened.map((photo) => photo.name),
      photos.map((photo) => photo.name),
    );
    for (final photo in reopened) {
      expect(readPptxPhotoPreview(edited, photo), original[_sharedMedia]);
    }
    expect(() => rotatePptxPhoto(edited, photos.first), throwsFormatException);
  });

  test('PPTX rotates a directly embedded JPEG without re-encoding it', () {
    final source = pptxPhotoFixture();
    final jpeg = WindowsOfficeImageAsset.fromBytes(
      im.encodeJpg(im.Image(width: 25, height: 21)),
    );
    final replaced = replacePptxPhoto(
      source,
      listPptxPhotos(source).first,
      jpeg,
    );
    final edited = rotatePptxPhoto(
      replaced,
      listPptxRotatablePhotos(replaced).first,
    );
    final target = listPptxRotatablePhotos(edited).first;
    expect(readPptxPhotoPreview(edited, target), jpeg.bytes);
    expect(
      _transform(_picture(_parse(_entries(edited), _slide), target.name))
          .getAttribute('rot'),
      '6300000',
    );
  });

  test('PPTX rotates missing and signed angles through a full turn', () {
    for (final (angle, expected) in <(String?, String)>[
      (null, '5400000'),
      ('20880000', '4680000'),
      ('-5400000', '0'),
      ('-10800000', '16200000'),
    ]) {
      final source = _editFirstPicture(
        (picture) => _transform(picture).setAttribute('rot', angle),
      );
      final target = listPptxRotatablePhotos(source).first;
      final edited = rotatePptxPhoto(source, target);
      expect(
        _transform(_picture(_parse(_entries(edited), _slide), target.name))
            .getAttribute('rot'),
        expected,
        reason: 'original rotation: $angle',
      );
    }
  });

  test('PPTX keeps ineligible rotations out without narrowing replacement', () {
    final edits = <String, void Function(XmlElement)>{
      'missing transform': (picture) => _transform(picture).remove(),
      'duplicate transform': (picture) {
        final transform = _transform(picture);
        transform.parent!.children.add(transform.copy());
      },
      'malformed rotation': (picture) =>
          _transform(picture).setAttribute('rot', '0x1'),
      'out-of-range rotation': (picture) =>
          _transform(picture).setAttribute('rot', '2147483648'),
      'zero extent': (picture) =>
          _transform(picture).childElements
              .singleWhere((child) => child.localName == 'ext')
              .setAttribute('cx', '0'),
      'missing coordinate': (picture) =>
          _transform(picture).childElements
              .singleWhere((child) => child.localName == 'off')
              .removeAttribute('x'),
      'rotation lock': (picture) => _addChild(
        picture,
        'cNvPicPr',
        XmlElement(XmlName('picLocks', 'a'), [
          XmlAttribute(XmlName('noRot'), '1'),
        ]),
      ),
      'placeholder': (picture) =>
          _addChild(picture, 'nvPr', XmlElement(XmlName('ph', 'p'))),
    };
    for (final (reason, edit) in edits.entries.map((e) => (e.key, e.value))) {
      final source = _editFirstPicture(edit);
      final target = listPptxPhotos(source).first;
      expect(target.name, 'Target photo', reason: reason);
      expect(listPptxRotatablePhotos(source).map((photo) => photo.name), [
        'Shared relationship',
        'Shared media',
      ], reason: reason);
      expect(
        () => rotatePptxPhoto(source, target),
        throwsFormatException,
        reason: reason,
      );
    }
  });
}

Uint8List pptxPhotoFixture({bool includeExternal = false}) {
  final starter = OfficeTemplates.create(
    OfficeTemplateKind.presentation,
    title: 'PIV photo replacement',
  );
  final entries = _entries(starter.bytes);
  final pictures = [
    _photo('Target photo', 100, 'rIdPhoto', x: 800000),
    _photo('Shared relationship', 101, 'rIdPhoto', x: 4300000),
    _photo('Shared media', 102, 'rIdSharedMedia', x: 7800000),
    if (includeExternal)
      _photo('External photo', 103, 'rIdExternal', x: 4300000, linked: true),
  ];
  entries[_slide] = _text(
    entries,
    _slide,
  ).replaceFirst('</p:spTree>', '${pictures.join()}\n</p:spTree>').toBytes();
  final relationships = [
    _imageRelationship('rIdPhoto', '../media/shared.png'),
    _imageRelationship('rIdSharedMedia', '../media/shared.png'),
    if (includeExternal)
      _imageRelationship(
        'rIdExternal',
        'https://example.invalid/never.png',
        external: true,
      ),
  ];
  entries[_rels] = _text(entries, _rels)
      .replaceFirst(
        '</Relationships>',
        '${relationships.join()}</Relationships>',
      )
      .toBytes();
  entries[_types] = _text(entries, _types)
      .replaceFirst(
        '</Types>',
        '<Default Extension="png" ContentType="image/png"/></Types>',
      )
      .toBytes();
  entries[_sharedMedia] = _png(31, 19, im.ColorRgb8(35, 85, 210));
  return _zip(entries);
}

WindowsOfficeImageAsset pptxReplacementPhoto() =>
    WindowsOfficeImageAsset.fromBytes(_png(47, 29, im.ColorRgb8(230, 105, 40)));

String _photo(
  String name,
  int id,
  String rel, {
  required int x,
  bool linked = false,
}) {
  final relationship = linked ? 'link' : 'embed';
  return '''
  <p:pic xmlns:r="$_relationshipNamespace">
    <p:nvPicPr><p:cNvPr id="$id" name="$name"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
    <p:blipFill><a:blip r:$relationship="$rel"/><a:srcRect l="14000" t="19000" r="9000" b="17000"/>
      <a:stretch><a:fillRect/></a:stretch>
    </p:blipFill>
    <p:spPr><a:xfrm rot="900000"><a:off x="$x" y="2900000"/><a:ext cx="2650000" cy="1600000"/></a:xfrm>
      <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
    </p:spPr>
  </p:pic>''';
}

String _imageRelationship(String id, String target, {bool external = false}) =>
    '<Relationship Id="$id" Type="$_relationshipNamespace/image" '
    'Target="$target"${external ? ' TargetMode="External"' : ''}/>';

Uint8List _png(int width, int height, im.Color color) {
  final image = im.Image(width: width, height: height);
  im.fill(image, color: color);
  return Uint8List.fromList(im.encodePng(image));
}

Map<String, Uint8List> _entries(Uint8List zip) => {
  for (final file in ZipDecoder().decodeBytes(zip).files)
    if (file.isFile) file.name: Uint8List.fromList(file.content),
};

Uint8List _zip(Map<String, Uint8List> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

String _text(Map<String, Uint8List> entries, String name) =>
    utf8.decode(entries[name]!);

XmlDocument _parse(Map<String, Uint8List> entries, String name) =>
    XmlDocument.parse(_text(entries, name));

XmlElement _relationship(XmlDocument xml, String id) => xml
    .rootElement
    .childElements
    .singleWhere((element) => element.getAttribute('Id') == id);

String _mediaPath(XmlElement relationship) {
  final target = relationship.getAttribute('Target')!;
  return target.startsWith('/')
      ? target.substring(1)
      : path.posix.normalize(path.posix.join('ppt/slides', target));
}

XmlElement _picture(XmlDocument xml, String name) => xml.descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == 'pic')
    .singleWhere(
      (picture) => picture.descendants.whereType<XmlElement>().any(
        (element) =>
            element.name.local == 'cNvPr' &&
            element.getAttribute('name') == name,
      ),
    );

XmlElement _blip(XmlElement picture) => picture.descendants
    .whereType<XmlElement>()
    .singleWhere((element) => element.name.local == 'blip');

String? _embed(XmlElement picture) =>
    _blip(picture).getAttribute('embed', namespace: _relationshipNamespace);

XmlElement _transform(XmlElement picture) => picture.descendants
    .whereType<XmlElement>()
    .singleWhere((element) => element.localName == 'xfrm');

Uint8List _editFirstPicture(void Function(XmlElement) edit) {
  final entries = _entries(pptxPhotoFixture());
  final slide = _parse(entries, _slide);
  edit(_picture(slide, 'Target photo'));
  entries[_slide] = slide.toXmlString().toBytes();
  return _zip(entries);
}

void _addChild(XmlElement picture, String parent, XmlElement child) {
  picture.descendants
      .whereType<XmlElement>()
      .singleWhere((element) => element.localName == parent)
      .children
      .add(child);
}

extension on String {
  Uint8List toBytes() => Uint8List.fromList(utf8.encode(this));
}
