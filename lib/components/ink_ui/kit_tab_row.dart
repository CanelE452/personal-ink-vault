import 'dart:async';

import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/ink_ui/floating_bar/floating_bar_parts.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// One tab of [KitTabRow].
@immutable
class KitTab {
  const new({required this.id, required this.title, this.editing = false});

  final String id;
  final String title;

  /// Its Office·한글 editor is open: 「편집 중」 before the name.
  final bool editing;
}

/// The tab row over an open document (9th draft c `#c9tabs`, design 「탭
/// 줄」): home · the tabs · +. The open tab has a ⌄ with the document's
/// state and 이름 변경 (design 「탭 줄의 ⌄」); each tab has × and, held,
/// 229's menu (닫기, 다른 탭 닫기). The tabs share the row up to 190 each,
/// but never narrower than their name: on a phone the row slides instead
/// (the user's phone rule, 「자리가 없으면 숨기지 말고 밀기」), and the open
/// tab slides into view, the ends the tabs run past faded as the floating
/// bar's sliding tools. [trailing] (229's list of the open tabs) sits at
/// the right end.
class KitTabRow extends StatefulWidget {
  const new({
    super.key,
    required this.tabs,
    required this.activeId,
    this.fallbackTitle,
    required this.onHome,
    required this.onSelect,
    required this.onClose,
    required this.onCloseOthers,
    required this.onNewTab,
    required this.docInfo,
    required this.onRename,
    this.trailing,
  });

  final List<KitTab> tabs;
  final String? activeId;

  /// The name shown alone while there are no tabs.
  final String? fallbackTitle;

  /// Back to the library; null while it cannot go.
  final VoidCallback? onHome;

  /// Null while the tabs take no taps (busy).
  final ValueChanged<String>? onSelect;
  final ValueChanged<String>? onClose;

  /// 다른 탭 닫기: keeps the given tab; null with a single tab.
  final ValueChanged<String>? onCloseOthers;

  /// +: opens another document in a new tab.
  final VoidCallback? onNewTab;

  /// What ⌄ shows of the open document, read as it opens (⋯ 「문서 정보」's
  /// values).
  final DocInfo Function() docInfo;
  final VoidCallback? onRename;
  final Widget? trailing;

  @override
  State<KitTabRow> createState() => _KitTabRowState();
}

class _KitTabRowState extends State<KitTabRow> {
  final _infoAnchor = GlobalKey();
  final _tabAnchors = <String, GlobalKey>{};

  /// Each tab, to slide the open one into view.
  final _tabKeys = <String, GlobalKey>{};

  /// Which ends of the row the tabs run past.
  final _past = ValueNotifier((start: false, end: false));

  /// The sliding tabs, kept (with where they slid to) when the fade comes
  /// or goes around them.
  final _strip = GlobalKey();

  @override
  void initState() {
    super.initState();
    _showOpenTab();
  }

  @override
  void dispose() {
    _past.dispose();
    super.dispose();
  }

  bool _slid(ScrollMetrics m) {
    final past = (
      start: m.pixels > m.minScrollExtent + 1,
      end: m.pixels < m.maxScrollExtent - 1,
    );
    if (_past.value != past) _past.value = past;
    return false;
  }

  @override
  void didUpdateWidget(KitTabRow old) {
    super.didUpdateWidget(old);
    if (old.activeId != widget.activeId || old.tabs.length != widget.tabs.length) {
      _showOpenTab();
    }
  }

