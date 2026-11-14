import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/imports/image_capture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('personal_ink_vault/camera');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'Windows reports camera unavailable without invoking a device channel',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw StateError('No device call permitted'),
      );
      const capture = NativeImageCapture(platform: TargetPlatform.windows);
      expect((await capture.capabilities()).available, isFalse);
      await expectLater(
        capture.capture(),
        throwsA(
          isA<ImageCaptureException>().having(
            (e) => e.code,
            'code',
            'unavailable',
          ),
        ),
      );
    },
  );
  test('Android capabilities and full-resolution capture use the native channel path', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => switch (call.method) {
        'capabilities' => {'available': true},
        'capture' => {
          'path': '/private/photo-imports/photo.jpg',
          'fileName': 'photo.jpg',
        },
        _ => throw StateError('Unexpected method'),
      },
    );
    const capture = NativeImageCapture(platform: TargetPlatform.android);
    expect((await capture.capabilities()).available, isTrue);
    expect((await capture.capture())!.path, '/private/photo-imports/photo.jpg');
  });
  test(
    'cancelled camera returns no photo and an unavailable bridge is explicit',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'capabilities' ? {'available': true} : null,
      );
      const capture = NativeImageCapture(platform: TargetPlatform.android);
      expect(await capture.capture(), isNull);
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw MissingPluginException(),
      );
      expect((await capture.capabilities()).available, isFalse);
      await expectLater(
        capture.capture(),
        throwsA(
          isA<ImageCaptureException>().having(
            (e) => e.code,
            'code',
            'unavailable',
          ),
        ),
      );
    },
  );
  test('native capture errors retain their code and malformed responses are rejected', () async {
    const capture = NativeImageCapture(platform: TargetPlatform.android);
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'capabilities') return {'available': true};
      throw PlatformException(
        code: 'invalid_image',
        message: 'Photo was incomplete',
      );
    });
    await expectLater(
      capture.capture(),
      throwsA(
        isA<ImageCaptureException>().having(
          (e) => e.code,
          'code',
          'invalid_image',
        ),
      ),
    );
    messenger.setMockMethodCallHandler(
      channel,
      (call) async =>
          call.method == 'capabilities' ? {'available': true} : {'path': ''},
    );
    await expectLater(
      capture.capture(),
      throwsA(
        isA<ImageCaptureException>().having(
          (e) => e.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });
}
