import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder;
import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;
import 'package:saber/data/office/office_image_asset.dart';
import 'package:xml/xml.dart';

const _presentation =
    'http://schemas.openxmlformats.org/presentationml/2006/main';
const _drawing = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _officeRels =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _packageRels =
    'http://schemas.openxmlformats.org/package/2006/relationships';
const _typeNamespace =
    'http://schemas.openxmlformats.org/package/2006/content-types';
const _drawing2010 = 'http://schemas.microsoft.com/office/drawing/2010/main';
const _drawing2014 = 'http://schemas.microsoft.com/office/drawing/2014/main';
const _presentation2010 =
    'http://schemas.microsoft.com/office/powerpoint/2010/main';
const _compatibility =
    'http://schemas.openxmlformats.org/markup-compatibility/2006';
const _typesPart = '[Content_Types].xml';
const _rootRelationships = '_rels/.rels';
const _presentationType =
    'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml';
const _slideType =
    'application/vnd.openxmlformats-officedocument.presentationml.slide+xml';
const _maxZipBytes = 128 * 1024 * 1024;
const _maxExpandedBytes = 256 * 1024 * 1024;
const _maxMemberBytes = 64 * 1024 * 1024;
const _maxXmlBytes = 8 * 1024 * 1024;
const _maxPreviewBytes = 4 * 1024 * 1024;
const _maxEntries = 10000;
const _quarterTurn = 5400000;
const _fullTurn = 21600000;
final _partCharacters = RegExp(r'^[A-Za-z0-9_.\[\]/-]+$');
final _xmlDeclarations = RegExp(
  r'<!\s*(?:DOCTYPE|ENTITY)',
  caseSensitive: false,
);

final class PptxPhotoTarget {
  const new _({
    required this.slideNumber,
    required this.photoNumber,
    required this.name,
    required this._archiveSha,
    required this._slidePart,
    required this._pictureId,
    required this._relationshipId,
    required this._mediaPart,
    required this._mimeType,
  });

  final int slideNumber, photoNumber;
  final String name;
  final String _archiveSha, _slidePart, _pictureId, _relationshipId, _mediaPart;
  final String _mimeType;
}

enum _PhotoSelection { all, rotatable, deletable }

List<PptxPhotoTarget> listPptxPhotos(Uint8List bytes) =>
    _listPptxPhotos(bytes, _PhotoSelection.all);

List<PptxPhotoTarget> listPptxRotatablePhotos(Uint8List bytes) =>
    _listPptxPhotos(bytes, _PhotoSelection.rotatable);

List<PptxPhotoTarget> listPptxDeletablePhotos(Uint8List bytes) =>
    _listPptxPhotos(bytes, _PhotoSelection.deletable);

List<PptxPhotoTarget> _listPptxPhotos(
  Uint8List bytes,
  _PhotoSelection selection,
) => _checked(() {
  final package = _PresentationPackage(bytes);
  final result = <PptxPhotoTarget>[];
  for (var i = 0; i < package.slides.length; i++) {
    final slide = package.photosOn(i + 1);
    final references =
        selection == _PhotoSelection.deletable && slide.photos.isNotEmpty
        ? _deletionReferences(slide.xml, slide.relationships!)
        : null;
    for (final photo in slide.photos) {
      final selectable = switch (selection) {
        _PhotoSelection.all => true,
        _PhotoSelection.rotatable => _rotationFor(photo.picture) != null,
        _PhotoSelection.deletable => _canDeletePhoto(photo, references),
      };
      if (selectable) result.add(photo.target);
    }
    if (result.length > 2048) {
      throw const FormatException('Too many PPTX photos');
    }
  }
  return List.unmodifiable(result);
});

Uint8List? readPptxPhotoPreview(Uint8List bytes, PptxPhotoTarget target) =>
    _checked(() {
      _requireEdition(bytes, target);
      return _readPhotoPreview(bytes, target._mediaPart, target._mimeType);
    });

Uint8List? readOfficePhotoPreview(
  Uint8List bytes,
  String mediaPart,
  String mediaSha256, {
  required String mimeType,
}) => _checked(
  () => _readPhotoPreview(
    bytes,
    mediaPart,
    mimeType,
    expectedSha256: mediaSha256,
  ),
);

