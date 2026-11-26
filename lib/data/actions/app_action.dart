import 'package:flutter/widgets.dart';
import 'package:saber/components/kit/kit_icons.g.dart';

/// One thing the user can do, as the toolbar, menus, selection bars and the
/// keyboard all see it. The owner (editor or workspace) builds these with its
/// current state and publishes them in an `AppActionRegistry`.
@immutable
class AppAction {
  const new({
    required this.id,
    required this.label,
    required this.icon,
    required this.run,
    this.enabled = true,
    this.checked,
    this.widgetKey,
  });

  /// One of `AppActionIds`.
  final String id;

  /// Its name in the current state (e.g. 연속 스크롤 / 한 쪽씩 보기).
  final String label;

  /// Its icon in the current state.
  final KitIconName icon;

  /// Does the action. [context] belongs to the input that called it: a button's
  /// own context, for a menu row the context of the button that opened the menu
  /// (after the menu closed), for the keyboard the focused editor's context.
  /// An action that needs a choice (export format, ...) opens a small dialog on
  /// that context. It never throws synchronously; an async failure goes through
  /// the owner's own error path.
  final void Function(BuildContext context) run;

  /// Can be pressed now. When false the view draws it dimmed and ignores taps.
  final bool enabled;

  /// For an on/off row: whether it is on now. Null for a plain action.
  final bool? checked;

  /// Key of the button or row that draws this action (the name tests look for).
  final Key? widgetKey;

  /// Whether [other] equals this in the six fields except [run]. The registry
  /// uses it to decide whether a change is worth telling listeners.
  bool looksSame(AppAction other) =>
      id == other.id &&
      label == other.label &&
      icon == other.icon &&
      enabled == other.enabled &&
      checked == other.checked &&
      widgetKey == other.widgetKey;
}
