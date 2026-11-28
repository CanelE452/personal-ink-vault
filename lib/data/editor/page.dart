import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show FragmentShader;

import 'package:collection/collection.dart' show mergeSort;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId, validateId;
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/inner_canvas.dart';
import 'package:saber/components/canvas/pencil_shader.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/has_size.dart';

typedef CanvasKey = GlobalKey<State<InnerCanvas>>;

class EditorPage extends ChangeNotifier implements HasSize {
  final String pageId;
  static const double defaultWidth = 1000;
  static const double defaultHeight = defaultWidth * 1.4;
  static const defaultSize = Size(defaultWidth, defaultHeight);

  @override
  final Size size;

  late final CanvasKey innerCanvasKey = CanvasKey();
  RenderBox? _renderBox;
  RenderBox? get renderBox {
    return _renderBox ??=
        innerCanvasKey.currentState?.context.findRenderObject() as RenderBox?;
  }

  var _isRendered = false;
  bool get isRendered => _isRendered;
  set isRendered(bool isRendered) {
    if (isRendered == _isRendered) return;
    _isRendered = isRendered;

    // reset renderBox as renderObject has changed
    _renderBox = null;
  }

  FragmentShader get pencilShader => _pencilShader ??= PencilShader.create();
  FragmentShader? _pencilShader;

  final List<Stroke> strokes;

  /// The strokes as opening put them, when it grouped them by tool the old
  /// way ([sortStrokes]): saving compares the strokes with it
  /// ([drawnOrderChanged]). Not saved, and not given to a [copyWith].
  List<Stroke>? openedOrder;

  final List<LaserStroke> laserStrokes;
  final List<EditorImage> images;
  final QuillStruct quill;

  /// Notein's hyperlinks on this page. They are not page content, so
  /// [isEmpty] does not look at them.
  final List<PageLink> links;

  EditorImage? backgroundImage;

  /// This page's own pattern, or null to follow the note's
  /// [EditorCoreInfo.backgroundPattern]. Saved as `bp` only when it differs
  /// from the note's, which makes the note version 20
  /// ([EditorCoreInfo.versionToWrite]).
  CanvasBackgroundPattern? backgroundPattern;

  /// Whether this page draws a pattern other than [notePattern], the note's.
  /// A page with a [backgroundImage] draws no pattern, so it has none of its
  /// own whatever [backgroundPattern] says.
  bool hasOwnPattern(CanvasBackgroundPattern notePattern) =>
      backgroundImage == null &&
      backgroundPattern != null &&
      backgroundPattern != notePattern;

  /// Whether this page holds something only version 21 notes can carry (a
  /// pen engine tool or stroke value), which makes the note version 21
  /// ([EditorCoreInfo.versionToWrite]).
  bool get needsV21 => strokes.any((stroke) => stroke.needsV21);

  bool get isEmpty =>
      strokes.isEmpty &&
      images.isEmpty &&
      quill.controller.document.isEmpty() &&
      backgroundImage == null &&
      backgroundPattern == null;
  bool get isNotEmpty => !isEmpty;

  /// The height of the canvas cropped to the content.
  double previewHeight({required int lineHeight}) {
    // avoid dividing by zero (this should never happen)
    assert(size.height != 0);
    assert(size.width != 0);
    if (size.height == 0 || size.width == 0) {
      return 0;
    }

    // if we have a background image, show full height
    if (backgroundImage != null) {
      return size.height;
    }

    /// The maximum y value of any stroke, image, or text.
    double maxY = 0;
    for (final stroke in strokes) {
      maxY = max(maxY, stroke.maxY);
    }
    for (final image in images) {
      maxY = max(maxY, image.dstRect.bottom);
    }
    if (!quill.controller.document.isEmpty()) {
      // this does not account for text that wraps to the next line
      final int linesOfText = quill.controller.document
          .toPlainText()
          .split('\n')
          .length;
      maxY = max(maxY, linesOfText * lineHeight * 1.5); // ×1.5 fudge factor
    }

    /// The uncropped height of the page.
    /// In lots of cases, this is [Editor.defaultHeight].
    final fullHeight = size.height;

    /// The height of the canvas (cropped),
    /// adjusted to be between 10% and 100% of the full height.
    final croppedHeight = min(fullHeight, max(maxY, 0) + (0.1 * fullHeight));

    return croppedHeight;
  }

