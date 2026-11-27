import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, clampDouble;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/widgets.dart';
import 'package:saber/components/ink_ui/audio/record_pill.dart';
import 'package:saber/components/ink_ui/quick_note/kit_quick_note.dart';
import 'package:saber/components/ink_ui/quick_note/quick_note_paper.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/editor/quick_note.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/user_error.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/pages/editor/editor_chrome.dart';

/// The note's quick note beside the editor (supplement Task 13), apart from
/// the editor's state so that none of it builds the page again; the left
/// panel's host owns it.
///
/// It is there where the note's vault keeps attachments ([bind], a format 2
/// vault): [available] shows the toolbar's 노트 창. The quick note is read
/// when the window first opens ([open]). Closing it, folding it into its
/// pill and the editor going (disposed) save what was written; it also saves
/// on its own a little after writing stops ([QuickNote.saveDelay]). Where
/// the window was left ([place]) and the phone sheet's height ([sheet]) are
/// kept on this device, read once the device's settings are read. A read
/// that fails is said in the window ([readFailed]) until [retry] reads it.
class EditorQuickNoteHost {
  new({ValueNotifier<bool>? open})
    : open = open ?? ValueNotifier(false),
      _ownsOpen = open == null {
    this.open.addListener(_openChanged);
    unawaited(_readKept());
  }

  /// Whether the window (or its pill) is open: the editor's 노트 창.
  final ValueNotifier<bool> open;
  final bool _ownsOpen;

  /// The note's vault keeps a quick note.
  final available = ValueNotifier(false);

  /// Folded into its pill.
  final folded = ValueNotifier(false);

  /// Where the window was left over the page area; null: where it starts.
  final place = ValueNotifier<Rect?>(_kept());

  /// The share of the page area's height the phone sheet rests at.
  final sheet = ValueNotifier(stows.quickNoteSheet.value);

  /// The quick note, once read.
  final note = ValueNotifier<QuickNote?>(null);

  /// The last read failed.
  final readFailed = ValueNotifier(false);

  /// How long after writing stops it saves (the quick note's own when null).
  @visibleForTesting
  static Duration? debugSaveDelay;

  NoteSideBinding? _binding;
  Future<void>? _reading;
  var _disposed = false;

  /// Moved, sized or pulled here before the kept values were read: those
  /// stay.
  var _placed = false;
  var _sheetPulled = false;

  /// The kept place and sheet height (at its nearest stop) once the
  /// device's settings are read (`waitUntilRead`, as the editor does); if
  /// that fails, where it starts.
  Future<void> _readKept() async {
    final window = stows.quickNoteWindow, share = stows.quickNoteSheet;
    try {
      if (!window.loaded) await window.waitUntilRead();
      if (!share.loaded) await share.waitUntilRead();
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
      return;
    }
    if (_disposed) return;
    if (!_placed) place.value = _kept();
    if (!_sheetPulled) sheet.value = quickNoteSheetStop(share.value);
  }

  static Rect? _kept() {
    final kept = [
      for (final value in stows.quickNoteWindow.value) double.tryParse(value),
    ];
    if (kept.length != 4 || kept.contains(null)) return null;
    return Rect.fromLTWH(kept[0]!, kept[1]!, kept[2]!, kept[3]!);
  }

  /// The note's attachments are in [binding] (a format 2 vault).
  void bind(NoteSideBinding binding) {
    _binding = binding;
    available.value = true;
    if (open.value) _read();
  }

  void _openChanged() {
    if (open.value) return _read();
    folded.value = false;
    unawaited(flush());
  }

  void _read() {
    final binding = _binding;
    if (binding == null || _reading != null) return;
    readFailed.value = false;
    _reading = () async {
      try {
        final delay = debugSaveDelay;
        final quick = delay == null
            ? await QuickNote.open(binding.store, binding.noteId)
            : await QuickNote.open(
                binding.store,
                binding.noteId,
                saveDelay: delay,
              );
        if (_disposed) {
          await quick.flush();
          quick.dispose();
          return;
        }
        note.value = quick;
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
        // read again on 「다시 시도」 or when the window opens again
        _reading = null;
        if (!_disposed) readFailed.value = true;
      }
    }();
  }

