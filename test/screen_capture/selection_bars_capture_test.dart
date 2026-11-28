import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/inner_canvas.dart';
import 'package:saber/components/ink_ui/selection_bars/kit_lasso_bar.dart';
import 'package:saber/components/ink_ui/selection_bars/kit_text_bar.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:sbn/quill_styles.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the text box and lasso bars (Task 15) to
/// build/screen-review/t15/app-t15-*.png with the app's fonts at device
/// pixel ratio 2, on a 760 x 760 page like the preview's 1-2 stage
/// (ref-t15-*.png beside them). The text bar starts at the preview bar's
/// left (96) and top (150); the lasso bar stands under the preview's lassoed
/// area (222, 62, 230 x 142). Runs only with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t15');
const _latin = captureLatin;
const _korean = captureKorean;

Future<void> _loadFonts() async {
  await loadCaptureFonts();
  // the text box's own font
  final neucha = FontLoader('Neucha')
    ..addFont(
      Future.value(
        ByteData.sublistView(
          File('assets/google_fonts/Neucha/Neucha-Regular.ttf')
              .readAsBytesSync(),
        ),
      ),
    );
  await neucha.load();
  // the format window's I (Georgia, as the preview asks; Windows has it)
  final georgia = FontLoader('Georgia');
  for (final file in ['georgia', 'georgiab', 'georgiai', 'georgiaz']) {
    final font = File('C:/Windows/Fonts/$file.ttf');
    if (!font.existsSync()) continue;
    georgia.addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
  }
  await georgia.load();
}

/// The preview's `.kpaper`: `--paper` with a 1px `--paper-grid` line every 22.
class _Paper extends CustomPainter {
  const new();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfffbf8ef),
    );
    final grid = Paint()..color = const Color(0xffece4cd);
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 22) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), grid);
    }
  }

  @override
  bool shouldRepaint(_Paper old) => false;
}

