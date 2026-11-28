import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/ink/ink_timing.dart';
import 'package:saber/pages/editor/ink_timing_replay.dart';

/// A frame whose build took [buildMs] and whose raster took [rasterMs];
/// [number] is the engine's frame number (-1 when not known).
FrameTiming _frame(double buildMs, double rasterMs, {int number = -1}) {
  final build = (buildMs * 1000).round();
  final raster = (rasterMs * 1000).round();
  return FrameTiming(
    vsyncStart: 0,
    buildStart: 1000,
    buildFinish: 1000 + build,
    rasterStart: 1000 + build,
    rasterFinish: 1000 + build + raster,
    rasterFinishWallTime: 1000 + build + raster,
    frameNumber: number,
  );
}

/// The number of the frame the engine began last.
int get _frameNow =>
    SchedulerBinding.instance.platformDispatcher.frameData.frameNumber;

/// The engine reports [frames] the way it does on a device: through the
/// binding's timings callbacks.
void _report(List<FrameTiming> frames) =>
    SchedulerBinding.instance.platformDispatcher.onReportTimings?.call(frames);

/// Measurement hooks (stage 2, tablet measurement 1): on only in a build made
/// with `--dart-define=PIV_INK_TIMING=true`. The tests pass `enabled` to see
/// both ways, since the build value is always false here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a disabled recorder records nothing', () {
    final recorder = FrameTimingRecorder(enabled: false)..start('off');
    _report([_frame(12, 3), _frame(2, 9)]);
    final result = recorder.stop();
    expect(result.name, 'off');
    expect(result.frames, 0);
    expect(result.over8ms, 0);
    expect(
      [result.buildP50, result.buildP95, result.rasterP50, result.rasterP95],
      [0, 0, 0, 0],
    );
  });

  test('an enabled recorder records the frames it sees', () {
    final recorder = FrameTimingRecorder(enabled: true);
    // before start and after stop it is not listening
    _report([_frame(30, 30)]);
    recorder.start('on');
    _report([_frame(2, 3), _frame(4, 5)]);
    _report([_frame(6, 1)]);
    final result = recorder.stop();
    expect(result.name, 'on');
    expect(result.frames, 3);
    expect(result.buildP95, 6);
    expect(result.rasterP95, 5);
    expect(result.over8ms, 0);
    _report([_frame(30, 30)]);
    // a new start forgets the last recording
    recorder.start('again');
    _report([_frame(9, 1)]);
    final again = recorder.stop();
    expect(again.name, 'again');
    expect(again.frames, 1);
    expect(again.over8ms, 1);
  });

  test('enabled defaults to the build value', () {
    expect(FrameTimingRecorder().enabled, inkTimingOn);
    expect(InkTimingReplay().enabled, inkTimingOn);
    // so a recorder made the usual way follows the build: records nothing
    // here, where the build value is not set
    final recorder = FrameTimingRecorder()..start('default');
    _report([_frame(3, 3)]);
    expect(recorder.stop().frames, inkTimingOn ? 1 : 0);
  });

  test('p95 is computed from the recorded frames', () {
    final recorder = FrameTimingRecorder(enabled: true)..start('p95');
    // build 1 to 20 ms, given last to first; raster 1 ms but 10 ms for the
    // 1 ms build frame
    _report([
      for (var i = 20; i >= 1; i--) _frame(i.toDouble(), i == 1 ? 10 : 1),
    ]);
    final result = recorder.stop();
    expect(result.frames, 20);
    // nearest rank: the 10th and the 19th of 20 sorted values
    expect(result.buildP50, 10);
    expect(result.buildP95, 19);
    expect(result.rasterP50, 1);
    expect(result.rasterP95, 1);
    // build over 8.3 ms (9 to 20 ms) or raster over it (the 1 ms frame)
    expect(result.over8ms, 13);
  });

  test('only frames begun after start and by the end mark are counted', () {
    final now = _frameNow;
    final recorder = FrameTimingRecorder(enabled: true)..start('window');
    // the frame begun before start comes late, with the first batch
    _report([_frame(20, 20, number: now), _frame(2, 2, number: now + 1)]);
    // the end mark: the frame the last step asked for is the next one
    recorder.markEnd();
    _report([
      _frame(3, 3, number: now + 1),
      _frame(30, 30, number: now + 2),
      _frame(40, 40, number: now + 3),
    ]);
    final result = recorder.stop();
    expect(result.frames, 2);
    expect(result.buildP95, 3);
    expect(result.over8ms, 0);
    // without a mark every frame after start counts
    recorder.start('no mark');
    _report([_frame(9, 1, number: now + 1), _frame(9, 1, number: now + 9)]);
    expect(recorder.stop().frames, 2);
  });

  test('a result goes to its json file and one PIV_TIMING line', () async {
    final temp = await Directory.systemTemp.createTemp('ink-timing-');
    addTearDown(() => temp.delete(recursive: true));
    final lines = <String>[];
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) => lines.add(message ?? '');
    addTearDown(() => debugPrint = print);
    const result = (
      name: 'draw-fountain',
      buildP50: 1.5,
      buildP95: 4.25,
      rasterP50: 2.0,
      rasterP95: 6.5,
      over8ms: 3,
      frames: 240,
    );
    await writeTimingResult(result, directory: temp);
    final file = File('${temp.path}/ink-timing/draw-fountain.json');
    final json = jsonDecode(await file.readAsString());
    const expected = {
      'name': 'draw-fountain',
      'buildP50': 1.5,
      'buildP95': 4.25,
      'rasterP50': 2.0,
      'rasterP95': 6.5,
      'over8ms': 3,
      'frames': 240,
    };
    expect(json, expected);
    expect(lines, hasLength(1));
    expect(lines.single, startsWith('PIV_TIMING {'));
    expect(jsonDecode(lines.single.substring('PIV_TIMING '.length)), expected);
  });
}