Uint8List? _readPhotoPreview(
  Uint8List bytes,
  String mediaPart,
  String mimeType, {
  String? expectedSha256,
}) {
  final zip = _PptxZip(bytes);
  final media = zip.members[mediaPart];
  if (media == null || media.size > _maxPreviewBytes) return null;
  final payload = media.read(bytes, keep: true)!;
  if (expectedSha256 != null &&
      crypto.sha256.convert(payload).toString() != expectedSha256) {
    return null;
  }
  final decoder = mimeType == 'image/png'
      ? image.PngDecoder()
      : image.JpegDecoder();
  final info = decoder.startDecode(payload);
  if (info == null ||
      info.width < 1 ||
      info.height < 1 ||
      info.width > WindowsOfficeImageAsset.maxPixels ~/ info.height) {
    return null;
  }
  return payload;
}

Uint8List replacePptxPhoto(
  Uint8List bytes,
  PptxPhotoTarget target,
  WindowsOfficeImageAsset replacement,
) => _checked(() {
  _requireEdition(bytes, target);
  final package = _PresentationPackage(bytes, archiveSha: target._archiveSha);
  final slide = package.photosOn(target.slideNumber);
  final chosen = _selectedPhoto(slide.photos, target);

  final extension = replacement.mimeType == 'image/png' ? 'png' : 'jpg';
  final seed = utf8.encode(
    '${target._archiveSha}/${target._slidePart}/${target._pictureId}/${replacement.sha256}',
  );
  final suffix = crypto.sha256.convert(seed).toString().substring(0, 32);
  var mediaPart = 'ppt/media/piv-photo-$suffix.$extension';
  var mediaIndex = 1;
  while (package.zip.names.contains(mediaPart.toLowerCase()) ||
      package.types.overrides.containsKey(mediaPart.toLowerCase())) {
    mediaPart = 'ppt/media/piv-photo-$suffix-${mediaIndex++}.$extension';
  }
  final relationships = slide.relationships!;
  var relationshipId = 'rIdPivPhoto';
  var relationshipIndex = 1;
  while (relationships.byId.containsKey(relationshipId)) {
    relationshipId = 'rIdPivPhoto${relationshipIndex++}';
  }
  chosen.embed.value = relationshipId;
  _append(relationships.xml.rootElement, 'Relationship', {
    'Id': relationshipId,
    'Type': '$_officeRels/image',
    'Target': p.posix.relative(
      mediaPart,
      from: p.posix.dirname(target._slidePart),
    ),
  });
  final addType = package.types.typeFor(mediaPart) != replacement.mimeType;
  if (addType) {
    _append(package.types.xml.rootElement, 'Override', {
      'PartName': '/$mediaPart',
      'ContentType': replacement.mimeType,
    });
  }
  final archive = package.zip.verifiedArchive();
  try {
    archive.add(ArchiveFile.string(target._slidePart, slide.xml.toXmlString()));
    archive.add(
      ArchiveFile.string(relationships.part, relationships.xml.toXmlString()),
    );
    if (addType) {
      archive.add(
        ArchiveFile.string(_typesPart, package.types.xml.toXmlString()),
      );
    }
    archive.add(ArchiveFile.bytes(mediaPart, replacement.bytes));
    return _encodePptxArchive(archive);
  } finally {
    archive.clearSync();
  }
});

/// Adds one clockwise quarter-turn to the selected picture.
Uint8List rotatePptxPhoto(Uint8List bytes, PptxPhotoTarget target) => _checked(
  () {
    _requireEdition(bytes, target);
    final package = _PresentationPackage(bytes, archiveSha: target._archiveSha);
    final slide = package.photosOn(target.slideNumber);
    final picture = _selectedPhoto(slide.photos, target).picture;
    final rotation = _rotationFor(picture);
    if (rotation == null) {
      throw const FormatException('This PPTX photo cannot be rotated');
    }
    final angle = (rotation.angle + _quarterTurn) % _fullTurn;
    rotation.transform.setAttribute('rot', angle.toString());
    return _writeSlide(package.zip, target._slidePart, slide.xml);
  },
);

