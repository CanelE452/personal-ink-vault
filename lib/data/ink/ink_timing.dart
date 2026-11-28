import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

/// Whether this is a measurement build (tablet measurement 1 of stage 2):
/// `flutter build apk --dart-define=PIV_INK_TIMING=true`. Every other build
/// records no frame times and plays no input.
const inkTimingOn = bool.fromEnvironment('PIV_INK_TIMING');

/// One frame at 120 Hz, in ms, as the measurement's pass mark writes it
/// (p95 at most 8.3 ms).
const inkFrameBudgetMs = 8.3;

/// What one measurement saw: the build and raster times of its frames in ms
/// (the 50th and 95th percentile), how many frames went over
/// [inkFrameBudgetMs] in either, and how many frames there were.
typedef InkTimingResult = ({
  String name,
  double buildP50,
  double buildP95,
  double rasterP50,
  double rasterP95,
  int over8ms,
  int frames,
});

/// Records the build and raster time of each frame the engine reports
/// ([SchedulerBinding.addTimingsCallback]) that began after [start] and,
/// once [markEnd] is called, by then.
///
/// The engine hands frame times over in batches, up to a second late in a
/// release build: a caller marks the end when its last step is done, waits
/// that long, and then calls [stop]. Frames are told apart by the engine's
/// frame number ([FrameTiming.frameNumber] against
/// [PlatformDispatcher.frameData]); a timing without one (-1) is counted.
class FrameTimingRecorder {
  /// A recorder that is not [enabled] never listens and records nothing.
  new({this.enabled = inkTimingOn});

  final bool enabled;

  var _name = '';
  final _build = <double>[];
  final _raster = <double>[];
  var _listening = false;

  /// Frames numbered above [_from], and up to [_to] when it is set, count.
  var _from = -1;
  int? _to;

  /// Forgets what was recorded and records the frames from now on as [name].
  void start(String name) {
    _name = name;
    _build.clear();
    _raster.clear();
    _from = _frameNow;
    _to = null;
    if (!enabled || _listening) return;
    SchedulerBinding.instance.addTimingsCallback(_record);
    _listening = true;
  }

  /// The last step is done: frames begun later than the one it asked for
  /// (the next frame) are not counted.
  void markEnd() => _to = _frameNow + 1;

  /// Stops recording and gives what was recorded since [start].
  InkTimingResult stop() {
    if (_listening) {
      SchedulerBinding.instance.removeTimingsCallback(_record);
      _listening = false;
    }
    final build = [..._build]..sort();
    final raster = [..._raster]..sort();
    var over = 0;
    for (var i = 0; i < _build.length; i++) {
      if (_build[i] > inkFrameBudgetMs || _raster[i] > inkFrameBudgetMs) {
        over++;
      }
    }
    return (
      name: _name,
      buildP50: _percentile(build, 0.5),
      buildP95: _percentile(build, 0.95),
      rasterP50: _percentile(raster, 0.5),
      rasterP95: _percentile(raster, 0.95),
      over8ms: over,
      frames: _build.length,
    );
  }

  void _record(List<FrameTiming> timings) {
    for (final timing in timings) {
      final number = timing.frameNumber;
      if (number >= 0 && (number <= _from || number > (_to ?? number))) {
        continue;
      }
      _build.add(timing.buildDuration.inMicroseconds / 1000);
      _raster.add(timing.rasterDuration.inMicroseconds / 1000);
    }
  }

  static int get _frameNow =>
      SchedulerBinding.instance.platformDispatcher.frameData.frameNumber;

  /// The nearest-rank percentile [p] (0 to 1) of [sorted], 0 when empty.
  static double _percentile(List<double> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final rank = (p * sorted.length).ceil().clamp(1, sorted.length);
    return sorted[rank - 1];
  }
}

/// Writes [result] to `ink-timing/<name>.json` in the app's own folder (or
/// in [directory]) and logs it as one line `PIV_TIMING <json>`, which the
/// measurement script reads from the app's log.
Future<void> writeTimingResult(
  InkTimingResult result, {
  Directory? directory,
}) async {
  final json = jsonEncode({
    'name': result.name,
    'buildP50': result.buildP50,
    'buildP95': result.buildP95,
    'rasterP50': result.rasterP50,
    'rasterP95': result.rasterP95,
    'over8ms': result.over8ms,
    'frames': result.frames,
  });
  final root = directory ?? await getApplicationSupportDirectory();
  final folder = Directory('${root.path}/ink-timing');
  await folder.create(recursive: true);
  await File('${folder.path}/${result.name}.json').writeAsString(json);
  debugPrint('PIV_TIMING $json');
}
