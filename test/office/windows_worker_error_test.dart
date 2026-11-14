import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/windows_office_engine.dart';

const _code = 'office_operation_failed';
const _message = '원래 CLI 원인: 문서 실패 😀';

Map<String, dynamic> _diagnostics() => {
  'type': '원인오류',
  'frames': [
    <String, dynamic>{'file': '문서처리😀.py', 'function': '읽기_검사', 'line': 37},
    <String, dynamic>{
      'file': 'office_worker.py',
      'function': 'main',
      'line': 769,
    },
  ],
  'framesTruncated': false,
  'causes': [
    <String, dynamic>{
      'type': 'ValueError',
      'frames': [
        <String, dynamic>{
          'file': 'office_text.py',
          'function': 'selection',
          'line': 140,
        },
      ],
      'framesTruncated': false,
    },
  ],
  'causesTruncated': false,
};

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

Map<String, dynamic> _maximumDiagnostics({bool oversizedUtf8 = false}) {
  final text = (oversizedUtf8 ? '한' : 'x') * 128;
  Map<String, dynamic> cause() => {
    'type': text,
    'frames': [
      for (var i = 0; i < 16; i++)
        <String, dynamic>{'file': text, 'function': text, 'line': i + 1},
    ],
    'framesTruncated': true,
  };
  return {
    ...cause(),
    'causes': [cause(), cause()],
    'causesTruncated': true,
  };
}

