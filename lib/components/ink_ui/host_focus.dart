import 'package:flutter/widgets.dart';

/// The workspace keeps the focus on its own root, so a note's autofocus does
/// not apply there: [node] (the editor's, the infinite note's) takes the keys
/// from a host that holds them, never from a field elsewhere (the Markdown
/// beside the note).
void takeFocusFromHost(FocusNode node) {
  final focused = FocusManager.instance.primaryFocus;
  if (focused == null || node.ancestors.contains(focused)) {
    node.requestFocus();
  }
}
