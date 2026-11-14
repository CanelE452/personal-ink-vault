import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:path/path.dart' as path;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/office/pptx_photo_replacement.dart';
import 'package:saber/data/office/windows_office_engine.dart';

import 'pptx_photo_replacement_test.dart'
    show pptxPhotoFixture, pptxReplacementPhoto;

void main() {
  const office = String.fromEnvironment('PIV_PPTX_PHOTO_NATIVE_OFFICE');
  test(
    'bundled LibreOffice reopens the patched PPTX and renders its slide',
    () async {
      expect(path.isAbsolute(office), isTrue);
      final engine = WindowsOfficeEngine(
        runtimePath: path.join(office, 'runtime'),
        helperDirectory: office,
      );
      expect(await engine.available, isTrue);

      final stage = await _nativePhotoStage();

      final source = pptxPhotoFixture();
      final original = await File(path.join(stage.path, 'original.pptx'))
          .writeAsBytes(source);
      final target = listPptxPhotos(source)
          .singleWhere((photo) => photo.name == 'Target photo');
      final edited = replacePptxPhoto(source, target, pptxReplacementPhoto());
      final patched = await File(path.join(stage.path, 'patched.pptx'))
          .writeAsBytes(edited);

      final before = await engine.inspect(original.path);
      final after = await engine.inspect(patched.path, preview: true);
      addTearDown(after.disposePreview);
      expect(before.sourceSha256, sha256.convert(source).toString());
      expect(after.sourceSha256, sha256.convert(edited).toString());
      expect(after.sourceSha256, isNot(before.sourceSha256));
      expect(await original.readAsBytes(), source);

      final originalSlide = before.slides.single;
      final patchedSlide = after.slides.single;
      expect(patchedSlide.shapes.map(_shape), originalSlide.shapes.map(_shape));
      final originalPhotos = originalSlide.shapes
          .map((shape) => shape.image)
          .whereType<WindowsOfficeImageDetails>()
          .toList();
      final patchedPhotos = patchedSlide.shapes
          .map((shape) => shape.image)
          .whereType<WindowsOfficeImageDetails>()
          .toList();
      expect(originalPhotos.map(_pixels), List.filled(3, (31, 19)));
      expect(patchedPhotos.map(_pixels), [(47, 29), (31, 19), (31, 19)]);
      expect(
        patchedPhotos.map((image) => image.rotationHundredths),
        originalPhotos.map((image) => image.rotationHundredths),
      );
      expect(patchedPhotos.map(_color), [
        (230, 105, 40),
        (35, 85, 210),
        (35, 85, 210),
      ]);
      expect(after.previewPageCount, 1);
      final pdf = await File(after.previewPdfPath!).readAsBytes();
      expect(ascii.decode(pdf.take(5).toList()), '%PDF-');
      expect(pdf.length, greaterThan(1000));
    },
    skip: !Platform.isWindows || office.isEmpty
        ? 'Set PIV_PPTX_PHOTO_NATIVE_OFFICE to a bundled Windows Office folder.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'bundled Impress reopens the deletion and PDFium sees only the selected photo disappear',
    () async {
      expect(path.isAbsolute(office), isTrue);
      final engine = WindowsOfficeEngine(
        runtimePath: path.join(office, 'runtime'),
        helperDirectory: office,
      );
      expect(await engine.available, isTrue);
      final pdfium = File(path.join(path.dirname(office), 'pdfium.dll'));
      expect(pdfium.existsSync(), isTrue);
      final previousModule = Pdfrx.pdfiumModulePath;
      Pdfrx.pdfiumModulePath = pdfium.path;
      addTearDown(() => Pdfrx.pdfiumModulePath = previousModule);
      final stage = await _nativePhotoStage();
      await pdfrxInitialize(tmpPath: stage.path);

      final originalBytes = pptxPhotoFixture();
      final target = listPptxDeletablePhotos(originalBytes)
          .singleWhere((photo) => photo.name == 'Target photo');
      final changedBytes = deletePptxPhoto(originalBytes, target);
      final original = await File(path.join(stage.path, 'original.pptx'))
          .writeAsBytes(originalBytes);
      final changed = await File(path.join(stage.path, 'deleted.pptx'))
          .writeAsBytes(changedBytes);

      final before = await engine.inspect(original.path, preview: true);
      addTearDown(before.disposePreview);
      final after = await engine.inspect(changed.path, preview: true);
      addTearDown(after.disposePreview);
      expect(before.previewPageCount, 1);
      expect(after.previewPageCount, 1);
      expect(await original.readAsBytes(), originalBytes);
      expect(after.sourceSha256, sha256.convert(changedBytes).toString());
      final beforeSlide = before.slides.single;
      final afterSlide = after.slides.single;
      final pictures = beforeSlide.shapes
          .where((shape) => shape.image != null)
          .toList();
      expect(pictures, hasLength(3));
      expect(
        afterSlide.shapes.map(_shape),
        beforeSlide.shapes
            .where((shape) => shape != pictures.first)
            .map(_shape),
      );
      final points = [
        for (final picture in pictures)
          (
            (picture.x + picture.width / 2) / beforeSlide.width,
            (picture.y + picture.height / 2) / beforeSlide.height,
          ),
      ];
      final oldPixels = await _samplePdf(before.previewPdfPath!, points);
      final newPixels = await _samplePdf(after.previewPdfPath!, points);
      expect(oldPixels, everyElement(_isBluePhoto));
      expect(newPixels.first, _isWhitePaper);
      expect(newPixels.skip(1), oldPixels.skip(1));
    },
    skip: !Platform.isWindows || office.isEmpty
        ? 'Set PIV_PPTX_PHOTO_NATIVE_OFFICE to a bundled Windows Office folder.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<Directory> _nativePhotoStage() async {
  final temp = Directory(await Directory.systemTemp.resolveSymbolicLinks());
  final stage = await temp.createTemp('piv-pptx-photo-');
  addTearDown(() async {
    final resolved = await stage.resolveSymbolicLinks();
    expect(path.equals(resolved, stage.path), isTrue);
    expect(path.equals(path.dirname(resolved), temp.path), isTrue);
    expect(path.basename(resolved), startsWith('piv-pptx-photo-'));
    await Directory(resolved).delete(recursive: true);
  });
  return stage;
}

Future<List<(int, int, int)>> _samplePdf(
  String filename,
  List<(double, double)> points,
) async {
  final document = await PdfDocument.openData(
    await File(filename).readAsBytes(),
  );
  try {
    final page = document.pages.single;
    const width = 320, height = 240;
    final rendered = (await page.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
    ))!;
    try {
      final pixels = rendered.pixels;
      final samples = <(int, int, int)>[];
      for (final (x, y) in points) {
        final offset = ((y * height).floor() * width + (x * width).floor()) * 4;
        samples.add((pixels[offset + 2], pixels[offset + 1], pixels[offset]));
      }
      return samples;
    } finally {
      rendered.dispose();
    }
  } finally {
    await document.dispose();
  }
}

final _isBluePhoto = predicate<(int, int, int)>((pixel) {
  final (red, green, blue) = pixel;
  return red < 100 && green < 160 && blue > 150;
}, 'is the blue photo');

final _isWhitePaper = predicate<(int, int, int)>((pixel) {
  final (red, green, blue) = pixel;
  return red >= 240 && green >= 240 && blue >= 240;
}, 'is the white slide background');

(String, String, double, double, double, double) _shape(
  WindowsOfficeShape shape,
) => (shape.type, shape.text, shape.x, shape.y, shape.width, shape.height);

(int?, int?) _pixels(WindowsOfficeImageDetails image) =>
    (image.pixelWidth, image.pixelHeight);

(int, int, int) _color(WindowsOfficeImageDetails image) {
  final pixel = im.decodePng(image.thumbnailBytes!)!.getPixel(0, 0);
  return (pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt());
}
