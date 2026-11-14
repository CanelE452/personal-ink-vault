import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

Map<String, dynamic> _shape(String id, {String? ownerKind, String? ownerId,
  bool? presentation, bool? empty, bool? canEditGeometry, bool? canDelete,
  bool? canEditTextStyle,
}) => {
  'id': id, 'type': 'com.sun.star.drawing.CustomShape', 'text': 'content',
  'editableText': true, 'x': 1, 'y': 2, 'width': 30, 'height': 20,
  'ownerKind': ?ownerKind, 'ownerId': ?ownerId,
  'presentationObject': ?presentation, 'emptyPresentationObject': ?empty,
  'canEditGeometry': ?canEditGeometry, 'canDelete': ?canDelete,
  'canEditTextStyle': ?canEditTextStyle,
};

Map<String, dynamic> _snapshot(String hash) => {
  'kind': 'presentation', 'sourceSha256': hash,
  'paragraphs': [], 'tables': [], 'slides': [],
};

void main() {
  test('presentation snapshot keeps actual master ownership, design and placeholder capabilities', () {
    final data = _snapshot('a' * 64);
    data['masters'] = [
      {'id': 'master-0', 'name': 'Actual shared design', 'width': 280, 'height': 157.5,
        'backgroundStyle': 'solid', 'backgroundColor': 0xEEDDEE,
        'shapes': [_shape('master-0/shape-0', ownerKind: 'master', ownerId: 'master-0',
          presentation: true, empty: true, canEditGeometry: false, canDelete: false,
          canEditTextStyle: false)]},
    ];
    data['layoutOptions'] = [
      {'code': 0, 'label': 'Title'}, {'code': 1, 'label': 'Title and content'},
      {'code': 19, 'label': 'Title only'}, {'code': 20, 'label': 'Blank'},
    ];
    data['slides'] = [
      {'id': 'slide-0', 'width': 280, 'height': 157.5, 'masterId': 'master-0',
        'layoutCode': 20, 'designSha256': 'b' * 64, 'visible': false,
        'showMasterObjects': false, 'shapes': [_shape('slide-0/shape-0',
          ownerKind: 'slide', ownerId: 'slide-0', presentation: false, empty: false,
          canEditGeometry: true, canDelete: true, canEditTextStyle: true)]},
    ];
    final dynamic snapshot = WindowsOfficeSnapshot.fromJson(data);
    final dynamic master = snapshot.masters.single;
    expect(master.id, 'master-0');
    expect(master.name, 'Actual shared design');
    expect([master.width, master.height], [280, 157.5]);
    expect(master.backgroundStyle, 'solid');
    expect(master.backgroundColor, 0xEEDDEE);
    final dynamic template = master.shapes.single;
    expect([template.ownerKind, template.ownerId], ['master', 'master-0']);
    expect(template.presentationObject, isTrue);
    expect(template.emptyPresentationObject, isTrue);
    expect(template.canEditGeometry, isFalse);
    expect(template.canDelete, isFalse);
    expect(template.canEditTextStyle, isFalse);
    final dynamic slide = snapshot.slides.single;
    expect([slide.masterId, slide.layoutCode, slide.designSha256], ['master-0', 20, 'b' * 64]);
    expect(slide.visible, isFalse);
    expect(slide.showMasterObjects, isFalse);
    expect([slide.shapes.single.ownerKind, slide.shapes.single.ownerId], ['slide', 'slide-0']);
    expect([for (final dynamic option in snapshot.layoutOptions) option.code], [0, 1, 19, 20]);
    expect(snapshot.layoutOptions.first.label, 'Title');
  });

  test('old snapshots keep design unknown and retain legacy shape edit defaults', () {
    final data = _snapshot('a' * 64);
    data['slides'] = [
      {'id': 'slide-0', 'width': 280, 'height': 157.5,
        'shapes': [_shape('slide-0/shape-0')]},
    ];
    final dynamic snapshot = WindowsOfficeSnapshot.fromJson(data);
    final dynamic slide = snapshot.slides.single;
    final dynamic shape = slide.shapes.single;
    expect(snapshot.masters, isNull);
    expect(snapshot.layoutOptions, isEmpty);
    expect(slide.masterId, isNull);
    expect(slide.layoutCode, isNull);
    expect(slide.designSha256, isNull);
    expect(slide.visible, isNull);
    expect(slide.showMasterObjects, isNull);
    expect(shape.ownerKind, isNull);
    expect(shape.ownerId, isNull);
    expect(shape.presentationObject, isNull);
    expect(shape.emptyPresentationObject, isNull);
    expect(shape.canEditGeometry, isTrue);
    expect(shape.canDelete, isTrue);
    expect(shape.canEditTextStyle, isTrue);
  });

  test('requested live draft is separate from canonical hash and must match the original source', () async {
    final directory = await Directory.systemTemp.createTemp('office-design-result-');
    addTearDown(() => directory.delete(recursive: true));
    final input = await File('${directory.path}/input.pptx').writeAsBytes([1, 2, 3]);
    final edited = await File('${directory.path}/edited.pptx').writeAsBytes([4, 5, 6]);
    final pdf = await File('${directory.path}/preview.pdf').writeAsBytes([7, 8]);
    final sourceHash = sha256.convert(await input.readAsBytes()).toString();
    final editedHash = sha256.convert(await edited.readAsBytes()).toString();
    for (final draftHash in <String?>[sourceHash, null, '0' * 64]) {
      final dynamic engine = WindowsOfficeEngine(runner: (request) async {
        expect(request['includeDraftSnapshot'], isTrue);
        return {
          'status': 'saved', 'sessionId': 'design-session', 'sourcePath': edited.path,
          'pdfPath': pdf.path, 'sourceSha256': editedHash,
          'pdfSha256': sha256.convert(await pdf.readAsBytes()).toString(),
          'pdfPageCount': 1, 'engineVersion': 'fixture', 'snapshot': _snapshot(editedHash),
          if (draftHash != null) 'draftSnapshot': _snapshot(draftHash),
        };
      });
      final Future<dynamic> pending = engine.apply(input.path,
        sessionId: 'design-session', operations: <WindowsOfficeOperation>[],
        expectedSourceSha256: sourceHash, includeDraftSnapshot: true);
      if (draftHash == sourceHash) {
        final dynamic result = await pending;
        expect(result.snapshot.sourceSha256, editedHash);
        expect(result.draftSnapshot.sourceSha256, sourceHash);
      } else {
        await expectLater(pending, throwsA(isA<WindowsOfficeException>()));
      }
    }
  });
}
