import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/canvas_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/ink_swap.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_list.dart';
import 'package:saber/data/extensions/change_notifier_extensions.dart';
import 'package:saber/data/ink/hold_to_line.dart';
import 'package:saber/data/ink/ink_input_policy.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/select.dart';

/// What the editor's ink input reads and asks of the editor.
abstract interface class EditorInkHost {
  EditorCoreInfo get coreInfo;
  EditorHistory get history;
  PageList get pageList;
  Tool get currentTool;
  set currentTool(Tool tool);

  /// The last [currentTool] that was not the eraser.
  Tool get lastNonEraserTool;

  /// The page under the current draw gesture.
  int? get dragPageIndex;
  set dragPageIndex(int? index);

  bool get mounted;

  /// Whether the note is read-only, locked, loading, placing a link,
  /// picking a colour or in gesture mode: pens and fingers draw nothing.
  bool get inkBlocked;

  /// Where the pen is on screen now, null when it is lifted.
  set strokeAt(Offset? at);

  /// Builds the editor again (the editor's `setState`).
  void rebuild(VoidCallback fn);

  /// A draw gesture began: the note is busy and dirty.
  void drawBegan();

  /// A draw gesture ended. [save] starts the delayed autosave.
  void drawEnded({required bool save});

  int? onWhichPageIsFocalPoint(Offset focalPoint);
  void undo([EditorHistoryItem? item]);
}

/// The editor's draw gestures: pen, eraser, selection and laser pointer
/// strokes, and telling a stroke from a pinch.
class EditorInkInput {
  new(this.host);

  final EditorInkHost host;
  final _log = Logger('EditorInkInput');

  Tool get _tool => host.currentTool;

  /// The position of the previous draw gesture event.
  /// Used to move a selection.
  Offset previousPosition = .zero;

  /// The total offset of the current move gesture.
  /// Used to record a move in the history.
  Offset moveOffset = .zero;

  var isHovering = true;

  /// Whether the last pen or eraser gesture added a history item.
  var lastDrawRecorded = false;

  /// The drag page's strokes when the eraser touched down: the eraser
  /// takes strokes off as it goes, and the undo step needs their places.
  List<Stroke> _eraseStart = const [];
  PointerDeviceKind? currentPointerKind;
  double? currentPressure;

  // used to prevent accidentally drawing when pinch zooming
  var lastSeenPointerCount = 0;
  Timer? _lastSeenPointerCountTimer;

  /// If the stylus button is pressed, or was pressed, during the current draw gesture.
  ///
  /// For now, this also includes when an [PointerDeviceKind.inverseStylus] is
  /// used since the stylus rear-end and stylus button currently act the same.
  /// If we add customized button bindings, we may have to separate this again.
  var stylusButtonWasPressed = false;

  /// 「멈추면 직선」 of the stroke an ink pen is drawing (null for other
  /// tools), and the wait for the pen to stay still.
  HoldToLine? _hold;
  Timer? _holdTimer;

  void dispose() {
    _lastSeenPointerCountTimer?.cancel();
    _holdTimer?.cancel();
  }

  /// Waits [holdToLineDelay] again for the pen to stay still on [page].
  void _waitForHold(EditorPage page) {
    _holdTimer?.cancel();
    _holdTimer = Timer(holdToLineDelay, () {
      final stroke = Pen.currentStroke;
      if (stroke == null) return;
      _hold?.turn();
      // the end follows the pen itself from now on
      stroke.stabilise(0);
      _straighten(stroke);
      // only the stroke being drawn is drawn again, not the editor
      page.redrawStrokes();
    });
  }

  /// The held stroke as a line from its first point to the pen, on an axis
  /// with the pen's 수평/수직 (usable only with its straight line on).
  void _straighten(Stroke stroke) {
    final kind = penKindOf(_tool);
    stroke.straightenWhileDrawing(
      axisLock: kind != null && straightLineOf(kind) && axisLockOf(kind),
    );
  }

  bool isDrawGesture(ScaleStartDetails details) {
    if (host.inkBlocked) return false;

    CanvasImage.activeListener
        .notifyListenersPlease(); // un-select active image

    final acceptedStylus =
        details.pointerCount == 1 &&
        (details.kind == PointerDeviceKind.stylus ||
            details.kind == PointerDeviceKind.invertedStylus);
    _lastSeenPointerCountTimer?.cancel();
    if (acceptedStylus) {
      // The touch debounce must not delay a pen or undo its completed stroke.
      lastSeenPointerCount = 0;
    } else if (lastSeenPointerCount >= 2) {
      // was a zoom gesture, ignore
      return false;
    } else if (details.pointerCount >= 2) {
      // is a zoom gesture, remove accidental stroke
      // Only the first finger's own change: a stroke or erase that changed
      // nothing left no history, and the item before it is the user's.
      if (lastSeenPointerCount == 1 &&
          lastDrawRecorded &&
          stows.editorFingerDrawing.value &&
          (_tool is Pen || _tool is Eraser)) {
        lastDrawRecorded = false;
        final item = host.history.removeAccidentalStroke();
        if (item != null) host.undo(item);
      }
      lastSeenPointerCount = details.pointerCount;
      return false;
    } else {
      // is a stroke
      lastSeenPointerCount = details.pointerCount;
    }

    host.dragPageIndex = host.onWhichPageIsFocalPoint(details.focalPoint);
    if (host.dragPageIndex == null) return false;

    if (_tool == Tool.textEditing) {
      return false;
    } else if (inkRoute(
              device: details.kind ?? PointerDeviceKind.touch,
              touches: details.pointerCount,
              gestureMode: false,
              fingerDrawing: stows.editorFingerDrawing.value,
            ) ==
            InkRoute.draw ||
        currentPointerKind == PointerDeviceKind.stylus ||
        currentPointerKind == PointerDeviceKind.invertedStylus ||
        currentPressure != null) {
      return true;
    } else {
      _log.fine('Non-stylus found, rejected stroke');
      return false;
    }
  }