/// Removes the selected picture without changing slide or media relationships.
Uint8List deletePptxPhoto(Uint8List bytes, PptxPhotoTarget target) => _checked(
  () {
    _requireEdition(bytes, target);
    final package = _PresentationPackage(bytes, archiveSha: target._archiveSha);
    final slide = package.photosOn(target.slideNumber);
    final chosen = _selectedPhoto(slide.photos, target);
    if (!_canDeletePhoto(
      chosen,
      _deletionReferences(slide.xml, slide.relationships!),
    )) {
      throw const FormatException('This PPTX photo cannot be deleted');
    }
    chosen.picture.remove();
    return _writeSlide(package.zip, target._slidePart, slide.xml);
  },
);

Uint8List _writeSlide(_PptxZip zip, String part, XmlDocument slide) {
  final archive = zip.verifiedArchive();
  try {
    archive.add(ArchiveFile.string(part, slide.toXmlString()));
    return _encodePptxArchive(archive);
  } finally {
    archive.clearSync();
  }
}

_BoundPhoto _selectedPhoto(List<_BoundPhoto> photos, PptxPhotoTarget target) {
  final chosen = photos.where((photo) {
    final candidate = photo.target;
    return candidate._slidePart == target._slidePart &&
        candidate._pictureId == target._pictureId &&
        candidate._relationshipId == target._relationshipId &&
        candidate._mediaPart == target._mediaPart;
  }).singleOrNull;
  if (chosen == null) throw const FormatException('PPTX photo changed');
  return chosen;
}

Uint8List _encodePptxArchive(Archive archive) {
  final result = ZipEncoder().encodeBytes(
    archive,
    modified: DateTime.utc(2000),
  );
  _PptxZip(result);
  return result;
}

void _requireEdition(Uint8List bytes, PptxPhotoTarget target) {
  if (bytes.length > _maxZipBytes ||
      crypto.sha256.convert(bytes).toString() != target._archiveSha) {
    throw const FormatException(
      'PPTX photo belongs to another document revision',
    );
  }
}

final class _PresentationPackage {
  new(Uint8List bytes, {String? archiveSha})
    : zip = _PptxZip(bytes),
      _archiveSha = archiveSha ?? crypto.sha256.convert(bytes).toString() {
    types = _ContentTypes(zip);
    final relationships = _Relationships(zip, _rootRelationships);
    final documents = relationships.byId.values.where(
      (relationship) =>
          relationship.type == '$_officeRels/officeDocument' &&
          !relationship.external,
    );
    final document = documents.singleOrNull;
    if (document == null) _badPackage();
    final main = _resolvePart('', document.target);
    if (types.typeFor(main) != _presentationType) _badPackage();
    final xml = _readXml(zip, main, 'presentation', _presentation);
    final idList = _child(xml.rootElement, 'sldIdLst', _presentation);
    if (idList == null) return;
    final presentationRels = _Relationships(zip, _relsPart(main));
    final parts = <String>{};
    for (final node in _elements(idList, 'sldId', _presentation)) {
      final id = node.getAttribute('id', namespace: _officeRels);
      final rel = presentationRels.byId[id];
      if (rel == null || rel.external || rel.type != '$_officeRels/slide') {
        _badPackage();
      }
      final part = _resolvePart(main, rel.target);
      if (types.typeFor(part) != _slideType ||
          !parts.add(part) ||
          slides.length >= 512) {
        _badPackage();
      }
      slides.add(part);
    }
  }

  final _PptxZip zip;
  final String _archiveSha;
  late final _ContentTypes types;
  final slides = <String>[];

