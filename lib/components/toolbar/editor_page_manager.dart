import 'dart:math';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/theming/adaptive_icon.dart';
import 'package:saber/components/theming/saber_theme.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/i18n/strings.g.dart';

class EditorPageManager extends StatefulWidget {
  const new({
    super.key,
    required this.coreInfo,
    required this.currentPageIndex,
    this.readOnly = false,
    required this.redrawAndSave,
    required this.insertPageAfter,
    required this.duplicatePage,
    required this.clearPage,
    required this.deletePage,
    required this.onPageSelected,
  });

  final EditorCoreInfo coreInfo;

  /// The page the window opens on: its row is scrolled into view and its
  /// number is set in the accent, as the left panel marks it, while that
  /// page is in the note.
  final int? currentPageIndex;

  /// The pages may be looked at and gone to, not changed (the editor's
  /// 「읽기 전용」).
  final bool readOnly;

  final VoidCallback redrawAndSave;

  final void Function(int) insertPageAfter;
  final void Function(int) duplicatePage;
  final void Function(int) clearPage;
  final void Function(int) deletePage;

  final ValueChanged<int> onPageSelected;

  @override
  State<EditorPageManager> createState() => _EditorPageManagerState();
}

class _EditorPageManagerState extends State<EditorPageManager> {
  final _scroll = ScrollController();
  final _currentRow = GlobalKey();

  /// The page the window opened on, followed by its id: pages deleted, put
  /// in or moved in the window leave the mark on it (gone with it).
  late final _currentId = switch (widget.currentPageIndex) {
    final int i => widget.coreInfo.pages.elementAtOrNull(i)?.pageId,
    null => null,
  };

  @override
  void initState() {
    super.initState();
    final index = widget.currentPageIndex;
    if (index != null && index > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Puts the current page's row in view. The list builds a row only as it
  /// comes near the view, so it moves a view at a time until that row is
  /// built.
  Future<void> _reveal() async {
    for (var step = 0; step < 1000; step++) {
      if (!mounted || !_scroll.hasClients) return;
      final row = _currentRow.currentContext;
      if (row != null && row.mounted) {
        return Scrollable.ensureVisible(row, alignment: 0.5);
      }
      final position = _scroll.position;
      if (position.pixels >= position.maxScrollExtent) return;
      _scroll.jumpTo(
        min(
          position.pixels + position.viewportDimension,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// A page's button, dimmed as the kit dims while off: its own colour at
  /// [KitTokens.disabledOpacity], not Material's own fade.
  Widget _pageButton({
    required String tooltip,
    required Widget icon,
    required VoidCallback? onPressed,
  }) => Opacity(
    opacity: onPressed == null ? KitTokens.disabledOpacity : 1,
    child: IconButton(
      tooltip: tooltip,
      icon: icon,
      disabledColor: ColorScheme.of(context).onSurfaceVariant,
      onPressed: onPressed,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final cupertino = platform.isCupertino;
    return SizedBox(
      width: cupertino ? null : 300,
      height: cupertino ? 600 : null,
      child: ReorderableListView.builder(
        scrollController: _scroll,
        buildDefaultDragHandles: false,
        itemCount: widget.coreInfo.pages.length,
        itemBuilder: (context, pageIndex) {
          final isEmptyLastPage =
              pageIndex == widget.coreInfo.pages.length - 1 &&
              widget.coreInfo.pages[pageIndex].isEmpty;
          final current =
              _currentId != null &&
              widget.coreInfo.pages[pageIndex].pageId == _currentId;
          return InkWell(
            key: ValueKey(pageIndex),
            onTap: () => widget.onPageSelected(pageIndex),
            child: Padding(
              key: current ? _currentRow : null,
              padding: const .all(8),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: .spaceAround,
                    children: [
                      Text(
                        '${pageIndex + 1} / ${widget.coreInfo.pages.length}',
                        style: current
                            ? const TextStyle(
                                color: KitTokens.sideThumbOnInk,
                                fontWeight: FontWeight.w600,
                              )
                            : null,
                      ),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: cupertino ? 100 : 150,
                            maxHeight: 250,
                          ),
                          child: FittedBox(
                            child: CanvasPreview(
                              pageIndex: pageIndex,
                              height: null,
                              coreInfo: widget.coreInfo,
                            ),
                          ),
                        ),
                      ),
                      // locked, the handle does not drag and is dimmed
                      Opacity(
                        opacity: widget.readOnly
                            ? KitTokens.disabledOpacity
                            : 1,
                        child: MouseRegion(
                          cursor: widget.readOnly
                              ? MouseCursor.defer
                              : SystemMouseCursors.resizeUpDown,
                          child: ReorderableDragStartListener(
                            index: pageIndex,
                            enabled: !widget.readOnly,
                            child: const Padding(
                              padding: .all(8),
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    alignment: .center,
                    children: [
                      _pageButton(
                        tooltip: t.editor.menu.insertPage,
                        icon: const AdaptiveIcon(
                          icon: Icons.insert_page_break,
                          cupertinoIcon: CupertinoIcons.add,
                        ),
                        onPressed: widget.readOnly
                            ? null
                            : () => setState(() {
                                widget.insertPageAfter(pageIndex);
                                widget.onPageSelected(pageIndex + 1);
                              }),
                      ),
                      _pageButton(
                        tooltip: t.editor.menu.duplicatePage,
                        icon: const AdaptiveIcon(
                          icon: Icons.content_copy,
                          cupertinoIcon: CupertinoIcons.doc_on_clipboard,
                        ),
                        onPressed: widget.readOnly
                            ? null
                            : () => setState(() {
                                widget.duplicatePage(pageIndex);
                                widget.onPageSelected(pageIndex + 1);
                              }),
                      ),
                      _pageButton(
                        tooltip: t.editor.menu.clearPage(
                          page: pageIndex + 1,
                          totalPages: widget.coreInfo.pages.length,
                        ),
                        icon: const Icon(Icons.cleaning_services),
                        onPressed: isEmptyLastPage || widget.readOnly
                            ? null
                            : () => setState(() {
                                widget.clearPage(pageIndex);
                                widget.onPageSelected(pageIndex);
                              }),
                      ),
                      _pageButton(
                        tooltip: t.editor.menu.deletePage,
                        icon: const AdaptiveIcon(
                          icon: Icons.delete,
                          cupertinoIcon: CupertinoIcons.delete,
                        ),
                        onPressed: isEmptyLastPage || widget.readOnly
                            ? null
                            : () => setState(() {
                                widget.deletePage(pageIndex);
                                widget.onPageSelected(pageIndex);
                              }),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
        onReorderItem: (oldIndex, newIndex) {
          if (oldIndex == newIndex || widget.readOnly) return;
          widget.coreInfo.pages.insert(
            newIndex,
            widget.coreInfo.pages.removeAt(oldIndex),
          );

          // reassign pageIndex of pages' strokes and images
          for (int i = 0; i < widget.coreInfo.pages.length; i++) {
            final page = widget.coreInfo.pages[i];
            page.updatePageIndex(i);
          }

          widget.redrawAndSave();
        },
      ),
    );
  }
}
