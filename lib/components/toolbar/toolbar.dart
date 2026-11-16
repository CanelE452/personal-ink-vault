import 'dart:async';
import 'dart:io';

import 'package:collapsible/collapsible.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:keybinder/keybinder.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:saber/components/theming/adaptive_icon.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/components/theming/uni_icon.dart';
import 'package:saber/components/toolbar/color_bar.dart';
import 'package:saber/components/toolbar/export_dialog.dart';
import 'package:saber/components/toolbar/ink_width_presets.dart';
import 'package:saber/components/toolbar/selection_bar.dart';
import 'package:saber/components/toolbar/size_picker.dart';
import 'package:saber/components/toolbar/tool_panels.dart';
import 'package:saber/components/toolbar/toolbar_button.dart';
import 'package:saber/components/toolbar/toolbar_layout.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/select.dart';

class Toolbar extends StatefulWidget {
  const new({
    super.key,
    required this.alignment,
    required this.readOnly,
    required this.setTool,
    required this.currentTool,
    required this.setColor,
    required this.quillFocus,
    required this.textEditing,
    required this.toggleTextEditing,
    required this.undo,
    required this.isUndoPossible,
    required this.redo,
    required this.isRedoPossible,
    required this.toggleFingerDrawing,
    required this.pickPhoto,
    required this.paste,
    required this.duplicateSelection,
    required this.deleteSelection,
    required this.exportAsSba,
    required this.exportAsPdf,
    required this.exportAsPng,
    this.exportTitle = '',
    this.leading = const [],
    this.hostItems = const {},
    this.trailing = const [],
  });

  final AxisDirection alignment;
  final bool readOnly;

  final ValueChanged<Tool> setTool;
  final Tool currentTool;
  final ValueChanged<Color> setColor;

  final ValueNotifier<QuillStruct?> quillFocus;
  final bool textEditing;
  final VoidCallback toggleTextEditing;

  final VoidCallback undo;
  final bool isUndoPossible;
  final VoidCallback redo;
  final bool isRedoPossible;

  final VoidCallback toggleFingerDrawing;

  final VoidCallback pickPhoto;

  final VoidCallback paste;

  final VoidCallback duplicateSelection;
  final VoidCallback deleteSelection;

  final ExportFunction? exportAsSba;
  final ExportFunction? exportAsPdf;
  final ExportFunction? exportAsPng;

  /// The note's name, the export dialog's default file name.
  final String exportTitle;

  /// Placed before the tools, for example the handle that moves the toolbar.
  final List<Widget> leading;

  /// The host's own toolbar items (the page actions), by [ToolbarItem.id];
  /// they are ordered and hidden like the toolbar's tools.
  final Map<String, Widget> hostItems;

  /// Always placed last, for example the toolbar settings button.
  final List<Widget> trailing;

  @override
  State<Toolbar> createState() => _ToolbarState();

  static const _buttonPaddingHorizontal = EdgeInsets.symmetric(horizontal: 6);
  static const _buttonPaddingVertical = EdgeInsets.symmetric(vertical: 6);
}

class _ToolbarState extends State<Toolbar> {
  ValueNotifier<bool> showColorOptions = ValueNotifier(false);
  ValueNotifier<ToolOptions> toolOptionsType = ValueNotifier(ToolOptions.hide);

  /// The tool whose panel is open ('pen', 'pencil', 'highlighter', 'eraser'
  /// or 'select'), if any. Tapping the chosen tool again toggles it.
  final _openPanel = ValueNotifier<String?>(null);

  /// The toolbar and the open panel share this tap group, so taps on the
  /// toolbar keep the panel open while taps on the page close it.
  final _panelGroup = Object();

  void _togglePanel(String id) =>
      _openPanel.value = _openPanel.value == id ? null : id;

  // Keyed, so a button keeps its own panel when the toolbar layout changes.
  Widget _withPanel(String id, Widget button, WidgetBuilder panel) =>
      ToolPanelAnchor(
        key: ValueKey('tool-panel-anchor-$id'),
        id: id,
        openPanel: _openPanel,
        edge: widget.alignment,
        groupId: _panelGroup,
        panel: panel,
        child: button,
      );