  new({
    String? pageId,
    Size? size,
    double? width,
    double? height,
    List<Stroke>? strokes,
    List<EditorImage>? images,
    QuillStruct? quill,
    List<PageLink>? links,
    this.backgroundImage,
    this.backgroundPattern,
  }) : assert(
         (size == null) || (width == null && height == null),
         "size and width/height shouldn't both be specified",
       ),
       pageId = pageId ?? newId(),
       size = size ?? Size(width ?? defaultWidth, height ?? defaultHeight),
       strokes = strokes ?? [],
       laserStrokes = [],
       images = images ?? [],
       links = links ?? [],
       quill =
           quill ??
           QuillStruct(
             controller: QuillController.basic(),
             focusNode: FocusNode(debugLabel: 'Quill Focus Node'),
           );

  factory fromJson(
    Map<String, dynamic> json, {
    required List<Uint8List>? inlineAssets,
    required bool readOnly,
    required int fileVersion,
    required String sbnPath,
    required AssetCache assetCache,
  }) {
    final size = Size(json['w'] ?? defaultWidth, json['h'] ?? defaultHeight);
    if (json['pageId'] != null) validateId(json['pageId'] as String);
    return EditorPage(
      pageId: json['pageId'] as String?,
      size: size,
      strokes: parseStrokesJson(
        json['s'] as List?,
        page: HasSize(size),
        onlyFirstPage: false,
        fileVersion: fileVersion,
      ),
      images: parseImagesJson(
        json['i'] as List?,
        inlineAssets: inlineAssets,
        isThumbnail: readOnly,
        onlyFirstPage: false,
        sbnPath: sbnPath,
        assetCache: assetCache,
      ),
      quill: QuillStruct(
        controller: json['q'] != null
            ? QuillController(
                document: Document.fromJson(json['q'] as List),
                selection: const TextSelection.collapsed(offset: 0),
              )
            : QuillController.basic(),
        focusNode: FocusNode(debugLabel: 'Quill Focus Node'),
      ),
      links: [
        if (json['lk'] case final List entries)
          for (final entry in entries) ?PageLink.fromJson(entry),
      ],
      backgroundImage: json['b'] != null
          ? parseImageJson(
              json['b'],
              inlineAssets: inlineAssets,
              isThumbnail: false,
              sbnPath: sbnPath,
              assetCache: assetCache,
            )
          : null,
      backgroundPattern: json['bp'] != null
          ? CanvasBackgroundPattern.fromName(json['bp'] as String)
          : null,
    );
  }

  /// [notePattern] is the note's pattern: the page writes its own (`bp`) only
  /// when [hasOwnPattern].
  Map<String, dynamic> toJson(
    OrderedAssetCache assets, {
    required CanvasBackgroundPattern notePattern,
  }) => {
    'pageId': pageId,
    'w': size.width,
    'h': size.height,
    if (strokes.isNotEmpty)
      's': strokes.map((stroke) => stroke.toJson()).toList(),
    if (images.isNotEmpty)
      'i': images.map((image) => image.toJson(assets)).toList(),
    if (!quill.controller.document.isEmpty())
      'q': quill.controller.document.toDelta().toJson(),
    if (backgroundImage != null) 'b': backgroundImage?.toJson(assets),
    if (links.isNotEmpty) 'lk': links.map((link) => link.toJson()).toList(),
    if (hasOwnPattern(notePattern)) 'bp': backgroundPattern!.name,
  };

