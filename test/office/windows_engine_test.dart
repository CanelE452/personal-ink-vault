import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

Map<String, dynamic> snapshot(String hash) => {
  'kind': 'word',
  'sourceSha256': hash,
  'paragraphs': [
    {
      'id': 'paragraph-0',
      'text': '제목',
      'fontSize': 22,
      'bold': true,
      'color': 0,
    },
  ],
  'tables': [
    {
      'id': 'Table1',
      'cells': {'A1': '셀'},
    },
  ],
  'slides': [],
};

void main() {
  test('presentation snapshot exposes authored geometry and appearance without dropping unsupported styles', () {
    final result = WindowsOfficeSnapshot.fromJson({
      'kind': 'presentation',
      'sourceSha256': 'a' * 64,
      'paragraphs': [],
      'tables': [],
      'slides': [
        {
          'id': 'slide-0',
          'width': 254,
          'height': 142.875,
          'backgroundStyle': 'solid',
          'backgroundColor': 0xF0E0D0,
          'shapes': [
            {
              'id': 'slide-0/shape-0',
              'type': 'com.sun.star.drawing.CustomShape',
              'shapeKind': 'rectangle',
              'text': 'literal macro://text',
              'editableText': true,
              'x': 1,
              'y': 2,
              'width': 30,
              'height': 20,
              'fillStyle': 'gradient',
              'fillColor': 0x112233,
              'lineStyle': 'dash',
              'lineColor': 0x445566,
              'lineWidth': .75,
              'canEditFill': true,
              'canEditLine': true,
            },
            {
              'id': 'slide-0/shape-1',
              'type': 'com.sun.star.drawing.LineShape',
              'shapeKind': 'line',
              'text': '',
              'editableText': false,
              'x': 10,
              'y': 20,
              'width': 70,
              'height': 0,
              'fillStyle': 'none',
              'lineStyle': 'solid',
              'lineColor': 0,
              'lineWidth': 0,
              'canEditFill': false,
              'canEditLine': true,
            },
          ],
        },
      ],
    });
    final dynamic slide = result.slides.single;
    expect(slide.backgroundStyle, 'solid');
    expect(slide.backgroundColor, 0xF0E0D0);
    final dynamic rectangle = result.slides.single.shapes.first;
    expect(rectangle.shapeKind, 'rectangle');
    expect(rectangle.fillStyle, 'gradient');
    expect(rectangle.lineStyle, 'dash');
    expect(rectangle.lineWidth, .75);
    expect(rectangle.canEditFill, isTrue);
    final dynamic line = result.slides.single.shapes.last;
    expect(line.shapeKind, 'line');
    expect(line.height, 0);
    expect(line.lineColor, 0);
    expect(line.lineWidth, 0);
    expect(line.canEditFill, isFalse);
  });

  test('older presentation snapshots retain absent appearance metadata', () {
    final result = WindowsOfficeSnapshot.fromJson({
      'kind': 'presentation',
      'sourceSha256': 'a' * 64,
      'paragraphs': [],
      'tables': [],
      'slides': [
        {
          'id': 'slide-0',
          'width': 254,
          'height': 142.875,
          'shapes': [
            {
              'id': 'slide-0/shape-0',
              'type': 'TextShape',
              'text': 'Existing',
              'editableText': true,
              'x': 0,
              'y': 0,
              'width': 30,
              'height': 20,
            },
          ],
        },
      ],
    });
    final dynamic shape = result.slides.single.shapes.single;
    expect(shape.shapeKind, isNull);
    expect(shape.fillStyle, isNull);
    expect(shape.lineStyle, isNull);
    expect(shape.canEditFill, isFalse);
    expect(shape.canEditLine, isFalse);
    final dynamic slide = result.slides.single;
    expect(slide.backgroundStyle, isNull);
    expect(slide.backgroundColor, isNull);
  });

  test('new PPT operations retain literal content stable aliases zero lines and explicit style intent', () {
    final operations = [
      WindowsOfficeOperation.shapeAdd(
        id: 'draft-line',
        slideId: 'slide-0',
        shapeKind: 'line',
        x: 10,
        y: 20,
        width: 70,
        height: 0,
      ),
      WindowsOfficeOperation.shapeAppearance(
        'draft-line',
        lineStyle: 'solid',
        lineColor: 0,
        lineWidth: 0,
      ),
      WindowsOfficeOperation.shapeAdd(
        id: 'draft-text',
        slideId: 'slide-0',
        shapeKind: 'text',
        x: 10,
        y: 30,
        width: 90,
        height: 20,
        text: 'macro://literal',
      ),
      WindowsOfficeOperation.shapeDelete('slide-0/shape-0'),
      WindowsOfficeOperation.slideBackground('slide-0', fillStyle: 'none'),
    ].map((operation) => operation.toJson()).toList();
    expect(operations[0], {
      'op': 'shapeAdd',
      'id': 'draft-line',
      'slideId': 'slide-0',
      'shapeKind': 'line',
      'x': 10,
      'y': 20,
      'width': 70,
      'height': 0,
      'text': '',
    });
    expect(operations[1], {
      'op': 'shapeAppearance',
      'id': 'draft-line',
      'lineStyle': 'solid',
      'lineColor': 0,
      'lineWidth': 0,
    });
    expect(operations[2]['text'], 'macro://literal');
    expect(operations[3], {'op': 'shapeDelete', 'id': 'slide-0/shape-0'});
    expect(operations[4], {
      'op': 'slideBackground',
      'id': 'slide-0',
      'fillStyle': 'none',
    });
  });

  test(
    'optional initial preview is bound to inspected source without an edit',
    () async {
      final engine = WindowsOfficeEngine(
        runner: (request) async {
          expect(request['mode'], 'inspect');
          expect(request['preview'], true);
          expect(request.containsKey('operations'), false);
          return {
            'snapshot': {
              ...snapshot('a' * 64),
              'previewPdfPath': 'initial-preview.pdf',
              'previewPageCount': 3,
            },
          };
        },
      );
      final result = await engine.inspect('materialized.docx', preview: true);
      expect(result.sourceSha256, 'a' * 64);
      expect(result.previewPdfPath, 'initial-preview.pdf');
      expect(result.previewPageCount, 3);
    },
  );

  test(
    'inspection exposes editable document objects and style units',
    () async {
      final engine = WindowsOfficeEngine(
        runner: (_) async => {'snapshot': snapshot('a' * 64)},
      );
      final result = await engine.inspect('materialized.docx');
      expect(result.kind, 'word');
      expect(result.paragraphs.single.fontSize, 22);
      expect(result.tables.single.cells['A1'], '셀');
      expect(result.previewPdfPath, isNull);
      expect(result.previewPageCount, isNull);
    },
  );

  test('typed changes keep text literal and represent actual slide geometry and ordering', () {
    expect(
      WindowsOfficeOperation.shapeText(
        'slide-0/shape-0',
        'macro://literal',
      ).toJson(),
      {'op': 'shapeText', 'id': 'slide-0/shape-0', 'text': 'macro://literal'},
    );
    expect(
      WindowsOfficeOperation.shapeGeometry(
        'slide-0/shape-0',
        x: 32,
        y: 41,
        width: 110,
        height: 45,
      ).toJson()['x'],
      32,
    );
    expect(WindowsOfficeOperation.slideMove('slide-1', 0).toJson(), {
      'op': 'slideMove',
      'id': 'slide-1',
      'index': 0,
    });
  });

  test(
    'saved result checks physical output hashes and reopened source identity',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'windows-office-contract-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final edited = await File('${temp.path}/edited.docx')
          .writeAsBytes([1, 2, 3]);
      final pdf = await File('${temp.path}/preview.pdf')
          .writeAsBytes([4, 5, 6]);
      final sourceHash = sha256.convert(await edited.readAsBytes()).toString();
      final pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
      final engine = WindowsOfficeEngine(
        runner: (request) async {
          expect(request['expectedSourceSha256'], 'a' * 64);
          return {
            'status': 'saved',
            'sessionId': 's1',
            'sourcePath': edited.path,
            'pdfPath': pdf.path,
            'sourceSha256': sourceHash,
            'pdfSha256': pdfHash,
            'pdfPageCount': 1,
            'engineVersion': 'test-engine',
            'snapshot': snapshot(sourceHash),
          };
        },
      );
      final result = await engine.apply(
        'materialized.docx',
        operations: [],
        sessionId: 's1',
        expectedSourceSha256: 'a' * 64,
      );
      expect(result.sourceSha256, sourceHash);
      expect(result.pdfPageCount, 1);
      await pdf.writeAsBytes([7]);
      await expectLater(
        engine.apply(
          'materialized.docx',
          operations: [],
          sessionId: 's1',
          expectedSourceSha256: 'a' * 64,
        ),
        throwsA(
          isA<WindowsOfficeException>().having(
            (e) => e.code,
            'code',
            'office_payload_mismatch',
          ),
        ),
      );
    },
  );

  test('PDF-only output cannot stand in for a saved original', () async {
    final engine = WindowsOfficeEngine(
      runner: (_) async => {
        'status': 'saved',
        'sessionId': 's1',
        'pdfPath': 'preview.pdf',
      },
    );
    await expectLater(
      engine.apply('materialized.docx', operations: [], sessionId: 's1'),
      throwsA(
        isA<WindowsOfficeException>().having(
          (e) => e.code,
          'code',
          'invalid_office_result',
        ),
      ),
    );
  });
}