  @override
  void initState() {
    _assignKeybindings();

    DynamicMaterialApp.addFullscreenListener(_setState);

    super.initState();
  }

  void _setState() => setState(() {});

  @override
  void didUpdateWidget(Toolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A panel belongs to the edge it opened from.
    if (oldWidget.alignment != widget.alignment) _openPanel.value = null;
  }

  Keybinding? _ctrlF;
  Keybinding? _ctrlE;
  Keybinding? _ctrlC;
  Keybinding? _ctrlShiftS;
  Keybinding? _f11;
  Keybinding? _ctrlV;
  void _assignKeybindings() {
    _ctrlF = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyF),
    ], inclusive: true);
    _ctrlE = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyE),
    ], inclusive: true);
    _ctrlC = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyC),
    ], inclusive: true);
    _ctrlShiftS = Keybinding([
      KeyCode.ctrl,
      KeyCode.shift,
      KeyCode.from(LogicalKeyboardKey.keyS),
    ], inclusive: true);
    _f11 = Keybinding([KeyCode.from(LogicalKeyboardKey.f11)], inclusive: true);
    _ctrlV = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyV),
    ], inclusive: true);

    Keybinder.bind(_ctrlF!, widget.toggleFingerDrawing);
    Keybinder.bind(_ctrlE!, toggleEraser);
    Keybinder.bind(_ctrlC!, toggleColorOptions);
    Keybinder.bind(_ctrlShiftS!, openExportDialog);
    Keybinder.bind(_f11!, toggleFullscreen);
    Keybinder.bind(_ctrlV!, widget.paste);
  }

  void _removeKeybindings() {
    if (_ctrlF != null) Keybinder.remove(_ctrlF!);
    if (_ctrlE != null) Keybinder.remove(_ctrlE!);
    if (_ctrlC != null) Keybinder.remove(_ctrlC!);
    if (_ctrlShiftS != null) Keybinder.remove(_ctrlShiftS!);
    if (_f11 != null) Keybinder.remove(_f11!);
    if (_ctrlV != null) Keybinder.remove(_ctrlV!);
  }

  void toggleEraser() {
    _openPanel.value = null;
    toolOptionsType.value = .hide;
    widget.setTool(Eraser()); // this toggles eraser
  }

  void toggleColorOptions() {
    showColorOptions.value = !showColorOptions.value;
  }

  void openExportDialog() {
    if (widget.readOnly) return;
    _openPanel.value = null;
    unawaited(
      showExportDialog(
        context,
        title: widget.exportTitle,
        pdf: widget.exportAsPdf,
        image: widget.exportAsPng,
        original: widget.exportAsSba,
      ),
    );
  }

  void toggleFullscreen() async {
    DynamicMaterialApp.setFullscreen(
      !DynamicMaterialApp.isFullscreen,
      updateSystem: true,
    );
  }

  void _setPenSize(Pen pen, double size) {
    if (widget.readOnly ||
        !identical(widget.currentTool, pen) ||
        pen.options.size == size) {
      return;
    }
    setState(() => pen.setSize(size));
  }

  /// The pen button's pen: the one in hand when it is a pen kind (whatever
  /// put it there), otherwise the pen kind chosen last.
  Pen get _penButtonPen => Pen.isPenFamily(widget.currentTool)
      ? widget.currentTool as Pen
      : Pen.currentPenFamily;

  /// The pen panel, shared by the pen button and the separate pencil button.
  Widget _penPanel() => PenPanel(
    getPen: () => _penButtonPen,
    setTool: widget.setTool,
    setSize: _setPenSize,
    setColor: widget.setColor,
    openColors: _openColorsFromPanel,
  );

  /// The chosen swatch tapped again in a panel: the full palette opens under
  /// the toolbar, where the panel would cover it, so the panel closes.
  void _openColorsFromPanel() {
    _openPanel.value = null;
    showColorOptions.value = true;
  }

  void _applyPenBoxEntry(PenBoxEntry entry) {
    _openPanel.value = null;
    toolOptionsType.value = .hide;
    widget.setTool(entry.createPen());
    // Through the editor, which adds the highlighter's transparency.
    widget.setColor(Color(entry.color));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        _buildToolbar(context, constraints.maxWidth),
  );

  Widget _buildToolbar(BuildContext context, double availableWidth) {
    final colorScheme = ColorScheme.of(context);

    final brightness = Theme.brightnessOf(context);
    final invert = stows.editorAutoInvert.value && brightness == .dark;

    final isToolbarVertical =
        widget.alignment == AxisDirection.left ||
        widget.alignment == AxisDirection.right;

    final buttonPadding = isToolbarVertical
        ? Toolbar._buttonPaddingVertical
        : Toolbar._buttonPaddingHorizontal;

    final currentColor = switch (widget.currentTool) {
      final Pen pen => pen.color,
      final Select select => select.getDominantStrokeColor(),
      _ => null,
    };

    if (widget.currentTool == Select.currentSelect) {
      // Enable selection bar only when selection is done
      toolOptionsType.value = Select.currentSelect.doneSelecting
          ? .select
          : .hide;
    }

    final bars = <Widget>[
      ValueListenableBuilder(
        valueListenable: toolOptionsType,
        builder: (context, toolOptionsType, _) {
          return Collapsible(
            axis: isToolbarVertical
                ? CollapsibleAxis.horizontal
                : CollapsibleAxis.vertical,
            maintainState: true,
            collapsed: toolOptionsType == .hide,
            child: switch (toolOptionsType) {
              .hide => const SizedBox.square(dimension: SizePicker.smallLength),
              .select => SelectionBar(
                duplicateSelection: widget.duplicateSelection,
                deleteSelection: widget.deleteSelection,
              ),
            },
          );
        },
      ),
      ValueListenableBuilder(
        valueListenable: showColorOptions,
        builder: (context, showColorOptions, child) {
          return Collapsible(
            axis: isToolbarVertical
                ? CollapsibleAxis.horizontal
                : CollapsibleAxis.vertical,
            maintainState: true,
            collapsed: !showColorOptions,
            child: child!,
          );
        },
        child: ColorBar(
          axis: isToolbarVertical ? Axis.vertical : Axis.horizontal,
          setColor: widget.setColor,
          currentColor: currentColor,
          invert: invert,
        ),
      ),
      ValueListenableBuilder(
        valueListenable: widget.quillFocus,
        builder: (context, quill, _) {
          final baseButtonStyle =
              IconButtonTheme.of(context).style ?? const ButtonStyle();

          final iconTheme = QuillIconTheme(
            iconButtonUnselectedData: IconButtonData(
              style: baseButtonStyle.copyWith(
                backgroundColor: WidgetStateProperty.all(Colors.transparent),
                foregroundColor: WidgetStateProperty.all(colorScheme.primary),
              ),
            ),
            iconButtonSelectedData: IconButtonData(
              style: baseButtonStyle.copyWith(
                backgroundColor: WidgetStateProperty.all(colorScheme.primary),
                foregroundColor: WidgetStateProperty.all(colorScheme.onPrimary),
              ),
            ),
          );
          return Collapsible(
            axis: isToolbarVertical
                ? CollapsibleAxis.horizontal
                : CollapsibleAxis.vertical,
            maintainState: false,
            collapsed: !widget.textEditing || quill == null,
            child: quill != null
                ? QuillSimpleToolbar(
                    controller: quill.controller,
                    config: QuillSimpleToolbarConfig(
                      axis: isToolbarVertical ? Axis.vertical : Axis.horizontal,
                      buttonOptions: QuillSimpleToolbarButtonOptions(
                        base: QuillToolbarBaseButtonOptions(
                          iconTheme: iconTheme,
                        ),
                      ),
                      // scrollable on Android and iOS
                      multiRowsDisplay: !Platform.isAndroid && !Platform.isIOS,
                      showUndo: false,
                      showRedo: false,
                      showFontSize: false,
                      showFontFamily: false,
                      showClearFormat: false,
                    ),
                  )
                : const SizedBox.shrink(),
          );
        },
      ),
      Padding(
        padding: const .all(4),
        child: ValueListenableBuilder(
          valueListenable: stows.pageToolbarLayout,
          builder: (context, stored, _) {
            final layout = ToolbarLayout.decode(pageToolbarItems, stored);
            final items = _mainItems(
              layout: layout,
              isToolbarVertical: isToolbarVertical,
              availableWidth: availableWidth,
              buttonPadding: buttonPadding,
              currentColor: currentColor,
              invert: invert,
            );
            // One line like StarNote: the tools scroll when they do not fit,
            // while the handle and the settings button stay at the ends.
            final axis = isToolbarVertical ? Axis.vertical : Axis.horizontal;
            return Flex(
              direction: axis,
              children: [
                ...widget.leading,
                Expanded(
                  // An open panel would stay where its button was.
                  child: NotificationListener<ScrollStartNotification>(
                    onNotification: (_) {
                      _openPanel.value = null;
                      return false;
                    },
                    child: SingleChildScrollView(
                      key: const ValueKey('toolbar-scroll'),
                      scrollDirection: axis,
                      child: Flex(
                        direction: axis,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final id in layout.shownIds) ?items[id],
                        ],
                      ),
                    ),
                  ),
                ),
                ...widget.trailing,
              ],
            );
          },
        ),
      ),
    ];

    return TapRegion(
      groupId: _panelGroup,
      child: Flex(
        direction: isToolbarVertical ? Axis.horizontal : Axis.vertical,
        textDirection: switch (widget.alignment) {
          AxisDirection.left => .rtl,
          AxisDirection.right => .ltr,
          _ => null,
        },
        verticalDirection: switch (widget.alignment) {
          AxisDirection.down => VerticalDirection.down,
          AxisDirection.up => VerticalDirection.up,
          _ => VerticalDirection.down,
        },
        children: bars,
      ),
    );
  }

  /// The toolbar's own tools and the host's items, by [ToolbarItem.id]; the
  /// user's [ToolbarLayout] picks and orders them.
  Map<String, Widget> _mainItems({
    required ToolbarLayout layout,
    required bool isToolbarVertical,
    required double availableWidth,
    required EdgeInsets buttonPadding,
    required Color? currentColor,
    required bool invert,
  }) {
    final colorScheme = ColorScheme.of(context);
    final axis = isToolbarVertical ? Axis.vertical : Axis.horizontal;
    String label(String id) => layout.labelOf(id);
    // StarNote's toolbar shows the highlighter's own colours while it is in
    // hand.
    final quickColors = widget.currentTool is Highlighter
        ? highlighterQuickColors
        : toolbarQuickColors;
    return {
      'undo': ToolbarIconButton(
        tooltip: label('undo'),
        enabled: !widget.readOnly && widget.isUndoPossible,
        onPressed: widget.undo,
        padding: buttonPadding,
        child: const AdaptiveIcon(
          icon: Icons.undo,
          cupertinoIcon: CupertinoIcons.arrow_uturn_left,
        ),
      ),
      'redo': ToolbarIconButton(
        tooltip: label('redo'),
        enabled: !widget.readOnly && widget.isRedoPossible,
        onPressed: widget.redo,
        padding: buttonPadding,
        child: const AdaptiveIcon(
          icon: Icons.redo,
          cupertinoIcon: CupertinoIcons.arrow_uturn_right,
        ),
      ),
      // Tapping the chosen tool again opens its panel (StarNote's tool panels).
      // The pen button holds every pen kind, the pencil included, like
      // StarNote's pen; it shows and picks the kind chosen last.
      'pen': _withPanel(
        'pen',
        ToolbarIconButton(
          tooltip: label('pen'),
          selected: Pen.isPenFamily(widget.currentTool),
          enabled: !widget.readOnly,
          onPressed: () {
            if (Pen.isPenFamily(widget.currentTool)) {
              _togglePanel('pen');
            } else {
              _openPanel.value = null;
              toolOptionsType.value = .hide;
              widget.setTool(_penButtonPen);
            }
          },
          padding: buttonPadding,
          child: UniIcon(_penButtonPen.icon, size: 16),
        ),
        (_) => _penPanel(),
      ),
      'pencil': _withPanel(
        'pencil',
        ToolbarIconButton(
          tooltip: label('pencil'),
          selected: widget.currentTool == Pencil.currentPencil,
          enabled: !widget.readOnly,
          onPressed: () {
            if (widget.currentTool == Pencil.currentPencil) {
              _togglePanel('pencil');
            } else {
              _openPanel.value = null;
              toolOptionsType.value = .hide;
              widget.setTool(Pencil.currentPencil);
            }
          },
          padding: buttonPadding,
          child: const FaIcon(Pencil.pencilIcon, size: 16),
        ),
        (_) => _penPanel(),
      ),
      'highlighter': _withPanel(
        'highlighter',
        ToolbarIconButton(
          tooltip: label('highlighter'),
          selected: widget.currentTool == Highlighter.currentHighlighter,
          enabled: !widget.readOnly,
          onPressed: () {
            if (widget.currentTool == Highlighter.currentHighlighter) {
              _togglePanel('highlighter');
            } else {
              _openPanel.value = null;
              toolOptionsType.value = .hide;
              widget.setTool(Highlighter.currentHighlighter);
            }
          },
          padding: buttonPadding,
          child: const FaIcon(Highlighter.highlighterIcon, size: 16),
        ),
        (_) => HighlighterPanel(
          getPen: () => Highlighter.currentHighlighter,
          setSize: _setPenSize,
          setColor: widget.setColor,
          openColors: _openColorsFromPanel,
        ),
      ),
      // A second tap opens the panel; Ctrl+E (toggleEraser) still switches
      // back to the previous tool.
      'eraser': _withPanel(
        'eraser',
        ToolbarIconButton(
          tooltip: label('eraser'),
          selected: widget.currentTool is Eraser,
          enabled: !widget.readOnly,
          onPressed: () {
            if (widget.currentTool is Eraser) {
              _togglePanel('eraser');
            } else {
              toggleEraser();
            }
          },
          padding: buttonPadding,
          child: const FaIcon(FontAwesomeIcons.eraser, size: 16),
        ),
        (_) => const EraserPanel(),
      ),
      'select': _withPanel(
        'select',
        ToolbarIconButton(
          tooltip: label('select'),
          selected: widget.currentTool is Select,
          enabled: !widget.readOnly,
          onPressed: () {
            if (widget.currentTool is Select) {
              _togglePanel('select');
            } else {
              _openPanel.value = null;
              toolOptionsType.value = .hide;
              widget.setTool(Select.currentSelect);
            }
          },
          padding: buttonPadding,
          child: Icon(
            CupertinoIcons.lasso,
            shadows: !widget.readOnly
                ? [
                    BoxShadow(
                      color: colorScheme.primary,
                      blurRadius: 0.1,
                      spreadRadius: 10,
                      blurStyle: BlurStyle.solid,
                    ),
                  ]
                : null,
          ),
        ),
        (_) => const SelectPanel(),
      ),
      'photo': ToolbarIconButton(
        tooltip: label('photo'),
        enabled: !widget.readOnly,
        onPressed: widget.pickPhoto,
        padding: buttonPadding,
        child: const AdaptiveIcon(
          icon: Icons.photo,
          cupertinoIcon: CupertinoIcons.photo,
        ),
      ),
      'text': ToolbarIconButton(
        tooltip: label('text'),
        selected: widget.textEditing,
        enabled: !widget.readOnly,
        onPressed: widget.toggleTextEditing,
        padding: buttonPadding,
        child: const AdaptiveIcon(
          icon: Icons.text_fields,
          cupertinoIcon: CupertinoIcons.text_cursor,
        ),
      ),
      'colors': Flex(
        key: const ValueKey('toolbar-colors'),
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, value) in quickColors.indexed)
            _quickColor(index, Color(value), currentColor, invert),
          ValueListenableBuilder(
            valueListenable: showColorOptions,
            builder: (context, showColorOptions, child) {
              return ToolbarIconButton(
                tooltip: '색 더보기',
                selected: showColorOptions,
                enabled: !widget.readOnly,
                onPressed: toggleColorOptions,
                padding: buttonPadding,
                child: child!,
              );
            },
            child: currentColor != null &&
                    !quickColors.contains(
                      currentColor.withValues(alpha: 1).toARGB32(),
                    )
                ? Container(
                    key: const ValueKey('toolbar-current-color'),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: currentColor
                          .withInversion(invert)
                          .withValues(alpha: 1),
                      shape: .circle,
                      border: Border.all(color: colorScheme.primary, width: 2),
                    ),
                  )
                : const Icon(Icons.palette_outlined),
          ),
        ],
      ),
      // The pens kept with "펜박스에 추가" (the star at the end of StarNote's
      // colour row).
      'penBox': _withPanel(
        'penBox',
        ToolbarIconButton(
          key: const ValueKey('toolbar-pen-box'),
          tooltip: label('penBox'),
          enabled: !widget.readOnly,
          onPressed: () => _togglePanel('penBox'),
          padding: buttonPadding,
          child: const Icon(Icons.star_border),
        ),
        (_) => PenBoxPanel(apply: _applyPenBoxEntry),
      ),
      if (widget.currentTool case final Pen pen
          when isToolbarVertical || availableWidth >= 700)
        if (pen.sizePresets case final widths?)
          'widths': InkWidthPresets(
            key: const ValueKey('toolbar-quick-ink-widths'),
            widths: widths,
            selectedWidth: pen.options.size,
            onSelected: widget.readOnly
                ? null
                : (size) => _setPenSize(pen, size),
            widthLabel: label('widths'),
            axis: axis,
          ),
      ...widget.hostItems,
      if (!stows.hideFingerDrawingToggle.value)
        'finger': ValueListenableBuilder(
          valueListenable: stows.editorFingerDrawing,
          builder: (context, value, child) {
            return ToolbarIconButton(
              tooltip: label('finger'),
              selected: value,
              enabled: !widget.readOnly,
              onPressed: widget.toggleFingerDrawing,
              padding: buttonPadding,
              child: const Icon(CupertinoIcons.hand_draw),
            );
          },
        ),
      'fullscreen': ToolbarIconButton(
        tooltip: label('fullscreen'),
        selected: DynamicMaterialApp.isFullscreen,
        enabled: !widget.readOnly,
        onPressed: toggleFullscreen,
        padding: buttonPadding,
        child: AdaptiveIcon(
          icon: DynamicMaterialApp.isFullscreen
              ? Icons.fullscreen_exit
              : Icons.fullscreen,
          cupertinoIcon: DynamicMaterialApp.isFullscreen
              ? CupertinoIcons.fullscreen_exit
              : CupertinoIcons.fullscreen,
        ),
      ),
      'laser': ToolbarIconButton(
        tooltip: label('laser'),
        selected: widget.currentTool == LaserPointer.currentLaserPointer,
        enabled: true, // even in read-only mode
        onPressed: () {
          toolOptionsType.value = .hide;
          widget.setTool(LaserPointer.currentLaserPointer);
        },
        padding: buttonPadding,
        child: const Icon(Symbols.stylus_laser_pointer),
      ),
      'export': ToolbarIconButton(
        tooltip: label('export'),
        enabled: !widget.readOnly,
        onPressed: openExportDialog,
        padding: buttonPadding,
        child: const AdaptiveIcon(
          icon: Icons.share,
          cupertinoIcon: CupertinoIcons.share,
        ),
      ),
    };
  }

  /// One of the five colours always shown in the toolbar.
  Widget _quickColor(int index, Color color, Color? currentColor, bool invert) {
    final selected =
        currentColor != null &&
        currentColor.withValues(alpha: 1).toARGB32() == color.toARGB32();
    final colorScheme = ColorScheme.of(context);
    return Tooltip(
      message: '색 ${index + 1}',
      child: InkResponse(
        key: ValueKey('toolbar-color-$index'),
        onTap: widget.readOnly ? null : () => widget.setColor(color),
        radius: 20,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color.withInversion(invert),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? colorScheme.primary : Colors.transparent,
                width: 3,
              ),
            ),
            child: selected
                ? const Icon(Icons.check, size: 14, color: Colors.white)
                : null,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    DynamicMaterialApp.removeFullscreenListener(_setState);
    DynamicMaterialApp.setFullscreen(false, updateSystem: true);

    _removeKeybindings();
    _openPanel.dispose();
    super.dispose();
  }
}

/// The strip under the toolbar: nothing, or the selection's actions. The pen
/// options moved to the tool panels.
enum ToolOptions { hide, select }
