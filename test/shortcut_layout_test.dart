import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/components/toolbar/toolbar_layout.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/tools/highlighter.dart';

void main() {
  group('shortcut layout', () {
    test('empty storage gives the spec defaults', () {
      final l = ShortcutLayout.decode(noteShortcutItems, const []);
      expect(l.left, [
        'prev',
        'next',
        'save',
        'pdfSearch',
        'documentExport',
        'insertPage',
        'pageMode',
        'finger',
      ]);
      expect(l.right, ['viewToggle', 'fullscreen']);
      expect(
        l.more,
        containsAll([
          'export',
          'pdfRemake',
          'quickSwitch',
          'bookmarks',
          'knowledge',
          'mcp',
          'copyPageLink',
          'openNoteLink',
          'vaultExport',
          'linkAdd',
        ]),
      );
      expect(l.barCount, maxBarShortcuts);
    });

    test(
      'stored entries keep order and side; unknown ids are dropped; missing ids follow defaults',
      () {
        final l = ShortcutLayout.decode(noteShortcutItems, const [
          'R:save',
          'L:fullscreen',
          'L:nope',
          '!prev',
        ]);
        expect(l.left.first, 'fullscreen');
        expect(l.right.first, 'save');
        expect(l.more, contains('prev'));
        // Not stored: the default side.
        expect(l.left, contains('next'));
        expect(
          [...l.left, ...l.right, ...l.more],
          unorderedEquals(noteShortcutItems.map((item) => item.id)),
        );
      },
    );

    test('legacy toolbar visibility moves hidden page actions to more', () {
      final l = ShortcutLayout.decode(
        noteShortcutItems,
        const [],
        legacyToolbar: const [
          'colors',
          '!finger',
          'pageMode',
          '!insertPage',
          'export',
          'pen',
        ],
      );
      expect(l.more, containsAll(['finger', 'insertPage']));
      expect(l.left, contains('pageMode'));
      // Shown in the old toolbar: it stays on the bar.
      expect(l.left, contains('export'));
      expect(l.more, isNot(contains('export')));
    });

    test('stored layout ignores the legacy toolbar', () {
      final l = ShortcutLayout.decode(
        noteShortcutItems,
        const ['L:finger'],
        legacyToolbar: const ['!finger'],
      );
      expect(l.left.first, 'finger');
    });

    test('placed moves an item between sides at an index and encode round-trips', () {
      final l = ShortcutLayout.decode(
        noteShortcutItems,
        const [],
      ).placed('fullscreen', ShortcutSide.left, index: 0);
      expect(l.left.first, 'fullscreen');
      expect(l.right, isNot(contains('fullscreen')));
      expect(
        ShortcutLayout.decode(noteShortcutItems, l.encode()).encode(),
        l.encode(),
      );
      expect(l.sideOf('fullscreen'), ShortcutSide.left);
      expect(l.placed('save', ShortcutSide.more).sideOf('save'), ShortcutSide.more);
    });
  });

  test('StarNote defaults', () {
    // The highlighter reads its last options from the preferences.
    FlavorConfig.setup();
    expect(toolbarQuickColors, [
      0xff000000,
      0xffb33333,
      0xff2b4faf,
      0xff007355,
      0xffdaa001,
    ]);
    expect(highlighterQuickColors, [
      0xffffe60f,
      0xffffa047,
      0xff60f748,
      0xffa0c6fe,
      0xffbe9aff,
    ]);
    expect(Highlighter().sizePresets, [25, 35, 50]);
    expect(Highlighter.alpha, 100);
  });
}
