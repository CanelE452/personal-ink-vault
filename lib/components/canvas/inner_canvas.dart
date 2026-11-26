import 'package:defer_pointer/defer_pointer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:one_dollar_unistroke_recognizer/one_dollar_unistroke_recognizer.dart';
import 'package:saber/components/canvas/_canvas_background_painter.dart';
import 'package:saber/components/canvas/_canvas_painter.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/canvas_image.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/quill_styles.dart';

class InnerCanvas extends StatefulWidget {
  const new({
    super.key,
    required this.pageIndex,
    this.redrawPageListenable,
    required this.width,
    required this.height,
    this.showPageIndicator = true,
    this.textEditing = false,
    this.inkLocked = false,
    required this.coreInfo,
    required this.currentStroke,
    required this.currentStrokeDetectedShape,
    required this.currentSelection,
    this.setAsBackground,
    this.onRenderObjectChange,
    required this.currentToolIsSelect,
    this.selectionErases = false,
    required this.currentScale,
    this.linkLayer,
  });

  final int pageIndex;
  final Listenable? redrawPageListenable;
  final double width;
  final double height;
  final bool showPageIndicator;
  final bool textEditing;

  /// The editor's 「읽기 전용」: the text box and the pictures take no input.
  final bool inkLocked;
  final EditorCoreInfo coreInfo;
  final Stroke? currentStroke;
  final RecognizedUnistroke? currentStrokeDetectedShape;
  final SelectResult? currentSelection;
  final void Function(EditorImage image)? setAsBackground;
  final ValueChanged<RenderObject>? onRenderObjectChange;

  final bool currentToolIsSelect;

  /// The selection is the eraser's loop: draw it in the error colour.
  final bool selectionErases;

  final double currentScale;

  /// The page's links (a `PageLinkLayer`), over its pictures. Only the editor
  /// gives one: previews and exports draw the page without links.
  final Widget? linkLayer;

  static const defaultBackgroundColor = Color(0xFFFCFCFC);

  /// On an inverted page a text highlight is drawn with its lightness
  /// inverted, as the strokes are, so the white letters stay readable on it
  /// (a pale highlight would put white on white). The note keeps its colour.
  static TextStyle invertedHighlight(Attribute attribute) {
    final value = attribute.value;
    if (attribute.key != Attribute.background.key ||
        value is! String ||
        !value.startsWith('#')) {
      return const TextStyle();
    }
    var hex = value.substring(1);
    if (hex.length == 6) hex = 'ff$hex';
    final argb = hex.length == 8 ? int.tryParse(hex, radix: 16) : null;
    if (argb == null) return const TextStyle();
    return TextStyle(backgroundColor: Color(argb).withInversion());
  }

  @override
  State<InnerCanvas> createState() => _InnerCanvasState();
}

class _InnerCanvasState extends State<InnerCanvas> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final brightness = theme.brightness;
    final invert = stows.editorAutoInvert.value && brightness == .dark;
    final Color backgroundColor =
        widget.coreInfo.backgroundColor ?? InnerCanvas.defaultBackgroundColor;

    if (widget.coreInfo.pages.isEmpty) {
      return SizedBox(width: widget.width, height: widget.height);
    }

    final page = widget.coreInfo.pages[widget.pageIndex];

    final quillEditor = widget.coreInfo.pages.isNotEmpty
        ? QuillEditor(
            controller:
                widget.coreInfo.pages[widget.pageIndex].quill.controller,
            config: QuillEditorConfig(
              customStyles: SaberQuillStyles.get(
                invert: invert,
                secondary: colorScheme.secondary,
                lineHeight: widget.coreInfo.lineHeight,
              ),
              customStyleBuilder: invert ? InnerCanvas.invertedHighlight : null,
              scrollable: false,
              autoFocus: false,
              expands: true,
              placeholder: widget.textEditing
                  ? t.editor.quill.typeSomething
                  : null,
              showCursor: true,
              keyboardAppearance: invert ? .dark : .light,
              padding: .only(
                top: widget.coreInfo.lineHeight * 1.2,
                left: widget.coreInfo.lineHeight * 0.5,
                right: widget.coreInfo.lineHeight * 0.5,
                bottom: widget.coreInfo.lineHeight * 0.5,
              ),
              showCodeBlockLineNumbers: false,
            ),
            scrollController: ScrollController(),
            focusNode: widget.coreInfo.pages[widget.pageIndex].quill.focusNode,
          )
        : null;

    return RepaintBoundary(
      child: CustomPaint(
        painter: CanvasBackgroundPainter(
          invert: invert,
          backgroundColor: () {
            if (page.backgroundImage != null) {
              return Colors.white;
            } else {
              return backgroundColor;
            }
          }(),
          backgroundPattern: () {
            if (page.backgroundImage != null) {
              return CanvasBackgroundPattern.none;
            } else {
              return widget.coreInfo.backgroundPattern;
            }
          }(),
          lineHeight: widget.coreInfo.lineHeight,
          lineThickness: widget.coreInfo.lineThickness,
          primaryColor: colorScheme.primary,
          secondaryColor: colorScheme.secondary,
        ),
        foregroundPainter: CanvasPainter(
          repaint: widget.redrawPageListenable,
          invert: invert,
          strokes: page.strokes,
          laserStrokes: page.laserStrokes,
          currentStroke: widget.currentStroke,
          currentSelection: widget.currentSelection,
          primaryColor: widget.selectionErases
              ? colorScheme.error
              : colorScheme.primary,
          page: page,
          showPageIndicator: widget.showPageIndicator,
          pageIndex: widget.pageIndex,
          totalPages: widget.coreInfo.pages.length,
          currentScale: widget.currentScale,
          defaultTextStyle: theme.textTheme.bodyMedium!,
        ),
        isComplex: true,
        willChange: true,
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: DeferredPointerHandler(
            child: Stack(
              children: [
                if (page.backgroundImage != null)
                  CanvasImage(
                    filePath: widget.coreInfo.filePath,
                    image: page.backgroundImage!,
                    pageSize: Size(widget.width, widget.height),
                    setAsBackground: null,
                    isBackground: true,
                    readOnly: true,
                  ),
                Positioned(
                  top: 0,
                  left: 0,
                  width: widget.width,
                  height: widget.height,
                  child: IgnorePointer(
                    ignoring:
                        widget.coreInfo.readOnly ||
                        widget.inkLocked ||
                        !widget.textEditing,
                    child: quillEditor,
                  ),
                ),
                for (int i = 0; i < page.images.length; i++)
                  CanvasImage(
                    filePath: widget.coreInfo.filePath,
                    image: page.images[i],
                    pageSize: Size(widget.width, widget.height),
                    setAsBackground: widget.setAsBackground,
                    readOnly:
                        widget.coreInfo.readOnly ||
                        widget.inkLocked ||
                        !widget.currentToolIsSelect,
                    selected:
                        widget.currentSelection?.images.contains(
                          page.images[i],
                        ) ??
                        false,
                  ),
                if (widget.linkLayer case final linkLayer?)
                  Positioned.fill(child: linkLayer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
