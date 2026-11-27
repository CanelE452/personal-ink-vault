import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_pages.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/kit/kit_tokens.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the left panel (supplement Task 9) to
/// build/screen-review/supp-t9/app-supp-t9-*.png with the app's fonts at
/// device pixel ratio 2, on the 12th draft's page area (`#extras12`: 586 x
/// 734 on the tablet, 360 x 600 on the phone): the pages tab (page 2 of 5
/// on screen, pages 2 and 4 favourites, as the draft starts), the
/// favourites tab, and the empty favourites, outline and audio tabs. The
/// pages are drawn as the draft draws them (`inkBars`, 1 : 1.3), so the
/// picture compares with it; the app draws each page itself, at its own
/// shape. Runs only with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/supp-t9');
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
      File('$_outDir/app-supp-t9-$name.png')
          .writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

/// The draft's page sketch (`inkBars`): grey lines, a yellow one on even
/// pages.
Widget _inkBars(int n) {
  const widths = [
    [70, 52, 80, 40, 62],
    [60, 84, 46, 72, 30, 58],
    [88, 58, 70, 44],
    [50, 76, 64, 82, 44],
    [66, 40, 72],
  ];
  return LayoutBuilder(
    builder: (context, box) => Stack(
      children: [
        for (final (i, w) in widths[(n - 1) % 5].indexed)
          Positioned(
            left: box.maxWidth * .12,
            top:
                box.maxHeight * (14 + i * 12) / 100 -
                (i == 1 && n.isEven ? 2 : 0),
            width: box.maxWidth * w * .76 / 100,
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
}

void main() {
  const favourites = {1, 3};

  Future<GlobalKey> mount(
    WidgetTester tester, {
    required Size size,
    required KitSideTab tab,
    bool empty = false,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final phone = size.width < KitTokens.sidePanelPhoneBelow;
    final pages = [
      for (var i = 0; i < 5; i++)
        if (tab == KitSideTab.pages || favourites.contains(i))
          KitSidePage(
            index: i,
            aspectRatio: 1 / 1.3,
            favorite: favourites.contains(i),
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
                phone: phone,
                tabs: KitSideTab.values,
                tab: tab,
                onTab: (_) {},
                body: empty || tab.empty != null && pages.isEmpty
                    ? KitSideEmpty(tab)
                    : tab == KitSideTab.pages || tab == KitSideTab.favorites
                    ? KitSidePages(
                        pages: pages,
                        columns: phone
                            ? KitTokens.sideGridPhoneColumns
                            : KitTokens.sideGridColumns,
                        thumbnail: (i) => _inkBars(i + 1),
                        onPage: (_) {},
                      )
                    : KitSideEmpty(tab),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return boundary;
  }

  const tablet = Size(586, 734);
  const phone = Size(360, 600);

  group('side panel captures', skip: !_capture, () {
    for (final (name, size, tab, empty) in [
      ('pages', tablet, KitSideTab.pages, false),
      ('favorites', tablet, KitSideTab.favorites, false),
      ('favorites-empty', tablet, KitSideTab.favorites, true),
      ('outline-empty', tablet, KitSideTab.outline, true),
      ('audio-empty', tablet, KitSideTab.audio, true),
      ('phone-pages', phone, KitSideTab.pages, false),
      ('phone-audio-empty', phone, KitSideTab.audio, true),
    ]) {
      testWidgets(name, (tester) async {
        final boundary = await mount(
          tester,
          size: size,
          tab: tab,
          empty: empty,
        );
        if (empty && tab != KitSideTab.audio && size == tablet) {
          // as the draft breaks it: 「…를 누르면」, then 「여기에 모입니다.」
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byType(KitSideEmpty),
              matching: find.byType(RichText),
            ),
          );
          final text = paragraph.text.toPlainText();
          // the end of the first line (a 19.5 line: 5 is inside it)
          final end = paragraph
              .getPositionForOffset(Offset(paragraph.size.width, 5))
              .offset;
          expect(
            text.substring(0, end).replaceAll('\u2060', '').trim(),
            endsWith('누르면'),
          );
          // two lines (each rounded to whole pixels), not three
          expect(
            paragraph.size.height,
            lessThan(KitTokens.sideEmptyFontSize * 1.5 * 2.5),
          );
        }
        await _write(tester, boundary, name);
      });
    }
  });
}