  /// After the frame, slides the row just enough for the open tab to show.
  void _showOpenTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final tab = _tabKeys[widget.activeId]?.currentContext;
      if (!mounted || tab == null) return;
      for (final policy in const [
        ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      ]) {
        unawaited(Scrollable.ensureVisible(tab, alignmentPolicy: policy));
      }
    });
  }

  /// The name's style; no letter spacing (the theme's body text has .25,
  /// which made the open tab's name 2 wider than the preview's).
  TextStyle _titleStyle(bool on) => TextStyle(
    fontSize: KitTokens.tabFontSize,
    fontWeight: on ? FontWeight.w600 : FontWeight.w400,
    letterSpacing: 0,
    color: KitTokens.toolbarOnBar,
  );

  /// How wide [tab] is with its whole name: the padding, 편집 중, the name,
  /// ⌄ on the open one and ×.
  double _fullWidth(KitTab tab, bool on) {
    final name = TextPainter(
      text: TextSpan(
        text: tab.title,
        style: DefaultTextStyle.of(context).style.merge(_titleStyle(on)),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final title = name.width.ceilToDouble();
    name.dispose();
    return KitTokens.tabPaddingH +
        (tab.editing ? KitTokens.tabIconSize + KitTokens.tabGap : 0) +
        title +
        (on ? KitTokens.tabHit : 0) +
        KitTokens.tabHit;
  }

  /// The ⌄ window is open.
  var _infoOpen = false;

  static const _endWidth =
      KitTokens.tabEndIconSize + 2 * KitTokens.tabEndPaddingH;

  RenderBox? get _screen =>
      Navigator.of(context).context.findRenderObject() as RenderBox?;

  Future<void> _openInfo() async {
    setState(() => _infoOpen = true);
    await showKitMenu(
      context: context,
      anchor: _infoAnchor,
      within: _screen,
      builder: _infoMenu,
    );
    if (mounted) setState(() => _infoOpen = false);
  }

  /// 마지막 편집 · 동기화 상태 · 오프라인용으로 저장 · 이름 변경, worded
  /// as ⋯ 「문서 정보」 (「알 수 없음」, synced in green).
  KitMenu _infoMenu() {
    final info = widget.docInfo();
    final edited = info.lastEdited;
    final rename = widget.onRename;
    return KitMenu(
      width: KitTokens.tabMenuWidth,
      window: true,
      groups: [
        KitMenuGroup(
          rows: [
            KitMenuRow.info(
              key: const ValueKey('document-tab-info-edited'),
              icon: KitIconName.clock,
              label: '마지막 편집',
              value: edited == null
                  ? '알 수 없음'
                  : docInfoAgo(edited, DateTime.now()),
            ),
            KitMenuRow.info(
              key: const ValueKey('document-tab-info-sync'),
              icon: KitIconName.cloudDone,
              label: '동기화 상태',
              value: info.syncLabel,
              valueColor: info.synced ? KitTokens.ok : null,
            ),
            // the note is kept on this device; the row only closes
            KitMenuRow.action(
              key: const ValueKey('document-tab-info-offline'),
              icon: KitIconName.offlinePin,
              label: '오프라인용으로 저장',
              value: info.offlineLabel,
              onTap: () => closeMenuThen(context, () {}),
            ),
          ],
        ),
        KitMenuGroup(
          rows: [
            KitMenuRow.action(
              key: const ValueKey('document-tab-info-rename'),
              icon: KitIconName.rename,
              label: '이름 변경',
              enabled: rename != null,
              onTap: () => closeMenuThen(context, rename ?? () {}),
            ),
          ],
        ),
      ],
    );
  }

  /// 229's menu of a held tab, under it.
  void _openTabMenu(String id) {
    final anchor = _tabAnchors[id];
    if (anchor == null) return;
    final close = widget.onClose;
    final closeOthers = widget.onCloseOthers;
    unawaited(
      showKitMenu(
        context: context,
        anchor: anchor,
        within: _screen,
        menu: KitMenu(
          width: KitTokens.tabMenuWidth,
          window: true,
          groups: [
            KitMenuGroup(
              rows: [
                KitMenuRow.action(
                  key: const ValueKey('document-tab-menu-close'),
                  label: '닫기',
                  enabled: close != null,
                  onTap: () => closeMenuThen(context, () => close?.call(id)),
                ),
                KitMenuRow.action(
                  key: const ValueKey('document-tab-menu-close-others'),
                  label: '다른 탭 닫기',
                  enabled: closeOthers != null && widget.tabs.length > 1,
                  onTap: () =>
                      closeMenuThen(context, () => closeOthers?.call(id)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Home and + (`.tabs>span`): the plain 22 icon at .9, 6 each side, the
  /// row's height to tap. An [IconButton], as the 229 back button was
  /// (callers read whether it is on).
  Widget _end({
    required Key key,
    required KitIconName icon,
    required String tooltip,
    required VoidCallback? onTap,
  }) => IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onTap,
    style: IconButton.styleFrom(
      fixedSize: const Size(_endWidth, KitTokens.tabRowHeight),
      minimumSize: const Size(_endWidth, KitTokens.tabRowHeight),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const RoundedRectangleBorder(),
    ),
    icon: Opacity(
      opacity:
          KitTokens.tabEndOpacity *
          (onTap == null ? KitTokens.disabledOpacity : 1),
      child: KitIcon(
        icon,
        size: KitTokens.tabEndIconSize,
        strokeWidth: KitTokens.tabEndIconStroke,
        color: KitTokens.toolbarOnBar,
      ),
    ),
  );

  Widget _tabIcon(KitIconName icon) => KitIcon(
    icon,
    size: KitTokens.tabIconSize,
    strokeWidth: KitTokens.tabIconStroke,
    color: KitTokens.toolbarOnBar,
  );

  /// The open tab's ⌄ (`.tcv`), 6 after the name, its window 4 under it at
  /// its left; pressed over [KitTokens.tabHit] from the name's end.
  Widget _infoButton() => Semantics(
    button: true,
    label: '이 문서 메뉴',
    onTap: _openInfo,
    excludeSemantics: true,
    child: GestureDetector(
      key: const ValueKey('document-tab-info'),
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: () => unawaited(_openInfo()),
      child: SizedBox(
        width: KitTokens.tabHit,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: KitTokens.tabGap),
            child: Stack(
            clipBehavior: Clip.none,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: _infoOpen ? KitTokens.tabMenuOpenFill : null,
                  borderRadius: BorderRadius.circular(KitTokens.tabMenuRadius),
                ),
                child: _tabIcon(KitIconName.chev),
              ),
              Positioned(
                left: 0,
                top: KitTokens.tabIconSize + KitTokens.tabMenuGap,
                width: 0,
                height: 0,
                child: SizedBox(key: _infoAnchor),
              ),
            ],
          ),
          ),
        ),
      ),
    ),
  );

  Widget _tab(KitTab tab, double width) {
    final on = tab.id == widget.activeId;
    final select = widget.onSelect;
    final close = widget.onClose;
    final anchor = _tabAnchors.putIfAbsent(tab.id, GlobalKey.new);
    final style = _titleStyle(on);
    final body = Row(
      children: [
        if (tab.editing) ...[
          Tooltip(
            message: '편집 중',
            child: KitIcon(
              KitIconName.edit,
              key: ValueKey('document-tab-editing-${tab.id}'),
              size: KitTokens.tabIconSize,
              strokeWidth: KitTokens.tabIconStroke,
              color: KitTokens.toolbarOnBar,
            ),
          ),
          const SizedBox(width: KitTokens.tabGap),
        ],
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  tab.title,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
              if (on) _infoButton(),
            ],
          ),
        ),
        // × 10 inside the tab's end, pressed over [KitTokens.tabHit] (the
        // padding after it and the gap before it)
        Semantics(
          button: true,
          enabled: close != null,
          label: '${tab.title} 탭 닫기',
          onTap: close == null ? null : () => close(tab.id),
          excludeSemantics: true,
          child: Tooltip(
            message: '${tab.title} 탭 닫기',
            child: GestureDetector(
              key: ValueKey('document-tab-close-${tab.id}'),
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: close == null ? null : () => close(tab.id),
              child: SizedBox(
                width: KitTokens.tabHit,
                child: Align(
                  child: Opacity(
                    opacity: KitTokens.tabCloseOpacity,
                    child: _tabIcon(KitIconName.close),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return Padding(
      key: _tabKeys.putIfAbsent(tab.id, GlobalKey.new),
      padding: const EdgeInsets.only(top: KitTokens.tabTop),
      child: SizedBox(
        width: width,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Opacity(
                opacity: on ? 1 : KitTokens.tabIdleOpacity,
                child: Material(
                  color: on ? KitTokens.tabOnFill : Colors.transparent,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(KitTokens.tabRadius),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Semantics(
                    selected: on,
                    child: InkWell(
                      key: ValueKey('document-tab-${tab.id}'),
                      onTap: select == null ? null : () => select(tab.id),
                      onLongPress: select == null
                          ? null
                          : () => _openTabMenu(tab.id),
                      child: Padding(
                        padding: const EdgeInsets.only(
                          left: KitTokens.tabPaddingH,
                        ),
                        child: body,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 229's menu opens under the held tab
            Positioned(
              left: 0,
              bottom: 0,
              width: 0,
              height: 0,
              child: SizedBox(key: anchor),
            ),
          ],
        ),
      ),
    );
  }

  /// [strip] faded at the ends the tabs run past.
  Widget _fading(Widget strip) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) => _slid(n.metrics),
        child: NotificationListener<ScrollUpdateNotification>(
          onNotification: (n) => _slid(n.metrics),
          child: ValueListenableBuilder(
            valueListenable: _past,
            builder: (context, past, child) => FloatingBarEdgeFade(
              axis: Axis.horizontal,
              start: past.start,
              end: past.end,
              child: child!,
            ),
            child: strip,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    _tabAnchors.removeWhere((id, _) => !tabs.any((tab) => tab.id == id));
    _tabKeys.removeWhere((id, _) => !tabs.any((tab) => tab.id == id));
    final fallback = widget.fallbackTitle;
    return SizedBox(
      height: KitTokens.tabRowHeight,
      child: ColoredBox(
        color: KitTokens.tabRowBg,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KitTokens.tabRowPadding,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _end(
                key: const ValueKey('workspace-back-to-library'),
                icon: KitIconName.home,
                tooltip: '문서 목록으로',
                onTap: widget.onHome,
              ),
              const SizedBox(width: KitTokens.tabRowGap),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    // each tab an equal share up to 190 (`flex:1`), but
                    // not under its whole name: then the row slides
                    final room =
                        box.maxWidth -
                        _endWidth -
                        KitTokens.tabRowGap * tabs.length;
                    final share = tabs.isEmpty ? 0.0 : room / tabs.length;
                    double width(KitTab tab) {
                      final full = _fullWidth(tab, tab.id == widget.activeId);
                      final wide = share > full ? share : full;
                      return wide > KitTokens.tabMaxWidth
                          ? KitTokens.tabMaxWidth
                          : wide;
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Flexible(
                          child: tabs.isEmpty && fallback != null
                              ? Align(
                                  alignment: Alignment.centerLeft,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: KitTokens.tabPaddingH,
                                    ),
                                    child: Text(
                                      fallback,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: _titleStyle(true),
                                    ),
                                  ),
                                )
                              : _fading(
                                  SingleChildScrollView(
                                    key: _strip,
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      spacing: KitTokens.tabRowGap,
                                      children: [
                                        for (final tab in tabs)
                                          _tab(tab, width(tab)),
                                      ],
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(width: KitTokens.tabRowGap),
                        _end(
                          key: const ValueKey('workspace-new-tab'),
                          icon: KitIconName.plus,
                          tooltip: '새 탭',
                          onTap: widget.onNewTab,
                        ),
                      ],
                    );
                  },
                ),
              ),
              ?widget.trailing,
            ],
          ),
        ),
      ),
    );
  }
}
