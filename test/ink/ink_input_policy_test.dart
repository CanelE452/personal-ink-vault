import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/ink/ink_input_policy.dart';

void main() {
  InkRoute route(
    PointerDeviceKind device, {
    int touches = 1,
    bool gesture = false,
    bool finger = false,
    bool panTool = false,
    bool lock = false,
  }) => inkRoute(
    device: device,
    touches: touches,
    gestureMode: gesture,
    fingerDrawing: finger,
    panTool: panTool,
    singleFingerPanLock: lock,
  );

  // Rows follow the editor's isDrawGesture (editor.dart); the editor does
  // not look at mouse buttons.
  test('route stylus with finger drawing off is draw', () {
    expect(route(PointerDeviceKind.stylus), InkRoute.draw);
  });
  test('route invertedStylus with finger drawing off is draw', () {
    expect(route(PointerDeviceKind.invertedStylus), InkRoute.draw);
  });
  test('route touch with finger drawing on is draw', () {
    expect(route(PointerDeviceKind.touch, finger: true), InkRoute.draw);
  });
  test('route touch with finger drawing off is pan', () {
    expect(route(PointerDeviceKind.touch), InkRoute.pan);
  });
  test('route touch with finger drawing off and pan lock is ignore', () {
    expect(route(PointerDeviceKind.touch, lock: true), InkRoute.ignore);
  });
  test('route two touches with pan lock is pan', () {
    expect(
      route(PointerDeviceKind.touch, touches: 2, finger: true, lock: true),
      InkRoute.pan,
    );
  });
  test('route touch in gesture mode is pan', () {
    expect(
      route(PointerDeviceKind.touch, gesture: true, finger: true),
      InkRoute.pan,
    );
  });
  test('route stylus in gesture mode is pan', () {
    expect(route(PointerDeviceKind.stylus, gesture: true), InkRoute.pan);
  });
  test('route mouse with finger drawing on is draw', () {
    expect(route(PointerDeviceKind.mouse, finger: true), InkRoute.draw);
  });
  test('route mouse with finger drawing off is pan', () {
    expect(route(PointerDeviceKind.mouse), InkRoute.pan);
  });
  test('route mouse in gesture mode with pan lock is pan', () {
    expect(
      route(PointerDeviceKind.mouse, gesture: true, lock: true),
      InkRoute.pan,
    );
  });
  test('route stylus with the pan tool and pan lock is pan', () {
    expect(
      route(PointerDeviceKind.stylus, panTool: true, lock: true),
      InkRoute.pan,
    );
  });
  test('route stylus with the pan tool is pan', () {
    expect(route(PointerDeviceKind.stylus, panTool: true), InkRoute.pan);
  });
  test('route trackpad with finger drawing on is pan', () {
    expect(route(PointerDeviceKind.trackpad, finger: true), InkRoute.pan);
  });

  test('stylus touch turns finger drawing off unless the toggle is hidden', () {
    bool off(PointerDeviceKind d, bool auto, bool hidden) =>
        stylusTurnsFingerDrawingOff(
          device: d,
          autoDisable: auto,
          toggleHidden: hidden,
        );
    expect(off(PointerDeviceKind.stylus, true, false), isTrue);
    expect(off(PointerDeviceKind.invertedStylus, true, false), isTrue);
    expect(off(PointerDeviceKind.stylus, true, true), isFalse);
    expect(off(PointerDeviceKind.stylus, false, false), isFalse);
    expect(off(PointerDeviceKind.touch, true, false), isFalse);
    expect(off(PointerDeviceKind.mouse, true, false), isFalse);
  });
}
