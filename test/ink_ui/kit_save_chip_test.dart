import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_save_chip.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/editor/saving_state.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';

import '../utils/shown.dart';

/// The page area of the preview (586 × 734 under the toolbar).
const _page = Size(586, 734);

class _Chip {
  final state = ValueNotifier(SavingState.saved);
  final strokeAt = ValueNotifier<Offset?>(null);
  final actions = AppActionRegistry();
  var saves = 0;
  var canvasTaps = 0;

  void publishSave() => actions.publish(this, [
    AppAction(
      id: AppActionIds.save,
      label: '기기에 저장',
      icon: KitIconName.download,
      run: (_) => saves++,
    ),
  ]);
}

Future<_Chip> _pump(WidgetTester tester, {bool withSave = true}) async {
  tester.view.physicalSize = _page;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final delay = stows.autosaveDelay.value;
  addTearDown(() => stows.autosaveDelay.value = delay);
  final chip = _Chip();
  addTearDown(chip.state.dispose);
  addTearDown(chip.strokeAt.dispose);
  addTearDown(chip.actions.dispose);
  if (withSave) chip.publishSave();
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: _page),
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => chip.canvasTaps++,
                ),
              ),
              Positioned.fill(
                child: KitSaveChip(
                  state: chip.state,
                  actions: chip.actions,
                  strokeAt: chip.strokeAt,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return chip;
}

final _box = find.byKey(const ValueKey('kit-save-chip'));

/// The chip's words now, null when it is not there.
String? _says(WidgetTester tester) {
  if (_box.evaluate().isEmpty) return null;
  return tester
      .widgetList<Text>(find.descendant(of: _box, matching: find.byType(Text)))
      .map((t) => t.data)
      .join();
}

double _shown(WidgetTester tester) => shownOf(tester, _box);

bool _takesPresses(WidgetTester tester) => takesPresses(tester, _box);

void main() {
  setUp(FlavorConfig.setup);

  testWidgets('save chip follows the saving state', (tester) async {
    final chip = await _pump(tester);
    stows.autosaveDelay.value = 10000;

    // auto save on: waiting shows nothing, even past the auto save time
    chip.state.value = SavingState.waitingToSave;
    await tester.pump(const Duration(seconds: 12));
    expect(_says(tester), isNull);

    // a save that takes more than a second
    chip.state.value = SavingState.saving;
    await tester.pump(const Duration(milliseconds: 999));
    expect(_says(tester), isNull);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 180));
    expect(_says(tester), '저장 중…');
    expect(_shown(tester), 1);
    expect(
      find.descendant(
        of: _box,
        matching: find.byKey(const ValueKey('save-chip-spin')),
      ),
      findsOneWidget,
    );
    await tester.tap(_box);
    expect(chip.saves, 0, reason: 'saving cannot be pressed');

    // saved: it goes
    chip.state.value = SavingState.saved;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 127));
    await tester.pump();
    expect(_says(tester), isNull);

    // failed: at once, and a press saves again
    chip.state.value = SavingState.failed;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(_says(tester), '저장 안 됨 · 다시 시도');
    expect(
      find.descendant(
        of: _box,
        matching: find.byKey(const ValueKey('save-chip-warn')),
      ),
      findsOneWidget,
    );
    await tester.tap(_box);
    expect(chip.saves, 1);

    // auto save off: waiting shows a second after the change
    chip.state.value = SavingState.saved;
    await tester.pumpAndSettle();
    stows.autosaveDelay.value = -1;
    chip.state.value = SavingState.waitingToSave;
    await tester.pump(const Duration(milliseconds: 999));
    expect(_says(tester), isNull);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 180));
    expect(_says(tester), '저장 대기 · 지금 저장');
    expect(
      find.descendant(
        of: _box,
        matching: find.byKey(const ValueKey('save-chip-wait')),
      ),
      findsOneWidget,
    );
    await tester.tap(_box);
    expect(chip.saves, 2);
    chip.state.value = SavingState.saved;
    await tester.pumpAndSettle();
    expect(_says(tester), isNull);
  });

  testWidgets('the chip sits under the bar at the page top right', (
    tester,
  ) async {
    final chip = await _pump(tester);
    chip.state.value = SavingState.failed;
    await tester.pumpAndSettle();
    final r = tester.getRect(_box);
    // values §7-1: right 12, top 58, 30 high
    expect(r.right, _page.width - 12);
    expect(r.top, 58);
    expect(r.height, 30);
    // the press reaches 7 above and below it (44)
    await tester.tapAt(Offset(r.center.dx, r.top - 6));
    await tester.tapAt(Offset(r.center.dx, r.bottom + 6));
    expect(chip.saves, 2);
    await tester.tapAt(Offset(r.center.dx, r.bottom + 8));
    expect((chip.saves, chip.canvasTaps), (2, 1));
  });

  testWidgets('7 between the words and the pressed words, no letter spacing', (
    tester,
  ) async {
    // values §7-2: the mark, the words and the button are the chip's flex
    // items 7 apart; the preview's text has no letter spacing
    final chip = await _pump(tester);
    for (final (state, front, action) in const [
      (SavingState.failed, '저장 안 됨 · ', '다시 시도'),
      (SavingState.waitingToSave, '저장 대기 · ', '지금 저장'),
    ]) {
      stows.autosaveDelay.value = -1;
      chip.state.value = state;
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text(action)).left -
            tester.getRect(find.text(front)).right,
        7,
        reason: action,
      );
      for (final words in [front, action]) {
        expect(tester.widget<Text>(find.text(words)).style!.letterSpacing, 0);
      }
      chip.state.value = SavingState.saved;
      await tester.pumpAndSettle();
    }
  });

  testWidgets('without a save action the chip only tells', (tester) async {
    final chip = await _pump(tester, withSave: false);
    chip.state.value = SavingState.failed;
    await tester.pumpAndSettle();
    expect(_says(tester), '저장 안 됨 · 다시 시도');
    await tester.tap(_box);
    expect(chip.saves, 0);
  });

  testWidgets('a stroke into the chip hides it until the pen is lifted', (
    tester,
  ) async {
    final chip = await _pump(tester);
    chip.state.value = SavingState.failed;
    await tester.pumpAndSettle();
    final r = tester.getRect(_box);
    chip.strokeAt.value = Offset(r.left - 13, r.center.dy);
    await tester.pump();
    expect(_shown(tester), 1, reason: '13 to its left is outside');
    chip.strokeAt.value = Offset(r.left - 11, r.center.dy);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_shown(tester), 0);
    expect(_takesPresses(tester), isFalse);
    chip.strokeAt.value = null;
    await tester.pump(const Duration(milliseconds: 599));
    expect(_takesPresses(tester), isFalse);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 180));
    expect(_shown(tester), 1);
    expect(_takesPresses(tester), isTrue);
  });
}
