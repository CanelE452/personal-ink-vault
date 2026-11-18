import 'dart:ui' show Rect;

import 'package:fixnum/fixnum.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show validateId;
import 'package:saber/data/vault/note_link.dart';

/// What a [PageLink] opens.
enum PageLinkKind {
  /// A page of the same note (`page:<pageId>`), followed by its id so it still
  /// works after the pages are reordered.
  page,

  /// Another note, or a page of it (an `inkvault://note/…` link).
  note,

  /// A web address (http or https only).
  web,
}

/// A hyperlink on a handwritten page (Notein's "링크"): an area of the page,
/// in page coordinates, that opens [target]. An icon link, put where the user
/// tapped, has an area of zero width and height.
///
/// Pages store their links under `lk` as `{i, x, y, w, h, t}`. Builds that do
/// not know the key skip it.
final class PageLink {
  const new({required this.id, required this.rect, required this.target});

  final String id;
  final Rect rect;
  final String target;

  static const pagePrefix = 'page:';

  /// What [target] opens, or null when it is not a link this app follows.
  static PageLinkKind? kindOf(String target) {
    if (target.startsWith(pagePrefix)) {
      return _isId(target.substring(pagePrefix.length))
          ? PageLinkKind.page
          : null;
    }
    if (NoteLink.parse(target) != null) return PageLinkKind.note;
    if (isSafeExternalLink(target)) return PageLinkKind.web;
    return null;
  }

  /// Every link the app makes or reads has a target [kindOf] knows.
  PageLinkKind get kind => kindOf(target)!;

  /// Whether this link is an icon only (no area to underline).
  bool get isIcon => rect.width == 0 && rect.height == 0;

  /// The linked page of this note, for a [PageLinkKind.page] link.
  String? get pageId => kindOf(target) == PageLinkKind.page
      ? target.substring(pagePrefix.length)
      : null;

  Map<String, Object?> toJson() => {
    'i': id,
    'x': rect.left,
    'y': rect.top,
    'w': rect.width,
    'h': rect.height,
    't': target,
  };

  /// A link read back from a page, or null when the entry is broken: an
  /// entry this build cannot use is dropped, never an error that would stop
  /// the note from opening.
  static PageLink? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['i'];
    final target = json['t'];
    final x = _number(json['x']);
    final y = _number(json['y']);
    final width = _number(json['w']);
    final height = _number(json['h']);
    if (id is! String ||
        id.isEmpty ||
        target is! String ||
        kindOf(target) == null ||
        x == null ||
        y == null ||
        width == null ||
        height == null ||
        width < 0 ||
        height < 0) {
      return null;
    }
    return PageLink(
      id: id,
      rect: Rect.fromLTWH(x, y, width, height),
      target: target,
    );
  }

  /// Numbers come back as int, double or BSON's Int64.
  static double? _number(Object? value) {
    final number = switch (value) {
      final int value => value.toDouble(),
      final double value => value,
      final Int64 value => value.toDouble(),
      _ => null,
    };
    return number != null && number.isFinite ? number : null;
  }

  static bool _isId(String value) {
    try {
      validateId(value);
      return true;
    } on FormatException {
      return false;
    }
  }
}
