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
}
