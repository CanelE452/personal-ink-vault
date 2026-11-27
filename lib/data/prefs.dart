import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/home/home_layout_button.dart';
import 'package:saber/components/home/sort_button.dart';
import 'package:saber/components/navbar/responsive_navbar.dart';
import 'package:saber/data/codecs/base64_codec.dart';
import 'package:saber/data/codecs/name_list_codec.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/quota.dart';
import 'package:saber/data/sentry/sentry_consent.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/tool_id.dart';
import 'package:stow/stow.dart';
import 'package:stow_codecs/stow_codecs.dart';
import 'package:stow_plain/stow_plain.dart';
import 'package:stow_secure/stow_secure.dart';

/// If false, all stows are stuck at their default values.
var _isOnMainIsolate = false;

final stows = Stows();

class Stows {
  new() {
    recentColorsLength.addListener(() {
      // truncate if needed
      while (recentColorsLength.value < recentColorsPositioned.value.length) {
        // remove oldest color
        final removed = recentColorsChronological.value.removeAt(0);
        recentColorsPositioned.value.remove(removed);
      }
    });
  }

  /// Call this before [runApp] to set [_isOnMainIsolate] to true.
  static void markAsOnMainIsolate() {
    _isOnMainIsolate = true;
  }

  final log = Logger('Stows');

  final customDataDir = PlainStow<String?>(
    'customDataDir',
    null,
    volatile: !_isOnMainIsolate,
  );

  final allowInsecureConnections = SecureStow.bool(
    'allowInsecureConnections',
    false,
    volatile: !_isOnMainIsolate,
  );
  final url = SecureStow('url', '', volatile: !_isOnMainIsolate);
  final username = SecureStow('username', '', volatile: !_isOnMainIsolate);

  /// the password used to login to Nextcloud
  final ncPassword = SecureStow('ncPassword', '', volatile: !_isOnMainIsolate);

  /// the password used to encrypt/decrypt notes
  final encPassword = SecureStow(
    'encPassword',
    '',
    volatile: !_isOnMainIsolate,
  );

  /// Whether the user is logged in and has provided both passwords.
  /// Please ensure that the relevant Prefs are loaded before using this.
  bool get loggedIn => false;

  final key = SecureStow('key', '', volatile: !_isOnMainIsolate);
  final iv = SecureStow('iv', '', volatile: !_isOnMainIsolate);

  final pfp = PlainStow<Uint8List?>(
    'pfp',
    null,
    codec: const Base64StowCodec(),
    volatile: !_isOnMainIsolate,
  );
  final syncInBackground = PlainStow(
    'syncInBackground',
    false,
    volatile: !_isOnMainIsolate,
  );

  final appTheme = PlainStow(
    'appTheme',
    ThemeMode.system,
    codec: const EnumCodec(ThemeMode.values),
    volatile: !_isOnMainIsolate,
  );

  /// The type of platform to theme. Default value is [defaultTargetPlatform].
  final platform = PlainStow(
    'platform',
    defaultTargetPlatform,
    codec: const EnumCodec(TargetPlatform.values),
    volatile: !_isOnMainIsolate,
  );
  final layoutSize = PlainStow(
    'layoutSize',
    LayoutSize.auto,
    codec: LayoutSize.codec,
    volatile: !_isOnMainIsolate,
  );

  /// The accent color of the app. If 0, the system accent color will be used.
  final accentColor = PlainStow<Color?>(
    'accentColor',
    null,
    codec: const ColorCodec(),
    volatile: !_isOnMainIsolate,
  );
  final hyperlegibleFont = PlainStow(
    'hyperlegibleFont',
    false,
    volatile: !_isOnMainIsolate,
  );

  final editorToolbarAlignment = PlainStow(
    'editorToolbarAlignment',
    AxisDirection.down,
    codec: const EnumCodec(AxisDirection.values),
    volatile: !_isOnMainIsolate,
  );

  /// The 229 PDF/page pen toolbar's tools in the user's order, `!` before a
  /// hidden one; empty means its default. Read only to move it into
  /// [editorToolbarTools] (`ToolbarToolsLayout`).
  final pageToolbarLayout = PlainStow(
    'pageToolbarLayout',
    <String>[],
    volatile: !_isOnMainIsolate,
  );