  ({XmlDocument xml, _Relationships? relationships, List<_BoundPhoto> photos})
  photosOn(int slideNumber) {
    if (slideNumber < 1 || slideNumber > slides.length) _badPackage();
    final part = slides[slideNumber - 1];
    final xml = _readXml(zip, part, 'sld', _presentation);
    final slide = _child(xml.rootElement, 'cSld', _presentation);
    final tree = slide == null ? null : _child(slide, 'spTree', _presentation);
    if (tree == null) _badPackage();
    final pictures = _elements(tree, 'pic', _presentation).toList();
    final photos = <_BoundPhoto>[];
    if (pictures.isEmpty)
      return (xml: xml, relationships: null, photos: photos);
    final shapeIds = <int>{};
    for (final shape in tree.findAllElements(
      'cNvPr',
      namespace: _presentation,
    )) {
      final id = int.tryParse(shape.getAttribute('id') ?? '');
      if (id == null || id < 0 || id > 0xffffffff || !shapeIds.add(id)) {
        _badPackage();
      }
    }
    final relsPart = _relsPart(part);
    if (!zip.members.containsKey(relsPart)) {
      return (xml: xml, relationships: null, photos: photos);
    }
    final relationships = _Relationships(zip, relsPart);
    for (var i = 0; i < pictures.length; i++) {
      final photo = pictures[i];
      final nonVisual = _child(photo, 'nvPicPr', _presentation);
      final props = nonVisual == null
          ? null
          : _child(nonVisual, 'cNvPr', _presentation);
      final pictureId = props?.getAttribute('id');
      final fill = _child(photo, 'blipFill', _presentation);
      final blip = fill == null ? null : _child(fill, 'blip', _drawing);
      if (pictureId == null ||
          blip == null ||
          blip.getAttribute('link', namespace: _officeRels) != null ||
          !_plainBlip(blip) ||
          fill!.findAllElements('blip', namespace: _drawing).length != 1) {
        continue;
      }
      final embed = blip.getAttributeNode('embed', namespace: _officeRels);
      final relationship = relationships.byId[embed?.value];
      if (embed == null ||
          relationship == null ||
          relationship.external ||
          relationship.type != '$_officeRels/image') {
        continue;
      }
      final media = _resolvePart(part, relationship.target);
      final mime = types.typeFor(media);
      final member = zip.members[media];
      if ((mime != 'image/png' && mime != 'image/jpeg') ||
          member == null ||
          member.directory ||
          member.size == 0) {
        continue;
      }
      final name = (props?.getAttribute('name') ?? '').trim();
      photos.add(
        _BoundPhoto(
          PptxPhotoTarget._(
            slideNumber: slideNumber,
            photoNumber: i + 1,
            name: name.isEmpty
                ? '사진 ${i + 1}'
                : String.fromCharCodes(name.runes.take(160)),
            archiveSha: _archiveSha,
            slidePart: part,
            pictureId: pictureId,
            relationshipId: embed.value,
            mediaPart: media,
            mimeType: mime!,
          ),
          embed,
          photo,
        ),
      );
    }
    return (xml: xml, relationships: relationships, photos: photos);
  }
}

final class _BoundPhoto {
  const new(this.target, this.embed, this.picture);
  final PptxPhotoTarget target;
  final XmlAttribute embed;
  final XmlElement picture;
}

Set<int>? _deletionReferences(XmlDocument xml, _Relationships relationships) {
  // Comment parts can carry shape anchors outside the slide XML.
  if (relationships.byId.values.any(
    (relationship) =>
        p.posix.basename(relationship.type.toLowerCase()).startsWith('comment'),
  )) {
    return null;
  }
  final timing = _elements(xml.rootElement, 'timing', _presentation);
  if (timing.length > 1 ||
      timing.any(
        (node) => node.descendants.whereType<XmlElement>().any(
          (element) =>
              element.namespaceUri != _presentation &&
              element.namespaceUri != _drawing,
        ),
      )) {
    return null;
  }

  final references = <int>{};
  for (final element in xml.descendants.whereType<XmlElement>()) {
    if (_isElement(element, 'AlternateContent', _compatibility) ||
        (element.localName == 'extLst' && !_knownPictureMetadata(element))) {
      return null;
    }
    final connectorEnd =
        _isElement(element, 'stCxn', _drawing) ||
        _isElement(element, 'endCxn', _drawing);
    for (final attribute in element.attributes) {
      final name = attribute.localName;
      if (name.toLowerCase() != 'spid' &&
          name.toLowerCase() != 'shapeid' &&
          !(connectorEnd && name == 'id')) {
        continue;
      }
      final id = int.tryParse(attribute.value.trim(), radix: 10);
      if (id == null || id < 0 || id > 0xffffffff) return null;
      references.add(id);
    }
  }
  return references;
}