  void onDrawStart(ScaleStartDetails details) {
    host.strokeAt = details.focalPoint;
    host.drawBegan();
    final dragPageIndex = host.dragPageIndex!;
    final page = host.coreInfo.pages[dragPageIndex];
    final position = page.renderBox!.globalToLocal(details.focalPoint);
    host.history.canRedo = false;

    if (_tool is Pen) {
      // The page's zoom and fit on screen, so the stabiliser smooths and the
      // pen stays still the same on screen however far the page is zoomed.
      final screenScale = page.renderBox!
          .getTransformTo(null)
          .getMaxScaleOnAxis();
      (_tool as Pen).onDragStart(
        position,
        page,
        dragPageIndex,
        currentPressure,
        screenScale: screenScale,
      );
      // every ink pen, whatever its straight line; not the shape pen. The
      // wait starts once the pen leaves where it touched down, so a pause
      // there before writing keeps the stroke freehand.
      _holdTimer?.cancel();
      _hold = null;
      if (isInkTool(_tool)) {
        _hold = HoldToLine(slop: holdToLineSlop / screenScale)..start(position);
      }
    } else if (_tool is Eraser) {
      final eraser = _tool as Eraser;
      _eraseStart = List.of(page.strokes);
      if (stows.eraserMode.value == EraserMode.lasso) {
        // Nothing is erased until the loop is closed (onDrawEnd).
        eraser.startLasso(position, dragPageIndex);
      } else {
        // Empty pages are tidied in onDrawEnd: removing the page under the
        // eraser here would leave the drag on a page that is gone.
        for (final stroke in eraser.checkForOverlappingStrokes(
          position,
          page.strokes,
        )) {
          page.strokes.remove(stroke);
        }
      }
    } else if (_tool is Select) {
      final select = _tool as Select;
      if (select.doneSelecting &&
          select.selectResult.pageIndex == dragPageIndex &&
          select.selectResult.path.contains(position)) {
        // drag selection in onDrawUpdate
      } else {
        select.onDragStart(position, dragPageIndex);
        host.history.canRedo = true; // selection doesn't affect history
      }
    } else if (_tool is LaserPointer) {
      (_tool as LaserPointer).onDragStart(position, page, dragPageIndex);
    }

    previousPosition = position;
    moveOffset = .zero;

    if (_tool is! Select) {
      Select.currentSelect.unselect();
    }

    // setState to let canvas know about currentStroke
    host.rebuild(() {});
  }

  void onDrawUpdate(ScaleUpdateDetails details) {
    host.strokeAt = details.focalPoint;
    final page = host.coreInfo.pages[host.dragPageIndex!];
    final position = page.renderBox!.globalToLocal(details.focalPoint);
    final offset = position - previousPosition;

    if (_tool is Pen) {
      (_tool as Pen).onDragUpdate(position, currentPressure);
      if (_hold case final hold?) {
        if (hold.isLine) {
          if (Pen.currentStroke case final stroke?) _straighten(stroke);
        } else if (hold.moved(position)) {
          _waitForHold(page);
        }
      }
      page.redrawStrokes();
    } else if (_tool is Eraser) {
      final eraser = _tool as Eraser;
      if (eraser.lassoPath != null) {
        eraser.extendLasso(position);
        page.redrawStrokes();
      } else {
        for (final stroke in eraser.checkForOverlappingStrokes(
          position,
          page.strokes,
        )) {
          page.strokes.remove(stroke);
        }
        page.redrawStrokes();
      }
    } else if (_tool is Select) {
      final select = _tool as Select;
      if (select.doneSelecting) {
        for (final stroke in select.selectResult.strokes) {
          stroke.shift(offset);
        }
        for (final image in select.selectResult.images) {
          image.dstRect = image.dstRect.shift(offset);
        }
        select.selectResult.path = select.selectResult.path.shift(offset);
      } else {
        select.onDragUpdate(position);
      }
      page.redrawStrokes();
    } else if (_tool is LaserPointer) {
      (_tool as LaserPointer).onDragUpdate(position);
      page.redrawStrokes();
    }
    previousPosition = position;
    moveOffset += offset;
  }

