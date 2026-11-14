import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/windows_office_engine.dart';

const _session = 'office-conversion-session';
const _legacy = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 0x01];
const _pdf = '%PDF-1.7\npreview fixture\n%%EOF\n';

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

Matcher _error(String code) =>
    isA<WindowsOfficeException>().having((error) => error.code, 'code', code);

Uint8List _ooxml(String target) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..addFile(
        ArchiveFile.string(
          target == 'docx' ? 'word/document.xml' : 'ppt/presentation.xml',
          '<document/>',
        ),
      ),
  ),
);

Future<Map<String, dynamic>> _response(
  File converted,
  File pdf,
  String target,
) async => {
  'sessionId': _session,
  'inputSourceSha256': _digest(_legacy),
  'targetExtension': target,
  'sourcePath': converted.path,
  'sourceSha256': _digest(await converted.readAsBytes()),
  'pdfPath': pdf.path,
  'pdfSha256': _digest(await pdf.readAsBytes()),
  'pdfPageCount': 1,
  'engineVersion': 'fixture-engine',
};

String _quote(String value) => "'${value.replaceAll("'", "''")}'";

void main() {
  late Directory temp;
  late File source, pdf;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('office-legacy-conversion-');
    source = await File(p.join(temp.path, 'original.doc'))
        .writeAsBytes(_legacy);
    pdf = await File(p.join(temp.path, 'preview.pdf')).writeAsString(_pdf);
  });
  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  for (final (extension, target) in [('DOC', 'docx'), ('ppt', 'pptx')]) {
    test(
      '$extension binds the converted package and PDF to the source',
      () async {
        source = await File(p.join(temp.path, 'example.$extension'))
            .writeAsBytes(_legacy);
        final converted = await File(p.join(temp.path, 'converted.$target'))
            .writeAsBytes(_ooxml(target));
        final initialModified = source.lastModifiedSync();
        final engine = WindowsOfficeEngine(
          runner: (request) async {
            expect(request, {
              'mode': 'convertLegacy',
              'sourcePath': source.path,
              'sessionId': _session,
              'expectedSourceSha256': _digest(_legacy),
            });
            return _response(converted, pdf, target);
          },
        );
        final result = await engine.convertLegacy(
          source.path,
          sessionId: _session,
          expectedSourceSha256: _digest(_legacy),
        );
        expect(result.targetExtension, target);
        expect(result.originalBytes, await converted.readAsBytes());
        expect(result.pdfBytes, await pdf.readAsBytes());
        expect(result.pageCount, 1);
        expect(result.engineVersion, 'fixture-engine');
        expect(() => result.originalBytes[0] = 0, throwsUnsupportedError);
        expect(await source.readAsBytes(), _legacy);
        expect(source.lastModifiedSync(), initialModified);
        expect(converted.existsSync(), isTrue);
        expect(pdf.existsSync(), isTrue);
      },
    );
  }

  test(
    'invalid legacy input and a stale source hash stop before invocation',
    () async {
      var invoked = false;
      final engine = WindowsOfficeEngine(
        runner: (_) async {
          invoked = true;
          throw StateError('Invalid conversion reached the worker');
        },
      );
      await expectLater(
        engine.convertLegacy(
          source.path,
          sessionId: _session,
          expectedSourceSha256: '0' * 64,
        ),
        throwsA(_error('source_changed')),
      );
      await expectLater(
        engine.convertLegacy(
          'relative.doc',
          sessionId: _session,
          expectedSourceSha256: _digest(_legacy),
        ),
        throwsFormatException,
      );
      await expectLater(
        engine.convertLegacy(
          p.join(temp.path, 'modern.docx'),
          sessionId: _session,
          expectedSourceSha256: _digest(_legacy),
        ),
        throwsFormatException,
      );
      await source.writeAsString('not a compound file');
      await expectLater(
        engine.convertLegacy(
          source.path,
          sessionId: _session,
          expectedSourceSha256: _digest(_legacy),
        ),
        throwsA(_error('invalid_office_source')),
      );
      expect(invoked, isFalse);
    },
  );

  test('rejects mismatched fields, hashes, and paths without deleting injected files', () async {
    final converted = await File(p.join(temp.path, 'converted.docx'))
        .writeAsBytes(_ooxml('docx'));
    for (final override in <Map<String, Object?>>[
      {'extra': true},
      {'sessionId': 'wrong-session'},
      {'inputSourceSha256': '0' * 64},
      {'targetExtension': 'pptx'},
      {'pdfPageCount': 0},
      {'engineVersion': ' '},
      {'sourceSha256': '0' * 64},
      {'pdfSha256': '0' * 64},
      {'sourcePath': 'relative.docx'},
      {'pdfPath': source.path},
    ]) {
      final engine = WindowsOfficeEngine(
        runner: (_) async => {
          ...await _response(converted, pdf, 'docx'),
          ...override,
        },
      );
      await expectLater(
        engine.convertLegacy(
          source.path,
          sessionId: _session,
          expectedSourceSha256: _digest(_legacy),
        ),
        throwsA(_error('invalid_office_result')),
      );
    }
    expect(source.existsSync(), isTrue);
    expect(converted.existsSync(), isTrue);
    expect(pdf.existsSync(), isTrue);
  });

  test('rejects a truncated PDF even with its matching hash', () async {
    final converted = await File(p.join(temp.path, 'converted.docx'))
        .writeAsBytes(_ooxml('docx'));
    await pdf.writeAsString('%PDF-1.7\nno trailer');
    final engine = WindowsOfficeEngine(
      runner: (_) => _response(converted, pdf, 'docx'),
    );
    await expectLater(
      engine.convertLegacy(
        source.path,
        sessionId: _session,
        expectedSourceSha256: _digest(_legacy),
      ),
      throwsA(_error('invalid_office_result')),
    );
  });

  test('rejects a source that changes during the conversion call', () async {
    final converted = await File(p.join(temp.path, 'converted.docx'))
        .writeAsBytes(_ooxml('docx'));
    final engine = WindowsOfficeEngine(
      runner: (_) async {
        await source.setLastModified(DateTime.utc(2000));
        return _response(converted, pdf, 'docx');
      },
    );
    await expectLater(
      engine.convertLegacy(
        source.path,
        sessionId: _session,
        expectedSourceSha256: _digest(_legacy),
      ),
      throwsA(_error('source_changed')),
    );
    expect(await source.readAsBytes(), _legacy);
  });

  for (final external in [false, true]) {
    test(
      'worker ${external ? 'rejects external output and cleans only its job' : 'returns bytes and cleans its owned job'}',
      () async {
        final helpers = await Directory(p.join(temp.path, 'helpers')).create();
        final program = await Directory(p.join(temp.path, 'runtime', 'program'))
            .create(recursive: true);
        await File(p.join(program.path, 'python.exe')).writeAsBytes([]);
        final marker = File(p.join(temp.path, 'worker-job.txt'));
        final modernBytes = _ooxml('docx');
        await File(p.join(helpers.path, 'run-office.ps1')).writeAsString('''
param([string]\$RuntimePath, [string]\$RequestPath, [string]\$ResponsePath)
\$ErrorActionPreference = 'Stop'
\$job = Split-Path -Parent \$ResponsePath
[IO.File]::WriteAllText(${_quote(marker.path)}, \$job)
\$modern = Join-Path \$job 'edited.docx'
[IO.File]::WriteAllBytes(\$modern, [Convert]::FromBase64String('${base64Encode(modernBytes)}'))
\$pdf = ${external ? _quote(pdf.path) : "Join-Path \$job 'preview.pdf'"}
if (-not (Test-Path -LiteralPath \$pdf)) {
  [IO.File]::WriteAllBytes(\$pdf, [Convert]::FromBase64String('${base64Encode(utf8.encode(_pdf))}'))
}
\$result = @{sessionId='$_session';inputSourceSha256='${_digest(_legacy)}';targetExtension='docx';sourcePath=\$modern;sourceSha256='${_digest(modernBytes)}';pdfPath=\$pdf;pdfSha256='${_digest(utf8.encode(_pdf))}';pdfPageCount=1;engineVersion='fixture-engine'}
\$reply = @{ok=\$true;result=\$result} | ConvertTo-Json -Compress
[IO.File]::WriteAllText(\$ResponsePath, \$reply)
''');
        final engine = WindowsOfficeEngine(
          runtimePath: program.parent.path,
          helperDirectory: helpers.path,
        );
        final conversion = engine.convertLegacy(
          source.path,
          sessionId: _session,
          expectedSourceSha256: _digest(_legacy),
        );
        if (external) {
          await expectLater(
            conversion,
            throwsA(_error('invalid_office_result')),
          );
        } else {
          final result = await conversion;
          expect(result.originalBytes, modernBytes);
          expect(result.pdfBytes, utf8.encode(_pdf));
        }
        final job = Directory(await marker.readAsString());
        expect(p.basename(job.path), startsWith('piv-o-'));
        expect(job.existsSync(), isFalse);
        expect(await pdf.readAsString(), _pdf);
        expect(await source.readAsBytes(), _legacy);
      },
      skip: !Platform.isWindows,
    );
  }
}
