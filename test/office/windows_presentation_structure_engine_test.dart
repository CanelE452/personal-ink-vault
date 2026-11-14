// Typed runner-boundary tests; actual Office processes are verified separately.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

import 'windows_presentation_structure_operation_test.dart';
import 'windows_presentation_structure_preview_test.dart';

Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return [for (final child in value) _ordered(child)];
  return value;
}

void _snapshotHash(Map<String, dynamic> snapshot, String hash) {
  snapshot['sourceSha256'] = hash;
  for (final slide in snapshot['slides'] as List) {
    slide['sourceStructureAuthority']['sourceSha256'] = hash;
    for (final table in slide['presentationTables'] as List) {
      table['sourceTextPatchAuthority']['sourceSha256'] = hash;
    }
  }
}

class _Case {
  new(
    this.root,
    this.source,
    this.edited,
    this.pdf,
    this.sourceHash,
    this.editedHash,
    this.pdfHash,
  );
  final Directory root;
  final File source;
  final File edited;
  final File pdf;
  final String sourceHash;
  final String editedHash;
  final String pdfHash;
  var calls = 0;
  Map<String, Object?>? request;

  WindowsOfficeOperation get operation => structureOperation(
    changes: {
      'expectedSourceSha256': sourceHash,
      'xMm': 0,
      'yMm': 0,
      'columnWidthsMm': <num>[30],
      'rowHeightsMm': <num>[12],
    },
  );

  WindowsOfficeEngine engine({
    void Function(Map<String, dynamic>, Map<String, Object?>)? mutate,
  }) => WindowsOfficeEngine(
    runner: (request) async {
      calls++;
      this.request = request;
      final result = structuralResultWire();
      result.addAll({
        'status': 'saved',
        'sessionId': request['sessionId'],
        'sourcePath': edited.path,
        'pdfPath': pdf.path,
        'sourceSha256': editedHash,
        'pdfSha256': pdfHash,
      });
      _snapshotHash(result['snapshot'] as Map<String, dynamic>, editedHash);
      final preview = result['structuralPreview'] as Map<String, dynamic>;
      preview['baseSourceSha256'] = sourceHash;
      preview['candidateSourceSha256'] = editedHash;
      preview['operationsSha256'] = sha256
          .convert(utf8.encode(jsonEncode(_ordered(request['operations']))))
          .toString();
      _snapshotHash(preview['snapshot'] as Map<String, dynamic>, editedHash);
      if (request['includeDraftSnapshot'] != true)
        result.remove('structuralPreview');
      mutate?.call(result, request);
      return result;
    },
  );
}

Future<void> _fixture(Future<void> Function(_Case) body) async {
  final root = await Directory.systemTemp.createTemp('piv-structure-engine-');
  try {
    final source = await File('${root.path}/source.pptx')
        .writeAsBytes(utf8.encode('UNCHANGED SOURCE'));
    final edited = await File('${root.path}/edited.pptx')
        .writeAsBytes(utf8.encode('SYNTHETIC CANDIDATE'));
    final pdf = await File('${root.path}/preview.pdf')
        .writeAsBytes(utf8.encode('%PDF-synthetic runner boundary'));
    String hash(File file) => sha256.convert(file.readAsBytesSync()).toString();
    await body(
      _Case(root, source, edited, pdf, hash(source), hash(edited), hash(pdf)),
    );
    expect(source.readAsBytesSync(), utf8.encode('UNCHANGED SOURCE'));
  } finally {
    await root.delete(recursive: true);
  }
}

Matcher get _invalidResult => throwsA(
  isA<WindowsOfficeException>().having(
    (error) => error.code,
    'code',
    'invalid_office_result',
  ),
);