  /// The editor toolbar's tools in the user's order, `!` before a tool kept
  /// in the ⌄ window (`ToolbarToolsLayout.encode`). Empty until the toolbar
  /// is customized; until then the [pageToolbarLayout] of 229 is read.
  final editorToolbarTools = PlainStow(
    'editorToolbarTools',
    <String>[],
    volatile: !_isOnMainIsolate,
  );

  /// Whether the editor is in gesture mode: pens and fingers move and zoom
  /// the page and draw nothing.
  final editorGestureMode = PlainStow(
    'editorGestureMode',
    false,
    volatile: !_isOnMainIsolate,
  );

  /// The note function row's shortcuts (`ShortcutLayout.encode`): `L:id` and
  /// `R:id` on the bar, `!id` in "더 많은 기능". Empty means the default, which
  /// takes the 228 toolbar's switches for the page actions that moved there.
  final noteShortcutLayout = PlainStow(
    'noteShortcutLayout',
    <String>[],
    volatile: !_isOnMainIsolate,
  );

  /// Whether the note's tab row is hidden (StarNote's "메모 막대 숨기기").
  final noteTabBarHidden = PlainStow(
    'noteTabBarHidden',
    false,
    volatile: !_isOnMainIsolate,
  );

  /// Whether the library's side panel is open (tablets and wider windows).
  /// Null until the user opens or closes it; until then it is open only on
  /// wide screens, where the old fixed rail was.
  final libraryPanelOpen = PlainStow<bool?>(
    'libraryPanelOpen',
    null,
    volatile: !_isOnMainIsolate,
  );

  /// The library shows covers in a grid (true) or a list (the ⋯ menu).
  final libraryGrid = PlainStow(
    'libraryGrid',
    true,
    volatile: !_isOnMainIsolate,
  );

  /// The library's order: `default`, `title`, `changed` or `created`.
  final librarySort = PlainStow(
    'librarySort',
    'default',
    volatile: !_isOnMainIsolate,
  );

  /// The tool panels (tap the chosen tool again). The eraser and lasso read
  /// these while they act, so a change applies to the tool in hand.
  final eraserSize = PlainStow<double>(
    'eraserSize',
    10,
    volatile: !_isOnMainIsolate,
  );
  final eraseHighlighterOnly = PlainStow(
    'eraseHighlighterOnly',
    false,
    volatile: !_isOnMainIsolate,
  );

  /// What the eraser rubs out (its advanced settings' 「지울 대상」), by
  /// name; read through EraserTargets (tools/eraser_targets.dart). Empty until
  /// first changed: [eraseHighlighterOnly] decides until then. A kept value
  /// that is not a list of names reads as unknown names (all four).
  final eraserTargets = PlainStow(
    'eraserTargets',
    <String>[],
    codec: const NameListCodec(),
    volatile: !_isOnMainIsolate,
  );
  final highlighterStraightLine = PlainStow(
    'highlighterStraightLine',
    false,
    volatile: !_isOnMainIsolate,
  );

  /// With [highlighterStraightLine], keep the line horizontal or vertical.
  final highlighterAxisLock = PlainStow(
    'highlighterAxisLock',
    false,
    volatile: !_isOnMainIsolate,
  );

  /// Whether the eraser rubs out the strokes it touches or the strokes
  /// inside a loop drawn around them (the eraser panel's cards).
  final eraserMode = PlainStow(
    'eraserMode',
    EraserMode.stroke,
    codec: const EnumCodec(EraserMode.values),
    volatile: !_isOnMainIsolate,
  );

  /// The pen button's kind: the fountain pen, ballpoint, pencil or shape pen
  /// chosen last, so the button keeps the pencil while another tool is used.
  final lastPenFamily = PlainStow(
    'lastPenFamily',
    ToolId.fountainPen,
    codec: ToolId.codec,
    volatile: !_isOnMainIsolate,
  );

  /// Pens kept with the pen panel's "펜박스에 추가", one JSON object each
  /// (see PenBoxEntry in tools/pen_box.dart).
  final penBox = PlainStow('penBox', <String>[], volatile: !_isOnMainIsolate);

  /// Whether the pen panel shows only its pen row. Kept while the app runs,
  /// never saved: the floating bar hands it to each panel it opens.
  final penPanelCollapsed = PlainStow(
    'penPanelCollapsed',
    false,
    volatile: true,
  );

