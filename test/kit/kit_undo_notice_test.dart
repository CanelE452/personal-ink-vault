import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_undo_notice.dart';

/// The undo notice the left panel's outline (supplement Task 10), the
/// recordings (Task 11) and the page insert (Task 14) share: the 12th
/// draft's `.r1toast`.
void main() {
  final notice = find.byKey(const ValueKey('kit-undo-notice'));

  Future<KitUndoNoticeController> mount(
    WidgetTester tester, {
    Size size = const Size(586, 734),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = KitUndoNoticeController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          home: Material(
            child: Stack(
              children: [
                Positioned.fill(child: KitUndoNotice(controller: controller)),
              ],
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('shows its line and 실행 취소; a press undoes once and hides', (
    tester,
  ) async {
    final controller = await mount(tester);
    expect(notice, findsNothing);
    var undone = 0;
    controller.show('지웠습니다 · 다시 볼 식', onAction: () => undone++);
    await tester.pump();
    await tester.pump(KitMotion.undoNoticeIn);
    expect(notice, findsOneWidget);
    expect(find.text('지웠습니다 · 다시 볼 식'), findsOneWidget);
    expect(find.text(KitTokens.undoNoticeAction), findsOneWidget);
    expect(KitTokens.undoNoticeAction, '실행 취소');

    await tester.tap(find.text(KitTokens.undoNoticeAction));
    await tester.pump();
    expect(undone, 1);
    // an animation is over only past its time
    await tester.pump(
      KitMotion.undoNoticeOut + const Duration(milliseconds: 1),
    );
    await tester.pump();
    expect(notice, findsNothing);
    // gone, a second press cannot undo again
    expect(undone, 1);
  });

  testWidgets('goes by itself: 4 s with an action, 2 s without', (
    tester,
  ) async {
    final controller = await mount(tester);
    controller.show('지웠습니다 · A', onAction: () {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3990));
    expect(notice, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 20));
    // an animation is over only past its time
    await tester.pump(
      KitMotion.undoNoticeOut + const Duration(milliseconds: 1),
    );
    await tester.pump();
    expect(notice, findsNothing);
    expect(KitMotion.undoNoticeShow, const Duration(seconds: 4));

    controller.show('저장했습니다');
    await tester.pump();
    expect(find.text(KitTokens.undoNoticeAction), findsNothing);
    await tester.pump(const Duration(milliseconds: 1990));
    expect(notice, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 20));
    // an animation is over only past its time
    await tester.pump(
      KitMotion.undoNoticeOut + const Duration(milliseconds: 1),
    );
    await tester.pump();
    expect(notice, findsNothing);
    expect(KitMotion.undoNoticeShowSolo, const Duration(seconds: 2));
  });

  testWidgets('a new notice takes the place of the last and its time', (
    tester,
  ) async {
    final controller = await mount(tester);
    var first = 0;
    var second = 0;
    controller.show('지웠습니다 · A', onAction: () => first++);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    controller.show('지웠습니다 · B', onAction: () => second++);
    await tester.pump();
    expect(find.text('지웠습니다 · A'), findsNothing);
    expect(find.text('지웠습니다 · B'), findsOneWidget);
    // the first one's 4 s are over; the second keeps its own
    await tester.pump(const Duration(seconds: 2));
    expect(notice, findsOneWidget);
    await tester.tap(find.text(KitTokens.undoNoticeAction));
    await tester.pump();
    expect((first, second), (0, 1));
  });

  testWidgets('onEnd: once when it goes unpressed, not when undone', (
    tester,
  ) async {
    final controller = await mount(tester);
    final heard = <String>[];
    void say(String name) => controller.show(
      name,
      onAction: () => heard.add('undo $name'),
      onEnd: () => heard.add('end $name'),
    );

    // by itself
    say('a');
    await tester.pump();
    await tester.pump(KitMotion.undoNoticeShow);
    expect(heard, ['end a']);
    // another takes its place: it ends after the new one is shown
    say('b');
    await tester.pump();
    say('c');
    expect(heard, ['end a', 'end b']);
    expect(controller.notice?.text, 'c');
    // hidden
    controller.hide();
    expect(heard, ['end a', 'end b', 'end c']);
    // undone: the action, not the end
    say('d');
    await tester.pump();
    await tester.pump(KitMotion.undoNoticeIn);
    await tester.tap(find.text(KitTokens.undoNoticeAction));
    await tester.pump();
    expect(heard, ['end a', 'end b', 'end c', 'undo d']);
    controller.hide();
    await tester.pump(KitMotion.undoNoticeShow);
    expect(heard, ['end a', 'end b', 'end c', 'undo d']);
    await tester.pumpAndSettle();
  });

  testWidgets('stands 78 above the page foot in the middle, as drawn', (
    tester,
  ) async {
    const size = Size(586, 734);
    final controller = await mount(tester, size: size);
    controller.show('지웠습니다 · 다시 볼 식', onAction: () {});
    await tester.pump();
    await tester.pump(KitMotion.undoNoticeIn);
    final box = tester.getRect(notice);
    expect(box.height, KitTokens.undoNoticeHeight);
    expect(KitTokens.undoNoticeHeight, 40);
    expect(box.bottom, size.height - KitTokens.undoNoticeBottom);
    expect(KitTokens.undoNoticeBottom, 78);
    expect(box.center.dx, closeTo(size.width / 2, 0.01));
    final pill = tester.widget<DecoratedBox>(
      find.descendant(of: notice, matching: find.byType(DecoratedBox)).first,
    );
    final decoration = pill.decoration as BoxDecoration;
    expect(decoration.color, const Color.fromRGBO(32, 34, 38, .9));
    expect(
      decoration.borderRadius,
      BorderRadius.circular(KitTokens.undoNoticeRadius),
    );
    final line = tester.widget<Text>(find.text('지웠습니다 · 다시 볼 식'));
    expect(line.style?.fontSize, 13);
    expect(line.style?.fontWeight, FontWeight.w600);
    expect(line.style?.color, const Color(0xffffffff));
    final action = tester.widget<Text>(find.text(KitTokens.undoNoticeAction));
    expect(action.style?.color, const Color(0xff9cc0ff));
    // the action's box: 32 high
    expect(
      tester
          .getSize(find.byKey(const ValueKey('kit-undo-notice-action')))
          .height,
      KitTokens.undoNoticeActionHeight,
    );
    expect(KitTokens.undoNoticeActionHeight, 32);
  });

  testWidgets('on a phone a long line stays 12 inside each side', (
    tester,
  ) async {
    const size = Size(360, 600);
    final controller = await mount(tester, size: size);
    controller.show('지웠습니다 · ${'아주 긴 개요 이름 ' * 6}', onAction: () {});
    await tester.pump();
    await tester.pump(KitMotion.undoNoticeIn);
    final box = tester.getRect(notice);
    expect(box.left, greaterThanOrEqualTo(12));
    expect(box.right, lessThanOrEqualTo(size.width - 12));
    expect(tester.takeException(), isNull);
  });
}
