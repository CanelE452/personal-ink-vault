import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/hwp_office_engine.dart';

String digest(String text) => sha256.convert(utf8.encode(text)).toString();

void main() {
  late Directory directory;
  late File source;
  late File edited;
  late File pdf;
  late String sourceHash;
  late String editedHash;
  late String pdfHash;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'piv-hwp-character-contract-',
    );
    source = await File('${directory.path}/original.hwpx')
        .writeAsBytes([1, 2, 3]);
    edited = await File('${directory.path}/edited.hwpx')
        .writeAsBytes([4, 5, 6]);
    pdf = await File('${directory.path}/preview.pdf')
        .writeAsString('%PDF-1.7\nfixture');
    sourceHash = sha256.convert(await source.readAsBytes()).toString();
    editedHash = sha256.convert(await edited.readAsBytes()).toString();
    pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
  });
  tearDown(() async {
    expect(
      await directory.parent.resolveSymbolicLinks(),
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    expect(
      directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
      startsWith('piv-hwp-character-contract-'),
    );
    await directory.delete(recursive: true);
  });

  Map<String, dynamic> response(Map<String, Object?> request) => {
    'status': 'saved',
    'sessionId': request['sessionId'],
    'sourcePath': edited.path,
    'pdfPath': pdf.path,
    'sourceSha256': editedHash,
    'pdfSha256': pdfHash,
    'pdfPageCount': 1,
    'engineVersion': 'synthetic-contract',
    'snapshot': {
      'kind': 'word',
      'sourceSha256': editedHash,
      'paragraphs': [],
      'tables': [],
      'slides': [],
    },
  };

  Map<String, Object?> style({
    bool cell = false,
    Map<String, Object?> properties = const {
      'bold': true,
      'fontSize': 18.5,
      'color': 0x1267ab,
    },
  }) => {
    'op': 'textStyle',
    'targetKind': cell ? 'cell' : 'paragraph',
    'id': cell ? 's0:p1:t0' : 's0:p0',
    if (cell) 'cell': '0,0',
    'startUtf16': 1,
    'endUtf16': 3,
    'expectedTextSha256': digest('한😀글'),
    ...properties,
  };
  Map<String, Object?> replacement() => {
    'op': 'textReplace',
    'targetKind': 'paragraph',
    'id': 's0:p0',
    'startUtf16': 3,
    'endUtf16': 3,
    'expectedTextSha256': digest('한😀글'),
    'text': '새',
  };

  for (final cell in [false, true]) {
    test(
      'HWP forwards selected ${cell ? 'cell' : 'paragraph'} style without widening permissions',
      () async {
        List<Object?>? forwarded;
        final engine = HwpOfficeEngine(
          runner: (request) async {
            forwarded = request['operations'] as List;
            expect(request['expectedSourceSha256'], sourceHash);
            return response(request);
          },
        );
        final operation = style(cell: cell);
        await engine.apply(
          source.path,
          sessionId: 'range-style',
          operations: [operation],
          expectedSourceSha256: sourceHash,
        );
        expect(forwarded, [operation]);
        expect(
          sha256.convert(await source.readAsBytes()).toString(),
          sourceHash,
        );
      },
    );
  }

  test('HWP forwards italic-only enable and disable operations', () async {
    final operations = [
      for (final italic in [true, false]) style(properties: {'italic': italic}),
    ];
    final engine = HwpOfficeEngine(
      runner: (request) async {
        expect(request['operations'], operations);
        return response(request);
      },
    );
    await engine.apply(
      source.path,
      sessionId: 'italic-only',
      operations: operations,
    );
  });

  for (final extension in ['hwp', 'hwpx']) {
    test('HWP forwards underline enable and disable for $extension', () async {
      final input = extension == 'hwp'
          ? await source.copy('${directory.path}/original.hwp')
          : source;
      final operations = [
        style(properties: {'underline': true}),
        style(cell: true, properties: {'underline': false}),
      ];
      var forwarded = false;
      final engine = HwpOfficeEngine(
        runner: (request) async {
          expect(request['operations'], operations);
          expect(request['expectedSourceSha256'], sourceHash);
          forwarded = true;
          return response(request);
        },
      );
      await engine.apply(
        input.path,
        sessionId: 'underline',
        operations: operations,
      );
      expect(forwarded, isTrue);
    });
  }

  test(
    'HWP keeps ordered current-text digests for replacement then formatting',
    () async {
      List<Object?>? forwarded;
      final engine = HwpOfficeEngine(
        runner: (request) async {
          forwarded = request['operations'] as List;
          return response(request);
        },
      );
      final operations = [
        replacement(),
        {
          ...style(),
          'expectedTextSha256': digest('한😀새글'),
          'startUtf16': 3,
          'endUtf16': 4,
        },
      ];
      await engine.apply(
        source.path,
        sessionId: 'combined',
        operations: operations,
      );
      expect(forwarded, operations);
    },
  );

  final invalidStyles = <String, Map<String, Object?>>{
    'null underline': {'underline': null},
    'wrong underline type': {'underline': 1},
    'null italic': {'italic': null},
    'wrong italic type': {'italic': 1},
    'unsupported font family': {'fontFamily': '다른 글꼴'},
    'missing style': {'bold': null, 'fontSize': null, 'color': null},
    'wrong bold type': {'bold': 1},
    'infinite size': {'fontSize': double.infinity},
    'NaN size': {'fontSize': double.nan},
    'small size': {'fontSize': 0.5},
    'large size': {'fontSize': 401},
    'negative color': {'color': -1},
    'large color': {'color': 0x1000000},
    'fractional color': {'color': 1.5},
    'empty selection': {'endUtf16': 1},
    'backward selection': {'startUtf16': 4},
    'negative selection': {'startUtf16': -1},
    'fractional offset': {'startUtf16': 1.5},
    'invalid hash': {'expectedTextSha256': 'not-a-digest'},
    'shape target': {'targetKind': 'shape'},
    'unexpected cell': {'cell': '0,0'},
    'extra field': {'unknown': true},
  };
  for (final entry in invalidStyles.entries) {
    test('HWP rejects ${entry.key} before native execution', () async {
      var called = false;
      final engine = HwpOfficeEngine(
        runner: (request) async {
          called = true;
          return response(request);
        },
      );
      await expectLater(
        engine.apply(
          source.path,
          sessionId: 'invalid',
          operations: [
            {...style(), ...entry.value},
          ],
        ),
        throwsA(
          isA<HwpOfficeException>().having(
            (e) => e.code,
            'code',
            'invalid_request',
          ),
        ),
      );
      expect(called, isFalse);
    });
  }
  for (final cell in ['-1,0', '00,0', '0', 'a,0']) {
    test(
      'HWP rejects malformed table cell $cell before native execution',
      () async {
        var called = false;
        final engine = HwpOfficeEngine(
          runner: (request) async {
            called = true;
            return response(request);
          },
        );
        await expectLater(
          engine.apply(
            source.path,
            sessionId: 'invalid-cell',
            operations: [
              {...style(cell: true), 'cell': cell},
            ],
          ),
          throwsA(
            isA<HwpOfficeException>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        expect(called, isFalse);
      },
    );
  }
  for (final extra in <Map<String, Object?>>[
    {'bold': true},
    {'italic': false},
    {'startUtf16': -1},
    {'endUtf16': 1},
    {'text': '\uD800'},
    {'text': 123},
    {'unknown': true},
  ]) {
    test(
      'HWP rejects malformed text replacement ${extra.keys.first} ${extra.values.first}',
      () async {
        var called = false;
        final engine = HwpOfficeEngine(
          runner: (request) async {
            called = true;
            return response(request);
          },
        );
        await expectLater(
          engine.apply(
            source.path,
            sessionId: 'invalid-text',
            operations: [
              {...replacement(), ...extra},
            ],
          ),
          throwsA(
            isA<HwpOfficeException>().having(
              (e) => e.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        expect(called, isFalse);
      },
    );
  }
}
