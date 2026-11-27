import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/ink_ui/side_panel/side_row_parts.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// One line of the outline tab: [title], [depth] levels in, leading to the
/// page counted [page] from 0; [current], the line of the page on screen.
class KitOutlineRow {
  const new({
    required this.id,
    required this.title,
    required this.page,
    this.depth = 0,
    this.current = false,
  });

  final String id;
  final String title;
  final int page;
  final int depth;
  final bool current;
}

/// The outline tab (12th draft `sideHtml`, `orow`): [pdf] under 「PDF 목차 ·
/// 자동」, [mine] under 「내가 더한 개요」, then a hint. A press on a line calls
/// [onGo]. Where [editable], each line has a ⋯ menu (「이름 바꾸기」 calls
/// [onRenameStart], 「지우기」 [onRemove]) and the line [renaming] names is a
/// field with 「완료」 ([onRename] with what was typed, [onRenameEdit] as it
/// is typed; Escape calls [onRename] with the old name). With no line at
/// all it shows the tab's empty line, or where nothing can be added
/// 「이 노트에는 개요가 없습니다.」, and nothing while the PDF's outline is
/// still [loading]. It scrolls, building the lines as they come in.
class KitSideOutline extends StatelessWidget {
  const new({
    super.key,
    required this.pdf,
    required this.mine,
    required this.editable,
    this.loading = false,
    this.renaming,
    required this.onGo,
    required this.onRenameStart,
    required this.onRenameEdit,
    required this.onRename,
    required this.onRemove,
  });

  final List<KitOutlineRow> pdf;
  final List<KitOutlineRow> mine;
  final bool editable;
  final bool loading;
  final String? renaming;
  final ValueChanged<KitOutlineRow> onGo;
  final ValueChanged<KitOutlineRow> onRenameStart;
  final void Function(KitOutlineRow row, String title) onRenameEdit;
  final void Function(KitOutlineRow row, String title) onRename;
  final ValueChanged<KitOutlineRow> onRemove;

  @override
  Widget build(BuildContext context) {
    if (pdf.isEmpty && mine.isEmpty) {
      if (loading) return const SizedBox.shrink();
      return editable
          ? const KitSideEmpty(KitSideTab.outline)
          : const KitSideEmpty(KitSideTab.outline, text: '이 노트에는 개요가 없습니다.');
    }
    Widget line(KitOutlineRow row) => row.id == renaming && editable
        ? _RenameRow(
            key: ValueKey('kit-outline-row-${row.id}'),
            row: row,
            onEdit: (title) => onRenameEdit(row, title),
            onDone: (title) => onRename(row, title),
          )
        : _Row(
            key: ValueKey('kit-outline-row-${row.id}'),
            row: row,
            editable: editable,
            onGo: onGo,
            onRename: onRenameStart,
            onRemove: onRemove,
          );
    // the group titles, the lines and the hint, in order
    final items = <Object>[
      if (pdf.isNotEmpty) ...[
        const KitSideGroupTitle('PDF 목차', tag: '자동'),
        ...pdf,
      ],
      if (mine.isNotEmpty) ...[const KitSideGroupTitle('내가 더한 개요'), ...mine],
      if (editable)
        const KitSideHint('쪽 ⋯ 메뉴의 「개요에 추가」로 지금 쪽을 더합니다. 줄을 누르면 그 쪽으로 갑니다.'),
    ];
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: items.length,
      itemBuilder: (context, i) => switch (items[i]) {
        final KitOutlineRow row => line(row),
        final item => item as Widget,
      },
    );
  }
}

/// The room left of a line's title (16, and 16 more a level in) and
/// [right] of its end.
EdgeInsets _rowPadding(KitOutlineRow row, double right) => EdgeInsets.only(
  left:
      KitTokens.sideRowPadLeft +
      KitTokens.sideRowIndent * row.depth.clamp(0, KitTokens.sideRowIndentMax),
  right: right,
);

const _titleStyle = TextStyle(
  fontSize: KitTokens.sideRowFontSize,
  height: KitTokens.sideLineHeight,
  letterSpacing: 0,
  color: KitTokens.sideRowInk,
);

