part of 'kit_menu.dart';

// The rows of a kit menu and how one row is drawn (the window is in
// kit_menu.dart).

/// A button in the quick row of a menu: an icon with a name. [selected]
/// draws it in the accent colour (a mode that is on); not [enabled], it is
/// dimmed and takes no tap.
class KitMenuQuick {
  const new({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.enabled = true,
    this.key,
  });

  final KitIconName icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final bool enabled;
  final Key? key;
}

/// Rows under an optional small title; groups are split by a thin line.
class KitMenuGroup {
  const new({this.title, required this.rows});

  final String? title;
  final List<KitMenuRow> rows;
}

/// One row of a menu. A row does not know what its action does and does not
/// close the menu: the code that builds the menu closes it, then acts.
sealed class KitMenuRow {
  const new _({required this.icon, required this.label, this.key});

  /// [checked] puts a check at the row's end (the choice in use), [opens]
  /// a › (the row opens a window of its own). Not [enabled], the row is
  /// dimmed and takes no tap. Without [icon] the label starts at the
  /// row's padding (a submenu's plain choices, `.ksub .it`).
  static KitMenuRow action({
    KitIconName? icon,
    required String label,
    String? value,
    bool danger = false,
    bool checked = false,
    bool opens = false,
    bool enabled = true,
    required VoidCallback onTap,
    Key? key,
  }) => _KitMenuAction(
    icon: icon,
    label: label,
    value: value,
    danger: danger,
    checked: checked,
    opens: opens,
    enabled: enabled,
    onTap: onTap,
    key: key,
  );

  /// A row that only shows [value] beside [label] (in [valueColor]) and
  /// takes no tap (the 9th draft c `.it.pas`: the tab ⌄'s 마지막 편집).
  static KitMenuRow info({
    KitIconName? icon,
    required String label,
    required String value,
    Color? valueColor,
    Key? key,
  }) => _KitMenuAction(
    icon: icon,
    label: label,
    value: value,
    valueColor: valueColor,
    onTap: null,
    key: key,
  );

  /// Opens [children] in a second window beside the menu, level with the
  /// row, or with its top [windowTop] under the menu's top (the 9th draft c
  /// ⋯ puts 「쪽 배치」 112 under its own top).
  static KitMenuRow submenu({
    required KitIconName icon,
    required String label,
    String? value,
    required List<KitMenuRow> children,
    double? windowTop,
    Key? key,
  }) => _KitMenuSubmenu(
    icon: icon,
    label: label,
    value: value,
    children: children,
    windowTop: windowTop,
    key: key,
  );

  /// [lineAbove] puts a line 4 above the row, as a submenu's last setting
  /// under its choices (`.ksub .it.zl`).
  static KitMenuRow toggle({
    KitIconName? icon,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool lineAbove = false,
    Key? key,
  }) => _KitMenuToggle(
    icon: icon,
    label: label,
    value: value,
    onChanged: onChanged,
    lineAbove: lineAbove,
    key: key,
  );

  /// Written `KitMenuRow.segment<T>(...)`; a method, because a constructor
  /// cannot take a type argument. The other rows are methods to match.
  static KitMenuRow segment<T>({
    required KitIconName icon,
    required String label,
    required List<(T, String)> options,
    required T value,
    required ValueChanged<T> onChanged,
    Key? key,
  }) => _KitMenuSegment(
    icon: icon,
    label: label,
    options: [for (final (v, text) in options) (v as Object?, text)],
    value: value,
    onChanged: (v) => onChanged(v as T),
    key: key,
  );

  final KitIconName? icon;
  final String label;
  final Key? key;
}

final class _KitMenuAction extends KitMenuRow {
  const new({
    required super.icon,
    required super.label,
    this.value,
    this.danger = false,
    this.checked = false,
    this.opens = false,
    this.enabled = true,
    this.valueColor,
    required this.onTap,
    super.key,
  }) : super._();

  final String? value;
  final bool danger;
  final bool checked;
  final bool opens;
  final bool enabled;
  final Color? valueColor;

  /// Null: a [KitMenuRow.info] row.
  final VoidCallback? onTap;
}

final class _KitMenuSubmenu extends KitMenuRow {
  const new({
    required super.icon,
    required super.label,
    this.value,
    required this.children,
    this.windowTop,
    super.key,
  }) : super._();

  final String? value;
  final List<KitMenuRow> children;
  final double? windowTop;
}

final class _KitMenuToggle extends KitMenuRow {
  const new({
    required super.icon,
    required super.label,
    required this.value,
    required this.onChanged,
    this.lineAbove = false,
    super.key,
  }) : super._();

  final bool value;
  final ValueChanged<bool> onChanged;
  final bool lineAbove;
}

final class _KitMenuSegment extends KitMenuRow {
  const new({
    required super.icon,
    required super.label,
    required this.options,
    required this.value,
    required this.onChanged,
    super.key,
  }) : super._();

  final List<(Object?, String)> options;
  final Object? value;
  final ValueChanged<Object?> onChanged;
}

