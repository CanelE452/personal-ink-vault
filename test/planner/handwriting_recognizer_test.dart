import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/planner/handwriting_recognizer.dart';
import 'package:saber/data/planner/planner_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = PlatformHandwritingRecognizer.channel;
  const strokes = [
    InkStroke(points: [0.0, 0.0, 0.5, 1.0], color: 0xFF000000, width: 0.01),
    InkStroke(points: [0.25, 0.5], color: 0xFF000000, width: 0.01),
  ];
  const area = Size(700, 350);

  void answer(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  test('channel name matches the native side', () {
    expect(channel.name, 'personal_ink_vault/handwriting');
  });

  test('modelStatus answers become model states', () async {
    final asked = <MethodCall>[];
    answer((call) async {
      asked.add(call);
      return switch ((call.arguments as Map)['language']) {
        'ko' => 'ready',
        'en-US' => 'missing',
        _ => 'something new',
      };
    });
    final recognizer = PlatformHandwritingRecognizer();
    expect(await recognizer.modelState('ko'), HandwritingModelState.ready);
    expect(
      await recognizer.modelState('en-US'),
      HandwritingModelState.missing,
    );
    // An answer the app does not know cannot be used.
    expect(
      await recognizer.modelState('ja'),
      HandwritingModelState.unavailable,
    );
    expect([for (final call in asked) call.method], [
      'modelStatus',
      'modelStatus',
      'modelStatus',
    ]);
    expect(asked.first.arguments, {'language': 'ko'});
  });

  test('recognize sends the language, the writing area and the strokes in '
      "the area's units, and returns the readings", () async {
    MethodCall? seen;
    answer((call) async {
      seen = call;
      return ['meeting', 'meetings'];
    });
    final readings = await PlatformHandwritingRecognizer().recognize(
      strokes,
      language: 'en-US',
      area: area,
    );
    expect(readings, ['meeting', 'meetings']);
    expect(seen!.method, 'recognize');
    expect(seen!.arguments, {
      'language': 'en-US',
      'width': 700.0,
      'height': 350.0,
      'strokes': [
        [0.0, 0.0, 350.0, 350.0],
        [175.0, 175.0],
      ],
    });
  });

  test('recognize reads Korean unless told otherwise', () async {
    MethodCall? seen;
    answer((call) async {
      seen = call;
      return null;
    });
    expect(
      await PlatformHandwritingRecognizer().recognize(strokes, area: area),
      isEmpty,
    );
    expect((seen!.arguments as Map)['language'], 'ko');
  });

  test('model_missing from recognize means the model must be downloaded', () {
    answer(
      (call) async => throw PlatformException(
        code: 'model_missing',
        message: '손글씨 모델을 먼저 받아야 합니다.',
      ),
    );
    expect(
      PlatformHandwritingRecognizer().recognize(strokes, area: area),
      throwsA(isA<HandwritingModelMissing>()),
    );
  });

  test('a missing plugin means the engine is unavailable', () async {
    final recognizer = PlatformHandwritingRecognizer();
    expect(
      await recognizer.modelState('ko'),
      HandwritingModelState.unavailable,
    );
    await expectLater(
      recognizer.recognize(strokes, area: area),
      throwsA(isA<HandwritingUnavailable>()),
    );
    await expectLater(
      recognizer.downloadModel('ko'),
      throwsA(isA<HandwritingUnavailable>()),
    );
  });

  test('the unavailable error code means the engine is unavailable', () async {
    answer(
      (call) async => throw PlatformException(
        code: 'unavailable',
        message: 'ML Kit did not start',
      ),
    );
    final recognizer = PlatformHandwritingRecognizer();
    expect(
      await recognizer.modelState('ko'),
      HandwritingModelState.unavailable,
    );
    await expectLater(
      recognizer.recognize(strokes, area: area),
      throwsA(isA<HandwritingUnavailable>()),
    );
    await expectLater(
      recognizer.downloadModel('ko'),
      throwsA(isA<HandwritingUnavailable>()),
    );
  });

  group('model downloads', () {
    test('a failed download keeps its error, and a second start retries', () async {
      final asked = <MethodCall>[];
      var fail = true;
      answer((call) async {
        asked.add(call);
        if (fail) {
          throw PlatformException(
            code: 'download_failed',
            message: '네트워크에 연결되어 있지 않습니다.',
          );
        }
        return null;
      });
      final models = PlatformHandwritingRecognizer().models;
      var changes = 0;
      models.addListener(() => changes++);

      final first = models.start('ko');
      expect(models.downloading('ko'), isTrue);
      expect(changes, 1);
      await first;
      expect(models.downloading('ko'), isFalse);
      expect(changes, 2);
      expect(
        models.lastError('ko'),
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'download_failed')
            .having(
              (error) => error.message,
              'message',
              '네트워크에 연결되어 있지 않습니다.',
            ),
      );

      fail = false;
      final second = models.start('ko');
      // A new try clears the old reason.
      expect(models.lastError('ko'), isNull);
      await second;
      expect(models.lastError('ko'), isNull);
      expect(models.downloading('ko'), isFalse);
      expect(changes, 4);
      expect([for (final call in asked) call.method], [
        'downloadModel',
        'downloadModel',
      ]);
      expect(asked.last.arguments, {'language': 'ko'});
    });

    test('a running download is not started twice', () async {
      final finish = Completer<void>();
      final asked = <String>[];
      final models = HandwritingModels((language) {
        asked.add(language);
        return language == 'ko' ? finish.future : Future.value();
      });
      final first = models.start('ko');
      final again = models.start('ko');
      expect(identical(first, again), isTrue);
      expect(asked, ['ko']);
      // Another language downloads beside it.
      await models.start('en-US');
      expect(asked, ['ko', 'en-US']);
      expect(models.downloading('en-US'), isFalse);
      expect(models.downloading('ko'), isTrue);

      finish.complete();
      await first;
      expect(models.downloading('ko'), isFalse);
      expect(models.lastError('ko'), isNull);
      expect(asked, ['ko', 'en-US']);
    });

    test('a download that cannot start ends with its reason', () async {
      final models = PlatformHandwritingRecognizer().models;
      await models.start('ko');
      expect(models.downloading('ko'), isFalse);
      expect(models.lastError('ko'), isA<HandwritingUnavailable>());
    });
  });
}