  /// The note's quick note is split (two devices wrote it offline): it is
  /// read and saved once, joined, though the window stays shut. A list that
  /// fails is only logged (the user changed nothing).
  Future<void> joinSplits() async {
    final binding = _binding;
    if (binding == null) return;
    final List<NoteSideRecord> records;
    try {
      records = await binding.store.list(
        binding.noteId,
        NoteSideKind.quickNote,
      );
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
      return;
    }
    if (_disposed || !records.any((record) => record.heads.length > 1)) {
      return;
    }
    _read();
    await reading;
    if (!_disposed) await flush();
  }

  /// Done when the quick note asked for has been read (or failed).
  @visibleForTesting
  Future<void> get reading => _reading ?? Future.value();

  /// 「다시 시도」 after a failed read.
  void retry() => _read();

  void fold() {
    folded.value = true;
    unawaited(flush());
  }

  void unfold() => folded.value = false;

  /// The window was moved or sized to [rect].
  void keepPlace(Rect rect) {
    _placed = true;
    place.value = rect;
    stows.quickNoteWindow.value = [
      for (final value in [rect.left, rect.top, rect.width, rect.height])
        '$value',
    ];
  }

  /// The phone sheet came to rest at [share] of the height.
  void keepSheet(double share) {
    _sheetPulled = true;
    sheet.value = share;
    stows.quickNoteSheet.value = share;
  }

  /// Saves what was written; done when it is saved (or failed).
  Future<void> flush() => note.value?.flush() ?? Future.value();

  void dispose() {
    _disposed = true;
    open.removeListener(_openChanged);
    if (_ownsOpen) open.dispose();
    // the note closes: what was written is saved
    if (note.value case final quick?) {
      unawaited(quick.flush().whenComplete(quick.dispose));
    }
    available.dispose();
    folded.dispose();
    place.dispose();
    sheet.dispose();
    note.dispose();
    readFailed.dispose();
  }
}

/// The phone sheet's height for a kept [share]: inside the pull's range
/// ([KitTokens.quickNoteSheetDragMin] to [KitTokens.quickNoteSheetDragMax])
/// at the nearest of 40, 60 and 90%.
double quickNoteSheetStop(double share) {
  final now = clampDouble(
    share,
    KitTokens.quickNoteSheetDragMin,
    KitTokens.quickNoteSheetDragMax,
  );
  return KitTokens.noteSheetFractions.reduce(
    (a, b) => (b - now).abs() < (a - now).abs() ? b : a,
  );
}

/// How far from the top the window and its pill keep while it records,
/// where their span across meets the record pill's.
const _underRecPill =
    KitTokens.recPillInset +
    KitTokens.recPillHeight +
    KitTokens.quickNoteUnderRecPill;

/// [rect] moved down under the record pill at [recordPill] (null: none)
/// where their spans across meet; without the room under it, made lower
/// down to 220 (controller's ruling, task 13 fix 2), and lower than that as
/// far down as the area's height lets it.
Rect _underPill(Rect rect, Rect? recordPill, Size area) {
  if (recordPill == null ||
      rect.top >= _underRecPill ||
      rect.right <= recordPill.left ||
      rect.left >= recordPill.right) {
    return rect;
  }
  final room = area.height - _underRecPill;
  if (rect.height > room && room >= KitTokens.quickNoteMinHeight) {
    return Rect.fromLTWH(rect.left, _underRecPill, rect.width, room);
  }
  final top = math.min(_underRecPill, math.max(0.0, area.height - rect.height));
  return Rect.fromLTWH(rect.left, top, rect.width, rect.height);
}

/// Where the window stands over a page area of [area]: where it was left
/// ([kept]) or 16 from the top right at 360 x 460, at least 260 x 220, at
/// most the area less 24, inside the area, and under the record pill at
/// [recordPill] (while it records) where they would meet.
Rect quickNotePlace(Rect? kept, Size area, {Rect? recordPill}) {
  final width = clampDouble(
    kept?.width ?? KitTokens.quickNoteWidth,
    KitTokens.quickNoteMinWidth,
    math.max(
      KitTokens.quickNoteMinWidth,
      area.width - KitTokens.quickNotePageMargin,
    ),
  );
  final height = clampDouble(
    kept?.height ?? KitTokens.quickNoteHeight,
    KitTokens.quickNoteMinHeight,
    math.max(
      KitTokens.quickNoteMinHeight,
      area.height - KitTokens.quickNotePageMargin,
    ),
  );
  return _moved(
    Rect.fromLTWH(
      kept?.left ?? area.width - width - KitTokens.quickNoteInset,
      kept?.top ?? KitTokens.quickNoteInset,
      width,
      height,
    ),
    Offset.zero,
    area,
    recordPill,
  );
}

