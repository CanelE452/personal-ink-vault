import 'package:flutter/widgets.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/pages/editor/editor.dart';

/// Hands the open note's actions to its host (the workspace): the editor
/// attaches itself and says when its shortcuts change. The editor's own
/// toolbar draws them; the host's function row of an Office PDF reads them
/// (Task 17: the ink editor has no function row).
class EditorChromeController extends ChangeNotifier {
  new({AppActionRegistry? appActions})
    : actions = AppActionRegistry(parent: appActions);

  /// The open document's actions: the editor's and the host's own, then the
  /// app's through the parent ([appActions]).
  final AppActionRegistry actions;

  EditorState? _editor;

  /// The attached editor, if any.
  EditorState? get editor => _editor;

  /// The attached editor's note may not change and its toolbar is folded
  /// away: the host keeps the function row (Task 17 fix 1).
  bool get editorReadOnly => _editor?.readOnlyNote ?? false;

  /// When the attached editor last changed its note.
  DateTime? get editorLastEdited => _editor?.lastEditedAt;

  /// What ⋯ 「문서 정보」 shows of the open note that the host knows (the
  /// file's time, the Drive state); set by the host.
  DocInfo Function()? docInfo;

  /// Opens a link to another note or a web address from a link in the note
  /// (the workspace's `_openLink`); set by the host. Without it the editor
  /// opens web addresses itself and cannot open other notes.
  Future<void> Function(String link)? openLink;

  /// The vault's notes for the link dialog's 「노트」 tab; set by the host.
  Future<List<({String id, String title})>> Function()? listNotes;

  var _scheduled = false;
  var _disposed = false;

  void attach(EditorState editor) {
    _editor = editor;
    changed();
  }

  void detach(EditorState editor) {
    if (!identical(_editor, editor)) return;
    _editor = null;
    changed();
  }

  /// The editor's shortcuts changed. Editors change while building too, so
  /// listeners hear it after the frame, once per frame.
  void changed() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    actions.dispose();
    super.dispose();
  }
}

/// The 229 shortcuts the editor publishes: a host's function row leaves
/// them out while the editor is not on screen.
const editorShortcutIds = [
  AppActionIds.insertPage,
  AppActionIds.pageMode,
  AppActionIds.finger,
  AppActionIds.fullscreen,
  AppActionIds.export,
  AppActionIds.linkAdd,
];