void main() {
  test('source table preview uses captured base plus verified candidate without legacy draft', () async {
    await _fixture((value) async {
      final result = await value.engine().apply(
        value.source.path,
        operations: [value.operation],
        sessionId: 'create-preview',
        expectedSourceSha256: value.sourceHash,
        includeDraftSnapshot: true,
      );
      expect(result.sourceSha256, value.editedHash);
      expect(result.draftSnapshot, isNull);
      final dynamic preview = (result as dynamic).structuralPreview;
      expect(preview.baseSourceSha256, value.sourceHash);
      expect(preview.candidateSourceSha256, value.editedHash);
      expect(preview.snapshot.sourceSha256, value.editedHash);
      expect(value.request!['expectedSourceSha256'], value.sourceHash);
      expect(value.calls, 1);
    });
  });

  test('saved source table result without requested preview keeps the normal saved snapshot', () async {
    await _fixture((value) async {
      final result = await value.engine().apply(
        value.source.path,
        operations: [value.operation],
        sessionId: 'create-save',
      );
      expect(result.sourceSha256, value.editedHash);
      expect(result.draftSnapshot, isNull);
      expect((result as dynamic).structuralPreview, isNull);
      expect(value.request!['expectedSourceSha256'], value.sourceHash);
    });
  });

  test('operation digest and captured base cannot be swapped in structural previews', () async {
    for (final field in ['operationsSha256', 'baseSourceSha256']) {
      await _fixture((value) async {
        final engine = value.engine(
          mutate: (result, _) {
            result['structuralPreview'][field] = '9' * 64;
          },
        );
        await expectLater(
          engine.apply(
            value.source.path,
            operations: [value.operation],
            sessionId: 'mismatch-preview',
            includeDraftSnapshot: true,
          ),
          _invalidResult,
        );
      });
    }
  });

  test('a legacy draft cannot replace the new structural receipt', () async {
    await _fixture((value) async {
      final engine = value.engine(
        mutate: (result, _) {
          result.remove('structuralPreview');
          final legacy = structureCandidateSnapshot();
          _snapshotHash(legacy, value.sourceHash);
          result['draftSnapshot'] = legacy;
        },
      );
      await expectLater(
        engine.apply(
          value.source.path,
          operations: [value.operation],
          sessionId: 'wrong-family',
          includeDraftSnapshot: true,
        ),
        _invalidResult,
      );
    });
  });

  test(
    'unrequested structural receipt is refused for a save and for legacy edits',
    () async {
      await _fixture((value) async {
        final engine = value.engine(
          mutate: (result, request) {
            result['structuralPreview'] = structuralPreviewWire();
          },
        );
        await expectLater(
          engine.apply(
            value.source.path,
            operations: [value.operation],
            sessionId: 'unrequested',
          ),
          _invalidResult,
        );
        await expectLater(
          engine.apply(
            value.source.path,
            operations: [WindowsOfficeOperation.slideMove('slide-0', 0)],
            sessionId: 'legacy-receipt',
          ),
          _invalidResult,
        );
      });
    },
  );

  test(
    'duplicate aliases and mixed source-native batches fail before the runner',
    () async {
      await _fixture((value) async {
        final engine = value.engine();
        for (final operations in [
          [value.operation, value.operation],
          [value.operation, WindowsOfficeOperation.slideMove('slide-0', 0)],
          List<WindowsOfficeOperation>.filled(101, value.operation),
        ]) {
          await expectLater(
            engine.apply(
              value.source.path,
              operations: operations,
              sessionId: 'invalid-batch',
            ),
            throwsFormatException,
          );
        }
        expect(value.calls, 0);
      });
    },
  );

  test('base package authority is checked against the actual input before the runner', () async {
    await _fixture((value) async {
      await expectLater(
        value.engine().apply(
          value.source.path,
          operations: [structureOperation()],
          sessionId: 'stale-operation',
        ),
        throwsA(
          isA<WindowsOfficeException>().having(
            (error) => error.code,
            'code',
            'source_changed',
          ),
        ),
      );
      expect(value.calls, 0);
    });
  });

  test(
    'receipt table geometry must equal the recorded source creation request',
    () async {
      await _fixture((value) async {
        final changed = structureOperation(
          changes: {
            'expectedSourceSha256': value.sourceHash,
            'xMm': 0,
            'yMm': 0,
            'columnWidthsMm': <num>[31],
            'rowHeightsMm': <num>[12],
          },
        );
        await expectLater(
          value.engine().apply(
            value.source.path,
            operations: [changed],
            sessionId: 'wrong-geometry',
            includeDraftSnapshot: true,
          ),
          _invalidResult,
        );
      });
    },
  );

  test(
    'retained preview copies preserve the separate structural receipt',
    () async {
      await _fixture((value) async {
        final preview = await value.engine().preview(
          value.source.path,
          operations: [value.operation],
          sessionId: 'retained-preview',
          expectedSourceSha256: value.sourceHash,
        );
        try {
          expect(
            (preview.result as dynamic).structuralPreview.baseSourceSha256,
            value.sourceHash,
          );
          expect(preview.result.sourcePath, isNot(value.edited.path));
          expect(
            File(preview.result.sourcePath).readAsBytesSync(),
            value.edited.readAsBytesSync(),
          );
        } finally {
          await preview.dispose();
        }
      });
    },
  );
}