bool _knownPictureMetadata(XmlElement list) {
  if (list.namespaceUri != _presentation && list.namespaceUri != _drawing) {
    return false;
  }
  return list.childElements.every((extension) {
    final data = extension.childElements.singleOrNull;
    return _isElement(extension, 'ext', list.namespaceUri!) &&
        data != null &&
        data.childElements.isEmpty &&
        (_isElement(data, 'useLocalDpi', _drawing2010) ||
            _isElement(data, 'creationId', _presentation2010) ||
            _isElement(data, 'creationId', _drawing2014));
  });
}

bool _canDeletePhoto(_BoundPhoto photo, Set<int>? references) {
  final id = int.tryParse(photo.target._pictureId.trim(), radix: 10);
  if (references == null || id == null || references.contains(id)) return false;
  final nonVisual = _elements(
    photo.picture,
    'nvPicPr',
    _presentation,
  ).singleOrNull;
  if (nonVisual == null) return false;
  final application = _elements(nonVisual, 'nvPr', _presentation).singleOrNull;
  final properties = _elements(
    nonVisual,
    'cNvPicPr',
    _presentation,
  ).singleOrNull;
  if (application == null ||
      properties == null ||
      application.childElements.any(
        (child) => !_isElement(child, 'extLst', _presentation),
      )) {
    return false;
  }
  return _elements(properties, 'picLocks', _drawing).every((lock) {
    final noSelect = lock.getAttribute('noSelect')?.trim();
    return noSelect == null || noSelect == '0' || noSelect == 'false';
  });
}

({XmlElement transform, int angle})? _rotationFor(XmlElement picture) {
  final nonVisual = _elements(picture, 'nvPicPr', _presentation).singleOrNull;
  if (nonVisual == null) return null;
  final application = _elements(nonVisual, 'nvPr', _presentation).singleOrNull;
  final properties = _elements(
    nonVisual,
    'cNvPicPr',
    _presentation,
  ).singleOrNull;
  if (application == null ||
      properties == null ||
      _elements(application, 'ph', _presentation).isNotEmpty) {
    return null;
  }
  for (final lock in _elements(properties, 'picLocks', _drawing)) {
    final noRotation = lock.getAttribute('noRot')?.trim();
    if (noRotation != null && noRotation != 'false' && noRotation != '0') {
      return null;
    }
  }

  final shape = _elements(picture, 'spPr', _presentation).singleOrNull;
  if (shape == null) return null;
  final transform = _elements(shape, 'xfrm', _drawing).singleOrNull;
  if (transform == null) return null;
  final offset = _elements(transform, 'off', _drawing).singleOrNull;
  final extent = _elements(transform, 'ext', _drawing).singleOrNull;
  if (_drawingInt32(offset?.getAttribute('x')) == null ||
      _drawingInt32(offset?.getAttribute('y')) == null ||
      (_drawingInt32(extent?.getAttribute('cx')) ?? 0) <= 0 ||
      (_drawingInt32(extent?.getAttribute('cy')) ?? 0) <= 0) {
    return null;
  }
  final angle = _drawingInt32(transform.getAttribute('rot') ?? '0');
  if (angle == null) return null;
  return (transform: transform, angle: angle);
}

int? _drawingInt32(String? value) {
  final parsed = value == null ? null : int.tryParse(value.trim(), radix: 10);
  return parsed != null && parsed >= -0x80000000 && parsed <= 0x7fffffff
      ? parsed
      : null;
}

bool _plainBlip(XmlElement blip) {
  // Local-DPI hints do not choose another image or apply an effect.
  for (final list in blip.childElements) {
    if (!_isElement(list, 'extLst', _drawing)) return false;
    for (final extension in list.childElements) {
      if (!_isElement(extension, 'ext', _drawing)) return false;
      final hint = extension.childElements.singleOrNull;
      if (hint == null ||
          !_isElement(hint, 'useLocalDpi', _drawing2010) ||
          hint.childElements.isNotEmpty) {
        return false;
      }
    }
  }
  return true;
}

