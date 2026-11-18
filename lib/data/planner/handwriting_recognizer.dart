import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/user_error.dart';

/// Whether a language's model can read handwriting on this device.
enum HandwritingModelState { ready, missing, unavailable }

/// A language the engine reads: its name, and the size of its model as ML
/// Kit's own model list gives it (downloaded from dl.google.com, then kept on
/// the device).
typedef HandwritingLanguage = ({String name, String download, String stored});

/// The languages the engine reads, by language tag, 한국어 first.
const handwritingLanguages = <String, HandwritingLanguage>{
  'ko': (name: '한국어', download: '15.7MB', stored: '25MB'),
  'en-US': (name: '영어', download: '13.8MB', stored: '26MB'),
};

abstract interface class HandwritingRecognizer {
  /// The model downloads, which outlive the page that started them.
  HandwritingModels get models;

  Future<HandwritingModelState> modelState(String language);

  /// Downloads [language]'s model; it can take minutes. Pages go through
  /// [models], which keeps the download running and its outcome.
  Future<void> downloadModel(String language);

  /// Readings of [strokes], best first. Their points are in 0..1 of [area],
  /// the writing area, whose size tells the engine how large the writing is.
  Future<List<String>> recognize(
    List<InkStroke> strokes, {
    String language = 'ko',
    required Size area,
  });
}

class HandwritingUnavailable implements Exception {
  final message = '손글씨 인식 엔진이 아직 이 앱에 없습니다. 글 칸에 펜으로 직접 쓰면 입력기가 글자로 바꿉니다.';

  @override
  String toString() => message;
}

/// The language's model is not on the device (any more): it must be
/// downloaded first.
class HandwritingModelMissing implements Exception {
  final message = '손글씨 모델을 먼저 받아야 합니다.';

  @override
  String toString() => message;
}

/// Model downloads, run in the background: a download outlives the page
/// that started it, so a page opened again still shows it running.
class HandwritingModels extends ChangeNotifier {
  new(this._download);

  final Future<void> Function(String language) _download;
  final _running = <String, Future<void>>{};
  final _errors = <String, Object>{};

  bool downloading(String language) => _running.containsKey(language);

  /// Why [language]'s last download failed; null once one succeeded, while
  /// one runs, or before any.
  Object? lastError(String language) => _errors[language];

  /// Downloads [language]'s model, unless that download is running already.
  /// The future ends with the download and never fails: a failure is kept
  /// in [lastError].
  Future<void> start(String language) {
    final running = _running[language];
    if (running != null) return running;
    _errors.remove(language);
    final download = Future.sync(() => _download(language))
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            logUserError(error, stackTrace);
            _errors[language] = error;
          },
        )
        .whenComplete(() {
          _running.remove(language);
          notifyListeners();
        });
    _running[language] = download;
    notifyListeners();
    return download;
  }
}

/// ML Kit digital ink through the Android side (HandwritingBridge.kt). Where
/// the channel has no handler (Windows, tests) the engine is unavailable.
class PlatformHandwritingRecognizer implements HandwritingRecognizer {
  static const channel = MethodChannel('personal_ink_vault/handwriting');

  /// The app's one recognizer, so its downloads outlive the calendar page.
  static final shared = PlatformHandwritingRecognizer();

  @override
  late final models = HandwritingModels(downloadModel);

  @override
  Future<HandwritingModelState> modelState(String language) async {
    try {
      final state = await _call(
        () => channel.invokeMethod<String>('modelStatus', {
          'language': language,
        }),
      );
      return switch (state) {
        'ready' => HandwritingModelState.ready,
        'missing' => HandwritingModelState.missing,
        _ => HandwritingModelState.unavailable,
      };
    } on HandwritingUnavailable {
      return HandwritingModelState.unavailable;
    }
  }

  @override
  Future<void> downloadModel(String language) => _call(
    () => channel.invokeMethod<void>('downloadModel', {'language': language}),
  );

  @override
  Future<List<String>> recognize(
    List<InkStroke> strokes, {
    String language = 'ko',
    required Size area,
  }) async {
    final result = await _call(
      () => channel.invokeListMethod<String>('recognize', {
        'language': language,
        'width': area.width,
        'height': area.height,
        // Flat [x0, y0, x1, y1, ...] lists in the writing area's units.
        'strokes': [
          for (final stroke in strokes)
            [
              for (final (index, value) in stroke.points.indexed)
                value * (index.isEven ? area.width : area.height),
            ],
        ],
      }),
    );
    return result ?? const [];
  }

  /// [call], with the answers meaning "no engine" (no handler, `unavailable`)
  /// as [HandwritingUnavailable] and `model_missing` as
  /// [HandwritingModelMissing].
  static Future<T> _call<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on MissingPluginException {
      throw HandwritingUnavailable();
    } on PlatformException catch (error) {
      if (error.code == 'unavailable') throw HandwritingUnavailable();
      if (error.code == 'model_missing') throw HandwritingModelMissing();
      rethrow;
    }
  }
}
