import 'package:flutter/foundation.dart';

/// Screens this app opens over itself: the Android document picker and the Office engine.
///
/// While one is in front, Android reports the app as paused although the user has not left it,
/// so background handling (saving, Drive handoff) waits until the screen has returned.
abstract final class AppExternalScreen {
  static final ValueNotifier<int> _open = ValueNotifier(0);

  static ValueListenable<int> get open => _open;
  static bool get active => _open.value > 0;

  static Future<T> run<T>(Future<T> Function() task) async {
    _open.value++;
    try {
      return await task();
    } finally {
      _open.value--;
    }
  }

  static final Set<String> _editorsInFront = {};

  /// An Office·한글 editor stays open behind the app's tabs, so it counts only while it is in
  /// front: from opening or bringing it back until the user leaves it or it closes. Repeated
  /// calls for one session count once.
  static void editorInFront(String sessionId) {
    if (_editorsInFront.add(sessionId)) _open.value++;
  }

  static void editorBehind(String sessionId) {
    if (_editorsInFront.remove(sessionId)) _open.value--;
  }
}
