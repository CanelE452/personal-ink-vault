import 'package:flutter/widgets.dart';
import 'package:saber/components/toolbar/note_function_row.dart';
import 'package:saber/pages/editor/editor.dart';

/// Lets a host draw the open note's function row and "기타 설정" panel
/// (StarNote's layout_function_tool and popup_note_document_more_settings):
/// the editor attaches itself and says when its shortcuts change; the host
/// asks for them when it builds. An editor without a controller draws them
/// itself.
class EditorChromeController extends ChangeNotifier {
  EditorState? _editor;

  /// The attached editor, if any.
  EditorState? get editor => _editor;

  /// Opens the host's "기타 설정" panel; set by the host.
  VoidCallback? openOtherSettings;

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

  List<NoteShortcut> get shortcuts => _editor?.chromeShortcuts() ?? const [];

  /// 문서 개요 and 기타 설정, at the bar's right end.
  List<NoteShortcut> get fixed => _editor?.chromeFixed() ?? const [];

  List<Widget> settingsSections({required VoidCallback close}) =>
      _editor?.otherSettingsSections(close: close) ?? const [];

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