  void onDrawEnd(ScaleEndDetails details) {
    host.strokeAt = null;
    final dragPageIndex = host.dragPageIndex!;
    final page = host.coreInfo.pages[dragPageIndex];
    bool shouldSave = true;
    lastDrawRecorded = false;
    _holdTimer?.cancel();
    final held = _hold?.isLine ?? false;
    _hold = null;
    host.rebuild(() {
      if (_tool is Pen) {
        final newStroke = (_tool as Pen).onDragEnd();
        if (newStroke == null) return;
        if (newStroke.isEmpty) return;

        // A held line ends where the pen lifts; it is not judged again.
        // Otherwise the pen's own straight line (not the shape pen's).
        final kind = penKindOf(_tool);
        if (held) {
          if (newStroke.length >= 2) newStroke.convertToLine();
        } else if (kind != null &&
            straightLineOf(kind) &&
            newStroke.isStraightLine()) {
          newStroke.convertToLine();
        }

        host.pageList.fillTo(newStroke.pageIndex);
        page.insertStroke(newStroke);
        host.history.recordChange(
          EditorHistoryItem(
            type: .draw,
            pageIndex: dragPageIndex,
            strokes: [newStroke],
            images: [],
            page: page,
          ),
        );
        lastDrawRecorded = true;
      } else if (_tool is Eraser) {
        final eraser = _tool as Eraser;
        if (eraser.lassoPath != null) {
          if (details.pointerCount > 0) {
            // Another finger landed (a pinch), so the gesture ended with the
            // loop unfinished: drop it rather than erase half a loop.
            eraser.cancelLasso();
          } else {
            // The pen was lifted: erase what the loop holds, in one undo step.
            final inside = eraser.finishLasso(page.strokes);
            for (final stroke in inside) {
              page.strokes.remove(stroke);
            }
            if (inside.isNotEmpty) page.redrawStrokes();
          }
        }
        final erased = eraser.onDragEnd();
        final before = _eraseStart;
        _eraseStart = const [];
        if (stylusButtonWasPressed || stows.disableEraserAfterUse.value) {
          // restore previous tool
          stylusButtonWasPressed = false;
          host.currentTool = host.lastNonEraserTool;
        }
        if (erased.isEmpty) return;
        // One undo step; empty pages are tidied only now, once the eraser
        // is lifted, and the record keeps this page.
        host.pageList.recordReplace([
          (
            page: page,
            swap: InkSwap(
              removedStrokes: [
                for (final stroke in erased) (before.indexOf(stroke), stroke),
              ]..sort((a, b) => a.$1.compareTo(b.$1)),
            ),
          ),
        ]);
        lastDrawRecorded = true;
      } else if (_tool is Select) {
        if (moveOffset == .zero) return;
        final select = _tool as Select;
        if (select.doneSelecting) {
          host.history.recordChange(
            EditorHistoryItem(
              type: .move,
              pageIndex: dragPageIndex,
              strokes: select.selectResult.strokes,
              images: select.selectResult.images,
              offset: .fromLTRB(
                moveOffset.dx,
                moveOffset.dy,
                moveOffset.dx,
                moveOffset.dy,
              ),
            ),
          );
        } else {
          shouldSave = false;
          select.onDragEnd(page.strokes, page.images);

          if (select.selectResult.isEmpty) {
            Select.currentSelect.unselect();
          }
        }
      } else if (_tool is LaserPointer) {
        shouldSave = false;
        final newStroke = (_tool as LaserPointer).onDragEnd(
          page.redrawStrokes,
          (Stroke stroke) {
            page.laserStrokes.remove(stroke);
          },
        );
        if (newStroke != null) page.laserStrokes.add(newStroke);
      }
    });

    host.drawEnded(save: shouldSave);
  }

  void onInteractionEnd(ScaleEndDetails details) {
    // reset after 1ms to keep track of the same gesture only
    _lastSeenPointerCountTimer?.cancel();
    _lastSeenPointerCountTimer = Timer(const Duration(milliseconds: 10), () {
      lastSeenPointerCount = 0;
    });
  }

  void updatePointerData(PointerDeviceKind kind, double? pressure) {
    currentPointerKind = kind;
    currentPressure = pressure;
  }

  void onHovering() {
    isHovering = true;
  }

  void onHoveringEnd() {
    isHovering = false;
  }

  void onStylusButtonChanged(bool buttonIsPressed) {
    stylusButtonWasPressed |= buttonIsPressed;

    if (!isHovering) return;
    if (buttonIsPressed) {
      // button pressed while hovering, switch to Eraser
      if (_tool is! Eraser) {
        host.currentTool = Eraser();
      }
    } else {
      // button was released while hovering, switch back to non-Eraser
      if (_tool is Eraser) {
        host.currentTool = host.lastNonEraserTool;
      }
    }

    if (host.mounted) host.rebuild(() {});
  }
}