void main() {
  FlavorConfig.setup();

  /// The text bar is 368 wide without the AI slot: a caret centred 184 past
  /// the preview's left 96, its foot 12 over the preview's top 150.
  const caret = Rect.fromLTWH(96 + 184 - 1, 108, 2, 30);
  const lassoed = Rect.fromLTWH(222, 62, 230, 142);

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Widget bar,
    Future<void> Function()? then,
    Color? page,
    Widget? under,
  }) async {
    await tester.runAsync(_loadFonts);
    const size = Size(760, 760);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // the clipboard holds text (the preview's 「글자 있음」)
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          theme: ThemeData(
            fontFamily: _latin,
            fontFamilyFallback: const [_korean],
          ),
          home: Material(
            child: Stack(
              children: [
                Positioned.fill(
                  child: page == null
                      ? const CustomPaint(painter: _Paper())
                      : ColoredBox(color: page),
                ),
                ?under,
                Positioned.fill(child: bar),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await then?.call();
    await tester.pumpAndSettle();
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
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await object.toImage(pixelRatio: 2);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        Directory(_outDir).createSync(recursive: true);
        File('$_outDir/app-t15-$name.png')
            .writeAsBytesSync(png.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = true;
    }
    expect(tester.takeException(), isNull);
  }

  /// The preview's text: 「스케일 학습 정리」 at 24, the caret at its end.
  QuillController text({bool bullet = false, bool chosen = false}) {
    final controller = QuillController(
      document: Document.fromJson([
        {
          'insert': '스케일 학습 정리',
          'attributes': {'size': '24'},
        },
        {
          'insert': '\n',
          if (bullet) 'attributes': {'list': 'bullet'},
        },
      ]),
      // chosen: 「학습」 (the link row needs chosen text)
      selection: chosen
          ? const TextSelection(baseOffset: 4, extentOffset: 6)
          : const TextSelection.collapsed(offset: 9),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<void> Function() tap(WidgetTester tester, List<String> keys) =>
      () async {
        for (final key in keys) {
          await tester.tap(find.byKey(ValueKey(key)));
          await tester.pumpAndSettle();
        }
      };

  /// Highlighted text on the inverted (dark) page, as the editor draws the
  /// text box there: white letters, the highlight as it is ([fixed] false)
  /// or with its lightness inverted ([InnerCanvas.invertedHighlight]).
  Widget darkText(QuillController controller, {required bool fixed}) {
    final focus = FocusNode();
    final scroll = ScrollController();
    addTearDown(focus.dispose);
    addTearDown(scroll.dispose);
    return Positioned(
      left: 96,
      top: 40,
      width: 560,
      height: 70,
      child: QuillEditor(
        controller: controller,
        focusNode: focus,
        scrollController: scroll,
        config: QuillEditorConfig(
          customStyles: SaberQuillStyles.get(
            invert: true,
            secondary: Colors.blue,
            lineHeight: 40,
          ),
          customStyleBuilder: fixed ? InnerCanvas.invertedHighlight : null,
          scrollable: false,
          expands: true,
          showCursor: false,
        ),
      ),
    );
  }

  QuillController highlighted() {
    final controller = QuillController(
      document: Document.fromJson([
        {
          'insert': 'Scale notes',
          'attributes': {'background': '#fffdffb6'},
        },
        {'insert': ' and plain text\n'},
      ]),
      selection: const TextSelection.collapsed(offset: 5),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('selection bar captures', skip: !_capture, () {
    for (final (name, fixed) in const [
      ('text-highlight-dark-before', false),
      ('text-highlight-dark', true),
    ]) {
      testWidgets(name, (tester) {
        final controller = highlighted();
        return shoot(
          tester,
          name,
          page: InnerCanvas.defaultBackgroundColor.withInversion(),
          under: darkText(controller, fixed: fixed),
          bar: KitTextBar(controller: controller, caretRect: caret),
        );
      });
    }
    for (final (name, keys) in const [
      ('text-bar', <String>[]),
      ('text-format', ['text-bar-format']),
      ('text-size', ['text-bar-size']),
      ('text-colour', ['text-bar-colour']),
      ('text-more', ['text-bar-more']),
      ('text-more-format', ['text-bar-more', 'text-format-more']),
    ]) {
      testWidgets(
        name,
        (tester) => shoot(
          tester,
          name,
          bar: KitTextBar(controller: text(), caretRect: caret),
          then: tap(tester, keys),
        ),
      );
    }
    // the link window, with an address typed (no preview drawing of this
    // window; compare with `.pmlk`)
    testWidgets(
      'text-link',
      (tester) => shoot(
        tester,
        'text-link',
        bar: KitTextBar(controller: text(chosen: true), caretRect: caret),
        then: () async {
          await tap(tester, ['text-bar-more', 'text-link'])();
          await tester.enterText(
            find.byKey(const ValueKey('text-link-field')),
            'example.org/paper',
          );
        },
      ),
    );
    testWidgets(
      'text-list',
      (tester) => shoot(
        tester,
        'text-list',
        bar: KitTextBar(controller: text(bullet: true), caretRect: caret),
        then: tap(tester, ['text-bar-list']),
      ),
    );
    for (final (name, keys) in const [
      ('lasso', <String>[]),
      ('lasso-colour', ['lasso-bar-colour']),
      ('lasso-more', ['lasso-bar-more']),
    ]) {
      testWidgets(
        name,
        (tester) => shoot(
          tester,
          name,
          bar: AppActionScope(
            actions: AppActionRegistry()
              ..publish(Object(), [
                for (final id in const [
                  AppActionIds.duplicateSelection,
                  AppActionIds.deleteSelection,
                  AppActionIds.linkSelection,
                ])
                  AppAction(
                    id: id,
                    label: id,
                    icon: KitIconName.dup,
                    run: (_) {},
                  ),
              ]),
            child: KitLassoBar(
              recolorSelection: (_) {},
              selectionRect: lassoed,
              selectionColor: const Color(0xfff7d708),
            ),
          ),
          then: tap(tester, keys),
        ),
      );
    }
  });
}
