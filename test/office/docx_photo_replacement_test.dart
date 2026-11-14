import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/docx_photo_replacement.dart';
import 'package:saber/data/office/office_templates.dart';

import 'pptx_photo_replacement_test.dart' show pptxReplacementPhoto;

const _fixtureSha =
    'f97f59f0ac18f86879fa7d11d9e935acf1b9ec46ed2ab1f866e524f8c3266d22';

Uint8List docxPhotoFixture(
  Uint8List original, {
  Uint8List? replacement,
  bool removeSecond = false,
  bool rotateSecond = false,
}) {
  const relationships =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  const drawing = 'http://schemas.openxmlformats.org/drawingml/2006';
  String photo(int id, String relation) =>
      '''
<w:p><w:r><w:drawing><wp:inline xmlns:wp="$drawing/wordprocessingDrawing"
 xmlns:a="$drawing/main" xmlns:pic="$drawing/picture" xmlns:r="$relationships">
  <wp:extent cx="360000" cy="240000"/>
  <wp:docPr id="$id" name="Photo $id"/>
  <a:graphic><a:graphicData uri="$drawing/picture"><pic:pic>
    <pic:nvPicPr><pic:cNvPr id="$id" name="Photo $id"/><pic:cNvPicPr/></pic:nvPicPr>
    <pic:blipFill><a:blip r:embed="$relation"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
    <pic:spPr><a:xfrm${rotateSecond && id == 2 ? ' rot="5400000"' : ''}><a:off x="0" y="0"/><a:ext cx="360000" cy="240000"/></a:xfrm>
      <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
  </pic:pic></a:graphicData></a:graphic>
</wp:inline></w:drawing></w:r></w:p>''';
  String imageRelation(String id, String name) =>
      '<Relationship Id="$id" Type="$relationships/image" Target="media/$name"/>';
  final second = removeSecond
      ? '<w:p><w:r></w:r></w:p>'
      : photo(2, replacement == null ? 'rIdPhoto' : 'rIdEdited');
  final template = OfficeTemplates.create(
    OfficeTemplateKind.document,
    title: 'Photo note',
  );
  final input = ZipDecoder().decodeBytes(template.bytes);
  final output = Archive();
  for (final part in input.files) {
    final edited = switch (part.name) {
      '[Content_Types].xml' =>
        utf8
            .decode(part.content)
            .replaceFirst(
              '</Types>',
              '<Default Extension="png" ContentType="image/png"/></Types>',
            ),
      'word/document.xml' =>
        utf8
            .decode(part.content)
            .replaceFirst(
              '<w:sectPr>',
              '${photo(1, 'rIdPhoto')}$second<w:sectPr>',
            ),
      'word/_rels/document.xml.rels' =>
        utf8
            .decode(part.content)
            .replaceFirst(
              '</Relationships>',
              '${imageRelation('rIdPhoto', 'shared.png')}'
                  '${replacement == null ? '' : imageRelation('rIdEdited', 'edited.png')}'
                  '</Relationships>',
            ),
      _ => null,
    };
    output.addFile(
      edited == null
          ? ArchiveFile.bytes(part.name, part.content)
          : ArchiveFile.string(part.name, edited),
    );
  }
  output.addFile(ArchiveFile.bytes('word/media/shared.png', original));
  if (replacement != null) {
    output.addFile(ArchiveFile.bytes('word/media/edited.png', replacement));
  }
  return Uint8List.fromList(ZipEncoder().encode(output));
}

void main() {
  final fixture = Platform.environment['PIV_DOCX_PHOTO_TEST_FIXTURE'];
  final library = Platform.environment['PIV_DOCX_PHOTO_TEST_LIBRARY'];
  test(
    'DOCX Rust adapter edits one shared-media photo',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'piv-docx-photo-',
      );
      final source = File(p.join(directory.path, 'source.docx'));
      final output = File(p.join(directory.path, 'edited.docx'));
      final removedOutput = File(p.join(directory.path, 'removed.docx'));
      final rotatedOutput = File(p.join(directory.path, 'rotated.docx'));
      final asset = File(p.join(directory.path, 'replacement.image'));
      addTearDown(() async {
        for (final file in [source, output, removedOutput, rotatedOutput, asset]) {
          if (file.existsSync()) await file.delete();
        }
        await directory.delete();
      });
      await File(fixture!).copy(source.path);
      final original = await source.readAsBytes();
      expect(sha256.convert(original).toString(), _fixtureSha);
      final image = pptxReplacementPhoto();
      await asset.writeAsBytes(image.bytes, flush: true);
      final engine = DocxPhotoReplacementEngine(libraryPath: library);
      final plan = await engine.inspect(
        sourcePath: source.path,
        sourceSha256: _fixtureSha,
      );
      expect(plan.photos.map((photo) => photo.index), [0, 1, 2]);
      final first = plan.photos.first;
      expect(
        plan.photos.map((photo) => photo.mediaPart),
        everyElement(first.mediaPart),
      );
      expect(
        plan.photos.map((photo) => photo.mediaSha256),
        everyElement(first.mediaSha256),
      );
      expect(readDocxPhotoPreview(original, first), isNotNull);
      final editedSha = await engine.replace(
        sourcePath: source.path,
        plan: plan,
        photoIndex: 1,
        outputPath: output.path,
        assetPath: asset.path,
        assetSha256: image.sha256,
      );
      final edited = await output.readAsBytes();
      expect(sha256.convert(edited).toString(), editedSha);
      final reopened = await engine.inspect(
        sourcePath: output.path,
        sourceSha256: editedSha,
      );
      expect(reopened.photos.map((photo) => photo.mediaSha256), [
        first.mediaSha256,
        image.sha256,
        first.mediaSha256,
      ]);
      expect(readDocxPhotoPreview(edited, reopened.photos[1]), image.bytes);
      expect(
        readDocxPhotoPreview(edited, reopened.photos.first),
        readDocxPhotoPreview(original, first),
      );

      final removedSha = await engine.remove(
        sourcePath: source.path,
        plan: plan,
        photoIndex: 1,
        outputPath: removedOutput.path,
      );
      expect(
        sha256.convert(await removedOutput.readAsBytes()).toString(),
        removedSha,
      );
      final remaining = await engine.inspect(
        sourcePath: removedOutput.path,
        sourceSha256: removedSha,
      );
      expect(remaining.photos.map((photo) => photo.index), [0, 1]);
      expect(remaining.photos.map((photo) => photo.title), [
        first.title,
        plan.photos.last.title,
      ]);
      expect(
        remaining.photos.map((photo) => photo.mediaSha256),
        everyElement(first.mediaSha256),
      );
      final rotatedSha = await engine.rotate(
        sourcePath: source.path,
        plan: plan,
        photoIndex: 1,
        outputPath: rotatedOutput.path,
      );
      final rotated = await rotatedOutput.readAsBytes();
      expect(sha256.convert(rotated).toString(), rotatedSha);
      final rotatedPlan = await engine.inspect(
        sourcePath: rotatedOutput.path,
        sourceSha256: rotatedSha,
      );
      expect(rotatedPlan.photos.map((photo) => photo.title),
        plan.photos.map((photo) => photo.title),
      );
      expect(rotatedPlan.photos.map((photo) => photo.mediaSha256),
        everyElement(first.mediaSha256),
      );
      expect(await source.readAsBytes(), original);
    },
    skip: fixture == null || library == null
        ? 'Set PIV_DOCX_PHOTO_TEST_FIXTURE and PIV_DOCX_PHOTO_TEST_LIBRARY'
        : false,
  );
}