class _RowShell extends StatelessWidget {
  const new({
    super.key,
    required this.icon,
    required this.label,
    required this.ink,
    this.value,
    this.valueColor,
    this.trailing,
    this.onTap,
    this.semanticsToggled,
    this.semanticsSelected,
    this.open = false,
    this.dense = false,
    this.enabled = true,
    this.height = KitTokens.menuRowHeight,
    this.labelLines = 1,
  });

  final KitIconName? icon;
  final String label;
  final Color ink;
  final String? value;
  final Color? valueColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool? semanticsToggled;
  final bool? semanticsSelected;
  final bool open;
  final bool dense;
  final bool enabled;
  final double height;
  final int labelLines;

  /// [label] as shown: a name too long for one line, where a second line
  /// is allowed, breaks only between words (a word joiner, U+2060, between
  /// the letters of each word, as the preview's `word-break: keep-all`;
  /// Flutter would break Korean between any two syllables). The row's
  /// semantics read [label] itself.
  String _wrapped(BuildContext context, TextStyle style, double width) {
    if (labelLines < 2) return label;
    final one = TextPainter(
      text: TextSpan(
        text: label,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    final fits = !one.didExceedMaxLines;
    one.dispose();
    return fits ? label : keepWords(label);
  }

  @override
  Widget build(BuildContext context) {
    final Widget body = ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: dense ? KitTokens.subMenuRowHeight : height,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: dense
              ? KitTokens.subMenuPaddingH
              : KitTokens.menuPaddingH,
        ),
        child: Row(
          children: [
            if (icon case final icon?) ...[
              ExcludeSemantics(
                child: KitIcon(
                  icon,
                  size: KitTokens.menuIconSize,
                  strokeWidth: KitTokens.menuIconStroke,
                  color: ink,
                ),
              ),
              SizedBox(
                width: dense ? KitTokens.subMenuIconGap : KitTokens.menuIconGap,
              ),
            ],
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  final style = TextStyle(
                    fontSize: KitTokens.menuFontSize,
                    color: ink,
                    decoration: TextDecoration.none,
                    fontWeight: FontWeight.w400,
                  );
                  return Text(
                    _wrapped(context, style, box.maxWidth),
                    maxLines: labelLines,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  );
                },
              ),
            ),
            if (value != null) ...[
              const SizedBox(width: KitTokens.menuIconGap),
              Text(
                value!,
                maxLines: 1,
                style: TextStyle(
                  fontSize: KitTokens.menuValueSize,
                  color: valueColor ?? KitTokens.menuValue,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
            if (trailing != null) ...[
              const SizedBox(width: KitTokens.menuIconGap),
              trailing!,
            ],
          ],
        ),
      ),
    );
    if (onTap == null) return body;
    if (!enabled) {
      return Semantics(
        button: true,
        enabled: false,
        label: label,
        value: value,
        excludeSemantics: true,
        child: Opacity(opacity: KitTokens.disabledOpacity, child: body),
      );
    }
    return Semantics(
      button: semanticsToggled == null,
      toggled: semanticsToggled,
      selected: semanticsSelected,
      label: label,
      value: value,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: open ? KitTokens.menuOpenRow : Colors.transparent,
        child: InkWell(onTap: onTap, child: body),
      ),
    );
  }
}

class _QuickButton extends StatelessWidget {
  const new(this.quick, {super.key});

  final KitMenuQuick quick;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(KitTokens.menuQuickRadius);
    final ink = quick.selected ? KitTokens.accent : KitTokens.menuInk;
    final onTap = quick.enabled ? quick.onTap : null;
    return Semantics(
      button: true,
      enabled: quick.enabled,
      selected: quick.selected,
      label: quick.label,
      onTap: onTap,
      excludeSemantics: true,
      child: Opacity(
        opacity: quick.enabled ? 1 : KitTokens.disabledOpacity,
        child: Material(
          color: KitTokens.menuGroupBg,
          borderRadius: shape,
          child: InkWell(
            borderRadius: shape,
            onTap: onTap,
            // the preview's computed boxes (`.kpanel .quick span`, a grid):
            // the icon centred in a row 42 high, the name on a line of
            // 12 × 1.35, 82.19 in all
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: KitTokens.menuQuickPadV,
              ),
              child: Column(
                spacing: KitTokens.menuQuickInnerGap,
                children: [
                  SizedBox(
                    height: KitTokens.menuQuickIconRow,
                    child: Center(
                      child: KitIcon(
                        quick.icon,
                        size: KitTokens.menuIconSize,
                        strokeWidth: KitTokens.menuIconStroke,
                        color: ink,
                        selected: quick.selected,
                      ),
                    ),
                  ),
                  SizedBox(
                    height:
                        KitTokens.menuQuickTextSize * KitTokens.menuQuickLine,
                    child: Center(
                      child: Text(
                        quick.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: KitTokens.menuQuickTextSize,
                          height: KitTokens.menuQuickLine,
                          color: ink,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