Rect _moved(Rect from, Offset by, Size area, Rect? recordPill) => _underPill(
  Rect.fromLTWH(
    clampDouble(from.left + by.dx, 0, math.max(0, area.width - from.width)),
    clampDouble(from.top + by.dy, 0, math.max(0, area.height - from.height)),
    from.width,
    from.height,
  ),
  recordPill,
  area,
);

/// [from] sized by [by] from its top left: at least 260 x 220, at most the
/// area less 24 and what is left of it right and under the window; above
/// the record pill's foot and left of it ([recordPill]), no wider than up
/// to it.
Rect _sized(Rect from, Offset by, Size area, Rect? recordPill) {
  double side(double size, double by, double min, double room, double left) =>
      clampDouble(
        size + by,
        min,
        math.max(
          min,
          math.min(room - KitTokens.quickNotePageMargin, room - left),
        ),
      );
  final sized = Rect.fromLTWH(
    from.left,
    from.top,
    side(from.width, by.dx, KitTokens.quickNoteMinWidth, area.width, from.left),
    side(
      from.height,
      by.dy,
      KitTokens.quickNoteMinHeight,
      area.height,
      from.top,
    ),
  );
  // above the pill's foot a window meeting its span has gone under it, so
  // one whose right is past the pill's left is right of the pill: it grows
  // away from it (not on the pages the pill stands top right on)
  if (recordPill == null ||
      from.top >= _underRecPill ||
      from.right > recordPill.left ||
      sized.right <= recordPill.left) {
    return sized;
  }
  return Rect.fromLTWH(
    sized.left,
    sized.top,
    math.max(KitTokens.quickNoteMinWidth, recordPill.left - sized.left),
    sized.height,
  );
}

/// The quick note over the editor's page area while it is open: the window
/// (or on a phone the sheet), or folded its pill. It follows [host] on its
/// own: opening, moving, sizing and writing in it build and paint this
/// layer only, never the page under it. [pen] is the pen it writes with;
/// [erasing], whether the eraser is in hand.
///
/// While the note records ([recording]) on a tablet, the window and its
/// pill keep under the record pill (drawn at [recordPill]) where their
/// spans across meet; a window there when it starts goes down at once and
/// stays there after (controller's ruling, task 13 fix 1).
class EditorQuickNoteLayer extends StatefulWidget {
  const new({
    super.key,
    required this.host,
    required this.pen,
    required this.erasing,
    this.recording,
    this.recordPill,
  });

  final EditorQuickNoteHost host;
  final Pen Function() pen;
  final bool Function() erasing;
  final ValueListenable<KitRecording>? recording;
  final GlobalKey? recordPill;

  @override
  State<EditorQuickNoteLayer> createState() => _EditorQuickNoteLayerState();
}

