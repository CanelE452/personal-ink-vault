import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/side_panel/kit_page_menu.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_pages.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/kit/kit_tokens.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the 「쪽」 tab with its ribbons, ⋮ buttons, drag and
/// page menu (batch 234, Task 6) to build/screen-review/pm-t6/app-pm-t6-*.png
/// with the app's fonts at device pixel ratio 2, on the same page areas as
/// the supp-t9 captures (586 x 734 tablet, 360 x 600 phone). Runs only with
/// PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/pm-t6');
const _paper = Color(0xfffbf8ef); // `--paper`

Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  debugDisableShadows = false;
  try {
    void mark(RenderObject o) {
      o.markNeedsPaint();
      o.visitChildren(mark);
    }

    mark(boundary.currentContext!.findRenderObject()!);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final object =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await object.toImage(pixelRatio: 2);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/app-pm-t6-$name.png')
          .writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

/// Grey lines on a page, a yellow one on even pages (as supp-t9's `inkBars`).
Widget _inkBars(int n) => LayoutBuilder(
  builder: (context, box) => Stack(
    children: [
      for (var i = 0; i < 5; i++)
        Positioned(
          left: box.maxWidth * .12,
          top: box.maxHeight * (14 + i * 12) / 100,
          width: box.maxWidth * (40 + (n * 13 + i * 17) % 45) * .76 / 100,
          height: i == 1 && n.isEven ? 6 : 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: i == 1 && n.isEven
                  ? const Color(0xffffe066).withValues(alpha: .7)
                  : const Color(0xff7d8698).withValues(alpha: .55),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
    ],
  ),
);

void main() {
  const tablet = Size(586, 734);
  const phone = Size(360, 600);

  Future<GlobalKey> mount(
    WidgetTester tester, {
    required Size size,
    required int count,
    bool landscape = false,
    bool canEdit = true,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final isPhone = size.width < KitTokens.sidePanelPhoneBelow;
    final pages = [
      for (var i = 0; i < count; i++)
        KitSidePage(
          index: i,
          aspectRatio: landscape && i == 2 ? 1.3 : 1 / 1.3,
          favorite: i == 2,
          current: i == 1,
        ),
    ];
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MediaQuery(
          data: MediaQueryData(size: size, devicePixelRatio: 2),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: captureLatin,
              fontFamilyFallback: const [captureKorean],
            ),
            home: Material(
              color: _paper,
              child: KitSidePanel(
                open: true,
                phone: isPhone,
                tabs: KitSideTab.values,
                tab: KitSideTab.pages,
                onTab: (_) {},
                body: Builder(
                  builder: (context) => KitSidePages(
                    pages: pages,
                    columns: isPhone
                        ? KitTokens.sideGridPhoneColumns
                        : KitTokens.sideGridColumns,
                    thumbnail: (i) => _inkBars(i + 1),
                    onPage: (_) {},
                    onMove: (_, _) {},
                    onFavorite: (_) {},
                    showRibbon: true,
                    onMenu: (button, i) => showKitPageMenu(
                      button,
                      canEdit: canEdit,
                      canPaste: true,
                      canDelete: true,
                      canClear: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return boundary;
  }

  Future<void> openMenu(WidgetTester tester, int page) async {
    await tester.tap(find.byKey(ValueKey('kit-side-page-$page-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('kit-page-menu-복사')), findsOneWidget);
  }

  group('page menu captures', skip: !_capture, () {
    for (final (name, size) in [('tablet', tablet), ('phone', phone)]) {
      testWidgets('$name pages', (tester) async {
        final boundary = await mount(tester, size: size, count: 6);
        expect(find.byKey(const ValueKey('kit-side-page-0-menu')), findsOne);
        expect(find.byKey(const ValueKey('kit-side-page-2-ribbon')), findsOne);
        await _write(tester, boundary, '$name-pages');
      });
    }

    testWidgets('tablet drag', (tester) async {
      final boundary = await mount(
        tester,
        size: tablet,
        count: 6,
        landscape: true,
      );
      final from = tester.getCenter(
        find.byKey(const ValueKey('kit-side-page-0')),
      );
      final to = tester.getCenter(
        find.byKey(const ValueKey('kit-side-page-3')),
      );
      final gesture = await tester.startGesture(from);
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveTo(from + const Offset(20, 20));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(to);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 600));
      await _write(tester, boundary, 'tablet-drag');
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('tablet menu editable', (tester) async {
      final boundary = await mount(tester, size: tablet, count: 6);
      await openMenu(tester, 1);
      await _write(tester, boundary, 'tablet-menu-edit');
    });

    testWidgets('tablet menu read-only', (tester) async {
      final boundary = await mount(
        tester,
        size: tablet,
        count: 6,
        canEdit: false,
      );
      await openMenu(tester, 1);
      await _write(tester, boundary, 'tablet-menu-readonly');
    });

    testWidgets('phone menu near the bottom', (tester) async {
      final boundary = await mount(tester, size: phone, count: 9);
      await openMenu(tester, 7);
      await _write(tester, boundary, 'phone-menu-up');
    });
  });
}
