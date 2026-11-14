import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';

import 'annotation_store_test.dart' show annotationOfficeFile, annotationPdf;

typedef _Runner = Future<Map<String, dynamic>> Function(
  Map<String, Object?> request,
  Directory directory,
  Future<void> cancellation,
);

WindowsOfficeEngine _engine(_Runner runner) {
  try {
    return Function.apply(WindowsOfficeEngine.new, const [], {
      #interactiveRunner: runner,
    }) as WindowsOfficeEngine;
  } on NoSuchMethodError catch (error) {
    fail(
      'The real Office engine must expose its interactive session runner: $error',
    );
  }
}

Future<dynamic> _start(
  WindowsOfficeEngine engine, {
  required String workingPath,
  required String sessionId,
  required String inputSourceSha256,
}) async {
  try {
    return await (engine as dynamic).startInteractive(
      workingPath: workingPath,
      sessionId: sessionId,
      inputSourceSha256: inputSourceSha256,
    );
  } on NoSuchMethodError catch (error) {
    fail(
      'The real Office engine must start an owned interactive session: $error',
    );
  }
}

Future<bool> _available(WindowsOfficeEngine engine) async {
  try {
    return await (engine as dynamic).interactiveAvailable as bool;
  } on NoSuchMethodError catch (error) {
    fail('The real Office engine must report interactive availability: $error');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late String sessionId;
  late File working;
  late String inputHash;
  late List<Directory> launched;
  late List<Map<String, Object?>> requests;
  late List<Directory> runtimeCaches;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('office-interactive-');
    sessionId = newId();
    final session = await Directory(p.join(temporary.path, sessionId)).create();
    working = await File(p.join(session.path, 'original.docx'))
        .writeAsBytes(annotationOfficeFile('original 한글 😀'), flush: true);
    inputHash = sha256.convert(await working.readAsBytes()).toString();
    launched = [];
    requests = [];
    runtimeCaches = [];
  });

  tearDown(() async {
    for (final cache in runtimeCaches) {
      if (!cache.existsSync()) continue;
      expect(p.basename(cache.path), startsWith('piv-i-'));
      expect(
        p.dirname(cache.path),
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      final retained = File(p.join(cache.path, 'retained-recovery.bin'));
      if (retained.existsSync()) {
        expect(await retained.readAsBytes(), [19, 23, 29]);
        await retained.delete();
      }
      await cache.delete();
    }
    final resolved = await temporary.resolveSymbolicLinks();
    expect(p.basename(resolved), startsWith('office-interactive-'));
    expect(
      p.dirname(resolved),
      await Directory.systemTemp.resolveSymbolicLinks(),
    );
    if (temporary.existsSync()) await temporary.delete(recursive: true);
  });

  Map<String, dynamic> common(Map<String, Object?> request) => {
    'version': 1,
    'sessionId': request['sessionId'],
    'controlNonce': request['controlNonce'],
    'inputSourceSha256': request['inputSourceSha256'],
    'engineVersion': 'LibreOffice26.8.2.2',
  };

  void capture(Map<String, Object?> request, Directory directory) {
    launched.add(directory);
    requests.add(Map<String, Object?>.from(request));
  }

  Future<Map<String, dynamic>> saved(
    Map<String, Object?> request,
    Directory directory, {
    List<int>? sourceBytes,
    List<int>? pdfBytes,
  }) async {
    final source = await File(p.join(directory.path, 'edited.docx'))
        .writeAsBytes(
          sourceBytes ?? annotationOfficeFile('saved 한글 😀'),
          flush: true,
        );
    final pdf = await File(p.join(directory.path, 'preview.pdf'))
        .writeAsBytes(pdfBytes ?? annotationPdf('saved 한글 😀'), flush: true);
    return {
      ...common(request),
      'status': 'saved',
      'sourcePath': source.path,
      'pdfPath': pdf.path,
      'sourceSha256': sha256.convert(await source.readAsBytes()).toString(),
      'pdfSha256': sha256.convert(await pdf.readAsBytes()).toString(),
      'pdfPageCount': 1,
    };
  }

  Future<dynamic> start(WindowsOfficeEngine engine) => _start(
    engine,
    workingPath: working.path,
    sessionId: sessionId,
    inputSourceSha256: inputHash,
  );

  test(
    'a structured test runner does not advertise native GUI availability',
    () async {
      final engine = WindowsOfficeEngine(runner: (_) async => {});
      expect(await _available(engine), isFalse);
    },
  );

  test(
    'an interactive runner reports availability without a native installation',
    () async {
      final engine = _engine(
        (request, directory, cancellation) async => {
          ...common(request),
          'status': 'cancelled',
        },
      );
      expect(await _available(engine), isTrue);
    },
  );

  test(
    'saved files are bound to a fresh session request and explicit release',
    () async {
      final unrelated = await File(p.join(working.parent.path, 'retain.bin'))
          .writeAsBytes([9, 8, 7]);
      final engine = _engine((request, directory, cancellation) async {
        capture(request, directory);
        expect(request.keys.toSet(), {
          'version',
          'sessionId',
          'controlNonce',
          'workingFileName',
          'inputSourceSha256',
          'expectedWorkingSha256',
          'workingLength',
          'parentProcessId',
          'parentExecutablePath',
        });
        expect(request['version'], 1);
        expect(request['sessionId'], sessionId);
        validateId(request['controlNonce']! as String);
        expect(request['workingFileName'], 'original.docx');
        expect(request['inputSourceSha256'], inputHash);
        expect(request['expectedWorkingSha256'], inputHash);
        expect(request['workingLength'], await working.length());
        expect(request['parentProcessId'], pid);
        expect(request['parentExecutablePath'], Platform.resolvedExecutable);
        expect(p.equals(directory.parent.path, working.parent.path), isTrue);
        expect(
          p.basename(directory.path),
          'interactive-${request['controlNonce']}',
        );
        expect(
          jsonDecode(
            await File(p.join(directory.path, 'request.json')).readAsString(),
          ),
          request,
        );
        expect(
          File(p.join(directory.path, 'request.pending')).existsSync(),
          isFalse,
        );
        return saved(request, directory);
      });
      final operation = await start(engine);
      final AndroidOfficeEditResult result = await operation.result;
      expect(result.status, AndroidOfficeEditStatus.saved);
      expect(result.sessionId, sessionId);
      expect(result.inputSourceSha256, inputHash);
      expect(result.engineVersion, 'LibreOffice26.8.2.2');
      expect(result.pdfPageCount, 1);
      expect(
        await File(result.sourcePath!).readAsBytes(),
        annotationOfficeFile('saved 한글 😀'),
      );
      expect(
        await File(result.pdfPath!).readAsBytes(),
        annotationPdf('saved 한글 😀'),
      );
      expect(sha256.convert(await working.readAsBytes()).toString(), inputHash);
      await operation.dispose();
      expect(launched.single.existsSync(), isTrue);
      await operation.releaseOutputs();
      await operation.releaseOutputs();
      expect(launched.single.existsSync(), isFalse);
      expect(await unrelated.readAsBytes(), [9, 8, 7]);
      expect(sha256.convert(await working.readAsBytes()).toString(), inputHash);
    },
  );

  test(
    'release cleans a deeply nested Windows Office launch without removing its working file',
    () async {
      final root = await temporary.resolveSymbolicLinks();
      final suffix = p.join(sessionId, 'interactive-$sessionId');
      final pad = 279 - p.join(root, 'x', suffix).length + 1;
      expect(pad, inInclusiveRange(1, 200));
      final session = p.join(root, 'x' * pad, sessionId);
      String extended(String path) => path.startsWith(r'\\')
          ? '\\\\?\\UNC\\${path.substring(2)}'
          : '\\\\?\\$path';
      final original = await working.readAsBytes();
      await Directory(extended(session)).create(recursive: true);
      final deepWorking = p.join(session, 'original.docx');
      await File(extended(deepWorking)).writeAsBytes(original, flush: true);
      expect(await File(deepWorking).readAsBytes(), original);

      final engine = _engine((request, directory, cancellation) async {
        capture(request, directory);
        return saved(request, directory);
      });
      final operation = await _start(
        engine,
        workingPath: deepWorking,
        sessionId: sessionId,
        inputSourceSha256: inputHash,
      );
      final AndroidOfficeEditResult result = await operation.result;
      expect(result.status, AndroidOfficeEditStatus.saved);
      final launch = launched.single;
      expect(launch.path.length, 279);
      expect(
        await Directory(extended(launch.path))
            .list(recursive: true, followLinks: false)
            .map((entry) => p.basename(entry.path))
            .toSet(),
        {'request.json', 'edited.docx', 'preview.pdf'},
      );

      await operation.releaseOutputs();

      expect(
        launch.existsSync(),
        isFalse,
        reason: 'Owned long-path launch output must be removed after saving.',
      );
      expect(await File(deepWorking).readAsBytes(), original);
    },
    skip: !Platform.isWindows,
  );

  for (final interruption in ['create', 'write']) {
    test(
      'an interrupted request $interruption leaves only an unpublished pending file',
      () async {
        var calls = 0;
        final engine = _engine((request, directory, cancellation) async {
          calls++;
          return {...common(request), 'status': 'cancelled'};
        });
        final realFile = Zone.current.bindUnaryCallback<File, String>(File.new);
        await expectLater(
          IOOverrides.runZoned(
            () => start(engine),
            createFile: (path) {
              final file = realFile(path);
              return [
                    'request.json',
                    'request.pending',
                  ].contains(p.basename(path))
                  ? _InterruptedRequestFile(file, interruption)
                  : file;
            },
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(calls, 0);
        expect(
          sha256.convert(await working.readAsBytes()).toString(),
          inputHash,
        );
        final launch = working.parent.listSync().whereType<Directory>().single;
        expect(p.basename(launch.path), startsWith('interactive-'));
        expect(
          File(p.join(launch.path, 'request.json')).existsSync(),
          isFalse,
          reason: 'A final request may become visible only after its complete flushed bytes exist',
        );
        final pending = File(p.join(launch.path, 'request.pending'));
        expect(pending.existsSync(), isTrue);
        if (interruption == 'create') {
          expect(await pending.length(), 0);
        } else {
          final bytes = await pending.readAsBytes();
          expect(bytes.length, greaterThan(0));
          expect(() => jsonDecode(utf8.decode(bytes)), throwsFormatException);
        }
      },
    );
  }

  test('start returns while editing and cancellation preserves last saved working data', () async {
    final entered = Completer<void>();
    final reply = Completer<Map<String, dynamic>>();
    final cancelled = Completer<void>();
    final bytes = annotationOfficeFile('last saved before cancellation');
    final engine = _engine((request, directory, cancellation) async {
      capture(request, directory);
      cancellation.then((_) => cancelled.complete());
      entered.complete();
      return reply.future;
    });
    final operation = await start(engine).timeout(const Duration(seconds: 5));
    await entered.future;
    await working.writeAsBytes(bytes, flush: true);
    final cancelling = operation.cancel();
    expect(operation.cancellationRequested, isTrue);
    await cancelling;
    await cancelled.future;
    final control = File(p.join(launched.single.path, 'cancel.json'));
    final controlBytes = await control.readAsBytes();
    expect(jsonDecode(utf8.decode(controlBytes)), {
      'version': 1,
      'sessionId': sessionId,
      'controlNonce': requests.single['controlNonce'],
    });
    var finished = false;
    operation.result.then((_) => finished = true);
    await Future<void>.delayed(Duration.zero);
    expect(finished, isFalse);
    await operation.cancel();
    expect(await control.readAsBytes(), controlBytes);
    reply.complete({...common(requests.single), 'status': 'cancelled'});
    final AndroidOfficeEditResult result = await operation.result;
    expect(result.status, AndroidOfficeEditStatus.cancelled);
    expect(result.sessionId, sessionId);
    expect(result.inputSourceSha256, inputHash);
    await operation.dispose();
    await operation.releaseOutputs();
    expect(launched.single.existsSync(), isTrue);
    expect(await working.readAsBytes(), bytes);
  });

  test('a late saved response after cancel retains its real receipt for durable preservation', () async {
    final entered = Completer<void>();
    final reply = Completer<Map<String, dynamic>>();
    final engine = _engine((request, directory, cancellation) async {
      capture(request, directory);
      entered.complete();
      return reply.future;
    });
    final operation = await start(engine);
    await entered.future;
    await operation.cancel();
    reply.complete(await saved(requests.single, launched.single));
    final AndroidOfficeEditResult result = await operation.result;
    expect(operation.cancellationRequested, isTrue);
    expect(result.status, AndroidOfficeEditStatus.saved);
    expect(launched.single.existsSync(), isTrue);
    expect(
      File(p.join(launched.single.path, 'edited.docx')).existsSync(),
      isTrue,
    );
    final recovery = await Directory(p.join(temporary.path, 'retained-native'))
        .create();
    await File(result.sourcePath!).copy(p.join(recovery.path, 'edited.docx'));
    await File(result.pdfPath!).copy(p.join(recovery.path, 'preview.pdf'));
    await operation.releaseOutputs();
    expect(launched.single.existsSync(), isFalse);
    expect(
      await File(p.join(recovery.path, 'edited.docx')).readAsBytes(),
      annotationOfficeFile('saved 한글 😀'),
    );
  });

  test('disposing a pending session requests cancellation without waiting for the native window', () async {
    final entered = Completer<void>();
    final reply = Completer<Map<String, dynamic>>();
    final cancelled = Completer<void>();
    final engine = _engine((request, directory, cancellation) async {
      capture(request, directory);
      cancellation.then((_) => cancelled.complete());
      entered.complete();
      return reply.future;
    });
    final operation = await start(engine);
    await entered.future;
    await operation.dispose().timeout(const Duration(seconds: 5));
    await operation.dispose();
    await cancelled.future;
    expect(launched.single.existsSync(), isTrue);
    reply.complete({...common(requests.single), 'status': 'cancelled'});
    expect(
      (await operation.result as AndroidOfficeEditResult).status,
      AndroidOfficeEditStatus.cancelled,
    );
  });

  test('an early release cannot dispose an editing session or suppress the later release', () async {
    final entered = Completer<void>();
    final reply = Completer<Map<String, dynamic>>();
    final engine = _engine((request, directory, cancellation) async {
      capture(request, directory);
      entered.complete();
      return reply.future;
    });
    final operation = await start(engine);
    await entered.future;
    await operation.releaseOutputs();
    expect(launched.single.existsSync(), isTrue);
    reply.complete(await saved(requests.single, launched.single));
    await operation.result;
    await operation.releaseOutputs();
    expect(launched.single.existsSync(), isFalse);
  });

  final malformed = <String, void Function(Map<String, dynamic>)>{
    'version': (value) => value['version'] = 2,
    'session': (value) => value['sessionId'] = newId(),
    'nonce': (value) => value['controlNonce'] = newId(),
    'base hash': (value) => value['inputSourceSha256'] = '0' * 64,
    'engine version': (value) => value['engineVersion'] = 'unexpected engine',
    'unknown field': (value) => value['unexpected'] = true,
    'page count': (value) => value['pdfPageCount'] = 0,
    'noninteger page count': (value) => value['pdfPageCount'] = 1.5,
    'source hash': (value) => value['sourceSha256'] = '0' * 64,
    'PDF hash': (value) => value['pdfSha256'] = '0' * 64,
    'source hash type': (value) => value['sourceSha256'] = 17,
  };
  for (final entry in malformed.entries) {
    test(
      'rejects a saved response with a different ${entry.key} and preserves its files',
      () async {
        final engine = _engine((request, directory, cancellation) async {
          capture(request, directory);
          final value = await saved(request, directory);
          entry.value(value);
          return value;
        });
        final operation = await start(engine);
        await expectLater(
          operation.result,
          throwsA(isA<WindowsOfficeException>()),
        );
        await operation.releaseOutputs();
        expect(launched.single.existsSync(), isTrue);
        expect(
          sha256.convert(await working.readAsBytes()).toString(),
          inputHash,
        );
      },
    );
  }

  for (final bytes in [
    utf8.encode('not a PDF\n%%EOF\n'),
    utf8.encode('%PDF-1.7\nmissing terminal marker'),
  ]) {
    test(
      'rejects invalid PDF bytes even when their reported SHA is correct ${bytes.length}',
      () async {
        final engine = _engine((request, directory, cancellation) async {
          capture(request, directory);
          return saved(request, directory, pdfBytes: bytes);
        });
        final operation = await start(engine);
        await expectLater(
          operation.result,
          throwsA(isA<WindowsOfficeException>()),
        );
        expect(launched.single.existsSync(), isTrue);
      },
    );
  }

  test(
    'a foreign valid source and PDF cannot become owned output or be deleted',
    () async {
      final foreign = await Directory(p.join(temporary.path, 'foreign'))
          .create();
      final source = await File(p.join(foreign.path, 'edited.docx'))
          .writeAsBytes(annotationOfficeFile('foreign'));
      final pdf = await File(p.join(foreign.path, 'preview.pdf'))
          .writeAsBytes(annotationPdf('foreign'));
      final engine = _engine((request, directory, cancellation) async {
        capture(request, directory);
        return {
          ...common(request),
          'status': 'saved',
          'sourcePath': source.path,
          'pdfPath': pdf.path,
          'sourceSha256': sha256.convert(await source.readAsBytes()).toString(),
          'pdfSha256': sha256.convert(await pdf.readAsBytes()).toString(),
          'pdfPageCount': 1,
        };
      });
      final operation = await start(engine);
      await expectLater(
        operation.result,
        throwsA(isA<WindowsOfficeException>()),
      );
      await operation.releaseOutputs();
      expect(await source.readAsBytes(), annotationOfficeFile('foreign'));
      expect(await pdf.readAsBytes(), annotationPdf('foreign'));
      expect(launched.single.existsSync(), isTrue);
    },
  );

  test('request replacement during editing cannot adopt a late result or authorize cleanup', () async {
    final entered = Completer<void>();
    final reply = Completer<Map<String, dynamic>>();
    final engine = _engine((request, directory, cancellation) async {
      capture(request, directory);
      entered.complete();
      return reply.future;
    });
    final operation = await start(engine);
    await entered.future;
    final value = await saved(requests.single, launched.single);
    final request = File(p.join(launched.single.path, 'request.json'));
    await request.writeAsString(
      jsonEncode({...requests.single, 'controlNonce': newId()}),
      flush: true,
    );
    final sentinel = await File(p.join(launched.single.path, 'foreign.bin'))
        .writeAsBytes([4, 5, 6]);
    reply.complete(value);
    await expectLater(operation.result, throwsA(isA<WindowsOfficeException>()));
    await operation.releaseOutputs();
    expect(await sentinel.readAsBytes(), [4, 5, 6]);
    expect(launched.single.existsSync(), isTrue);
  });

  test(
    'release rechecks ownership after the saved result has been copied',
    () async {
      final engine = _engine((request, directory, cancellation) async {
        capture(request, directory);
        return saved(request, directory);
      });
      final operation = await start(engine);
      await operation.result;
      final request = File(p.join(launched.single.path, 'request.json'));
      await request.writeAsString(
        jsonEncode({...requests.single, 'sessionId': newId()}),
        flush: true,
      );
      final foreign = await File(p.join(launched.single.path, 'foreign.bin'))
          .writeAsBytes([3, 2, 1]);
      await operation.releaseOutputs();
      expect(await foreign.readAsBytes(), [3, 2, 1]);
      expect(launched.single.existsSync(), isTrue);
    },
  );

  test('cancel does not bypass validation of a forged late response', () async {
    final entered = Completer<void>();
    final reply = Completer<Map<String, dynamic>>();
    final engine = _engine((request, directory, cancellation) async {
      capture(request, directory);
      entered.complete();
      return reply.future;
    });
    final operation = await start(engine);
    await entered.future;
    await operation.cancel();
    reply.complete({
      ...await saved(requests.single, launched.single),
      'controlNonce': newId(),
    });
    await expectLater(operation.result, throwsA(isA<WindowsOfficeException>()));
    expect(launched.single.existsSync(), isTrue);
  });

  test('release drains an in-flight cancellation file before removing saved outputs', () async {
    final entered = Completer<void>();
    final continueWrite = Completer<void>();
    final response = Completer<Map<String, dynamic>>();
    final realFile = Zone.current.bindUnaryCallback<File, String>(File.new);
    final engine = _engine((request, directory, cancellation) async {
      capture(request, directory);
      return response.future;
    });
    final operation = await start(engine);
    final cancellation = IOOverrides.runZoned(
      () => operation.cancel() as Future<void>,
      createFile: (path) {
        final file = realFile(path);
        return p.basename(path) == 'cancel.pending'
            ? _PausedCancellationFile(file, entered, continueWrite.future)
            : file;
      },
    );
    cancellation.ignore();
    await entered.future;
    response.complete(await saved(requests.single, launched.single));
    await operation.result;
    var released = false;
    final release = (operation.releaseOutputs() as Future<void>).then(
      (_) => released = true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final releasedBeforeCancellationWrite = released;
    continueWrite.complete();
    Object? cancellationFailure;
    try {
      await cancellation;
    } on Object catch (error) {
      cancellationFailure = error;
    }
    await release;
    expect(
      releasedBeforeCancellationWrite,
      isFalse,
      reason: 'Cleanup must wait for the cancellation writer that owns launch files',
    );
    expect(cancellationFailure, isNull);
    expect(launched.single.existsSync(), isFalse);
  });

  test(
    'an injected runner allocates no native runtime cache or diagnostic marker',
    () async {
      final systemTemp = Directory.systemTemp;
      final engine = _engine((request, directory, cancellation) async {
        capture(request, directory);
        expect(
          File(p.join(directory.path, 'runtime-temp.json')).existsSync(),
          isFalse,
        );
        return saved(request, directory);
      });
      final operation = await IOOverrides.runZoned(
        () => start(engine),
        getSystemTempDirectory: () =>
            _TrackedSystemTemp(systemTemp, runtimeCaches),
      );
      await operation.result;
      expect(runtimeCaches, isEmpty);
      await operation.releaseOutputs();
    },
  );

  test('backend failure is sanitized while the working copy and launch are retained', () async {
    final engine = _engine((request, directory, cancellation) async {
      capture(request, directory);
      throw StateError('private /outside path and sensitive backend detail');
    });
    final operation = await start(engine);
    await expectLater(
      operation.result,
      throwsA(
        isA<WindowsOfficeException>().having(
          (error) => error.message,
          'safe message',
          allOf(isNot(contains('/outside')), isNot(contains('sensitive'))),
        ),
      ),
    );
    await operation.releaseOutputs();
    expect(launched.single.existsSync(), isTrue);
    expect(sha256.convert(await working.readAsBytes()).toString(), inputHash);
  });

  test('invalid session, hash and private working location reject before the runner', () async {
    var calls = 0;
    final engine = _engine((request, directory, cancellation) async {
      calls++;
      return {...common(request), 'status': 'cancelled'};
    });
    for (final values in [
      (working.path, 'not-an-id', inputHash),
      (working.path, newId(), inputHash),
      (working.path, sessionId, 'not-a-hash'),
      (p.join(temporary.path, 'outside.docx'), sessionId, inputHash),
    ]) {
      await expectLater(
        _start(
          engine,
          workingPath: values.$1,
          sessionId: values.$2,
          inputSourceSha256: values.$3,
        ),
        throwsA(isA<Exception>()),
      );
    }
    expect(calls, 0);
    expect(sha256.convert(await working.readAsBytes()).toString(), inputHash);
  });

  test(
    'oversized working input rejects before invoking a native runner',
    () async {
      final oversized = await working.open(mode: FileMode.write);
      await oversized.truncate(128 * 1024 * 1024 + 1);
      await oversized.close();
      var calls = 0;
      final engine = _engine((request, directory, cancellation) async {
        calls++;
        return {...common(request), 'status': 'cancelled'};
      });
      await expectLater(start(engine), throwsA(isA<Exception>()));
      expect(calls, 0);
    },
  );

  group('default interactive PowerShell transport', () {
    late Directory helpers;

    Future<WindowsOfficeEngine> transport(
      String mode, {
      String? foreignPath,
    }) async {
      final runtime = Directory(p.join(temporary.path, 'transport runtime'));
      helpers = Directory(p.join(temporary.path, 'transport helpers 한글'));
      await Directory(p.join(runtime.path, 'program')).create(recursive: true);
      await File(p.join(runtime.path, 'program', 'python.exe'))
          .writeAsBytes(const []);
      await helpers.create();
      await File(p.join(helpers.path, 'source.docx'))
          .writeAsBytes(annotationOfficeFile('transport saved'));
      await File(p.join(helpers.path, 'preview.pdf'))
          .writeAsBytes(annotationPdf('transport saved'));
      await File(p.join(helpers.path, 'mode.json')).writeAsString(
        jsonEncode({'mode': mode, 'foreignPath': foreignPath}),
        encoding: utf8,
      );
      expect(_transportScript.codeUnits.every((unit) => unit < 128), isTrue);
      await File(p.join(helpers.path, 'run-office-interactive.ps1'))
          .writeAsString(_transportScript, encoding: utf8);
      return WindowsOfficeEngine(
        runtimePath: runtime.path,
        helperDirectory: helpers.path,
      );
    }

    Future<dynamic> startTransport(WindowsOfficeEngine engine) {
      final systemTemp = Directory.systemTemp;
      return IOOverrides.runZoned(
        () => start(engine),
        getSystemTempDirectory: () =>
            _TrackedSystemTemp(systemTemp, runtimeCaches),
      );
    }

    Future<Directory> observedCache(Directory launch) async {
      final observation = jsonDecode(
        await File(p.join(helpers.path, 'runtime-observation.json'))
            .readAsString(),
      ) as Map;
      final cachePath = observation['temp'] as String;
      expect(observation['tmp'], cachePath);
      expect(p.isAbsolute(cachePath), isTrue);
      expect(
        p.isWithin(launch.path, cachePath) || p.equals(launch.path, cachePath),
        isFalse,
        reason: 'LibreOffice needs a separate short cache instead of the deep launch directory',
      );
      expect(p.basename(cachePath), startsWith('piv-i-'));
      expect(
        p.dirname(cachePath),
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      expect(runtimeCaches.single.path, cachePath);
      final request = jsonDecode(
        await File(p.join(launch.path, 'request.json')).readAsString(),
      ) as Map;
      expect(observation['marker'], {
        'version': 1,
        'sessionId': sessionId,
        'controlNonce': request['controlNonce'],
        'path': cachePath,
      });
      return runtimeCaches.single;
    }

    Future<Directory> invoked() async {
      final invocation = File(p.join(helpers.path, 'invocation.json'));
      expect(
        invocation.existsSync(),
        isTrue,
        reason: 'The real default Process.start transport must run the owned helper',
      );
      final request = jsonDecode(await invocation.readAsString()) as Map;
      expect(request['sessionId'], sessionId);
      expect(request['inputSourceSha256'], inputHash);
      final launch = Directory(
        p.join(
          await working.parent.resolveSymbolicLinks(),
          'interactive-${request['controlNonce']}',
        ),
      );
      final diagnostic = File(p.join(launch.path, 'interactive-stderr.txt'));
      final stderr = diagnostic.existsSync()
          ? utf8.decode(await diagnostic.readAsBytes(), allowMalformed: true)
          : 'The owned helper did not emit stderr.';
      expect(
        File(p.join(launch.path, 'response.json')).existsSync(),
        isTrue,
        reason:
            'The invoked helper must publish its closed fixture response. $stderr',
      );
      expect(sha256.convert(await working.readAsBytes()).toString(), inputHash);
      return launch;
    }

    test('exit1 preserves the code of an owned closed error while hiding its raw message', () async {
      final engine = await transport('valid-error');
      expect(await _available(engine), isTrue);
      final operation = await startTransport(engine);
      await expectLater(
        operation.result,
        throwsA(
          isA<WindowsOfficeException>()
              .having(
                (error) => error.code,
                'owned backend code',
                'interactive_save_as_unbound',
              )
              .having(
                (error) => error.message,
                'safe message',
                allOf(
                  isNot(contains('C:\\outside')),
                  isNot(contains('private fixture')),
                ),
              ),
        ),
      );
      final launch = await invoked();
      final cache = await observedCache(launch);
      expect(
        cache.existsSync(),
        isTrue,
        reason: 'A failed native operation retains its cache for recovery',
      );
      await operation.releaseOutputs();
      expect(launch.existsSync(), isTrue);
    });

    for (final status in ['saved', 'cancelled']) {
      test(
        'a nonzero helper cannot authorize a successful $status result',
        () async {
          final engine = await transport('valid-$status');
          final operation = await startTransport(engine);
          await expectLater(
            operation.result,
            throwsA(isA<WindowsOfficeException>()),
          );
          final launch = await invoked();
          if (status == 'saved') {
            expect(
              await File(p.join(launch.path, 'edited.docx')).readAsBytes(),
              annotationOfficeFile('transport saved'),
            );
            expect(
              await File(p.join(launch.path, 'preview.pdf')).readAsBytes(),
              annotationPdf('transport saved'),
            );
          }
          await operation.releaseOutputs();
          expect(launch.existsSync(), isTrue);
        },
      );
    }

    for (final mode in ['foreign-error', 'malformed-error']) {
      test(
        'exit1 $mode cannot supply its claimed backend error code',
        () async {
          final engine = await transport(mode);
          final operation = await startTransport(engine);
          await expectLater(
            operation.result,
            throwsA(
              isA<WindowsOfficeException>().having(
                (error) => error.code,
                'validated error ownership and shape',
                isNot('interactive_save_as_unbound'),
              ),
            ),
          );
          final launch = await invoked();
          await operation.releaseOutputs();
          expect(launch.existsSync(), isTrue);
        },
      );
    }

    for (final status in ['saved', 'cancelled']) {
      test(
        'a validated $status result removes only its empty short runtime cache',
        () async {
          final engine = await transport('cache-$status-empty');
          final operation = await startTransport(engine);
          final OfficeOriginalEditResult result = await operation.result;
          expect(result.status.name, status);
          final launch = await invoked();
          final cache = await observedCache(launch);
          expect(cache.existsSync(), isFalse);
          await operation.releaseOutputs();
          if (status == 'saved') expect(launch.existsSync(), isFalse);
        },
      );
    }

    test(
      'saved recovery data retains its nonempty cache and diagnostic launch',
      () async {
        final engine = await transport('cache-saved-nonempty');
        final operation = await startTransport(engine);
        await operation.result;
        final launch = await invoked();
        final cache = await observedCache(launch);
        expect(
          await File(p.join(cache.path, 'retained-recovery.bin')).readAsBytes(),
          [19, 23, 29],
        );
        await operation.releaseOutputs();
        expect(launch.existsSync(), isTrue);
        expect(
          File(p.join(launch.path, 'runtime-temp.json')).existsSync(),
          isTrue,
        );
        expect(cache.existsSync(), isTrue);
      },
    );

    test('a diagnostic marker cannot authorize deletion of a foreign empty directory', () async {
      final foreign = await Directory(
        p.join(temporary.path, 'foreign-empty-cache'),
      ).create();
      final engine = await transport(
        'cache-saved-forged-marker',
        foreignPath: foreign.path,
      );
      final operation = await startTransport(engine);
      await operation.result;
      final launch = await invoked();
      final cache = await observedCache(launch);
      final forged = jsonDecode(
        await File(p.join(launch.path, 'runtime-temp.json')).readAsString(),
      ) as Map;
      expect(forged['path'], foreign.path);
      expect(cache.existsSync(), isFalse);
      expect(foreign.existsSync(), isTrue);
      await operation.releaseOutputs();
      expect(foreign.existsSync(), isTrue);
    });
  }, skip: !Platform.isWindows);
}

class _TrackedSystemTemp extends Fake implements Directory {
  new(this.directory, this.created);
  final Directory directory;
  final List<Directory> created;

  @override
  String get path => directory.path;

  @override
  Future<String> resolveSymbolicLinks() => directory.resolveSymbolicLinks();

  @override
  Future<Directory> createTemp([String? prefix]) async {
    final result = prefix == null
        ? await directory.createTemp()
        : await directory.createTemp(prefix);
    if (prefix == 'piv-i-')
      created.add(Directory(await result.resolveSymbolicLinks()));
    return result;
  }
}

class _PausedCancellationFile extends Fake implements File {
  new(this.file, this.entered, this.continueWrite);
  final File file;
  final Completer<void> entered;
  final Future<void> continueWrite;

  @override
  String get path => file.path;

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await file.create(recursive: recursive, exclusive: exclusive);
    entered.complete();
    await continueWrite;
    return this;
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await file.writeAsBytes(bytes, mode: mode, flush: flush);
    return this;
  }

  @override
  Future<File> rename(String newPath) => file.rename(newPath);
}

class _InterruptedRequestFile extends Fake implements File {
  new(this.file, this.interruption);
  final File file;
  final String interruption;

  @override
  String get path => file.path;

  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    await file.create(recursive: recursive, exclusive: exclusive);
    if (interruption == 'create')
      throw const FileSystemException('fixture interrupted request creation');
    return this;
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await file.writeAsBytes(
      bytes.sublist(0, bytes.length ~/ 2),
      mode: mode,
      flush: flush,
    );
    throw const FileSystemException('fixture interrupted request write');
  }
}

const _transportScript = r'''
param([Parameter(Mandatory)][string]$RuntimePath,
      [Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$raw = [System.IO.File]::ReadAllText($RequestPath, [System.Text.Encoding]::UTF8)
$request = ConvertFrom-Json -InputObject $raw
function Read-FixtureHash([string]$Path) {
    $hashStream = $null
    $algorithm = $null
    try {
        $hashStream = [System.IO.File]::OpenRead($Path)
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($hashStream))).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($null -ne $hashStream) { $hashStream.Dispose() }
        if ($null -ne $algorithm) { $algorithm.Dispose() }
    }
}
$modePath = Join-Path $PSScriptRoot 'mode.json'
$settings = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($modePath, [System.Text.Encoding]::UTF8))
$mode = $settings.mode
$launch = Split-Path -Parent $RequestPath
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'invocation.json'), $raw, $utf8)
$tempMarker = Join-Path $launch 'runtime-temp.json'
$marker = $null
if ([System.IO.File]::Exists($tempMarker)) {
    $marker = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($tempMarker, [System.Text.Encoding]::UTF8))
}
$observation = [ordered]@{ temp = $env:TEMP; tmp = $env:TMP; marker = $marker }
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'runtime-observation.json'), ($observation | ConvertTo-Json -Depth 8), $utf8)
if ($mode -eq 'cache-saved-nonempty') {
    [System.IO.File]::WriteAllBytes((Join-Path $env:TEMP 'retained-recovery.bin'), [byte[]]@(19, 23, 29))
}
if ($mode -eq 'cache-saved-forged-marker') {
    $forgedMarker = [ordered]@{ version = 1; sessionId = [string]$request.sessionId; controlNonce = [string]$request.controlNonce; path = [string]$settings.foreignPath }
    [System.IO.File]::WriteAllText($tempMarker, ($forgedMarker | ConvertTo-Json -Depth 8), $utf8)
}
$response = [ordered]@{
    version = 1
    sessionId = [string]$request.sessionId
    controlNonce = [string]$request.controlNonce
    inputSourceSha256 = [string]$request.inputSourceSha256
    status = 'error'
    engineVersion = 'LibreOffice26.8.2.2'
}
if ($mode -eq 'valid-saved' -or $mode -like 'cache-saved-*') {
    $source = Join-Path $launch 'edited.docx'
    $pdf = Join-Path $launch 'preview.pdf'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'source.docx') -Destination $source -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'preview.pdf') -Destination $pdf -ErrorAction Stop
    $response['status'] = 'saved'
    $response['sourcePath'] = $source
    $response['pdfPath'] = $pdf
    $response['sourceSha256'] = Read-FixtureHash $source
    $response['pdfSha256'] = Read-FixtureHash $pdf
    $response['pdfPageCount'] = 1
} elseif ($mode -eq 'valid-cancelled' -or $mode -eq 'cache-cancelled-empty') {
    $response['status'] = 'cancelled'
} else {
    $response['error'] = [ordered]@{
        code = 'interactive_save_as_unbound'
        message = 'private fixture C:\outside\private.docx'
    }
    if ($mode -eq 'foreign-error') {
        $response['sessionId'] = [System.Guid]::NewGuid().ToString('D')
    } elseif ($mode -eq 'malformed-error') {
        $response['error']['message'] = 17
    }
}
[System.IO.File]::WriteAllText((Join-Path $launch 'response.json'), ($response | ConvertTo-Json -Depth 8), $utf8)
if ($mode -like 'cache-*') { exit 0 }
exit 1
''';