class _EditorQuickNoteLayerState extends State<EditorQuickNoteLayer>
    with SingleTickerProviderStateMixin {
  late final _rise = AnimationController(
    vsync: this,
    value: host.open.value ? 1 : 0,
  );
  late final _curve = CurvedAnimation(
    parent: _rise,
    curve: KitMotion.samsungDecel,
  );

  EditorQuickNoteHost get host => widget.host;

  var _area = Size.zero;

  /// A drag going on: where the window (or the sheet's share) was when it
  /// began, how far it has gone, and where it is now.
  Rect? _from;
  double? _sheetFrom;
  var _dragged = Offset.zero;
  Rect? _now;
  double? _sheetNow;
  var _sizing = false;

  /// Where the pill was dragged to since it folded; null: by the head's
  /// right end.
  Offset? _pillAt;
  final _pill = GlobalKey();

  /// Where the record pill is while the note records; null: it does not.
  Rect? _recordPill;

  bool get _phone => _area.width < KitTokens.sidePanelPhoneBelow;

  /// The record pill to keep under: none on a phone (the sheet is at the
  /// foot).
  Rect? get _avoid => _phone ? null : _recordPill;

  @override
  void initState() {
    super.initState();
    host.open.addListener(_opened);
    host.folded.addListener(_folded);
    widget.recording?.addListener(_recordingChanged);
    _recordingChanged();
  }

  @override
  void didUpdateWidget(EditorQuickNoteLayer old) {
    super.didUpdateWidget(old);
    if (identical(old.recording, widget.recording)) return;
    old.recording?.removeListener(_recordingChanged);
    widget.recording?.addListener(_recordingChanged);
    _recordingChanged();
  }

  bool get _recording => switch (widget.recording?.value) {
    KitRecording.on || KitRecording.paused => true,
    _ => false,
  };

  /// A read of where the record pill is is waiting for the frame's end.
  var _watching = false;

  /// It starts or stops recording: read where the record pill is once it is
  /// laid out.
  void _recordingChanged() {
    _watch();
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Reads where the record pill is after the next frame, and while it
  /// records after every frame: the page area turns or is sized, and the
  /// pill grows wider with its time (9:59 to 10:00).
  void _watch() {
    if (_watching) return;
    _watching = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _watching = false;
      if (!mounted) return;
      _measure();
      if (_recording) _watch();
    });
  }

  void _measure() {
    final pill = _recording
        ? widget.recordPill?.currentContext?.findRenderObject() as RenderBox?
        : null;
    final layer = context.findRenderObject() as RenderBox?;
    final at = pill == null || layer == null || !pill.hasSize
        ? null
        : pill.localToGlobal(Offset.zero, ancestor: layer) & pill.size;
    if (at == _recordPill) return;
    setState(() => _recordPill = at);
    _keepUnder();
  }

  /// A window shown where the record pill is goes down once, at once, and
  /// stays there after; shut, where it was left stays as it was.
  void _keepUnder() {
    final at = _recordPill;
    if (at == null || _phone || !host.open.value || !host.available.value) {
      return;
    }
    final place = quickNotePlace(host.place.value, _area);
    final under = quickNotePlace(host.place.value, _area, recordPill: at);
    if (under != place) host.keepPlace(under);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rise.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : KitMotion.quickNoteRise;
  }

  void _opened() {
    if (host.open.value) {
      _keepUnder();
      unawaited(_rise.forward(from: 0));
    } else {
      _rise.value = 0;
    }
  }

  void _folded() => _pillAt = null;

  @override
  void dispose() {
    host.open.removeListener(_opened);
    host.folded.removeListener(_folded);
    widget.recording?.removeListener(_recordingChanged);
    _curve.dispose();
    _rise.dispose();
    super.dispose();
  }

  KitQuickNoteDrag _drag({
    required VoidCallback start,
    required void Function() moved,
    required VoidCallback end,
  }) => (
    start: () {
      _dragged = Offset.zero;
      start();
    },
    by: (step) => setState(() {
      _dragged += step;
      moved();
    }),
    end: () => setState(() {
      end();
      _from = null;
      _now = null;
      _sheetFrom = null;
      _sheetNow = null;
      _sizing = false;
    }),
  );

  Rect get _place =>
      quickNotePlace(host.place.value, _area, recordPill: _avoid);

  late final _move = _drag(
    start: () => _from = _place,
    moved: () => _now = _moved(_from!, _dragged, _area, _avoid),
    end: () {
      if (_now case final now?) host.keepPlace(now);
    },
  );

  late final _resize = _drag(
    start: () => setState(() {
      _from = _place;
      _sizing = true;
    }),
    moved: () => _now = _sized(_from!, _dragged, _area, _avoid),
    end: () {
      if (_now case final now?) host.keepPlace(now);
    },
  );

  late final _sheetDrag = _drag(
    start: () => _sheetFrom = host.sheet.value,
    moved: () => _sheetNow = clampDouble(
      _sheetFrom! - _dragged.dy / _area.height,
      KitTokens.quickNoteSheetDragMin,
      KitTokens.quickNoteSheetDragMax,
    ),
    end: () {
      if (_sheetNow case final now?) host.keepSheet(quickNoteSheetStop(now));
    },
  );

  late final _pillDrag = _drag(
    start: () {
      final pill = _pill.currentContext?.findRenderObject() as RenderBox?;
      final layer = context.findRenderObject() as RenderBox?;
      _from = pill == null || layer == null
          ? null
          : pill.localToGlobal(Offset.zero, ancestor: layer) & pill.size;
    },
    moved: () {
      if (_from case final from?) _pillAt = from.topLeft + _dragged;
    },
    end: () {},
  );

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: LayoutBuilder(
      builder: (context, box) {
        _area = box.biggest;
        final phone = _phone;
        return ListenableBuilder(
          listenable: Listenable.merge([
            host.open,
            host.available,
            host.folded,
            host.place,
            host.sheet,
            host.note,
            host.readFailed,
          ]),
          builder: (context, _) {
            if (!host.open.value || !host.available.value) {
              return const SizedBox.shrink();
            }
            if (host.folded.value) return _pillLayer(phone);
            return Stack(children: [_window(phone)]);
          },
        );
      },
    ),
  );

  Widget _window(bool phone) {
    final rise = phone
        ? AnimatedBuilder(
            animation: _curve,
            builder: (context, child) => FractionalTranslation(
              translation: Offset(0, 1 - _curve.value),
              child: child,
            ),
            child: RepaintBoundary(child: _frame(phone)),
          )
        : FadeTransition(
            opacity: _curve,
            child: AnimatedBuilder(
              animation: _curve,
              builder: (context, child) => Transform.translate(
                offset: Offset(
                  0,
                  (1 - _curve.value) * KitTokens.quickNoteRiseFrom,
                ),
                child: child,
              ),
              child: RepaintBoundary(child: _frame(phone)),
            ),
          );
    if (phone) {
      return Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        height: _area.height * (_sheetNow ?? host.sheet.value),
        child: rise,
      );
    }
    return Positioned.fromRect(rect: _now ?? _place, child: rise);
  }

  Widget _frame(bool phone) {
    final quick = host.note.value;
    final paper = KitQuickNotePaper(
      note: quick,
      pen: widget.pen,
      erasing: widget.erasing,
      retry: host.readFailed.value ? host.retry : null,
    );
    return ListenableBuilder(
      listenable: Listenable.merge([?quick?.saveState, ?quick?.page]),
      builder: (context, _) => KitQuickNoteWindow(
        phone: phone,
        paper: paper,
        canUndo: quick != null && !quick.readOnly && quick.history.canUndo,
        readOnly: quick?.readOnly ?? false,
        unsaved: quick?.hasUnsavedChanges ?? false,
        onUndo: () => quick?.undo(),
        onFold: host.fold,
        onClose: () => host.open.value = false,
        move: phone ? null : _move,
        resize: phone ? null : _resize,
        sheetDrag: phone ? _sheetDrag : null,
        size: _sizing ? (_now ?? _from)?.size : null,
      ),
    );
  }

  Widget _pillLayer(bool phone) => CustomSingleChildLayout(
    delegate: _PillPlace(
      window: _place,
      at: phone ? null : _pillAt,
      phone: phone,
      recordPill: _avoid,
    ),
    child: GestureDetector(
      dragStartBehavior: DragStartBehavior.down,
      onTap: host.unfold,
      onPanStart: phone ? null : (_) => _pillDrag.start(),
      onPanUpdate: phone ? null : (details) => _pillDrag.by(details.delta),
      onPanEnd: phone ? null : (_) => _pillDrag.end(),
      child: KitQuickNotePill(key: _pill, onOpen: host.unfold),
    ),
  );
}

/// The pill's place: where it was dragged ([at]) or at the head's right end
/// of [window]; on a [phone], 16 over the foot in the middle. Always inside
/// the area, and under the record pill ([recordPill]) where they would
/// meet.
class _PillPlace extends SingleChildLayoutDelegate {
  const new({
    required this.window,
    required this.at,
    required this.phone,
    required this.recordPill,
  });

  final Rect window;
  final Offset? at;
  final bool phone;
  final Rect? recordPill;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    if (phone) {
      return Offset(
        (size.width - childSize.width) / 2,
        size.height - childSize.height - KitTokens.quickNotePillPhoneBottom,
      );
    }
    final want = at ?? Offset(window.right - childSize.width, window.top);
    final inside = Offset(
      clampDouble(want.dx, 0, math.max(0, size.width - childSize.width)),
      clampDouble(want.dy, 0, math.max(0, size.height - childSize.height)),
    );
    return _underPill(inside & childSize, recordPill, size).topLeft;
  }

  @override
  bool shouldRelayout(_PillPlace old) =>
      old.window != window ||
      old.at != at ||
      old.phone != phone ||
      old.recordPill != recordPill;
}
