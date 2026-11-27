import 'package:flutter/widgets.dart';
import 'package:saber/components/ink_ui/add_page/kit_add_page_window.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/prefs.dart';
import 'package:sbn/canvas_background_pattern.dart';

/// 노트 추가 beside the editor (supplement Task 14, 12th draft `addHtml`):
/// its window under the toolbar's button ([anchor]), lit while [open], and
/// what this device keeps for it: where it puts a page
/// (`stows.addPagePlace`) and the patterns it last put pages in
/// (`stows.addPageRecent`, by name). They are read before the window shows
/// them.
class EditorAddPageHost {
  new({required VoidCallback onChanged}) {
    open.addListener(onChanged);
  }

  /// Under the toolbar's 노트 추가 button, as wide as it.
  final anchor = GlobalKey();

  /// The window is open.
  final open = ValueNotifier(false);

  /// Where a page goes, as last chosen (after the page on screen to start).
  KitAddPagePlace get place =>
      KitAddPagePlace.values.asNameMap()[stows.addPagePlace.value] ??
      KitAddPagePlace.after;

  /// The window's patterns last put in pages, newest first.
  List<KitAddPagePaper> get recent => [
    for (final name in stows.addPageRecent.value)
      for (final paper in kitAddPagePapers)
        if (paper.pattern.name == name) paper,
  ];

  /// Once the kept place and patterns are read.
  Future<void> ready() async {
    final place = stows.addPagePlace, recent = stows.addPageRecent;
    if (!place.loaded) await place.waitUntilRead();
    if (!recent.loaded) await recent.waitUntilRead();
  }

  /// Opens the window over the screen of [context] (the toolbar's), with
  /// 「문서 가져오기」 when [document]; what it was closed with, or null.
  Future<KitAddPageChoice?> show(
    BuildContext context, {
    required bool document,
  }) async {
    if (open.value) return null;
    open.value = true;
    final screen = Navigator.of(context).context;
    try {
      await ready();
      if (!screen.mounted) return null;
      return await showKitPopover<KitAddPageChoice>(
        context: screen,
        anchor: anchor,
        shadows: KitTokens.menuShadow,
        border: false,
        nub: true,
        within: screen.findRenderObject() as RenderBox?,
        builder: (_) => KitAddPageWindow(
          place: place,
          recent: recent,
          document: document,
          onPlace: (chosen) => stows.addPagePlace.value = chosen.name,
        ),
      );
    } finally {
      // the editor may go while its window is open
      if (!_disposed) open.value = false;
    }
  }

  /// A page was put in [pattern] from the window: it is the newest recent
  /// pattern, the oldest of more than 3 goes.
  void used(CanvasBackgroundPattern pattern) => stows.addPageRecent.value = [
    pattern.name,
    ...stows.addPageRecent.value.where((name) => name != pattern.name),
  ].take(3).toList();

  var _disposed = false;

  void dispose() {
    _disposed = true;
    open.dispose();
  }
}
