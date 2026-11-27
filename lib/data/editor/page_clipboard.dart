import 'package:flutter/foundation.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:sbn/canvas_background_pattern.dart';

/// One page held for pasting into a note, possibly another one. It keeps its
/// own bytes, so it does not depend on the note it came from.
class PageClip {
  const new({
    required this.json,
    required this.assets,
    required this.pattern,
    required this.fileVersion,
  });

  /// [EditorPage.toJson] of the page. The `'a'` of a photo or a PDF is an
  /// index into [assets].
  final Map<String, dynamic> json;
  final List<Uint8List> assets;

  /// The pattern the page drew, or null when it has a background picture.
  final CanvasBackgroundPattern? pattern;
  final int fileVersion;
}

class PageClipboard {
  /// One for the whole app; empty after the app restarts.
  static final current = ValueNotifier<PageClip?>(null);

  /// How many copies were started: each knows its own number.
  static var _copies = 0;

  /// Holds the clip [copy] makes, unless a copy started after it (that one
  /// is newer, even when it ends first, as a big PDF page's copy may);
  /// whether it did.
  static Future<bool> hold(Future<PageClip> Function() copy) async {
    final mine = ++_copies;
    final clip = await copy();
    if (mine != _copies) return false;
    current.value = clip;
    return true;
  }
}

/// Copies [page] into a [PageClip]. When [extractPdfPage] is given and the
/// background is a PDF page, only that page is kept (and `pdfi` becomes 0);
/// if it returns null the whole PDF is kept.
Future<PageClip> clipPage(
  EditorPage page, {
  required CanvasBackgroundPattern notePattern,
  required AssetCache assetCache,
  Future<Uint8List?> Function(Uint8List pdf, int pageIndex)? extractPdfPage,
}) async {
  final ordered = OrderedAssetCache();
  final json = page.toJson(ordered, notePattern: notePattern);
  final assets = <Uint8List>[
    for (var i = 0; i < ordered.length; i++)
      Uint8List.fromList(await ordered.getBytes(i)),
  ];

  final background = page.backgroundImage;
  final backgroundJson = json['b'];
  if (extractPdfPage != null &&
      background is PdfEditorImage &&
      backgroundJson is Map<String, dynamic>) {
    final assetIndex = backgroundJson['a'] as int;
    final onePage = await extractPdfPage(
      assets[assetIndex],
      background.pdfPage,
    );
    if (onePage != null) {
      assets[assetIndex] = onePage;
      backgroundJson['pdfi'] = 0;
    }
  }

  return PageClip(
    json: json,
    assets: assets,
    pattern: background != null ? null : page.backgroundPattern ?? notePattern,
    fileVersion: EditorCoreInfo.newestSbnVersion,
  );
}

/// Makes a new page from [clip], with a new page id and new link ids. Pictures
/// get id -1: the caller gives them ids from the note's `nextImageId`.
EditorPage pastePage(
  PageClip clip, {
  required String sbnPath,
  required AssetCache assetCache,
  required CanvasBackgroundPattern notePattern,
  required int pageIndex,
}) {
  final json = _copy(clip.json) as Map<String, dynamic>;
  json.remove('pageId');
  json.remove('bp');
  if (json['i'] case final List images) {
    for (final image in images) {
      (image as Map).remove('id');
    }
  }
  if (json['b'] case final Map background) background.remove('id');

  final read = EditorPage.fromJson(
    json,
    inlineAssets: clip.assets,
    readOnly: false,
    fileVersion: clip.fileVersion,
    sbnPath: sbnPath,
    assetCache: assetCache,
  );
  final page = read.copyWith(
    newIdentity: true,
    backgroundPattern: clip.pattern == notePattern ? null : clip.pattern,
  );
  page.updatePageIndex(pageIndex);
  return page;
}

Object? _copy(Object? value) => switch (value) {
  Map() => {for (final e in value.entries) e.key as String: _copy(e.value)},
  List() => [for (final e in value) _copy(e)],
  _ => value,
};
