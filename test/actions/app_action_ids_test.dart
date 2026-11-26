import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/data/actions/app_action_ids.dart';

void main() {
  test('every 229 shortcut id has an action id', () {
    for (final item in noteShortcutItems) {
      expect(AppActionIds.all, contains(item.id));
    }
  });

  test('229 more order is kept', () {
    expect(AppActionIds.more229, [
      for (final i in noteShortcutItems)
        if (i.side == ShortcutSide.more) i.id,
    ]);
  });

  test('ids are unique lowerCamel and tools are ids', () {
    expect(AppActionIds.all.toSet().length, AppActionIds.all.length);
    final lowerCamel = RegExp(r'^[a-z][A-Za-z0-9]*$');
    for (final id in AppActionIds.all) {
      expect(lowerCamel.hasMatch(id), isTrue, reason: id);
    }
    expect(AppActionIds.tools, hasLength(8));
    for (final id in AppActionIds.tools) {
      expect(AppActionIds.all, contains(id));
    }
    expect(AppActionIds.all, isNot(contains('toggleTextEditing')));
  });

  test('ids added by the architect review and the controller are present', () {
    for (final id in [
      'saveNow',
      'eyedropper',
      'toolText',
      'recolorSelection',
      'viewLogs',
      'openDataDir',
    ]) {
      expect(AppActionIds.all, contains(id));
    }
    expect(AppActionIds.save, isNot(AppActionIds.saveNow));
    // nobody publishes it: ⋯ 「확대 비율」 reads the editor's zoom (Task 14)
    expect(AppActionIds.all, isNot(contains('zoomRatio')));
  });
}