  /// Where the floating bar sits: across the top of the canvas (`'top'`) or
  /// upright at its left (`'left'`). Any other value is taken as the top.
  final floatingBarPosition = PlainStow(
    'floatingBarPosition',
    'top',
    volatile: !_isOnMainIsolate,
  );

  /// Where the quick note window was left over the page area, on this
  /// device: its left, top, width and height. Empty: where it starts (16
  /// from the top right, 360 x 460).
  final quickNoteWindow = PlainStow(
    'quickNoteWindow',
    <String>[],
    volatile: !_isOnMainIsolate,
  );

  /// The share of the page area's height the quick note's phone sheet was
  /// left at, on this device (0.4, 0.6 or 0.9).
  final quickNoteSheet = PlainStow(
    'quickNoteSheet',
    0.6,
    volatile: !_isOnMainIsolate,
  );

  /// Where the 노트 추가 window puts a page, on this device: `'before'` or
  /// `'after'` the page on screen, or at the `'end'`. Any other value is
  /// taken as after.
  final addPagePlace = PlainStow(
    'addPagePlace',
    'after',
    volatile: !_isOnMainIsolate,
  );

  /// The patterns the 노트 추가 window last put pages in, on this device:
  /// their names ([CanvasBackgroundPattern.name], `''` for 빈 종이), newest
  /// first, at most 3.
  final addPageRecent = PlainStow(
    'addPageRecent',
    <String>[],
    volatile: !_isOnMainIsolate,
  );
  final selectRectangle = PlainStow(
    'selectRectangle',
    false,
    volatile: !_isOnMainIsolate,
  );
  final selectInk = PlainStow('selectInk', true, volatile: !_isOnMainIsolate);
  final selectHighlighter = PlainStow(
    'selectHighlighter',
    true,
    volatile: !_isOnMainIsolate,
  );

  /// Whether the lasso picks up the shape pen's strokes (도형), apart from
  /// handwriting ([selectInk]).
  final selectShapes = PlainStow(
    'selectShapes',
    true,
    volatile: !_isOnMainIsolate,
  );
  final selectImages = PlainStow(
    'selectImages',
    true,
    volatile: !_isOnMainIsolate,
  );
  final editorToolbarShowInFullscreen = PlainStow(
    'editorToolbarShowInFullscreen',
    true,
    volatile: !_isOnMainIsolate,
  );
  final editorFingerDrawing = PlainStow(
    'editorFingerDrawing',
    true,
    volatile: !_isOnMainIsolate,
  );
  final editorAutoInvert = PlainStow(
    'editorAutoInvert',
    true,
    volatile: !_isOnMainIsolate,
  );
  final preferGreyscale = PlainStow(
    'preferGreyscale',
    false,
    volatile: !_isOnMainIsolate,
  );
  final editorPromptRename = PlainStow(
    'editorPromptRename',
    isDesktop,
    volatile: !_isOnMainIsolate,
  );
  final autosaveDelay = PlainStow(
    'autosaveDelay',
    10000,
    volatile: !_isOnMainIsolate,
  );
  final shapeRecognitionDelay = PlainStow(
    'shapeRecognitionDelay',
    500,
    volatile: !_isOnMainIsolate,
  );
  final autoStraightenLines = PlainStow(
    'autoStraightenLines',
    true,
    volatile: !_isOnMainIsolate,
  );

  final printPageIndicators = PlainStow(
    'printPageIndicators',
    false,
    volatile: !_isOnMainIsolate,
  );

  final maxImageSize = PlainStow<double>(
    'maxImageSize',
    1000,
    volatile: !_isOnMainIsolate,
  );

  final autoClearWhiteboardOnExit = PlainStow(
    'autoClearWhiteboardOnExit',
    false,
    volatile: !_isOnMainIsolate,
  );

  final disableEraserAfterUse = PlainStow(
    'disableEraserAfterUse',
    false,
    volatile: !_isOnMainIsolate,
  );
  final hideFingerDrawingToggle = PlainStow(
    'hideFingerDrawingToggle',
    false,
    volatile: !_isOnMainIsolate,
  );

