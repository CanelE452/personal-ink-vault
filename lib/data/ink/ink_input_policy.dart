import 'package:flutter/gestures.dart';

/// What a pointer that just landed does on a page.
enum InkRoute { draw, pan, ignore }

/// The one rule for "does this pointer draw, move the view or do nothing".
/// The editor, the infinite note and the quick note all ask it.
///
/// The editor does not look at mouse buttons (a mouse follows finger
/// drawing). The pen's button (eraser) and the infinite note's middle and
/// secondary mouse buttons (pan) are decided outside this function.
InkRoute inkRoute({
  required PointerDeviceKind device,
  int touches = 1,
  required bool gestureMode,
  required bool fingerDrawing,
  bool panTool = false,
  bool singleFingerPanLock = false,
}) {
  if (device == PointerDeviceKind.trackpad) return InkRoute.pan;
  // the lock is about fingers: a pen or mouse still pans
  final pan =
      device == PointerDeviceKind.touch && touches < 2 && singleFingerPanLock
      ? InkRoute.ignore
      : InkRoute.pan;
  if (touches >= 2 || gestureMode || panTool) return pan;
  final pen =
      device == PointerDeviceKind.stylus ||
      device == PointerDeviceKind.invertedStylus;
  if (pen || fingerDrawing) return InkRoute.draw;
  return pan;
}

/// A pen touching the screen switches finger drawing off (when the user
/// has not pinned the toggle).
bool stylusTurnsFingerDrawingOff({
  required PointerDeviceKind device,
  required bool autoDisable,
  required bool toggleHidden,
}) =>
    (device == PointerDeviceKind.stylus ||
        device == PointerDeviceKind.invertedStylus) &&
    autoDisable &&
    !toggleHidden;
