import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/ink_ui/side_panel/outline_tab.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_undo_notice.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the left panel's outline tab (supplement Task 10)
/// to build/screen-review/supp-t10/app-supp-t10-*.png with the app's fonts
/// at device pixel ratio 2, on the 12th draft's page area (`#extras12`: 586
/// x 734 on the tablet, 360 x 600 on the phone), with the draft's outline
/// (`OUT0`) and page 2 on screen: the PDF's outline with the user's own,
/// the empty tab, the empty tab of a note that cannot change, the phone, a
/// name being changed (`rename`), a line's menu
/// (`outmenu`) and the undo notice after 「다시 볼 식」 is removed. Runs only
/// with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/supp-t10');
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
      File('$_outDir/app-supp-t10-$name.png')
          .writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

void main() {
  // `OUT0`, page 2 (index 1) on screen: 「2. 방법」 and 「다시 볼 식」 lit
  const pdf = [
    KitOutlineRow(id: 'o1', title: '1. 들어가며', page: 0),
    KitOutlineRow(id: 'o2', title: '2. 방법', page: 1, current: true),
    KitOutlineRow(id: 'o3', title: '2.1 자료 모으기', page: 2, depth: 1),
    KitOutlineRow(id: 'o4', title: '2.2 실험 순서', page: 2, depth: 1),
    KitOutlineRow(id: 'o5', title: '3. 결과', page: 3),
  ];
  const mine = [
    KitOutlineRow(id: 'o6', title: '다시 볼 식', page: 1, current: true),
    KitOutlineRow(id: 'o7', title: '질문 모음', page: 4),
  ];

  Future<(GlobalKey, KitUndoNoticeController)> mount(
    WidgetTester tester, {
    required Size size,
    bool empty = false,
    String? renaming,
    bool removed = false,
    bool editable = true,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notice = KitUndoNoticeController();
    addTearDown(notice.dispose);
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
              child: Stack(
                children: [
                  Positioned.fill(
                    child: KitSidePanel(
                      open: true,
                      phone: size.width < KitTokens.sidePanelPhoneBelow,
                      tabs: KitSideTab.values,
                      tab: KitSideTab.outline,
                      onTab: (_) {},
                      body: KitSideOutline(
                        pdf: empty ? const [] : pdf,
                        mine: empty
                            ? const []
                            : [
                                for (final row in mine)
                                  if (!removed || row.id != 'o6') row,
                              ],
                        editable: editable,
                        renaming: renaming,
                        onGo: (_) {},
                        onRenameStart: (_) {},
                        onRenameEdit: (_, _) {},
                        onRename: (_, _) {},
                        onRemove: (_) {},
                      ),
                    ),
                  ),
                  Positioned.fill(child: KitUndoNotice(controller: notice)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (boundary, notice);
  }

  const tablet = Size(586, 734);
  const phone = Size(360, 600);

  group('outline tab captures', skip: !_capture, () {
    testWidgets('outline', (tester) async {
      final (boundary, _) = await mount(tester, size: tablet);
      await _write(tester, boundary, 'outline');
    });
    testWidgets('outline-empty', (tester) async {
      final (boundary, _) = await mount(tester, size: tablet, empty: true);
      await _write(tester, boundary, 'outline-empty');
    });
    // a note whose outline cannot change, with none (fix round 1, C6)
    testWidgets('outline-none', (tester) async {
      final (boundary, _) = await mount(
        tester,
        size: tablet,
        empty: true,
        editable: false,
      );
      await _write(tester, boundary, 'outline-none');
    });
    testWidgets('phone-outline', (tester) async {
      final (boundary, _) = await mount(tester, size: phone);
      await _write(tester, boundary, 'phone-outline');
    });
    testWidgets('outline-rename', (tester) async {
      final (boundary, _) = await mount(tester, size: tablet, renaming: 'o6');
      await _write(tester, boundary, 'outline-rename');
    });
    testWidgets('outline-menu', (tester) async {
      final (boundary, _) = await mount(tester, size: tablet);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('kit-outline-row-o6')),
          matching: find.byKey(const ValueKey('kit-outline-more')),
        ),
      );
      await tester.pumpAndSettle();
      await _write(tester, boundary, 'outline-menu');
    });
    testWidgets('outline-undo', (tester) async {
      final (boundary, notice) = await mount(
        tester,
        size: tablet,
        removed: true,
      );
      notice.show(KitTokens.removedNotice('다시 볼 식'), onAction: () {});
      await tester.pump();
      await tester.pump(KitMotion.undoNoticeIn);
      await _write(tester, boundary, 'outline-undo');
    });
  });
}