  /// The order of the strokes: highlighters first, by colour and then
  /// opacity, the rest in the order they were drawn. The canvas draws the
  /// highlighters under the rest anyway, so only the order among them and
  /// among the rest shows.
  static int layerCompare(Stroke a, Stroke b) {
    final aHighlights = a.toolId == .highlighter;
    if (aHighlights != (b.toolId == .highlighter)) return aHighlights ? -1 : 1;
    if (!aHighlights) return 0;
    final colour = a.color.toARGB32().compareTo(b.color.toARGB32());
    if (colour != 0) return colour;
    return (a.style.alpha ?? defaultAlphaOf(a.toolId)).compareTo(
      b.style.alpha ?? defaultAlphaOf(b.toolId),
    );
  }

  /// The order build 234 opens every note in: by pen type, highlighters
  /// among themselves by colour.
  static int legacyCompare(Stroke a, Stroke b) {
    final penTypeComparison = a.toolId.id.compareTo(b.toolId.id);
    if (penTypeComparison != 0) return penTypeComparison;
    if (a.toolId != .highlighter) return 0;
    return a.color.toARGB32().compareTo(b.color.toARGB32());
  }

  /// Inserts a stroke before the first stroke that [compare] puts after
  /// it: by default a stroke goes on top, a highlighter at the end of its
  /// colour and opacity.
  void insertStroke(
    Stroke newStroke, {
    Comparator<Stroke> compare = EditorPage.layerCompare,
  }) {
    final index = strokes.indexWhere(
      (stroke) => compare(stroke, newStroke) > 0,
    );
    strokes.insert(index == -1 ? strokes.length : index, newStroke);
  }

  /// Orders the strokes of a page just opened. In [drawnOrder] (a version
  /// 21 note, or one marked `so`) they keep the file's order but the
  /// highlighters' ([layerCompare]). Otherwise they are grouped by tool as
  /// build 234 does, with the same [List.sort], and [openedOrder] keeps
  /// the result.
  void sortStrokes({required bool drawnOrder}) {
    if (drawnOrder) {
      mergeSort(strokes, compare: layerCompare);
    } else {
      strokes.sort(legacyCompare);
      openedOrder = List.of(strokes);
    }
  }

  /// Whether opening this page the old way would not give its strokes in
  /// the order they have now, so the note must be saved marked `so`. A
  /// page opened the old way compares with [openedOrder]: [List.sort] does
  /// not keep equal strokes in order from 34 on, so sorting again could
  /// move strokes of an untouched page. Any other page is opened next
  /// time from the order it is saved in, so a sorted copy of it is what
  /// that opening would give.
  bool get drawnOrderChanged {
    final old = openedOrder ?? (List.of(strokes)..sort(legacyCompare));
    if (old.length != strokes.length) return true;
    for (var i = 0; i < old.length; i++) {
      if (!identical(old[i], strokes[i])) return true;
    }
    return false;
  }

  static List<Stroke> parseStrokesJson(
    List<dynamic>? strokes, {
    required HasSize page,
    required bool onlyFirstPage,
    required int fileVersion,
  }) => (strokes ?? [])
      .map((dynamic stroke) {
        final map = stroke as Map<String, dynamic>;
        final pageIndex = map['i'] ?? 0;
        if (onlyFirstPage && pageIndex > 0) return null;
        return Stroke.fromJson(
          map,
          fileVersion: fileVersion,
          pageIndex: pageIndex,
          page: page,
        );
      })
      .where((element) => element != null)
      .cast<Stroke>()
      .toList();

  static List<EditorImage> parseImagesJson(
    List<dynamic>? images, {
    required List<Uint8List>? inlineAssets,
    required bool isThumbnail,
    required bool onlyFirstPage,
    required String sbnPath,
    required AssetCache assetCache,
  }) =>
      images
          ?.cast<Map<String, dynamic>>()
          .map((Map<String, dynamic> image) {
            if (onlyFirstPage && image['i'] > 0) return null;
            return parseImageJson(
              image,
              inlineAssets: inlineAssets,
              isThumbnail: isThumbnail,
              sbnPath: sbnPath,
              assetCache: assetCache,
            );
          })
          .where((element) => element != null)
          .cast<EditorImage>()
          .toList() ??
      [];

