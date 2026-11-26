import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/pages/editor/editor.dart';

/// [text] as a kit window row shows it: a name too long for one line gets
/// word joiners (U+2060) between its letters so it breaks between words
/// (Task 14 fix 1); this finds it either way.
Finder findMenuText(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is Text &&
      widget.data?.replaceAll(String.fromCharCode(0x2060), '') == text,
);

/// The open editor's actions (its own [AppActionScope]).
AppActionRegistry editorActions(WidgetTester tester) => tester
    .widget<AppActionScope>(
      find
          .descendant(
            of: find.byType(Editor),
            matching: find.byType(AppActionScope),
          )
          .first,
    )
    .notifier!;

/// The editor shows one page at a time (the `pageMode` action is on). Fails
/// when the editor does not publish the action.
bool singlePageLayout(WidgetTester tester) {
  final action = editorActions(tester).lookup(AppActionIds.pageMode);
  expect(action, isNotNull, reason: 'the editor publishes pageMode');
  return action!.checked!;
}

/// The ink editor's ⋯ 쪽 배치, the other layout: one page at a time (가로로
/// 넘기기) or all pages in a column (세로로 이어 보기); 229's function row
/// toggle is gone (Task 17). Settles after each step.
Future<void> togglePageLayout(WidgetTester tester) async {
  final single = singlePageLayout(tester);
  await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('editor-doc-layout')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('editor-doc-layout-${!single}')));
  await tester.pumpAndSettle();
}
