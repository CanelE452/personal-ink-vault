import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/codecs/bool_map_codec.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/app_settings.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/settings_registry.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/pages/settings/settings_entries.dart';
import 'package:sbn/tool_id.dart';

/// Each pen's straight line and 수평/수직 (user answer 2): every pen starts
/// off, the two highlighters carry the highlighter's older setting.
void main() {
  FlavorConfig.setup();

  tearDown(() {
    for (final stow in [
      stows.autoStraightenLines,
      stows.highlighterStraightLine,
      stows.highlighterAxisLock,
    ]) {
      stow.value = stow.defaultValue;
    }
    stows.straightLineByPen.value = stows.straightLineByPen.defaultValue;
    stows.axisLockByPen.value = stows.axisLockByPen.defaultValue;
    stows.lastTool.value = stows.lastTool.defaultValue;
    stows.lastPenFamily.value = stows.lastPenFamily.defaultValue;
    stows.lastHighlighterKind.value = stows.lastHighlighterKind.defaultValue;
  });

  test('first read starts every pen with straight line and 수평/수직 off', () {
    expect(stows.straightLineByPen.value, isEmpty);
    expect(stows.axisLockByPen.value, isEmpty);
    for (final kind in KitPenKind.values) {
      expect(straightLineOf(kind), isFalse, reason: kind.label);
      expect(axisLockOf(kind), isFalse, reason: kind.label);
    }
  });

  test('first read ignores the old global auto straighten value', () {
    stows.autoStraightenLines.value = true;
    for (final kind in KitPenKind.values) {
      expect(straightLineOf(kind), isFalse, reason: kind.label);
    }
  });

  test('the two highlighters carry highlighterStraightLine and '
      'highlighterAxisLock', () {
    stows.highlighterStraightLine.value = true;
    stows.highlighterAxisLock.value = true;
    for (final kind in KitPenKind.values) {
      expect(straightLineOf(kind), kind.isHighlighter, reason: kind.label);
      expect(axisLockOf(kind), kind.isHighlighter, reason: kind.label);
    }
    // once a highlighter is set, its own value counts
    setStraightLine(KitPenKind.highlighterRound, false);
    expect(straightLineOf(KitPenKind.highlighterRound), isFalse);
    expect(straightLineOf(KitPenKind.highlighterChisel), isTrue);
    // the older setting is left as it was
    expect(stows.highlighterStraightLine.value, isTrue);
  });

  test('setting one pen leaves the others', () {
    setStraightLine(KitPenKind.pencil, true);
    setAxisLock(KitPenKind.brush, true);
    for (final kind in KitPenKind.values) {
      expect(
        straightLineOf(kind),
        kind == KitPenKind.pencil,
        reason: kind.label,
      );
      expect(axisLockOf(kind), kind == KitPenKind.brush, reason: kind.label);
    }
    expect(stows.straightLineByPen.value, {'pencil': true});
    expect(stows.axisLockByPen.value, {'brush': true});
    setStraightLine(KitPenKind.pencil, false);
    expect(straightLineOf(KitPenKind.pencil), isFalse);
    expect(axisLockOf(KitPenKind.brush), isTrue);
  });

  test("the rule's text keys match PenSettingInHand's keys", () {
    final reg = SettingsRegistry(reasons: ValueNotifier(<String, String>{}));
    addTearDown(reg.dispose);
    registerSettingsEntries(reg);
    registerInkRules(reg);
    final straight = reg.byKey(straightLineInHandKey);
    final axis = reg.byKey(axisLockInHandKey);
    expect(straight, isA<ToggleSetting>());
    expect((straight! as ToggleSetting).notifier, isA<PenSettingInHand>());
    expect((axis! as ToggleSetting).notifier, isA<PenSettingInHand>());
    expect(axis.onPage, isFalse);
    // the table owns them: filled again, the old ones are let go
    final first = (straight as ToggleSetting).notifier as PenSettingInHand;
    registerSettingsEntries(reg);
    final second =
        (reg.byKey(straightLineInHandKey)! as ToggleSetting).notifier;
    expect(second, isNot(same(first)));
    expect(() => ChangeNotifier.debugAssertNotDisposed(first), throwsFlutterError);
    expect(ChangeNotifier.debugAssertNotDisposed(second), isTrue);
    // the editor starts with the fountain pen: its straight line is off, so
    // its 수평/수직 cannot be used
    stows.lastTool.value = ToolId.fountainPen;
    expect(reg.unusableReason(axisLockInHandKey), '먼저 위의 ‘직선 자동 보정’을 켜세요.');
    setStraightLine(KitPenKind.fountain, true);
    expect(reg.unusableReason(axisLockInHandKey), isNull);
    // another pen in hand brings its own
    stows.lastTool.value = ToolId.pencil;
    expect(reg.unusableReason(axisLockInHandKey), isNotNull);
  });

  test('PenSettingInHand reads and sets the pen in hand, and tells when '
      'that changes', () {
    final tools = InkToolState(Pencil());
    final straight = PenSettingInHand.straightLine(tools);
    final axis = PenSettingInHand.axisLock(tools);
    addTearDown(straight.dispose);
    addTearDown(axis.dispose);
    var told = 0;
    straight.addListener(() => told++);
    expect(straight.kind, KitPenKind.pencil);
    straight.value = true;
    expect(straightLineOf(KitPenKind.pencil), isTrue);
    expect(straightLineOf(KitPenKind.fountain), isFalse);
    expect(told, 1);
    axis.value = true;
    expect(axisLockOf(KitPenKind.pencil), isTrue);
    // the round highlighter in hand: its own values
    tools.update(tool: Highlighter.round());
    expect(straight.kind, KitPenKind.highlighterRound);
    expect(straight.value, isFalse);
    expect(axis.value, isFalse);
    expect(told, 2);
    // a colour change of the same pen says nothing
    tools.update(color: const Color(0xff123456));
    expect(told, 2);
    // a tool that is not an ink pen (the shape pen, the eraser): no pen,
    // off, and setting it changes no pen; the pen a note opens with is
    // the settings page's only
    stows.lastTool.value = ToolId.pencil;
    for (final tool in [ShapePen(), Eraser()]) {
      tools.update(tool: tool);
      expect(straight.kind, isNull);
      expect(straight.value, isFalse);
      straight.value = true;
      axis.value = true;
    }
    expect(stows.straightLineByPen.value, {'pencil': true});
    expect(stows.axisLockByPen.value, {'pencil': true});
  });

  test('without a tool state the pen in hand is the one a note opens with', () {
    final straight = PenSettingInHand.straightLine();
    addTearDown(straight.dispose);
    expect(straight.kind, KitPenKind.fountain);
    stows.lastTool.value = ToolId.highlighter;
    expect(straight.kind, KitPenKind.highlighterChisel);
    stows.lastHighlighterKind.value = KitPenKind.highlighterRound.previewId;
    expect(straight.kind, KitPenKind.highlighterRound);
    stows.lastTool.value = ToolId.ballpointPen;
    expect(straight.kind, KitPenKind.finePen);
    // the last tool draws no ink (the eraser): the last pen of the pen
    // family, and the fountain pen when that is the shape pen
    stows.lastTool.value = ToolId.eraser;
    stows.lastPenFamily.value = ToolId.pencil;
    expect(straight.kind, KitPenKind.pencil);
    stows.lastPenFamily.value = ToolId.calligraphyPen;
    expect(straight.kind, KitPenKind.calligraphy);
    stows.lastPenFamily.value = ToolId.shapePen;
    expect(straight.kind, KitPenKind.fountain);
    stows.lastTool.value = ToolId.shapePen;
    stows.lastPenFamily.value = ToolId.brush;
    expect(straight.kind, KitPenKind.brush);
    expect(penKindOf(Highlighter.round()), KitPenKind.highlighterRound);
  });

  test('a broken stored value reads as no pen set', () {
    const codec = BoolMapCodec();
    expect(codec.decode(''), isEmpty);
    expect(codec.decode('not json'), isEmpty);
    expect(codec.decode('[true]'), isEmpty);
    expect(codec.decode(true), isEmpty);
    expect(codec.decode(null), isEmpty);
    expect(codec.decode('{"pencil":true,"pen":3,"brush":false}'), {
      'pencil': true,
      'brush': false,
    });
    expect(codec.decode(codec.encode({'hlround': true})), {'hlround': true});
  });
}
