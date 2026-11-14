import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';

const _id = '11111111-1111-4111-8111-111111111111';

void main() {
  test('photo edits stage only host-owned relative files and bounded descriptors', () async {
    final directory = await Directory.systemTemp.createTemp('office-image-result-');
    addTearDown(() => directory.delete(recursive: true));
    final original = await File('${directory.path}/edited.pptx').writeAsBytes([1, 2, 3]);
    final pdf = await File('${directory.path}/preview.pdf').writeAsBytes([4, 5]);
    final hash = sha256.convert(await original.readAsBytes()).toString();
    final asset = WindowsOfficeImageAsset.fromBytes(im.encodePng(im.Image(width: 3, height: 2)));
    final engine = WindowsOfficeEngine(runner: (request) async {
      expect(request['imageAssets'], [
        {
          'id': _id, 'fileName': 'assets/$_id.png',
          'mimeType': 'image/png', 'byteLength': asset.byteLength,
          'sha256': asset.sha256, 'width': 3, 'height': 2,
        },
      ]);
      expect(request.containsKey('assetDirectory'), isFalse);
      return {
        'status': 'saved', 'sessionId': 'photo-session',
        'sourcePath': original.path, 'pdfPath': pdf.path,
        'sourceSha256': hash, 'pdfSha256': sha256.convert(await pdf.readAsBytes()).toString(),
        'pdfPageCount': 1, 'engineVersion': 'fixture',
        'snapshot': {'kind': 'presentation', 'sourceSha256': hash, 'paragraphs': [], 'tables': [], 'slides': []},
      };
    });
    final result = await engine.apply('input.pptx', sessionId: 'photo-session',
      operations: [WindowsOfficeOperation.imageAdd(id: 'photo', slideId: 'slide-0', assetId: _id,
        x: 10, y: 20, width: 30, height: 40)], imageAssets: {_id: asset});
    expect(result.sourceSha256, hash);
  });

  test('unknown image identity and unused or path-shaped assets never reach a worker', () async {
    final asset = WindowsOfficeImageAsset.fromBytes(im.encodePng(im.Image(width: 2, height: 2)));
    var called = false;
    final engine = WindowsOfficeEngine(runner: (_) async {
      called = true;
      throw StateError('Unsafe photo request reached the worker');
    });
    for (final entry in <(List<WindowsOfficeOperation>, Map<String, WindowsOfficeImageAsset>)>[
      ([WindowsOfficeOperation.imageReplace(id: 'slide-0/shape-0', assetId: _id)], {}),
      ([], {_id: asset}),
      ([WindowsOfficeOperation.imageReplace(id: 'slide-0/shape-0', assetId: '../photo')], {'../photo': asset}),
    ]) {
      await expectLater(engine.apply('input.pptx', sessionId: 'reject',
        operations: entry.$1, imageAssets: entry.$2), throwsFormatException);
    }
    expect(called, isFalse);
  });
}
