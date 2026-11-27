import 'package:flutter/widgets.dart';
import 'package:saber/components/ink_ui/side_panel/kit_page_menu.dart';
import 'package:saber/components/ink_ui/tool_panels/kit_eraser_panel.dart'
    show confirmClearPage;

// the editor runs what the thumbnail menu picks
export 'package:saber/components/ink_ui/side_panel/kit_page_menu.dart'
    show KitPageAction;

/// What the left panel's page thumbnails do to the note, given by the editor
/// so that the panel knows nothing of the note's state: dragging a page,
/// and the menu of a page ([openMenu]).
class EditorPageActions {
  const new({
    required this.locks,
    required this.editable,
    required this.canPaste,
    required this.canDelete,
    required this.canClear,
    required this.move,
    required this.run,
  });

  /// Tells when [editable] may have changed (the note's lock).
  final Listenable locks;

  /// Whether the note may change: a read-only or locked one may not.
  final bool Function() editable;

  /// Whether a page was copied, here or in another note.
  final bool Function() canPaste;

  /// Whether page [index] may be deleted or cut.
  final bool Function(int index) canDelete;

  /// Whether page [index] has anything to clear.
  final bool Function(int index) canClear;

  /// Moves page `from` so that it is page `to` (a drop on a thumbnail).
  final void Function(int from, int to) move;

  /// Does [action] on page [index], and tells of it.
  final void Function(KitPageAction action, int index) run;

  /// The menu of page [index], hung from the thumbnail's button at
  /// [context]; what it picks is run, 「쪽 비우기」 once the user has said yes.
  Future<void> openMenu(BuildContext context, int index) async {
    final action = await showKitPageMenu(
      context,
      canEdit: editable(),
      canPaste: canPaste(),
      canDelete: canDelete(index),
      canClear: canClear(index),
    );
    if (action == null) return;
    if (action == KitPageAction.clear &&
        (!context.mounted || !await confirmClearPage(context))) {
      return;
    }
    run(action, index);
  }
}