  /// People don't know to turn off finger drawing when using a stylus,
  /// so we can do it automatically.
  final autoDisableFingerDrawingWhenStylusDetected = PlainStow(
    'autoDisableFingerDrawingWhenStylusDetected',
    true,
    volatile: !_isOnMainIsolate,
  );

  final recentColorsChronological = PlainStow(
    'recentColorsChronological',
    <String>[],
    volatile: !_isOnMainIsolate,
  );
  final recentColorsPositioned = PlainStow(
    'recentColorsPositioned',
    <String>[],
    volatile: !_isOnMainIsolate,
  );
  final pinnedColors = PlainStow(
    'pinnedColors',
    <String>[],
    volatile: !_isOnMainIsolate,
  );
  final recentColorsDontSavePresets = PlainStow(
    'dontSavePresetColors',
    false,
    volatile: !_isOnMainIsolate,
  );
  final recentColorsLength = PlainStow(
    'recentColorsLength',
    5,
    volatile: !_isOnMainIsolate,
  );

  /// Why the settings table turned a setting off (key → one line); the
  /// settings page shows it under that row while the row stays off.
  final settingsAutoOffReasons = PlainStow.json(
    'settingsAutoOffReasons',
    const <String, String>{},
    fromJson: _stringMapFromJson,
    volatile: !_isOnMainIsolate,
  );
  static Map<String, String> _stringMapFromJson(Object json) =>
      Map<String, String>.from(json as Map);

  final lastTool = PlainStow(
    'lastTool',
    ToolId.fountainPen,
    codec: ToolId.codec,
    volatile: !_isOnMainIsolate,
  );
  static StrokeOptions _strokeOptionsFromJson(Object json) =>
      StrokeOptions.fromJson(json as Map<String, dynamic>);
  final lastFountainPenOptions = PlainStow.json(
        'lastFountainPenProperties',
        Pen.fountainPenOptions,
        fromJson: _strokeOptionsFromJson,
        volatile: !_isOnMainIsolate,
      ),
      lastBallpointPenOptions = PlainStow.json(
        'lastBallpointPenProperties',
        Pen.ballpointPenOptions,
        fromJson: _strokeOptionsFromJson,
        volatile: !_isOnMainIsolate,
      ),
      lastHighlighterOptions = PlainStow.json(
        'lastHighlighterProperties',
        Pen.highlighterOptions,
        fromJson: _strokeOptionsFromJson,
        volatile: !_isOnMainIsolate,
      ),
      lastPencilOptions = PlainStow.json(
        'lastPencilProperties',
        Pen.pencilOptions,
        fromJson: _strokeOptionsFromJson,
        volatile: !_isOnMainIsolate,
      ),
      lastShapePenOptions = PlainStow.json(
        'lastShapePenProperties',
        Pen.shapePenOptions,
        fromJson: _strokeOptionsFromJson,
        volatile: !_isOnMainIsolate,
      );
  final lastFountainPenColor = PlainStow(
        'lastFountainPenColor',
        Colors.black.toARGB32(),
        volatile: !_isOnMainIsolate,
      ),
      lastBallpointPenColor = PlainStow(
        'lastBallpointPenColor',
        Colors.black.toARGB32(),
        volatile: !_isOnMainIsolate,
      ),
      lastHighlighterColor = PlainStow(
        'lastHighlighterColor',
        // StarNote's first highlighter colour (shape_color_list_mark_pen).
        const Color(0xffffe60f).withAlpha(Highlighter.alpha).toARGB32(),
        volatile: !_isOnMainIsolate,
      ),
      lastPencilColor = PlainStow(
        'lastPencilColor',
        Colors.black.toARGB32(),
        volatile: !_isOnMainIsolate,
      ),
      lastShapePenColor = PlainStow(
        'lastShapePenColor',
        Colors.black.toARGB32(),
        volatile: !_isOnMainIsolate,
      );
  final lastBackgroundPattern = PlainStow(
    'lastBackgroundPattern',
    CanvasBackgroundPattern.none,
    codec: const EnumCodec(CanvasBackgroundPattern.values),
    volatile: !_isOnMainIsolate,
  );
  static const defaultLineHeight = 40;
  static const defaultLineThickness = 3;
  final lastLineHeight = PlainStow(
    'lastLineHeight',
    defaultLineHeight,
    volatile: !_isOnMainIsolate,
  );
  final lastLineThickness = PlainStow(
    'lastLineThickness',
    defaultLineThickness,
    volatile: !_isOnMainIsolate,
  );
  final lastZoomLock = PlainStow(
        'lastZoomLock',
        false,
        volatile: !_isOnMainIsolate,
      ),
      lastSingleFingerPanLock = PlainStow(
        'lastSingleFingerPanLock',
        false,
        volatile: !_isOnMainIsolate,
      ),
      lastAxisAlignedPanLock = PlainStow(
        'lastAxisAlignedPanLock',
        false,
        volatile: !_isOnMainIsolate,
      );
  final lastSinglePageMode = PlainStow(
    'lastSinglePageMode',
    false,
    volatile: !_isOnMainIsolate,
  );

