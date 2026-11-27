import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// One page in the left panel's grid: its place in the note, its width over
/// its height, and whether it is a favourite or the page on screen.
class KitSidePage {
  const new({
    required this.index,
    required this.aspectRatio,
    this.favorite = false,
    this.current = false,
  });

  final int index;
  final double aspectRatio;
  final bool favorite;
  final bool current;
}

/// `.r1grid`: [pages] in rows of [columns] (2, a phone's 3), each a picture
/// drawn by [thumbnail] over its number. The page on screen has the accent
/// ring and number, a favourite a ribbon at its top right. A press calls
/// [onPage] with the page's index, a long press [onManage]. It scrolls.
class KitSidePages extends StatelessWidget {
  const new({
    super.key,
    required this.pages,
    required this.columns,
    required this.thumbnail,
    required this.onPage,
    this.onManage,
  });

  final List<KitSidePage> pages;
  final int columns;
  final Widget Function(int index) thumbnail;
  final ValueChanged<int> onPage;
  final ValueChanged<int>? onManage;

  @override
  Widget build(BuildContext context) {
    final rows = (pages.length / columns).ceil();
    return ListView.separated(
      padding: KitTokens.sideGridPadding,
      itemCount: rows,
      separatorBuilder: (_, _) => const SizedBox(height: KitTokens.sideGridGap),
      itemBuilder: (context, row) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var column = 0; column < columns; column++) ...[
            if (column > 0) const SizedBox(width: KitTokens.sideGridGap),
            Expanded(
              child: switch (row * columns + column) {
                final i when i < pages.length => _Page(
                  page: pages[i],
                  thumbnail: thumbnail,
                  onPage: onPage,
                  onManage: onManage,
                ),
                _ => const SizedBox.shrink(),
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const new({
    required this.page,
    required this.thumbnail,
    required this.onPage,
    required this.onManage,
  });

  final KitSidePage page;
  final Widget Function(int index) thumbnail;
  final ValueChanged<int> onPage;
  final ValueChanged<int>? onManage;

  @override
  Widget build(BuildContext context) {
    final i = page.index;
    const radius = BorderRadius.all(Radius.circular(KitTokens.sideThumbRadius));
    return Semantics(
      button: true,
      label: [
        '쪽 ${i + 1}',
        if (page.favorite) '즐겨찾기',
        if (page.current) '지금 쪽',
      ].join(', '),
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('kit-side-page-$i'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onPage(i),
        onLongPress: onManage == null ? null : () => onManage!(i),
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: page.aspectRatio,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      key: ValueKey('kit-side-page-$i-picture'),
                      decoration: BoxDecoration(
                        color: KitTokens.sideThumbBg,
                        borderRadius: radius,
                        boxShadow: page.current
                            ? KitTokens.sideThumbOnShadow
                            : KitTokens.sideThumbShadow,
                      ),
                      child: ClipRRect(
                        borderRadius: radius,
                        child: IgnorePointer(child: thumbnail(i)),
                      ),
                    ),
                  ),
                  if (page.favorite)
                    Positioned(
                      right: KitTokens.sideRibbonRight,
                      top: KitTokens.sideRibbonTop,
                      child: ClipPath(
                        clipper: const _Ribbon(),
                        child: SizedBox(
                          key: ValueKey('kit-side-page-$i-ribbon'),
                          width: KitTokens.sideRibbonWidth,
                          height: KitTokens.sideRibbonHeight,
                          child: const ColoredBox(color: KitTokens.accent),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: KitTokens.sideThumbGap),
            KitText(
              '${i + 1}',
              maxLines: 1,
              style: TextStyle(
                fontSize: KitTokens.sideThumbFontSize,
                height: KitTokens.sideLineHeight,
                letterSpacing: 0,
                color: page.current
                    ? KitTokens.sideThumbOnInk
                    : KitTokens.sideThumbInk,
                fontWeight: page.current ? FontWeight.w600 : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The ribbon's cut foot: `polygon(0 0,100% 0,100% 100%,50% 70%,0 100%)`.
class _Ribbon extends CustomClipper<Path> {
  const new();

  @override
  Path getClip(Size size) => Path()
    ..moveTo(0, 0)
    ..lineTo(size.width, 0)
    ..lineTo(size.width, size.height)
    ..lineTo(size.width / 2, size.height * KitTokens.sideRibbonNotch)
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(_Ribbon old) => false;
}
