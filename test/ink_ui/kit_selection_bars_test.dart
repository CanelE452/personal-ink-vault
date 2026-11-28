import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' hide EditorState;
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/hud/canvas_hud.dart';
import 'package:saber/components/canvas/inner_canvas.dart';
import 'package:saber/components/ink_ui/selection_bars/kit_lasso_bar.dart';
import 'package:saber/components/ink_ui/selection_bars/kit_text_bar.dart';
import 'package:saber/components/ink_ui/selection_bars/selection_bar_anchor.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_selection_bar.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/editor/saving_state.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The text box and lasso bars (Task 15): the place under what is chosen,
/// the text bar's Quill formats and clipboard rows, the lasso bar's buttons,
/// and the editor showing them instead of the old Quill toolbar.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  /// An 800 x 1000 screen at ratio 1, put back after the test.
  void screen(WidgetTester tester, [Size size = const Size(800, 1000)]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// The system clipboard as a plain string, for this test only.
  void fakeClipboard(WidgetTester tester) {
    String? held;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          held = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return held == null ? null : {'text': held};
        case 'Clipboard.hasStrings':
          return {'value': held?.isNotEmpty ?? false};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
  }

  /// A text bar over [controller], under a caret at 200, 100.
  Future<void> mountTextBar(
    WidgetTester tester,
    QuillController controller,
  ) async {
    screen(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SizedBox.expand(
            child: KitTextBar(
              controller: controller,
              caretRect: const Rect.fromLTWH(200, 100, 2, 30),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  QuillController controllerWith(String text, TextSelection selection) {
    final controller = QuillController(
      document: Document()..insert(0, text),
      selection: selection,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Map<String, Attribute> styleOf(QuillController controller) =>
      controller.getSelectionStyle().attributes;

  test('bar sits below the target, or above when there is no room', () {
    expect(
      selectionBarPosition(
        target: const Rect.fromLTWH(100, 100, 200, 40),
        bar: const Size(300, 56),
        viewport: const Size(800, 1000),
      ).dy,
      152,
    );
    expect(
      selectionBarPosition(
        target: const Rect.fromLTWH(100, 940, 200, 40),
        bar: const Size(300, 56),
        viewport: const Size(800, 1000),
      ).dy,
      940 - 12 - 56,
    );
    // centred under the target, pushed inside the screen at an edge
    expect(
      selectionBarPosition(
        target: const Rect.fromLTWH(100, 100, 200, 40),
        bar: const Size(300, 56),
        viewport: const Size(800, 1000),
      ).dx,
      50,
    );
    final atRight = selectionBarPosition(
      target: const Rect.fromLTWH(760, 100, 30, 40),
      bar: const Size(300, 56),
      viewport: const Size(800, 1000),
    );
    expect(atRight.dx + 300, lessThanOrEqualTo(800));
    expect(atRight.dx, greaterThanOrEqualTo(0));
    // no room under or over a tall target: at the foot of the screen
    expect(
      selectionBarPosition(
        target: const Rect.fromLTWH(100, 20, 200, 960),
        bar: const Size(300, 56),
        viewport: const Size(800, 1000),
      ),
      const Offset(50, 1000 - 56),
    );
    // a target wider than the screen, centred past its right edge: kept 8
    // inside
    expect(
      selectionBarPosition(
        target: const Rect.fromLTWH(200, 100, 2000, 40),
        bar: const Size(300, 56),
        viewport: const Size(800, 1000),
      ),
      const Offset(800 - 300 - 8, 152),
    );
    // a bar wider than the screen: centred on the screen
    expect(
      selectionBarPosition(
        target: const Rect.fromLTWH(100, 100, 200, 40),
        bar: const Size(900, 56),
        viewport: const Size(800, 1000),
      ).dx,
      -50,
    );
  });

  test('a text highlight is drawn inverted on the dark page', () {
    const pale = Color(0xfffdffb6);
    final shown = InnerCanvas.invertedHighlight(
      const BackgroundAttribute('#fffdffb6'),
    ).backgroundColor!;
    expect(shown, pale.withInversion());
    // dark enough for the page's white letters (4.5:1 at least)
    final contrast = 1.05 / (shown.computeLuminance() + 0.05);
    expect(contrast, greaterThan(4.5));
    expect(
      InnerCanvas.invertedHighlight(const BackgroundAttribute('#fdffb6'))
          .backgroundColor,
      shown,
    );
    expect(
      InnerCanvas.invertedHighlight(Attribute.bold).backgroundColor,
      isNull,
    );
  });

  testWidgets('bold button toggles bold on the selection', (tester) async {
    final controller = controllerWith(
      'Hello world',
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await mountTextBar(tester, controller);

    await tester.tap(find.byKey(const ValueKey('text-bar-format')));
    await tester.pumpAndSettle();
    for (final (key, attribute) in [
      ('text-format-bold', Attribute.bold),
      ('text-format-italic', Attribute.italic),
      ('text-format-underline', Attribute.underline),
      ('text-format-strike', Attribute.strikeThrough),
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      expect(styleOf(controller), contains(attribute.key), reason: key);
    }
    // pressed again, bold comes off; the others stay
    await tester.tap(find.byKey(const ValueKey('text-format-bold')));
    await tester.pumpAndSettle();
    expect(styleOf(controller), isNot(contains(Attribute.bold.key)));
    expect(styleOf(controller), contains(Attribute.italic.key));
  });

  testWidgets('text colour button colours the selection', (tester) async {
    final controller = controllerWith(
      'Hello world',
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await mountTextBar(tester, controller);
    expect(styleOf(controller), isNot(contains(Attribute.color.key)));

    await tester.tap(find.byKey(const ValueKey('text-bar-colour')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kit-swatch-ffe5323e')));
    await tester.pumpAndSettle();

    expect(styleOf(controller)[Attribute.color.key]?.value, '#ffe5323e');
    // the rest of the line keeps its colour
    controller.updateSelection(
      const TextSelection(baseOffset: 6, extentOffset: 11),
      ChangeSource.local,
    );
    expect(styleOf(controller), isNot(contains(Attribute.color.key)));
  });

  testWidgets('size box applies the chosen size', (tester) async {
    final controller = controllerWith(
      'Hello world',
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await mountTextBar(tester, controller);
    final box = find.byKey(const ValueKey('text-bar-size'));
    // no size on the text: the box shows the default size
    expect(find.descendant(of: box, matching: find.text('28')), findsOneWidget);

    await tester.tap(box);
    await tester.pumpAndSettle();
    for (final size in [8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64]) {
      expect(
        find.byKey(ValueKey('text-size-$size'), skipOffstage: false),
        findsOneWidget,
        reason: '$size',
      );
    }
    await tester.tap(find.byKey(const ValueKey('text-size-24')));
    await tester.pumpAndSettle();

    expect(styleOf(controller)[Attribute.size.key]?.value, '24');
    expect(find.byKey(const ValueKey('text-size-24')), findsNothing);
    expect(find.descendant(of: box, matching: find.text('24')), findsOneWidget);
  });

  testWidgets('paste and match style drops source formatting', (tester) async {
    fakeClipboard(tester);
    final controller = QuillController(
      document: Document.fromJson([
        {
          'insert': 'Bold',
          'attributes': {'bold': true},
        },
        {
          'insert': ' ital',
          'attributes': {'italic': true},
        },
        {'insert': '\n'},
      ]),
      selection: const TextSelection(baseOffset: 0, extentOffset: 4),
    );
    addTearDown(controller.dispose);
    // copy the bold word, then put the caret after the italic one
    // ignore: experimental_member_use
    expect(controller.clipboardSelection(true), isTrue);
    controller.updateSelection(
      const TextSelection.collapsed(offset: 9),
      ChangeSource.local,
    );
    await mountTextBar(tester, controller);

    await tester.tap(find.byKey(const ValueKey('text-bar-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('text-paste-match')));
    await tester.pumpAndSettle();

    expect(controller.document.toPlainText(), 'Bold italBold\n');
    final pasted = controller.document.collectStyle(9, 4).attributes;
    expect(pasted, isNot(contains(Attribute.bold.key)));
    expect(pasted, contains(Attribute.italic.key));
    expect(controller.selection, const TextSelection.collapsed(offset: 13));
  });

  testWidgets('paste rows are dimmed while the clipboard has no text', (
    tester,
  ) async {
    fakeClipboard(tester);
    final controller = controllerWith(
      'Hello world',
      const TextSelection.collapsed(offset: 5),
    );
    await mountTextBar(tester, controller);
    await tester.tap(find.byKey(const ValueKey('text-bar-more')));
    await tester.pumpAndSettle();

    bool enabled(String key) =>
        tester.widget<Semantics>(find.byKey(ValueKey(key))).properties.enabled!;
    expect(enabled('text-paste'), isFalse);
    expect(enabled('text-paste-match'), isFalse);
    // nothing chosen: nothing to cut, copy or link
    expect(enabled('text-cut'), isFalse);
    expect(enabled('text-copy'), isFalse);
    expect(enabled('text-link'), isFalse);
    expect(enabled('text-highlight-more'), isTrue);
    await tester.tap(find.byKey(const ValueKey('text-paste-match')));
    await tester.pumpAndSettle();
    expect(controller.document.toPlainText(), 'Hello world\n');
    expect(find.text('붙여넣고 스타일 맞추기'), findsOneWidget, reason: 'still open');
  });

  testWidgets('alignment, list and highlight change the text', (tester) async {
    final controller = controllerWith(
      'Hello world',
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await mountTextBar(tester, controller);
    Object? value(Attribute attribute) =>
        styleOf(controller)[attribute.key]?.value;

    final align = find.byKey(const ValueKey('text-bar-align'));
    for (final next in ['center', 'right', null]) {
      await tester.tap(align);
      await tester.pumpAndSettle();
      expect(value(Attribute.align), next);
    }
    // back at the left the line has no alignment of its own
    expect(styleOf(controller), isNot(contains(Attribute.align.key)));

    await tester.tap(find.byKey(const ValueKey('text-bar-list')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('text-list-number')));
    await tester.pumpAndSettle();
    expect(value(Attribute.list), 'ordered');
    await tester.tap(find.byKey(const ValueKey('text-list-number')));
    await tester.pumpAndSettle();
    expect(value(Attribute.list), isNull);
    await tester.tapAt(const Offset(780, 980)); // closes the window
    await tester.pumpAndSettle();

    final highlight = find.byKey(const ValueKey('text-bar-highlight'));
    await tester.tap(highlight);
    await tester.pumpAndSettle();
    expect(value(Attribute.background), '#fffdffb6');
    await tester.tap(highlight);
    await tester.pumpAndSettle();
    expect(value(Attribute.background), isNull);
  });

  testWidgets('cut, copy and paste rows use the clipboard', (tester) async {
    String? clipboard;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clipboard = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return clipboard == null ? null : {'text': clipboard};
        case 'Clipboard.hasStrings':
          return {'value': clipboard?.isNotEmpty ?? false};
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    // Quill first asks the platform for HTML on the clipboard, which the
    // test platform cannot answer; the plain text path is the app's own
    final controller = QuillController(
      document: Document()..insert(0, 'Hello world'),
      selection: const TextSelection(baseOffset: 0, extentOffset: 5),
      config: const QuillControllerConfig(
        // ignore: experimental_member_use
        clipboardConfig: QuillClipboardConfig(
          // ignore: experimental_member_use
          enableExternalRichPaste: false,
        ),
      ),
    );
    addTearDown(controller.dispose);
    await mountTextBar(tester, controller);
    Future<void> row(String key) async {
      await tester.tap(find.byKey(const ValueKey('text-bar-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    await row('text-copy');
    expect(clipboard, 'Hello');
    expect(controller.document.toPlainText(), 'Hello world\n');

    await row('text-cut');
    expect(clipboard, 'Hello');
    expect(controller.document.toPlainText(), ' world\n');
    expect(controller.selection, const TextSelection.collapsed(offset: 0));

    controller.updateSelection(
      const TextSelection.collapsed(offset: 6),
      ChangeSource.local,
    );
    await row('text-paste');
    expect(controller.document.toPlainText(), ' worldHello\n');
    expect(clipboard, 'Hello', reason: 'pasting leaves the clipboard');
  });

  testWidgets('the link window sets, changes and takes off a link', (
    tester,
  ) async {
    fakeClipboard(tester);
    final controller = controllerWith(
      'Hello world',
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await mountTextBar(tester, controller);
    Object? link() => styleOf(controller)[Attribute.link.key]?.value;
    final field = find.byKey(const ValueKey('text-link-field'));
    Future<void> open() async {
      await tester.tap(find.byKey(const ValueKey('text-bar-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('text-link')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(field, findsOneWidget);
    }

    Future<void> put(String text, String button) async {
      await tester.enterText(field, text);
      await tester.tap(find.byKey(ValueKey(button)));
      await tester.pumpAndSettle();
      expect(field, findsNothing, reason: 'the window closed');
    }

    await open();
    expect(find.text('링크'), findsOneWidget, reason: 'the title');
    // the caret in the kit's accent, not the theme's purple
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          )
          .cursorColor,
      KitTokens.accent,
    );
    // an address without a scheme gets https://
    await put('example.com', 'text-link-set');
    expect(link(), 'https://example.com');

    await open();
    expect(
      tester.widget<TextField>(field).controller!.text,
      'https://example.com',
    );
    await put('mailto:me@example.org', 'text-link-set');
    expect(link(), 'mailto:me@example.org');

    // an empty address takes the link off
    await open();
    await put('', 'text-link-set');
    expect(link(), isNull);

    await open();
    await put('example.org/a', 'text-link-set');
    expect(link(), 'https://example.org/a');
    await open();
    await tester.tap(find.byKey(const ValueKey('text-link-remove')));
    await tester.pumpAndSettle();
    expect(link(), isNull);
    expect(field, findsNothing);

    // a host with a port is not a scheme; a scheme with // or a known one
    // without it stays as typed
    for (final (typed, kept) in [
      ('localhost:8080', 'https://localhost:8080'),
      ('example.com:8080/x', 'https://example.com:8080/x'),
      ('http://example.com/a', 'http://example.com/a'),
      ('ftp://files.example.org', 'ftp://files.example.org'),
      ('tel:+82-2-123-4567', 'tel:+82-2-123-4567'),
      ('MAILTO:me@example.org', 'MAILTO:me@example.org'),
    ]) {
      await open();
      await put(typed, 'text-link-set');
      expect(link(), kept, reason: typed);
    }
  });

  /// The lasso bar under a registry that publishes [ids] (stand-ins that note
  /// the id they ran into [ran]).
  Future<void> mountLassoBar(
    WidgetTester tester,
    List<String> ran, {
    List<Color>? colours,
    List<String> ids = const [
      AppActionIds.duplicateSelection,
      AppActionIds.deleteSelection,
      AppActionIds.linkSelection,
    ],
  }) async {
    final actions = AppActionRegistry()
      ..publish(Object(), [
        for (final id in ids)
          AppAction(
            id: id,
            label: id,
            icon: KitIconName.dup,
            run: (_) => ran.add(id),
          ),
      ]);
    addTearDown(actions.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: AppActionScope(
            actions: actions,
            child: SizedBox.expand(
              child: KitLassoBar(
                recolorSelection: (colours ?? <Color>[]).add,
                selectionRect: const Rect.fromLTWH(200, 200, 300, 120),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the lasso bar runs duplicateSelection and deleteSelection by id', (
    tester,
  ) async {
    screen(tester);
    final ran = <String>[];
    await mountLassoBar(tester, ran);
    await tester.tap(find.byKey(const ValueKey('lasso-bar-duplicate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lasso-bar-delete')));
    await tester.pumpAndSettle();
    expect(ran, [
      AppActionIds.duplicateSelection,
      AppActionIds.deleteSelection,
    ]);
    // the ⋯ rows run them by id too
    await tester.tap(find.byKey(const ValueKey('lasso-bar-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lasso-menu-duplicate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lasso-bar-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('lasso-menu-delete')));
    await tester.pumpAndSettle();
    expect(ran.skip(2), [
      AppActionIds.duplicateSelection,
      AppActionIds.deleteSelection,
    ]);
  });

  testWidgets('the lasso bar hides a button whose action is not published', (
    tester,
  ) async {
    screen(tester);
    final ran = <String>[];
    await mountLassoBar(
      tester,
      ran,
      ids: const [AppActionIds.duplicateSelection],
    );
    expect(find.byKey(const ValueKey('lasso-bar-duplicate')), findsOneWidget);
    expect(find.byKey(const ValueKey('lasso-bar-delete')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('lasso-bar-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lasso-menu-duplicate')), findsOneWidget);
    expect(find.byKey(const ValueKey('selection-link')), findsNothing);
    expect(find.byKey(const ValueKey('lasso-menu-delete')), findsNothing);
  });

  testWidgets('the lasso bar leaves out a group with no published action', (
    tester,
  ) async {
    screen(tester);
    final ran = <String>[];
    const divider = ValueKey('kit-selection-bar-divider');
    await mountLassoBar(tester, ran);
    expect(find.byKey(divider), findsNWidgets(2), reason: 'three groups');
    // neither duplicate nor delete: no group, so no line for it either
    await mountLassoBar(tester, ran, ids: const []);
    expect(find.byKey(const ValueKey('lasso-bar-duplicate')), findsNothing);
    expect(find.byKey(const ValueKey('lasso-bar-delete')), findsNothing);
    expect(find.byKey(divider), findsOneWidget, reason: 'colour | ⋯ only');
    expect(find.byKey(const ValueKey('lasso-bar-colour')), findsOneWidget);
    expect(find.byKey(const ValueKey('lasso-bar-more')), findsOneWidget);
  });

  testWidgets('lasso bar has duplicate, delete, colour and link', (
    tester,
  ) async {
    screen(tester);
    final pressed = <String>[];
    final colours = <Color>[];
    await mountLassoBar(tester, pressed, colours: colours);

    final bar = tester.getRect(find.byType(KitSelectionBar));
    expect(bar.top, 200 + 120 + 12, reason: 'under the selection');
    expect(bar.center.dx, closeTo(350, 0.5));
    expect(
      find.byKey(const ValueKey('lasso-bar-colour')),
      findsOneWidget,
      reason: 'the colour chip',
    );
    final delete = find.byKey(const ValueKey('lasso-bar-delete'));
    expect(
      tester
          .widget<KitSquareButton>(
            find.descendant(of: delete, matching: find.byType(KitSquareButton)),
          )
          .iconColor,
      KitTokens.danger,
    );
    // rows the engine has no action for are not drawn
    for (final hidden in ['자르기', '크기 바꾸기', 'AI에게 묻기', '화면 캡처']) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }

    await tester.tap(find.byKey(const ValueKey('lasso-bar-duplicate')));
    await tester.pumpAndSettle();
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(pressed, [
      AppActionIds.duplicateSelection,
      AppActionIds.deleteSelection,
    ]);

    await tester.tap(find.byKey(const ValueKey('lasso-bar-more')));
    await tester.pumpAndSettle();
    expect(find.text('복제'), findsOneWidget);
    expect(find.text('링크'), findsOneWidget);
    expect(find.text('삭제'), findsOneWidget);
    for (final hidden in ['자르기', '복사하기', '붙여넣기', '크기 바꾸기', '맨 앞으로']) {
      expect(find.text(hidden), findsNothing, reason: hidden);
    }
    await tester.tap(find.byKey(const ValueKey('selection-link')));
    await tester.pumpAndSettle();
    expect(pressed, [
      AppActionIds.duplicateSelection,
      AppActionIds.deleteSelection,
      AppActionIds.linkSelection,
    ]);
    expect(find.text('링크'), findsNothing, reason: 'the menu closed');
    expect(colours, isEmpty);
  });

  /// The editor on a 1200 x 1600 screen.
  Future<EditorState> mountEditor(WidgetTester tester) async {
    screen(tester, const Size(1200, 1600));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          // The text box (a Quill editor) needs its strings.
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(
            path: '/selection-bars',
            onSaveSnapshot: (_, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  AppActionRegistry actionsOf(WidgetTester tester) =>
      tester.widget<AppActionScope>(find.byType(AppActionScope)).notifier!;

  const blue = Color(0xFF1E88E5);

  /// The editor with a blue line lassoed by a rectangle dragged across it;
  /// gives the line and the dragged rectangle on the screen.
  Future<(EditorState, Stroke, Rect)> lassoALine(WidgetTester tester) async {
    final rectangle = stows.selectRectangle.value;
    final lastTool = stows.lastTool.value;
    stows.selectRectangle.value = true;
    // the lasso is one object for every editor: start with nothing lassoed
    Select.currentSelect.unselect();
    addTearDown(() {
      Select.currentSelect.unselect();
      stows.selectRectangle.value = rectangle;
      stows.lastTool.value = lastTool;
    });
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    final stroke = Stroke(
      color: blue,
      pressureEnabled: false,
      options: StrokeOptions(size: 40),
      pageIndex: 0,
      page: page,
      toolId: ToolId.ballpointPen,
    )..addPoints([for (var x = 100.0; x <= 500; x += 20) Offset(x, 300)]);
    page.insertStroke(stroke);
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pump();

    final context = tester.element(find.byType(Editor));
    expect(actionsOf(tester).run(AppActionIds.toolLasso, context), isTrue);
    await tester.pump();
    final box = page.renderBox!;
    final from = box.localToGlobal(const Offset(60, 240));
    final to = box.localToGlobal(const Offset(540, 360));
    final pen = await tester.startGesture(from, kind: PointerDeviceKind.stylus);
    await pen.moveTo(Offset.lerp(from, to, .5)!);
    await pen.moveTo(to);
    await pen.up();
    await tester.pumpAndSettle();
    expect(Select.currentSelect.selectResult.strokes, [stroke]);
    return (editor, stroke, Rect.fromPoints(from, to));
  }

  /// The canvas's zoom and scroll.
  TransformationController canvasTransform(WidgetTester tester) =>
      tester.widget<CanvasHud>(find.byType(CanvasHud)).transformationController;

  /// Where [point] on the screen goes when the canvas's matrix changes from
  /// [before] to [after]: back into the canvas, then out again. The canvas
  /// starts at the top left of its area (where the zoom pill layer is).
  Offset moved(
    WidgetTester tester,
    Offset point,
    Matrix4 before,
    Matrix4 after,
  ) {
    final origin = tester.getTopLeft(find.byType(CanvasHud));
    final scene = MatrixUtils.transformPoint(
      Matrix4.inverted(before),
      point - origin,
    );
    return origin + MatrixUtils.transformPoint(after, scene);
  }

  /// Zoom 2 with [point] (on the screen, under [before]) at [at] in the
  /// viewer, inside the canvas's own limits (x in -1200..0, y at most 0).
  Matrix4 zoomTo(WidgetTester tester, Offset point, Matrix4 before, Offset at) {
    final origin = tester.getTopLeft(find.byType(CanvasHud));
    final scene = MatrixUtils.transformPoint(
      Matrix4.inverted(before),
      point - origin,
    );
    final tx = (at.dx - 2 * scene.dx).clamp(-1200.0, 0.0);
    final ty = math.min(0.0, at.dy - 2 * scene.dy);
    return Matrix4.translationValues(tx, ty, 0)
      ..multiply(Matrix4.diagonal3Values(2, 2, 1));
  }

  testWidgets('lasso colour chip recolours the selection', (tester) async {
    final (editor, stroke, dragged) = await lassoALine(tester);

    // the bar stands 12 under the dragged rectangle, centred on it
    final bar = tester.getRect(find.byType(KitSelectionBar));
    expect(bar.top, closeTo(dragged.bottom + 12, 0.5));
    expect(bar.center.dx, closeTo(dragged.center.dx, 0.5));

    await tester.tap(find.byKey(const ValueKey('lasso-bar-colour')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kit-swatch-ffe5323e')));
    await tester.pumpAndSettle();
    expect(stroke.color, const Color(0xffe5323e));

    editor.undo();
    await tester.pump();
    expect(stroke.color, blue, reason: 'one undo puts the colour back');
    editor.cancelAutosaveAndMarkSaved();
  });

  // Final review A-1: the lasso bar changed a 읽기 전용 note.
  testWidgets('읽기 전용 lets the lasso go: no bar, no recolour, no save', (
    tester,
  ) async {
    final (editor, stroke, dragged) = await lassoALine(tester);
    editor.cancelAutosaveAndMarkSaved();
    expect(find.byType(KitLassoBar), findsOneWidget);
    final actions = actionsOf(tester);
    final context = tester.element(find.byType(Editor));
    expect(actions.run(AppActionIds.readOnly, context), isTrue);
    await tester.pumpAndSettle();
    expect(editor.inkLocked.value, isTrue);
    expect(find.byType(KitLassoBar), findsNothing);
    expect(Select.currentSelect.doneSelecting, isFalse);
    expect(actions.run(AppActionIds.recolorSelection, context), isFalse);

    // lassoed again while locked: still no bar that could change the note
    final pen = await tester.startGesture(
      dragged.topLeft,
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveTo(dragged.center);
    await pen.moveTo(dragged.bottomRight);
    await pen.up();
    await tester.pumpAndSettle();
    expect(find.byType(KitLassoBar), findsNothing);
    expect(stroke.color, blue);
    expect(editor.savingState.value, SavingState.saved);
  });

  testWidgets('the lasso bar follows zoom and scroll, and leaves with it', (
    tester,
  ) async {
    final (editor, _, dragged) = await lassoALine(tester);
    final transform = canvasTransform(tester);
    final before = transform.value.clone();
    final foot = dragged.bottomCenter;

    transform.value = zoomTo(tester, foot, before, const Offset(500, 600));
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), closeTo(2, 1e-9));
    final now = moved(tester, foot, before, transform.value);
    final bar = tester.getRect(find.byType(KitSelectionBar));
    expect(bar.top, closeTo(now.dy + 12, 0.5));
    expect(bar.center.dx, closeTo(now.dx, 0.5));

    // scrolled far down the note: the lassoed line is off the screen
    transform.value = Matrix4.translationValues(0, -20000, 0)..multiply(before);
    await tester.pumpAndSettle();
    expect(find.byType(KitSelectionBar), findsNothing);
    transform.value = before;
    await tester.pumpAndSettle();
    expect(find.byType(KitSelectionBar), findsOneWidget);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the lasso bar hides while the lassoed line is dragged', (
    tester,
  ) async {
    final (editor, stroke, dragged) = await lassoALine(tester);
    final bar = tester.getRect(find.byType(KitSelectionBar));
    final start = dragged.center;
    const by = Offset(100, 60);
    final pen = await tester.startGesture(
      start,
      kind: PointerDeviceKind.stylus,
    );
    for (var k = 1; k <= 4; k++) {
      await pen.moveTo(start + by * (k / 4));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump();
    expect(find.byType(KitSelectionBar), findsNothing);
    await pen.up();
    await tester.pumpAndSettle();
    final after = tester.getRect(find.byType(KitSelectionBar));
    expect(after.top, closeTo(bar.top + by.dy, 0.5));
    expect(after.center.dx, closeTo(bar.center.dx + by.dx, 0.5));
    expect(Select.currentSelect.selectResult.strokes, [stroke]);
    editor.cancelAutosaveAndMarkSaved();
  });

  /// The editor with the text tool in hand and the first page's text box
  /// holding 「Hello world」 with 「Hello」 chosen.
  Future<(EditorState, QuillController)> writeText(WidgetTester tester) async {
    final lastTool = stows.lastTool.value;
    addTearDown(() => stows.lastTool.value = lastTool);
    final editor = await mountEditor(tester);
    final context = tester.element(find.byType(Editor));
    expect(actionsOf(tester).run(AppActionIds.toolText, context), isTrue);
    await tester.pump();
    final quill = editor.coreInfo.pages.first.quill;
    quill.focusNode.requestFocus();
    await tester.pumpAndSettle();
    quill.controller.replaceText(
      0,
      0,
      'Hello world',
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await tester.pumpAndSettle();
    return (editor, quill.controller);
  }

  testWidgets('the text bar follows zoom and scroll, and leaves with it', (
    tester,
  ) async {
    final (editor, _) = await writeText(tester);
    final transform = canvasTransform(tester);
    final before = transform.value.clone();
    final bar = tester.getRect(find.byType(KitSelectionBar));
    // the chosen text's foot, 12 over the bar
    final foot = Offset(bar.center.dx, bar.top - 12);

    transform.value = zoomTo(tester, foot, before, const Offset(600, 500));
    await tester.pumpAndSettle();
    final now = moved(tester, foot, before, transform.value);
    expect(
      tester.getRect(find.byType(KitSelectionBar)).top,
      closeTo(now.dy + 12, 0.5),
    );

    transform.value = Matrix4.translationValues(0, -20000, 0)..multiply(before);
    await tester.pumpAndSettle();
    expect(find.byType(KitSelectionBar), findsNothing);
    // back to the first page: the note remembers where it was left
    transform.value = before;
    await tester.pumpAndSettle();
    expect(find.byType(KitSelectionBar), findsOneWidget);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a window of the text bar gives the text box back its focus', (
    tester,
  ) async {
    // the ⋯ menu asks the clipboard before it opens
    fakeClipboard(tester);
    final (editor, controller) = await writeText(tester);
    final quill = editor.coreInfo.pages.first.quill;
    expect(quill.focusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('text-bar-format')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('text-format-bold')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(1150, 1550)); // outside: closes it
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('text-format-bold')), findsNothing);

    expect(quill.focusNode.hasFocus, isTrue);
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    expect(styleOf(controller), contains(Attribute.bold.key));

    // and after a row of the ⋯ menu ran
    await tester.tap(find.byKey(const ValueKey('text-bar-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('text-highlight-more')));
    await tester.pumpAndSettle();
    expect(quill.focusNode.hasFocus, isTrue);
    expect(styleOf(controller), contains(Attribute.background.key));

    // the link window takes the keys for its field, and gives them back
    await tester.tap(find.byKey(const ValueKey('text-bar-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('text-link')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('text-link-field'));
    expect(quill.focusNode.hasFocus, isFalse, reason: 'the field has them');
    await tester.enterText(field, 'example.com');
    await tester.tap(find.byKey(const ValueKey('text-link-set')));
    await tester.pumpAndSettle();
    expect(field, findsNothing);
    expect(quill.focusNode.hasFocus, isTrue);
    expect(
      controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    expect(
      styleOf(controller)[Attribute.link.key]?.value,
      'https://example.com',
    );
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('quill simple toolbar is gone', (tester) async {
    final lastTool = stows.lastTool.value;
    addTearDown(() => stows.lastTool.value = lastTool);
    final editor = await mountEditor(tester);
    final context = tester.element(find.byType(Editor));
    expect(actionsOf(tester).run(AppActionIds.toolText, context), isTrue);
    await tester.pump();
    final quill = editor.coreInfo.pages.first.quill;
    quill.focusNode.requestFocus();
    await tester.pumpAndSettle();
    expect(editor.quillFocus.value, quill);

    expect(find.byType(QuillSimpleToolbar), findsNothing);
    expect(find.byType(KitTextBar), findsOneWidget);
    // the bar stands 12 under the caret, which is on the first page
    final textBar = tester.widget<KitTextBar>(find.byType(KitTextBar));
    final layer = tester.getTopLeft(find.byType(KitTextBar));
    final caret = textBar.caretRect.shift(layer);
    final page = editor.coreInfo.pages.first.renderBox!;
    final pageRect = page.localToGlobal(Offset.zero) & page.size;
    expect(pageRect.contains(caret.center), isTrue, reason: '$caret');
    final bar = tester.getRect(find.byType(KitSelectionBar));
    expect(bar.top, closeTo(caret.bottom + 12, 0.5));
    editor.cancelAutosaveAndMarkSaved();
  });
}