final class _Relationships {
  new(_PptxZip zip, this.part)
    : xml = _readXml(zip, part, 'Relationships', _packageRels) {
    for (final child in xml.rootElement.childElements) {
      if (!_isElement(child, 'Relationship', _packageRels)) _badPackage();
      final id = child.getAttribute('Id');
      final type = child.getAttribute('Type');
      final target = child.getAttribute('Target');
      final mode = child.getAttribute('TargetMode');
      if (id == null ||
          id.isEmpty ||
          byId.containsKey(id) ||
          type == null ||
          type.isEmpty ||
          target == null ||
          target.isEmpty ||
          (mode != null && mode != 'Internal' && mode != 'External') ||
          _unsupportedPart(type)) {
        _badPackage();
      }
      byId[id] = (type: type, target: target, external: mode == 'External');
    }
  }

  final String part;
  final XmlDocument xml;
  final byId = <String, ({String type, String target, bool external})>{};
}

final class _ContentTypes {
  new(_PptxZip zip) : xml = _readXml(zip, _typesPart, 'Types', _typeNamespace) {
    for (final child in xml.rootElement.childElements) {
      final type = child.getAttribute('ContentType');
      if (type == null || type.isEmpty || _unsupportedPart(type)) _badPackage();
      if (_isElement(child, 'Default', _typeNamespace)) {
        final extension = child.getAttribute('Extension')?.toLowerCase();
        if (extension == null ||
            extension.isEmpty ||
            defaults.containsKey(extension))
          _badPackage();
        defaults[extension] = type;
      } else if (_isElement(child, 'Override', _typeNamespace)) {
        final name = child.getAttribute('PartName');
        if (name == null ||
            !name.startsWith('/') ||
            !_safePart(name.substring(1)))
          _badPackage();
        final key = name.substring(1).toLowerCase();
        if (overrides.containsKey(key)) _badPackage();
        overrides[key] = type;
      } else {
        _badPackage();
      }
    }
  }

  final XmlDocument xml;
  final defaults = <String, String>{};
  final overrides = <String, String>{};

  String? typeFor(String part) {
    final extension = p.posix.extension(part);
    return overrides[part.toLowerCase()] ??
        (extension.isEmpty
            ? null
            : defaults[extension.substring(1).toLowerCase()]);
  }
}

String _relsPart(String owner) => p.posix.join(
  p.posix.dirname(owner),
  '_rels',
  '${p.posix.basename(owner)}.rels',
);

String _resolvePart(String owner, String target) {
  final rootRelative = target.startsWith('/');
  if (target.length > 1024 || !_partCharacters.hasMatch(target)) _badPackage();
  final parts = rootRelative || owner.isEmpty
      ? <String>[]
      : (owner.split('/')..removeLast());
  for (final segment in (rootRelative ? target.substring(1) : target).split(
    '/',
  )) {
    if (segment == '..') {
      if (parts.isEmpty) _badPackage();
      parts.removeLast();
    } else if (segment != '.') {
      if (segment.isEmpty) _badPackage();
      parts.add(segment);
    }
  }
  final path = parts.join('/');
  if (!_safePart(path)) _badPackage();
  return path;
}

