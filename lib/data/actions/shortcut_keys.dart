import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';

/// The keys the editor and the infinite note share, each with the action id it
/// runs. A screen that does not publish the id leaves the key alone
/// ([shortcutCallbacks] does not bind it). Keys with no action
/// behind them (the editor's zoom and arrow keys, Esc ending the eyedropper)
/// are not here: they stay with the editor.
const List<(SingleActivator, String)> appShortcutKeys = [
  (
    SingleActivator(LogicalKeyboardKey.keyZ, control: true),
    AppActionIds.undo,
  ),
  (
    SingleActivator(LogicalKeyboardKey.keyY, control: true),
    AppActionIds.redo,
  ),
  (
    SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
    AppActionIds.redo,
  ),
  (
    SingleActivator(LogicalKeyboardKey.keyF, control: true),
    AppActionIds.finger,
  ),
  (
    SingleActivator(LogicalKeyboardKey.keyE, control: true),
    AppActionIds.eraserBar,
  ),
  (
    SingleActivator(LogicalKeyboardKey.keyC, control: true),
    AppActionIds.floatingBar,
  ),
  (
    SingleActivator(LogicalKeyboardKey.keyS, control: true),
    AppActionIds.saveNow,
  ),
  (
    SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true),
    AppActionIds.export,
  ),
  (SingleActivator(LogicalKeyboardKey.f11), AppActionIds.fullscreen),
  (
    SingleActivator(LogicalKeyboardKey.keyV, control: true),
    AppActionIds.paste,
  ),
];

/// [appShortcutKeys] as `CallbackShortcuts` bindings: each key whose id
/// [actions] has now runs it with [context]. A key whose id is not there is
/// not bound, so it goes on to the widgets above (a bound key is handled).
/// The caller builds the map again after it publishes.
Map<ShortcutActivator, VoidCallback> shortcutCallbacks(
  AppActionRegistry actions,
  BuildContext context,
) => {
  for (final (key, id) in appShortcutKeys)
    if (actions.has(id)) key: () => actions.run(id, context),
};
