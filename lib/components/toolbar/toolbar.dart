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
    this.linkSelection,
    required this.exportAsSba,
    required this.exportAsPdf,
    required this.exportAsPng,
    this.exportTitle = '',
    this.leading = const [],
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
  final VoidCallback? linkSelection;

  final ExportFunction? exportAsSba;
  final ExportFunction? exportAsPdf;
  final ExportFunction? exportAsPng;

  /// The note's name, the export dialog's default file name.
  final String exportTitle;

  /// Placed before the tools, for example the handle that moves the toolbar.
  final List<Widget> leading;

  /// Always placed last.
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
  Widget build(BuildContext context) => _buildToolbar(context);

  Widget _buildToolbar(BuildContext context) {
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
                linkSelection: widget.linkSelection,
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
          builder: (context, stored, _) => _mainBar(
            layout: ToolbarLayout.decode(pageToolbarItems, stored),
            isToolbarVertical: isToolbarVertical,
            buttonPadding: buttonPadding,
            currentColor: currentColor,
            invert: invert,
          ),
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

  /// StarNote's tool bar (view_tool_bar_container): undo and redo, the tools
  /// in the user's order, then the chosen tool's values. The tools and the
  /// values scroll apart, like StarNote's.
  Widget _mainBar({
    required ToolbarLayout layout,
    required bool isToolbarVertical,
    required EdgeInsets buttonPadding,
    required Color? currentColor,
    required bool invert,
  }) {
    final axis = isToolbarVertical ? Axis.vertical : Axis.horizontal;
    final tools = _toolItems(layout: layout, buttonPadding: buttonPadding);
    final params = _paramItems(
      axis: axis,
      buttonPadding: buttonPadding,
      currentColor: currentColor,
      invert: invert,
    );
    // An open panel would stay where its button was. Only this part's own
    // scrolling counts: an open panel hangs below its button (an
    // OverlayPortal), so the panel's own scrolling reaches here too.
    Widget scroll(String key, List<Widget> children) =>
        NotificationListener<ScrollStartNotification>(
          onNotification: (notification) {
            if (notification.depth == 0) _openPanel.value = null;
            return false;
          },
          child: SingleChildScrollView(
            key: ValueKey(key),
            scrollDirection: axis,
            child: Flex(
              direction: axis,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        );
    return Flex(
      direction: axis,
      children: [
        ...widget.leading,
        _undoRedo(axis, buttonPadding),
        _sectionDivider(axis),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // What the handle, undo and redo leave: the tools take what
              // they need of it up to a little over half, so the values
              // always have room.
              final toolsExtent =
                  (isToolbarVertical
                      ? constraints.maxHeight
                      : constraints.maxWidth) *
                  .55;
              return Flex(
                direction: axis,
                children: [
                  ConstrainedBox(
                    constraints: isToolbarVertical
                        ? BoxConstraints(maxHeight: toolsExtent)
                        : BoxConstraints(maxWidth: toolsExtent),
                    child: scroll('toolbar-tools-scroll', [
                      for (final id in layout.shownIds) ?tools[id],
                    ]),
                  ),
                  _sectionDivider(axis),
                  Expanded(child: scroll('toolbar-params-scroll', params)),
                ],
              );
            },
          ),
        ),
        ...widget.trailing,
        // Full screen hides the function row with its 전체 화면 shortcut.
        if (DynamicMaterialApp.isFullscreen)
          ToolbarIconButton(
            key: const ValueKey('toolbar-exit-fullscreen'),
            tooltip: '전체 화면 끝내기',
            onPressed: toggleFullscreen,
            padding: buttonPadding,
            child: const AdaptiveIcon(
              icon: Icons.fullscreen_exit,
              cupertinoIcon: CupertinoIcons.fullscreen_exit,
            ),
          ),
      ],
    );
  }

  /// Undo and redo, kept together before the tools (StarNote's
  /// ll_undo_redo_container).
  Widget _undoRedo(Axis axis, EdgeInsets buttonPadding) => Flex(
    key: const ValueKey('toolbar-undo-redo'),
    direction: axis,
    mainAxisSize: MainAxisSize.min,
    children: [
      ToolbarIconButton(
        tooltip: '실행 취소',
        enabled: !widget.readOnly && widget.isUndoPossible,
        onPressed: widget.undo,
        padding: buttonPadding,
        child: const AdaptiveIcon(
          icon: Icons.undo,
          cupertinoIcon: CupertinoIcons.arrow_uturn_left,
        ),
      ),
      _sectionDivider(axis, short: true),
      ToolbarIconButton(
        tooltip: '다시 실행',
        enabled: !widget.readOnly && widget.isRedoPossible,
        onPressed: widget.redo,
        padding: buttonPadding,
        child: const AdaptiveIcon(
          icon: Icons.redo,
          cupertinoIcon: CupertinoIcons.arrow_uturn_right,
        ),
      ),
    ],
  );

  /// The thin line between the toolbar's parts.
  Widget _sectionDivider(Axis axis, {bool short = false}) {
    final length = short ? 16.0 : 24.0;
    final horizontal = axis == Axis.horizontal;
    return Container(
      width: horizontal ? 0.5 : length,
      height: horizontal ? length : 0.5,
      margin: horizontal
          ? const EdgeInsets.symmetric(horizontal: 4)
          : const EdgeInsets.symmetric(vertical: 4),
      color: Theme.of(context).dividerColor,
    );
  }

  /// The tools, by [ToolbarItem.id]; the user's [ToolbarLayout] picks and
  /// orders them.
  Map<String, Widget> _toolItems({
    required ToolbarLayout layout,
    required EdgeInsets buttonPadding,
  }) {
    final colorScheme = ColorScheme.of(context);
    String label(String id) => layout.labelOf(id);
    return {
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
    };
  }

  /// The chosen tool's values (StarNote's params_container): colours, the pen
  /// box and widths for the pens and the highlighter; the eraser's modes and
  /// sizes; the lasso's shapes and the colours that recolour a selection.
  /// StarNote's pen box can be reached whatever the tool, so its star ends
  /// every tool's values.
  List<Widget> _paramItems({
    required Axis axis,
    required EdgeInsets buttonPadding,
    required Color? currentColor,
    required bool invert,
  }) => switch (widget.currentTool) {
    Eraser() => [
      ..._eraserParams(axis, buttonPadding),
      _sectionDivider(axis),
      _penBoxItem(buttonPadding),
    ],
    Select() => [
      _selectParams(axis, buttonPadding),
      _sectionDivider(axis),
      _colorItems(axis, buttonPadding, currentColor, invert),
      _penBoxItem(buttonPadding),
    ],
    final Pen pen => [
      _colorItems(axis, buttonPadding, currentColor, invert),
      _penBoxItem(buttonPadding),
      if (pen.sizePresets case final widths?)
        InkWidthPresets(
          key: const ValueKey('toolbar-quick-ink-widths'),
          widths: widths,
          selectedWidth: pen.options.size,
          onSelected: widget.readOnly
              ? null
              : (size) => _setPenSize(pen, size),
          widthLabel: '굵기',
          axis: axis,
        ),
    ],
    _ => [_penBoxItem(buttonPadding)],
  };

  /// The five colours and the palette button.
  Widget _colorItems(
    Axis axis,
    EdgeInsets buttonPadding,
    Color? currentColor,
    bool invert,
  ) {
    final colorScheme = ColorScheme.of(context);
    // StarNote's toolbar shows the highlighter's own colours while it is in
    // hand.
    final quickColors = widget.currentTool is Highlighter
        ? highlighterQuickColors
        : toolbarQuickColors;
    return Flex(
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
    );
  }

  /// The pens kept with "펜박스에 추가" (the star at the end of StarNote's
  /// colour row).
  Widget _penBoxItem(EdgeInsets buttonPadding) => _withPanel(
    'penBox',
    ToolbarIconButton(
      key: const ValueKey('toolbar-pen-box'),
      tooltip: '펜박스',
      enabled: !widget.readOnly,
      onPressed: () => _togglePanel('penBox'),
      padding: buttonPadding,
      child: const Icon(Icons.star_border),
    ),
    (_) => PenBoxPanel(apply: _applyPenBoxEntry),
  );

  /// StarNote's eraser values: its modes, then three sizes (the panel keeps
  /// the slider). Sizes do nothing for the loop, so they are off with it.
  List<Widget> _eraserParams(Axis axis, EdgeInsets buttonPadding) => [
    ValueListenableBuilder(
      valueListenable: stows.eraserMode,
      builder: (context, mode, _) => Flex(
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (key, value, tooltip) in const [
            ('toolbar-eraser-stroke', EraserMode.stroke, '스트로크 지우기'),
            ('toolbar-eraser-lasso', EraserMode.lasso, '원형 선택 지우기'),
          ])
            ToolbarIconButton(
              key: ValueKey(key),
              tooltip: tooltip,
              selected: mode == value,
              enabled: !widget.readOnly,
              onPressed: () => stows.eraserMode.value = value,
              padding: buttonPadding,
              child: EraserModeIcon(value),
            ),
          _sectionDivider(axis),
          ValueListenableBuilder(
            valueListenable: stows.eraserSize,
            builder: (context, size, _) => Flex(
              direction: axis,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (index, preset) in eraserSizePresets.indexed)
                  ToolbarIconButton(
                    key: ValueKey(
                      'toolbar-eraser-size-${preset.toStringAsFixed(0)}',
                    ),
                    tooltip: '크기 ${preset.toStringAsFixed(0)}',
                    selected: size == preset,
                    enabled: !widget.readOnly && mode == EraserMode.stroke,
                    onPressed: () => stows.eraserSize.value = preset,
                    padding: buttonPadding,
                    child: _SizeCircle(diameter: 7 + index * 5.0),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  ];

  /// The lasso's two shapes, as in StarNote's lasso values.
  Widget _selectParams(Axis axis, EdgeInsets buttonPadding) =>
      ValueListenableBuilder(
        valueListenable: stows.selectRectangle,
        builder: (context, rectangle, _) => Flex(
          direction: axis,
          mainAxisSize: MainAxisSize.min,
          children: [
            ToolbarIconButton(
              key: const ValueKey('toolbar-select-free'),
              tooltip: '자유 올가미',
              selected: !rectangle,
              enabled: !widget.readOnly,
              onPressed: () => stows.selectRectangle.value = false,
              padding: buttonPadding,
              child: const Icon(CupertinoIcons.lasso),
            ),
            ToolbarIconButton(
              key: const ValueKey('toolbar-select-rect'),
              tooltip: '사각형 올가미',
              selected: rectangle,
              enabled: !widget.readOnly,
              onPressed: () => stows.selectRectangle.value = true,
              padding: buttonPadding,
              child: const Icon(Icons.crop_square),
            ),
          ],
        ),
      );

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

/// A size choice in the toolbar: a ring as wide as the size it picks.
class _SizeCircle extends StatelessWidget {
  const new({required this.diameter});

  final double diameter;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 20,
    child: Center(
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: IconTheme.of(context).color ?? ColorScheme.of(context).onSurface,
            width: 1.5,
          ),
        ),
      ),
    ),
  );
}
