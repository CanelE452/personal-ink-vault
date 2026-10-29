import 'package:ink_vault_core/ink_vault_core.dart';

class NoteLink {
  final String noteId;
  final String? pageId;
  const new(this.noteId, [this.pageId]);

  static NoteLink? parse(String value) {
    try {
      final uri = Uri.parse(value);
      if (uri.scheme != 'inkvault' ||
          uri.host != 'note' ||
          uri.pathSegments.length != 1 ||
          uri.fragment.isNotEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort ||
          uri.queryParametersAll.keys.any((key) => key != 'page') ||
          (uri.queryParametersAll['page']?.length ?? 0) > 1)
        return null;
      final id = uri.pathSegments.single;
      final page = uri.queryParameters['page'];
      validateId(id);
      if (page != null) validateId(page);
      return NoteLink(id, page);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() =>
      'inkvault://note/$noteId${pageId == null ? '' : '?page=$pageId'}';
}

bool isSafeExternalLink(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}
