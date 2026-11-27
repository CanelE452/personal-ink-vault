import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart' show EagerGestureRecognizer, kTouchSlop;
import 'package:flutter/material.dart';

import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// A small switch: 32 x 18, the thumb slides, the track turns accent.
class KitSwitch extends StatelessWidget {
  const new({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: KitMotion.of(context, KitMotionStep.fast),
      curve: KitMotion.openCurve,
      width: KitTokens.switchWidth,
      height: KitTokens.switchHeight,
      padding: const EdgeInsets.all(KitTokens.switchInset),
      decoration: BoxDecoration(
        color: value ? KitTokens.accent : KitTokens.switchOff,
        borderRadius: BorderRadius.circular(KitTokens.switchHeight / 2),
      ),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      child: const DecoratedBox(
        decoration: BoxDecoration(
          color: KitTokens.controlThumb,
          shape: BoxShape.circle,
          boxShadow: KitTokens.switchThumbShadow,
        ),
        child: SizedBox.square(dimension: KitTokens.switchThumb),
      ),
    );
  }
}

/// One line with a name, optional lines under it, and a switch. With lines
/// under the name, the name and the switch stay at the top (`.snp .tg.tx`).
/// [onChanged] null: the name and the switch are dimmed and it cannot be
/// pressed.
class KitToggleRow extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.reason,
    this.description,
    this.lockedReason,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Why the line is off or dim; the last line, in the secondary colour.
  final String? reason;

  /// What the line does; under the name, above [reason].
  final String? description;

  /// Set when the switch cannot be changed now although it works (the last
  /// lasso target on): it keeps its look, takes no tap, and screen readers
  /// hear it cannot be changed and this reason (the preview's
  /// `aria-disabled` and `aria-describedby`). Not drawn: the panel shows it.
  final String? lockedReason;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final canTap = enabled && lockedReason == null;
    final notes = [?description, ?reason];
    const labelStyle = TextStyle(
      fontSize: KitTokens.toggleLabelSize,
      height: KitTokens.toggleLabelLineHeight,
      color: KitTokens.menuInk,
      decoration: TextDecoration.none,
      fontWeight: FontWeight.w400,
    );
    const sub = TextStyle(
      fontSize: KitTokens.menuSubSize,
      height: KitTokens.toggleSubLineHeight,
      color: KitTokens.menuSub,
      decoration: TextDecoration.none,
      fontWeight: FontWeight.w400,
    );
    return Semantics(
      container: true,
      toggled: value,
      enabled: canTap,
      label: label,
      hint: [...notes, ?lockedReason].join(' '),
      onTap: canTap ? () => onChanged!(!value) : null,
      excludeSemantics: true,
      child: InkWell(
        onTap: canTap ? () => onChanged!(!value) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: KitTokens.toggleRowHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: KitTokens.toggleTextPadV,
            ),
            child: Row(
              crossAxisAlignment: notes.isEmpty
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      right: KitTokens.toggleTextGap,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // With notes, on the preview's exact lines (17.5 and
                        // 15.4): a row with a one-line note is 56.9 high, as
                        // there, not 57. A lone name sits in the 46.
                        Opacity(
                          opacity: enabled ? 1 : KitTokens.disabledOpacity,
                          child: notes.isEmpty
                              ? KitText(label, style: labelStyle)
                              : KitLines(label, style: labelStyle),
                        ),
                        for (final note in notes)
                          Padding(
                            padding: const EdgeInsets.only(
                              top: KitTokens.toggleSubTop,
                            ),
                            child: KitLines(note, style: sub),
                          ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(
                    top: notes.isEmpty ? 0 : KitTokens.toggleSwitchTop,
                  ),
                  child: Opacity(
                    opacity: enabled ? 1 : KitTokens.disabledOpacity,
                    child: KitSwitch(value: value),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of text choices in one rounded frame; the chosen one is accent.
class KitSegment<T> extends StatelessWidget {
  const new({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(KitTokens.segmentRadius);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: KitTokens.menuLine),
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < options.length; i++) ...[
                if (i > 0)
                  const SizedBox(
                    width: KitTokens.segmentDividerWidth,
                    child: ColoredBox(color: KitTokens.menuLine),
                  ),
                _SegmentButton(
                  label: options[i].$2,
                  selected: options[i].$1 == value,
                  onTap: () => onChanged(options[i].$1),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const new({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: selected ? KitTokens.accent : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: KitTokens.segmentPaddingH,
              vertical: KitTokens.segmentPaddingV,
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: KitTokens.menuFontSize,
                color: selected ? KitTokens.onAccent : KitTokens.menuInk,
                decoration: TextDecoration.none,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The size slider of the Samsung pen panel: a thin track with eleven dots,
/// a round thumb that grows into a pill while held, and a minus and a plus.
///
/// It reacts on the first touch (raw pointer events, no tap wait). Dragging
/// never rebuilds the parent beyond the [onChanged] calls it makes: the thumb,
/// number and pill are drawn inside this widget.
class KitSlider extends StatefulWidget {
  const new({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeEnd,
    this.min = 1,
    this.max = 100,
    this.step = 5,
    this.snap = 1,
    this.enabled = true,
    this.unit = '',
    this.valueLabel,
    this.markColor,
    this.markDiameter,
    this.label,
    this.decreaseLabel,
    this.increaseLabel,
  });

  final int value;
  final ValueChanged<int> onChanged;

  /// A drag or a tap gives multiples of this (the preview's `snap`): the
  /// stabiliser moves in tens. The thumb then follows the finger in steps.
  final int snap;

  /// False: the row is dimmed like `.srow.dis`, the minus and plus are grey
  /// and nothing reacts to a touch.
  final bool enabled;

  /// Said after the value by screen readers but not drawn on the thumb (the
  /// preview's `unit`: the stabiliser shows its % at its title instead).
  final String unit;

  /// What the slider sets, read out by screen readers (preview `aria-label`).
  final String? label;

  /// The minus and plus buttons' names (screen readers and tooltips), like the
  /// preview's `lo` and `hi` (「가늘게」, 「굵게」). By default the icons' names.
  final String? decreaseLabel;
  final String? increaseLabel;

  /// Called once when a drag, a tap on the track or a button press is over.
  final ValueChanged<int>? onChangeEnd;
  final int min;
  final int max;

  /// How much the minus and plus buttons change the value.
  final int step;
  final String Function(int)? valueLabel;

  /// A dot at track height inside the held pill (the pen's ink colour). It is
  /// drawn only when [markDiameter] is given.
  final Color? markColor;
  final double Function(int value)? markDiameter;

  @override
  State<KitSlider> createState() => _KitSliderState();
}

enum _Touch { none, grab, tap, follow }

class _KitSliderState extends State<KitSlider> with TickerProviderStateMixin {
  static const _thumbRadius = KitTokens.sliderThumb / 2;
  static const _grabReach = _thumbRadius + KitTokens.sliderGrabMargin;
  static const _centreY = KitTokens.sliderHitHeight / 2;
  // The thumb's bottom edge stays where the resting circle ends.
  static const _bottomY = _centreY + KitTokens.sliderThumb / 2;

  late final _grow = AnimationController(
    vsync: this,
    duration: KitMotion.sliderGrow,
    reverseDuration: KitMotion.sliderShrink,
  );
  late final Animation<double> _growCurve = CurvedAnimation(
    parent: _grow,
    curve: KitMotion.samsungDecel,
    reverseCurve: KitMotion.samsungDecel,
  );
  late final _slide = AnimationController(
    vsync: this,
    duration: KitMotion.sliderJump,
  )..addStatusListener(_slideStatus);
  // 0 = number hidden, 1 = shown.
  late final _number = AnimationController(vsync: this, value: 1);

  late double _t; // value units, not rounded
  late int _target; // last value sent or received
  var _sliding = false;
  double _from = 0;
  double _to = 0;

  int? _pointer;
  _Touch _touch = _Touch.none;
  double _grabDx = 0;
  double _downX = 0;

  int get _min => widget.min;
  int get _max => widget.max;
  double get _x0 => _thumbRadius;
  double get _x1 => KitTokens.sliderTrackWidth - _thumbRadius;

  double get _pos => _sliding
      ? lerpDouble(_from, _to, KitMotion.samsungDecel.transform(_slide.value))!
      : _t;

  double _xOfT(double t) =>
      _x0 + (t - _min) / (_max - _min).clamp(1, 1 << 30) * (_x1 - _x0);

  double _tOfX(double x) => (_min + (x - _x0) / (_x1 - _x0) * (_max - _min))
      .clamp(_min.toDouble(), _max.toDouble());

  int _intOf(double t) =>
      ((t / widget.snap).round() * widget.snap).clamp(_min, _max);

  /// Where a finger at [t] puts the thumb: on the [KitSlider.snap] grid, or
  /// right under it.
  double _follow(double t) => widget.snap == 1 ? t : _intOf(t).toDouble();

  String _label(int v) => widget.valueLabel?.call(v) ?? '$v';

  String _spoken(int v) => '${_label(v)}${widget.unit}';

  bool get _reduce => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    _t = widget.value.toDouble();
    _target = widget.value;
  }

  @override
  void didUpdateWidget(KitSlider old) {
    super.didUpdateWidget(old);
    if (_touch == _Touch.none && widget.value != _target) {
      _slideTo(widget.value.toDouble(), hideNumber: true);
      _target = widget.value;
    }
  }

  @override
  void dispose() {
    _grow.dispose();
    _slide.dispose();
    _number.dispose();
    super.dispose();
  }

  void _slideStatus(AnimationStatus s) {
    if (s != AnimationStatus.completed) return;
    _t = _to;
    _sliding = false;
    if (mounted && _number.value < 1) {
      _number.animateTo(
        1,
        duration: KitMotion.sliderValueBack,
        curve: Interval(
          1 -
              KitMotion.sliderValueIn.inMilliseconds /
                  KitMotion.sliderValueBack.inMilliseconds,
          1,
        ),
      );
    }
  }

  /// Freezes the thumb where it is drawn now.
  void _stopSlide() {
    if (_sliding) {
      _t = _pos;
      _sliding = false;
    }
    _slide.stop();
  }

  void _slideTo(double t, {required bool hideNumber}) {
    _stopSlide();
    _number.stop();
    if (_reduce) {
      _t = t;
      _number.value = 1;
      setState(() {});
      return;
    }
    _from = _t;
    _to = t;
    _sliding = true;
    if (hideNumber) _number.value = 0;
    _slide.forward(from: 0);
    setState(() {});
  }

  void _emit(int v) {
    if (v == _target) return;
    _target = v;
    widget.onChanged(v);
  }

  void _down(PointerDownEvent e) {
    if (_pointer != null) return;
    _pointer = e.pointer;
    final x = e.localPosition.dx;
    _stopSlide();
    if ((x - _xOfT(_t)).abs() <= _grabReach) {
      _touch = _Touch.grab;
      _grabDx = x - _xOfT(_t);
      _number.value = 1;
      if (_reduce) {
        _grow.value = 1;
      } else {
        _grow.forward();
      }
      setState(() {});
    } else {
      _touch = _Touch.tap;
      _downX = x;
      final v = _intOf(_tOfX(x));
      _slideTo(v.toDouble(), hideNumber: true);
      _emit(v);
    }
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    final x = e.localPosition.dx;
    switch (_touch) {
      case _Touch.none:
        return;
      case _Touch.grab:
        setState(() => _t = _follow(_tOfX(x - _grabDx)));
      case _Touch.tap:
        if ((x - _downX).abs() <= kTouchSlop) return;
        _touch = _Touch.follow;
        _stopSlide();
        _number.value = 1;
        setState(() => _t = _follow(_tOfX(x)));
      case _Touch.follow:
        setState(() => _t = _follow(_tOfX(x)));
    }
    _emit(_intOf(_t));
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    final was = _touch;
    _touch = _Touch.none;
    if (was == _Touch.none) return;
    if (was != _Touch.tap) {
      _t = _target.toDouble();
    }
    if (was == _Touch.grab) {
      if (_reduce) {
        _grow.value = 0;
      } else {
        _grow.reverse();
      }
    }
    setState(() {});
    widget.onChangeEnd?.call(_target);
  }

  /// A button press or an accessibility action: change, then end.
  void _stepTo(int v) {
    final next = v.clamp(_min, _max);
    _stopSlide();
    _number.value = 1;
    _target = next;
    _slideTo(next.toDouble(), hideNumber: false);
    widget.onChanged(next);
    widget.onChangeEnd?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value.clamp(_min, _max);
    final enabled = widget.enabled;
    final canDown = enabled && v > _min;
    final canUp = enabled && v < _max;
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Stepper(
          icon: KitIconName.minus,
          label: widget.decreaseLabel ?? KitIconName.minus.label,
          onTap: canDown ? () => _stepTo(v - widget.step) : null,
        ),
        const SizedBox(width: KitTokens.sliderStepperSpace),
        Semantics(
          slider: true,
          enabled: enabled,
          label: widget.label,
          value: _spoken(v),
          increasedValue: _spoken((v + widget.step).clamp(_min, _max)),
          decreasedValue: _spoken((v - widget.step).clamp(_min, _max)),
          onIncrease: canUp ? () => _stepTo(v + widget.step) : null,
          onDecrease: canDown ? () => _stepTo(v - widget.step) : null,
          child: IgnorePointer(
            ignoring: !enabled,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: _up,
              onPointerCancel: _up,
              // The eager recognizer wins the touch at once, so a scrolling
              // parent does not take the drag; the Listener above still
              // reacts on the first touch.
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  EagerGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        EagerGestureRecognizer
                      >(EagerGestureRecognizer.new, (_) {}),
                },
                child: SizedBox(
                  key: const Key('kit-slider-track'),
                  width: KitTokens.sliderTrackWidth,
                  height: KitTokens.sliderHitHeight,
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_growCurve, _slide, _number]),
                    builder: (context, _) => _paint(),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: KitTokens.sliderStepperSpace),
        _Stepper(
          icon: KitIconName.plus,
          label: widget.increaseLabel ?? KitIconName.plus.label,
          onTap: canUp ? () => _stepTo(v + widget.step) : null,
        ),
      ],
    );
    return Opacity(
      opacity: enabled ? 1 : KitTokens.disabledOpacity,
      child: row,
    );
  }

  Widget _paint() {
    final g = _growCurve.value;
    final pos = _pos;
    final cx = _xOfT(pos);
    final width = lerpDouble(
      KitTokens.sliderThumb,
      KitTokens.sliderPillWidth,
      g,
    )!;
    final height = lerpDouble(
      KitTokens.sliderThumb,
      KitTokens.sliderPillHeight,
      g,
    )!;
    const pillTop = _bottomY - KitTokens.sliderPillHeight;
    final numberY = lerpDouble(
      _centreY,
      pillTop + KitTokens.sliderValueTopInset,
      g,
    )!;
    final shown = _intOf(pos);
    final number = _label(shown);
    final markSize = widget.markDiameter?.call(shown);
    final markOpacity =
        ((g - KitTokens.sliderMarkShowAt) / (1 - KitTokens.sliderMarkShowAt))
            .clamp(0.0, 1.0);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _TrackPainter(min: _min, max: _max, x0: _x0, x1: _x1),
          ),
        ),
        Positioned(
          left: cx - width / 2,
          top: _bottomY - height,
          width: width,
          height: height,
          child: DecoratedBox(
            key: const Key('kit-slider-thumb'),
            decoration: BoxDecoration(
              color: KitTokens.sliderThumbColor,
              borderRadius: BorderRadius.circular(KitTokens.sliderPillRadius),
              boxShadow: KitTokens.sliderThumbShadow,
            ),
          ),
        ),
        if (markSize != null && markOpacity > 0)
          Builder(
            builder: (context) {
              final d = markSize.clamp(0.0, KitTokens.sliderPillWidth);
              return Positioned(
                left: cx - d / 2,
                top: _centreY - d / 2,
                width: d,
                height: d,
                child: Opacity(
                  opacity: markOpacity,
                  child: DecoratedBox(
                    key: const Key('kit-slider-mark'),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.markColor ?? KitTokens.sliderValueInk,
                    ),
                  ),
                ),
              );
            },
          ),
        Positioned(
          left: cx - KitTokens.sliderNumberBoxWidth / 2,
          width: KitTokens.sliderNumberBoxWidth,
          top: numberY - KitTokens.sliderNumberBoxHeight / 2,
          height: KitTokens.sliderNumberBoxHeight,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: Opacity(
                key: const Key('kit-slider-number'),
                opacity: _number.value,
                child: Center(
                  child: Text(
                    number,
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: number.length > 3
                          ? KitTokens.sliderValueSizeLong
                          : KitTokens.sliderValueSize,
                      height: KitTokens.lineHeightOne,
                      color: KitTokens.sliderValueInk,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TrackPainter extends CustomPainter {
  const new({
    required this.min,
    required this.max,
    required this.x0,
    required this.x1,
  });

  final int min;
  final int max;
  final double x0;
  final double x1;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width / 2, cy),
          width: size.width,
          height: KitTokens.sliderHeight,
        ),
        const Radius.circular(KitTokens.sliderHeight / 2),
      ),
      Paint()..color = KitTokens.sliderTrackColor,
    );
    final dot = Paint()..color = KitTokens.sliderTickColor;
    const n = KitTokens.sliderTicks;
    for (var i = 0; i < n; i++) {
      canvas.drawCircle(
        Offset(x0 + i * (x1 - x0) / (n - 1), cy),
        KitTokens.sliderTickDiameter / 2,
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.x0 != x0 || old.x1 != x1 || old.min != min || old.max != max;
}

class _Stepper extends StatelessWidget {
  const new({required this.icon, required this.label, required this.onTap});

  final KitIconName icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: KitTokens.sliderStepperBox,
            height: KitTokens.sliderHitHeight,
            child: Center(
              child: KitIcon(
                icon,
                size: KitTokens.sliderStepperIconSize,
                strokeWidth: KitTokens.sliderStepperIconStroke,
                color: enabled
                    ? KitTokens.sliderStepperInk
                    : KitTokens.stepperDisabled,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