  static EditorImage parseImageJson(
    Map<String, dynamic> json, {
    required List<Uint8List>? inlineAssets,
    required bool isThumbnail,
    required String sbnPath,
    required AssetCache assetCache,
  }) => EditorImage.fromJson(
    json,
    inlineAssets: inlineAssets,
    isThumbnail: isThumbnail,
    sbnPath: sbnPath,
    assetCache: assetCache,
  );

  /// Triggers a redraw of the strokes. If you need to redraw images,
  /// call [setState] instead.
  void redrawStrokes() {
    notifyListeners();
  }

  /// Updates the `pageIndex` fields of this page's strokes/images.
  void updatePageIndex(int pageIndex) {
    for (final stroke in strokes) stroke.pageIndex = pageIndex;
    for (final stroke in laserStrokes) stroke.pageIndex = pageIndex;
    for (final image in images) image.pageIndex = pageIndex;
    backgroundImage?.pageIndex = pageIndex;
  }

  @override
  void dispose() {
    quill.dispose();
    _pencilShader?.dispose();
    isRendered = false;
    for (final image in images) {
      image.dispose();
    }
    backgroundImage?.dispose();
    super.dispose();
  }

  /// [cloneForRasterization] creates some new resources that need to be
  /// disposed, but it also contains some resources from the original page
  /// that should not be disposed since they are still in use.
  ///
  /// Call this method instead of [dispose] to dispose only the resources
  /// exclusive to the cloned page.
  void disposeClonedData() {
    quill.dispose();
    _pencilShader?.dispose();
    isRendered = false;
    super.dispose();
  }

  /// [backgroundPattern] given as null makes the copy follow the note's
  /// pattern; left out, the copy keeps this page's.
  EditorPage copyWith({
    String? pageId,
    bool newIdentity = false,
    Size? size,
    List<Stroke>? strokes,
    List<EditorImage>? images,
    QuillStruct? quill,
    EditorImage? backgroundImage,
    Object? backgroundPattern = _samePattern,
    List<PageLink>? links,
  }) => EditorPage(
    pageId: newIdentity ? newId() : pageId ?? this.pageId,
    size: size ?? this.size,
    strokes: strokes ?? this.strokes,
    images: images ?? this.images,
    quill: quill ?? this.quill,
    // A copy's links are its own: new ids, so undoing a change to one never
    // touches the other page's.
    links:
        links ??
        [
          for (final link in this.links)
            PageLink(id: newId(), rect: link.rect, target: link.target),
        ],
    backgroundImage: backgroundImage ?? this.backgroundImage,
    backgroundPattern: identical(backgroundPattern, _samePattern)
        ? this.backgroundPattern
        : backgroundPattern as CanvasBackgroundPattern?,
  );

  /// [copyWith] left without a pattern.
  static const _samePattern = Object();

  /// Clones this page for use in a screenshot.
  ///
  /// Avoids bugs caused by the quill editor being attached to multiple
  /// contexts, and filters out strokes that shouldn't be rasterized.
  ///
  /// Make sure to call [disposeClonedData] on the returned page when
  /// you're done with it.
  EditorPage cloneForRasterization({bool rasterizeAllStrokes = false}) {
    return copyWith(
      strokes: rasterizeAllStrokes
          ? strokes
          : strokes.where(EditorExporter.shouldRasterizeStroke).toList(),
      quill: quill.cloneForScreenshot(),
    );
  }
}

class QuillStruct {
  final QuillController controller;
  late final FocusNode focusNode;
  StreamSubscription? changeSubscription;

  new({required this.controller, required this.focusNode});

  void dispose() {
    changeSubscription?.cancel();
    focusNode.dispose();
    controller.dispose();
  }

  QuillStruct cloneForScreenshot() => QuillStruct(
    controller: QuillController(
      document: Document.fromDelta(controller.document.toDelta()),
      selection: const TextSelection.collapsed(offset: 0),
    ),
    focusNode: FocusNode(debugLabel: 'Screenshot Quill Focus Node'),
  );
}

/// The [pages] that had [own] as their pattern until the note took it
/// ([EditorCoreInfo.setNotePattern]): they follow the note from then on.
typedef PatternFollowers = ({
  CanvasBackgroundPattern own,
  List<EditorPage> pages,
});