bool _safePart(String name) =>
    name.isNotEmpty &&
    name.length <= 1024 &&
    _partCharacters.hasMatch(name) &&
    name
        .split('/')
        .every(
          (part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              part.length <= 255 &&
              !part.endsWith('.'),
        );

bool _unsupportedPart(String value) {
  final name = value.toLowerCase();
  return name.contains('macroenabled') ||
      name.contains('vbaproject') ||
      name.contains('_xmlsignatures') ||
      name.contains('digital-signature');
}

XmlDocument _readXml(
  _PptxZip zip,
  String part,
  String rootName,
  String namespace,
) {
  final member = zip.members[part];
  if (member == null ||
      member.directory ||
      member.size == 0 ||
      member.size > _maxXmlBytes)
    _badPackage();
  final source = utf8.decode(member.read(zip.bytes, keep: true)!);
  if (_xmlDeclarations.hasMatch(source)) _badPackage();
  final xml = XmlDocument.parse(source);
  if (!_isElement(xml.rootElement, rootName, namespace)) _badPackage();
  final pending = <(XmlElement, int)>[(xml.rootElement, 1)];
  while (pending.isNotEmpty) {
    final (node, depth) = pending.removeLast();
    if (depth > 64) _badPackage();
    pending.addAll(node.childElements.map((child) => (child, depth + 1)));
  }
  return xml;
}

bool _isElement(XmlElement node, String name, String namespace) =>
    node.localName == name && node.namespaceUri == namespace;

Iterable<XmlElement> _elements(
  XmlElement node,
  String name,
  String namespace,
) => node.childElements.where((child) => _isElement(child, name, namespace));

XmlElement? _child(XmlElement node, String name, String namespace) {
  final matches = _elements(node, name, namespace).iterator;
  if (!matches.moveNext()) return null;
  final child = matches.current;
  if (matches.moveNext()) _badPackage();
  return child;
}

void _append(XmlElement parent, String name, Map<String, String> attributes) =>
    parent.children.add(
      XmlElement(XmlName(name, parent.name.prefix), [
        for (final attribute in attributes.entries)
          XmlAttribute(XmlName(attribute.key), attribute.value),
      ]),
    );

Never _badPackage() =>
    throw const FormatException('Invalid or unsupported PPTX package');

T _checked<T>(T Function() action) {
  try {
    return action();
  } on FormatException {
    rethrow;
  } catch (_) {
    _badPackage();
  }
}

final class _PptxZip {
  new(this.bytes) {
    if (bytes.length < 22 || bytes.length > _maxZipBytes) _badPackage();
    final data = ByteData.sublistView(bytes);
    int u16(int offset) => data.getUint16(offset, Endian.little);
    int u32(int offset) => data.getUint32(offset, Endian.little);
    var end = bytes.length - 22;
    final minimum = end - 65535;
    while (end >= 0 &&
        end >= minimum &&
        (u32(end) != 0x06054b50 || end + 22 + u16(end + 20) != bytes.length)) {
      end--;
    }
    if (end < 0 || end < minimum) _badPackage();
    // Match the decoder's unambiguous ZIP32 end record before giving it bytes.
    for (var index = end + 22; index + 4 <= bytes.length; index++) {
      if (u32(index) == 0x06054b50) _badPackage();
    }
    if (end >= 20 && u32(end - 20) == 0x07064b50) _badPackage();
    final count = u16(end + 10);
    final central = u32(end + 16);
    if (count < 1 ||
        count > _maxEntries ||
        u16(end + 4) != 0 ||
        u16(end + 6) != 0 ||
        u16(end + 8) != count ||
        central + u32(end + 12) != end) {
      _badPackage();
    }
    var offset = central;
    var expanded = 0;
    for (var i = 0; i < count; i++) {
      if (offset + 46 > end || u32(offset) != 0x02014b50) _badPackage();
      final length = u16(offset + 28);
      final next = offset + 46 + length + u16(offset + 30) + u16(offset + 32);
      if (next > end || length == 0) _badPackage();
      final nameBytes = Uint8List.sublistView(
        bytes,
        offset + 46,
        offset + 46 + length,
      );
      final name = utf8.decode(nameBytes);
      final directory = name.endsWith('/');
      final key = directory ? name.substring(0, name.length - 1) : name;
      if (!_safePart(key) ||
          _unsupportedPart(key) ||
          !names.add(key.toLowerCase()))
        _badPackage();
      final flags = u16(offset + 8);
      final method = u16(offset + 10);
      final crc = u32(offset + 16);
      final compressedSize = u32(offset + 20);
      final size = u32(offset + 24);
      final attributes = u32(offset + 38);
      final mode = (attributes >> 16) & 0xf000;
      final local = u32(offset + 42);
      expanded += size;
      if (flags & ~0x080e != 0 ||
          (method != 0 && method != 8) ||
          u16(offset + 34) != 0 ||
          attributes & 0x400 != 0 ||
          (mode != 0 && mode != (directory ? 0x4000 : 0x8000)) ||
          (!directory && attributes & 0x10 != 0) ||
          (directory && (size != 0 || crc != 0)) ||
          (method == 0 && size != compressedSize) ||
          size > _maxMemberBytes ||
          expanded > _maxExpandedBytes ||
          local + 30 > central ||
          u32(local) != 0x04034b50 ||
          u16(local + 6) != flags ||
          u16(local + 8) != method ||
          u16(local + 26) != length) {
        _badPackage();
      }
      final start = local + 30 + length + u16(local + 28);
      final dataEnd = start + compressedSize;
      if (dataEnd > central) _badPackage();
      for (var j = 0; j < length; j++) {
        if (bytes[local + 30 + j] != nameBytes[j]) _badPackage();
      }
      var last = dataEnd;
      if (flags & 8 != 0) {
        if (last + 12 > central) _badPackage();
        if (u32(last) == 0x08074b50) last += 4;
        if (last + 12 > central ||
            u32(last) != crc ||
            u32(last + 4) != compressedSize ||
            u32(last + 8) != size)
          _badPackage();
        last += 12;
      } else if (u32(local + 14) != crc ||
          u32(local + 18) != compressedSize ||
          u32(local + 22) != size) {
        _badPackage();
      }
      members[name] = _PptxZipMember(
        directory,
        size,
        method,
        crc,
        local,
        start,
        dataEnd,
        last,
      );
      offset = next;
    }
    if (offset != end) _badPackage();
    final files = {
      for (final entry in members.entries)
        if (!entry.value.directory) entry.key.toLowerCase(),
    };
    for (final name in names) {
      var slash = name.indexOf('/');
      while (slash >= 0) {
        if (files.contains(name.substring(0, slash))) _badPackage();
        slash = name.indexOf('/', slash + 1);
      }
    }
    final ordered = members.values.toList()
      ..sort((a, b) => a.local.compareTo(b.local));
    if (ordered.first.local != 0) _badPackage();
    for (var i = 1; i < ordered.length; i++) {
      if (ordered[i - 1].last > ordered[i].local) _badPackage();
    }
  }

  final Uint8List bytes;
  final members = <String, _PptxZipMember>{};
  final names = <String>{};

  Archive verifiedArchive() {
    for (final entry in members.entries) {
      final member = entry.value;
      final extension = p.posix.extension(entry.key).toLowerCase();
      final xml =
          !member.directory &&
          (extension == '.xml' || extension == '.rels' || extension == '.svg');
      if (xml && member.size > _maxXmlBytes) _badPackage();
      final content = member.read(bytes, keep: xml);
      if (content != null && _xmlDeclarations.hasMatch(utf8.decode(content))) {
        _badPackage();
      }
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    if (archive.length != members.length ||
        archive.files.any(
          (entry) => !members.containsKey(entry.name) || entry.isSymbolicLink,
        )) {
      archive.clearSync();
      _badPackage();
    }
    return archive;
  }
}

final class _PptxZipMember {
  const new(
    this.directory,
    this.size,
    this.method,
    this.crc,
    this.local,
    this.start,
    this.end,
    this.last,
  );
  final bool directory;
  final int size, method, crc, local, start, end, last;

  Uint8List? read(Uint8List zip, {required bool keep}) {
    final bytes = Uint8List.sublistView(zip, start, end);
    final sink = _PptxInflateSink(size, keep);
    if (method == 0) {
      sink.add(bytes);
    } else {
      final decoder = ZLibDecoder(raw: true).startChunkedConversion(sink);
      decoder.add(bytes);
      decoder.close();
    }
    if (sink.length != size || sink.crc != crc) _badPackage();
    return sink.output?.takeBytes();
  }
}

final class _PptxInflateSink implements Sink<List<int>> {
  new(this.expected, bool keep) : output = keep ? BytesBuilder() : null;
  final int expected;
  final BytesBuilder? output;
  var length = 0;
  var crc = 0;

  @override
  void add(List<int> chunk) {
    length += chunk.length;
    if (length > expected) _badPackage();
    crc = getCrc32(chunk, crc);
    output?.add(chunk);
  }

  @override
  void close() {}
}
