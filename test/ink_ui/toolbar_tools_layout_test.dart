import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/toolbar_tools_layout.dart';
import 'package:saber/components/kit/kit_icons.g.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/data/tools/shape_pen.dart';

/// The editor toolbar's tools (9th draft c): lasso, pen, eraser, text,
/// shapes, picture on the bar, the laser pen in the ⌄ window; 1 to 6 on the
/// bar.
void main() {
  const defaults = [
    'lasso',
    'pen',
    'eraser',
    'text',
    'shapes',
    'image',
    '!laser',
  ];

  test('the default layout and order', () {
    final layout = ToolbarToolsLayout.decode(const []);
    expect(layout.encode(), defaults);
    expect(layout.shownIds, ['lasso', 'pen', 'eraser', 'text', 'shapes', 'image']);
    expect(layout.hiddenIds, ['laser']);
  });

  test('a saved order is kept and missing tools follow in default order', () {
    final layout = ToolbarToolsLayout.decode(const ['pen', '!lasso', 'laser']);
    expect(layout.encode(), [
      'pen',
      '!lasso',
      'laser',
      'eraser',
      'text',
      'shapes',
      'image',
    ]);
    // a missing tool joins the bar only while it has room
    expect(
      ToolbarToolsLayout.decode(const [
        'laser',
        'pen',
        'lasso',
        'eraser',
        'text',
        'shapes',
      ]).encode(),
      ['laser', 'pen', 'lasso', 'eraser', 'text', 'shapes', '!image'],
    );
  });

  test('corrupt stored layout falls back to defaults', () {
    final fallback = ToolbarToolsLayout.decode(const []).encode();
    expect(
      ToolbarToolsLayout.decode(const ['', '!', 'zzz', 'pen', 'pen']).encode(),
      fallback,
    );
    for (final broken in const [
      [''],
      ['!'],
      ['zzz'],
      ['pen', 'pen'],
      ['emoji'],
      // nothing on the bar
      ['!lasso', '!pen', '!eraser', '!text', '!shapes', '!image', '!laser'],
      // seven on the bar
      ['lasso', 'pen', 'eraser', 'text', 'shapes', 'image', 'laser'],
    ]) {
      expect(
        ToolbarToolsLayout.decode(broken).encode(),
        fallback,
        reason: '$broken',
      );
    }
  });

  test('229 layout migrates with hidden flags', () {
    expect(
      ToolbarToolsLayout.migrate(const ['!pen', 'select', 'photo', 'laser'])
          .encode(),
      ['!pen', 'lasso', 'image', 'laser', 'eraser', 'text', 'shapes'],
    );
    // 229's own default: the pencil and highlighter buttons and the 228
    // page actions are gone from the new bar
    expect(
      ToolbarToolsLayout.migrate(const [
        'pen',
        '!pencil',
        'highlighter',
        'eraser',
        'select',
        'photo',
        'text',
        '!laser',
        'insertPage',
      ]).encode(),
      ['pen', 'eraser', 'lasso', 'image', 'text', '!laser', 'shapes'],
    );
    expect(ToolbarToolsLayout.migrate(const []).encode(), defaults);
  });

  // Final review B-7 (Review Focus): broken 229 entries.
  test('a broken 229 entry is skipped, the rest of its layout kept', () {
    expect(ToolbarToolsLayout.migrate(const ['', '!']).encode(), defaults);
    expect(
      ToolbarToolsLayout.read(stored: const [], stored229: const ['', '!'])
          .encode(),
      defaults,
    );
    expect(
      ToolbarToolsLayout.migrate(const ['', '!pen', '!', 'select']).encode(),
      ['!pen', 'lasso', 'eraser', 'text', 'shapes', 'image', '!laser'],
    );
  });

  test('the saved layout wins over the 229 one once the bar is customized', () {
    expect(
      ToolbarToolsLayout.read(
        stored: const [],
        stored229: const ['!select'],
      ).encode(),
      ['!lasso', 'pen', 'eraser', 'text', 'shapes', 'image', '!laser'],
    );
    expect(
      ToolbarToolsLayout.read(
        stored: const ['laser', '!pen'],
        stored229: const ['!select'],
      ).shownIds,
      ['laser', 'lasso', 'eraser', 'text', 'shapes', 'image'],
    );
  });

  test('reset writes a full layout so the 229 one is not migrated again', () {
    final reset = ToolbarToolsLayout.decode(const []).encode();
    expect(reset, isNotEmpty);
    expect(
      ToolbarToolsLayout.read(stored: reset, stored229: const ['!pen']).encode(),
      defaults,
    );
  });

  test('1 to 6 tools on the bar', () {
    final six = ToolbarToolsLayout.decode(const []);
    final (tooMany, same) = six.withShown('laser', true);
    expect(tooMany, ToolbarToolSwitch.tooMany);
    expect(same.encode(), defaults);

    var layout = six;
    for (final id in ['lasso', 'pen', 'eraser', 'text', 'shapes']) {
      final (result, next) = layout.withShown(id, false);
      expect(result, ToolbarToolSwitch.done);
      layout = next;
    }
    expect(layout.shownIds, ['image']);
    final (tooFew, kept) = layout.withShown('image', false);
    expect(tooFew, ToolbarToolSwitch.tooFew);
    expect(kept.shownIds, ['image']);

    final (done, five) = six.withShown('pen', false);
    expect(done, ToolbarToolSwitch.done);
    final (on, back) = five.withShown('laser', true);
    expect(on, ToolbarToolSwitch.done);
    expect(back.shownIds, ['lasso', 'eraser', 'text', 'shapes', 'image', 'laser']);
  });

  test('moving a tool keeps where each one is', () {
    final layout = ToolbarToolsLayout.decode(const []).moved(6, 0);
    expect(layout.encode(), [
      '!laser',
      'lasso',
      'pen',
      'eraser',
      'text',
      'shapes',
      'image',
    ]);
  });

  test("the tool in hand shows its toolbar button's icon", () {
    FlavorConfig.setup();
    // the pen button holds every pen; the lasso shows its kind
    for (final (tool, icon) in <(Tool, KitIconName)>[
      (Pen.fountainPen(), KitIconName.pen),
      (Highlighter.currentHighlighter, KitIconName.pen),
      (Pencil.currentPencil, KitIconName.pen),
      (Eraser(), KitIconName.eraser),
      (Select.currentSelect, KitIconName.lassoFree),
      (ShapePen(), KitIconName.shapes),
      (Tool.textEditing, KitIconName.text),
      (LaserPointer.currentLaserPointer, KitIconName.laser),
    ]) {
      expect(kitIconForTool(tool, lassoRect: false), icon, reason: '$tool');
    }
    expect(
      kitIconForTool(Select.currentSelect, lassoRect: true),
      KitIconName.lassoRect,
    );
    expect(kitIconForTool(Pen.fountainPen(), lassoRect: true), KitIconName.pen);
    expect(
      toolbarToolIcon(toolbarToolOf('lasso'), lassoRect: true),
      KitIconName.lassoRect,
    );
  });
}