  final homeLayout = PlainStow(
    'homeLayout',
    HomeLayout.masonryGrid,
    codec: HomeLayout.codec,
    volatile: !_isOnMainIsolate,
  );
  final browseSortMetric = PlainStow(
    'browseSortMetric',
    SortMetric.nameAToZ,
    codec: SortMetric.codec,
    volatile: !_isOnMainIsolate,
  );
  final recentFiles = PlainStow(
    'recentFiles',
    <String>[],
    volatile: !_isOnMainIsolate,
  );

  /// File paths that have been deleted locally
  final fileSyncAlreadyDeleted = PlainStow(
    'fileSyncAlreadyDeleted',
    <String>{},
    volatile: !_isOnMainIsolate,
  );

  /// File paths that are known to be corrupted on Nextcloud
  final fileSyncCorruptFiles = PlainStow(
    'fileSyncCorruptFiles',
    <String>{},
    volatile: !_isOnMainIsolate,
  );

  /// Set when we want to resync everything.
  /// Files on the server older than this date will be
  /// reuploaded with the local version.
  /// By default, we resync everything uploaded before v0.18.4, since uploads before then resulted in 0B files.
  final fileSyncResyncEverythingDate = PlainStow(
    'fileSyncResyncEverythingDate',
    DateTime.parse('2023-12-10T10:06:31.000Z'),
    codec: const DateTimeCodec(),
    volatile: !_isOnMainIsolate,
  );

  /// The last storage quota that was fetched from Nextcloud
  final lastStorageQuota = PlainStow<Quota?>(
    'lastStorageQuota',
    null,
    codec: const QuotaCodec(),
    volatile: !_isOnMainIsolate,
  );

  final shouldCheckForUpdates = PlainStow(
    'shouldCheckForUpdates',
    FlavorConfig.shouldCheckForUpdatesByDefault && !Platform.isLinux,
    volatile: !_isOnMainIsolate,
  );
  final shouldAlwaysAlertForUpdates = PlainStow(
    'shouldAlwaysAlertForUpdates',
    kDebugMode ? true : false,
    volatile: !_isOnMainIsolate,
  );

  final locale = PlainStow('locale', '', volatile: !_isOnMainIsolate);

  final sentryConsent = PlainStow(
    'sentryConsent',
    SentryConsent.unknown,
    codec: SentryConsent.codec,
    volatile: !_isOnMainIsolate,
  );

  @pragma('vm:platform-const')
  static final isDesktop =
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;
}

/// An [Stow] that transforms the value of another [Stow].
class TransformedStow<T_in, T_out> extends Stow<dynamic, T_out, dynamic> {
  final Stow<dynamic, T_in, dynamic> parent;
  final T_out Function(T_in) transform;
  final T_in Function(T_out) reverseTransform;

  @override
  T_out get value => transform(parent.value);

  @override
  set value(T_out value) => parent.value = reverseTransform(value);

  new(this.parent, this.transform, this.reverseTransform)
    : super(parent.key, transform(parent.defaultValue), volatile: true) {
    parent.addListener(notifyListeners);
  }

  @override
  Future<dynamic> protectedRead() async => null;

  @override
  Future<void> protectedWrite(dynamic value) async {}

  @override
  String toString() {
    return 'TransformedPref<$T_in, $T_out>(from ${parent.key}, $value)';
  }

  @override
  void dispose() {
    parent.removeListener(notifyListeners);
    super.dispose();
  }
}