/// `.r1row`: a line's title, its page and its ⋯.
class _Row extends StatefulWidget {
  const new({
    super.key,
    required this.row,
    required this.editable,
    required this.onGo,
    required this.onRename,
    required this.onRemove,
  });

  final KitOutlineRow row;
  final bool editable;
  final ValueChanged<KitOutlineRow> onGo;
  final ValueChanged<KitOutlineRow> onRename;
  final ValueChanged<KitOutlineRow> onRemove;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  final _below = GlobalKey();
  final _above = GlobalKey();
  var _menuOpen = false;

  KitOutlineRow get row => widget.row;

  Future<void> _openMenu() async {
    setState(() => _menuOpen = true);
    final picked = await showKitSideRowMenu(
      context,
      below: _below,
      above: _above,
    );
    if (mounted) setState(() => _menuOpen = false);
    switch (picked) {
      case KitSideRowAction.rename:
        widget.onRename(row);
      case KitSideRowAction.remove:
        widget.onRemove(row);
      case null:
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.editable;
    return Semantics(
      button: true,
      label: '${row.title}, 쪽 ${row.page + 1}',
      selected: row.current,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onGo(row),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // `.r1row.mopen` comes after `.r1row.cur`
            color: _menuOpen
                ? KitTokens.sideRowMenuOpenBg
                : row.current
                ? KitTokens.sideRowCurrentBg
                : null,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: KitTokens.sideRowHeight,
                ),
                child: Padding(
                  // without a ⋯, as far from the right as from the left
                  padding: _rowPadding(
                    row,
                    menu
                        ? KitTokens.sideRowPadRight - kitSideMenuReach
                        : KitTokens.sideRowPadLeft,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: KitText(
                          row.title,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: row.current
                              ? _titleStyle.copyWith(
                                  fontWeight: FontWeight.w600,
                                )
                              : _titleStyle,
                        ),
                      ),
                      const SizedBox(width: KitTokens.sideRowGap),
                      KitText(
                        '${row.page + 1}',
                        maxLines: 1,
                        style: const TextStyle(
                          fontSize: KitTokens.sidePageFontSize,
                          height: KitTokens.sideLineHeight,
                          letterSpacing: 0,
                          color: KitTokens.sidePageInk,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      if (menu) ...[
                        const SizedBox(
                          width: KitTokens.sideRowGap - kitSideMenuReach,
                        ),
                        KitSideMoreButton(
                          buttonKey: const ValueKey('kit-outline-more'),
                          label: '${row.title} 메뉴',
                          open: _menuOpen,
                          onTap: _openMenu,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (row.current)
                const Positioned(
                  key: ValueKey('kit-outline-current'),
                  left: 0,
                  top: KitTokens.sideRowCurrentBarInset,
                  bottom: KitTokens.sideRowCurrentBarInset,
                  width: KitTokens.sideRowCurrentBar,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: KitTokens.accent,
                      borderRadius: BorderRadius.horizontal(
                        right: Radius.circular(KitTokens.sideRowCurrentBar),
                      ),
                    ),
                  ),
                ),
              ...kitSideMenuAnchors(_below, _above),
            ],
          ),
        ),
      ),
    );
  }
}

/// A line whose name is being changed: the name field (read out 「개요
/// 이름」) and 「완료」, in the line's room.
class _RenameRow extends StatelessWidget {
  const new({
    super.key,
    required this.row,
    required this.onEdit,
    required this.onDone,
  });

  final KitOutlineRow row;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onDone;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: KitTokens.sideRowHeight),
    child: Padding(
      padding: _rowPadding(row, KitTokens.sideRowPadRight),
      child: KitSideRenameField(
        title: row.title,
        label: '개요 이름',
        fieldKey: const ValueKey('kit-outline-rename'),
        style: _titleStyle,
        gap: KitTokens.sideRowGap,
        onEdit: onEdit,
        onDone: onDone,
      ),
    ),
  );
}