void _expectOriginal(dynamic error) {
  expect(error, isA<WindowsOfficeException>());
  expect(error.code, _code);
  expect(error.message, _message);
  expect(error.toString(), 'WindowsOfficeException($_code): $_message');
  expect(error.toString(), isNot(contains('office_text.py')));
  expect(error.message, isNot(contains('원인오류')));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('default Windows worker error diagnostics', () {
    late Directory directory;
    late Directory runtime;
    late Directory helpers;
    late File source;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'windows-worker-error-',
      );
      runtime = Directory(p.join(directory.path, 'runtime with space'));
      helpers = Directory(p.join(directory.path, 'helpers with space'));
      await Directory(p.join(runtime.path, 'program')).create(recursive: true);
      await File(p.join(runtime.path, 'program', 'python.exe'))
          .writeAsBytes([]);
      await helpers.create();
      source = await File(p.join(directory.path, 'source 한글.pptx'))
          .writeAsBytes([1, 2, 3]);
    });
    tearDown(() async {
      await directory.delete(recursive: true);
    });

    Future<dynamic> cliError(
      Object? diagnostics, {
      bool includeDiagnostics = true,
    }) async {
      final response = <String, dynamic>{
        'ok': false,
        'error': <String, dynamic>{
          'code': _code,
          'message': _message,
          if (includeDiagnostics) 'diagnostics': diagnostics,
        },
      };
      final payload = base64Encode(utf8.encode(jsonEncode(response)));
      final script =
          r'''
param([Parameter(Mandatory)][string]$RuntimePath,
      [Parameter(Mandatory)][string]$RequestPath,
      [Parameter(Mandatory)][string]$ResponsePath)
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'invocation.json'), [System.IO.File]::ReadAllText($RequestPath, [System.Text.Encoding]::UTF8), $utf8)
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'response-path.txt'), $ResponsePath, $utf8)
[System.IO.File]::WriteAllBytes($ResponsePath, [System.Convert]::FromBase64String('__RESPONSE_BASE64__'))
exit 0
'''
              .replaceFirst('__RESPONSE_BASE64__', payload);
      expect(script.codeUnits.every((unit) => unit < 128), isTrue);
      await File(p.join(helpers.path, 'run-office.ps1'))
          .writeAsString(script, encoding: utf8);
      final engine = WindowsOfficeEngine(
        runtimePath: runtime.path,
        helperDirectory: helpers.path,
      );
      Object? caught;
      try {
        await engine.inspect(source.path);
      } catch (error) {
        caught = error;
      }
      final invocation = File(p.join(helpers.path, 'invocation.json'));
      expect(
        invocation.existsSync(),
        isTrue,
        reason: 'The default Process.run CLI must return before reading diagnostics',
      );
      final request = jsonDecode(await invocation.readAsString()) as Map;
      expect(request['mode'], 'inspect');
      expect(request['sourcePath'], source.path);
      expect(request.containsKey('operations'), isFalse);
      final responsePath = await File(p.join(helpers.path, 'response-path.txt'))
          .readAsString();
      expect(
        File(responsePath).parent.existsSync(),
        isFalse,
        reason: 'Failed inspect retains its existing owned-directory cleanup',
      );
      expect(await source.readAsBytes(), [1, 2, 3]);
      _expectOriginal(caught);
      return caught;
    }

    test('the default fake CLI preserves the legacy error independently of diagnostics', () async {
      final dynamic error = await cliError(null, includeDiagnostics: false);
      _expectOriginal(error);
    });

    test('the real default CLI path preserves Unicode diagnostics and the original error', () async {
      final expected = _diagnostics();
      final dynamic error = await cliError(expected);
      expect(error.diagnostics, expected);
    });

    test(
      'legacy CLI errors without diagnostics keep a null optional payload',
      () async {
        final dynamic error = await cliError(null, includeDiagnostics: false);
        expect(error.diagnostics, isNull);
      },
    );

    test(
      'an explicit null diagnostics payload keeps the original CLI cause',
      () async {
        final dynamic error = await cliError(null);
        expect(error.diagnostics, isNull);
      },
    );

    test(
      'diagnostics and nested frame and cause collections are deeply immutable',
      () async {
        final expected = _diagnostics();
        final dynamic error = await cliError(expected);
        final dynamic diagnostics = error.diagnostics;
        expect(diagnostics, expected);
        expect(
          () => diagnostics['type'] = 'ChangedError',
          throwsUnsupportedError,
        );
        expect(() => diagnostics['frames'].clear(), throwsUnsupportedError);
        expect(
          () => diagnostics['frames'][0]['line'] = 999,
          throwsUnsupportedError,
        );
        expect(() => diagnostics['causes'].removeAt(0), throwsUnsupportedError);
        expect(
          () => diagnostics['causes'][0]['frames'][0]['file'] = 'changed.py',
          throwsUnsupportedError,
        );
        expected['frames'][0]['line'] = 999;
        expect(diagnostics['frames'][0]['line'], 37);
      },
    );

    test(
      'sixteen frames per exception and two causes retain truncation flags',
      () async {
        final expected = _maximumDiagnostics();
        expect(
          utf8.encode(jsonEncode(expected)).length,
          lessThanOrEqualTo(16 * 1024),
        );
        final dynamic error = await cliError(expected);
        expect(error.diagnostics, expected);
        expect(error.diagnostics['frames'], hasLength(16));
        expect(error.diagnostics['causes'], hasLength(2));
        expect(error.diagnostics['framesTruncated'], isTrue);
        expect(error.diagnostics['causesTruncated'], isTrue);
      },
    );

    final invalid = <String, Object? Function()>{
      'non-object': () => ['unexpected'],
      'required field missing': () => _diagnostics()..remove('framesTruncated'),
      'unknown root field': () =>
          _diagnostics()..['message'] = 'must not join diagnostics',
      'unknown frame field': () {
        final value = _diagnostics();
        value['frames'][0]['source'] = 'must not expose source lines';
        return value;
      },
      'non-boolean truncation flag': () =>
          _diagnostics()..['framesTruncated'] = 'false',
      'zero line': () {
        final value = _diagnostics();
        value['frames'][0]['line'] = 0;
        return value;
      },
      'fractional line': () {
        final value = _copy(_diagnostics());
        value['frames'][0]['line'] = 1.5;
        return value;
      },
      'boolean line': () {
        final value = _copy(_diagnostics());
        value['frames'][0]['line'] = true;
        return value;
      },
      'seventeen frames': () {
        final value = _diagnostics();
        value['frames'] = List.generate(
          17,
          (i) => <String, dynamic>{
            'file': 'worker.py',
            'function': 'inspect',
            'line': i + 1,
          },
        );
        return value;
      },
      'three causes': () {
        final value = _diagnostics();
        value['causes'] = List.generate(
          3,
          (_) => _copy(value['causes'][0] as Map<String, dynamic>),
        );
        return value;
      },
      'unknown cause field': () {
        final value = _diagnostics();
        value['causes'][0]['message'] = 'not allowed';
        return value;
      },
      'cause frame bound': () {
        final value = _diagnostics();
        value['causes'][0]['frames'] = List.generate(
          17,
          (i) => <String, dynamic>{
            'file': 'cause.py',
            'function': 'cause',
            'line': i + 1,
          },
        );
        return value;
      },
      'empty type': () => _diagnostics()..['type'] = '',
      'type length': () => _diagnostics()..['type'] = 'x' * 129,
      'file length': () {
        final value = _diagnostics();
        value['frames'][0]['file'] = 'x' * 129;
        return value;
      },
      'function length': () {
        final value = _diagnostics();
        value['frames'][0]['function'] = 'x' * 129;
        return value;
      },
    };
    for (final entry in invalid.entries) {
      test(
        'bad optional diagnostics are discarded without hiding the CLI cause: ${entry.key}',
        () async {
          final dynamic error = await cliError(entry.value());
          expect(error.diagnostics, isNull);
        },
      );
    }

    for (final filename in <String>[
      r'C:\Users\private\worker.py',
      '/home/private/worker.py',
      r'\\server\share\worker.py',
      'C:worker.py',
      'folder/worker.py',
      r'folder\worker.py',
    ]) {
      test(
        'diagnostic frame file rejects non-basename path: $filename',
        () async {
          final value = _diagnostics();
          value['frames'][0]['file'] = filename;
          final dynamic error = await cliError(value);
          expect(error.diagnostics, isNull);
        },
      );
    }

    test('the 16KiB diagnostic limit counts encoded UTF8 bytes without changing the error', () async {
      final value = _maximumDiagnostics(oversizedUtf8: true);
      expect(utf8.encode(jsonEncode(value)).length, greaterThan(16 * 1024));
      final dynamic error = await cliError(value);
      expect(error.diagnostics, isNull);
    });
  }, skip: !Platform.isWindows);
}
