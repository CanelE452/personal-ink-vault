import 'package:ink_vault_core/ink_vault_core.dart';

typedef OfficePageTarget = ({
  String sourceRevisionId,
  String pdfBindingId,
  String pageId,
});

class NoteLink {
  final String noteId;
  final String? pageId;
  final OfficePageTarget? officePageTarget;
  final bool isMarkdown;
  final String? markdownAnchor;
  const new(this.noteId, [this.pageId])
    : isMarkdown = false,
      officePageTarget = null,
      markdownAnchor = null;
  const new markdown(this.noteId, [this.markdownAnchor])
    : isMarkdown = true,
      officePageTarget = null,
      pageId = null;
  const new officePage(this.noteId, OfficePageTarget target)
    : isMarkdown = false,
      markdownAnchor = null,
      officePageTarget = target,
      pageId = null;

  static NoteLink? parse(String value) {
    try {
      final uri = Uri.parse(value);
      if (uri.scheme != 'inkvault' ||
          uri.host != 'note' ||
          uri.pathSegments.length != 1 ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort)
        return null;
      final fields = uri.queryParametersAll;
      const allowedFields = {'page', 'view', 'edition', 'pdf'};
      if (fields.keys.any((key) => !allowedFields.contains(key)) ||
          fields.values.any((values) => values.length != 1)) {
        return null;
      }
      final id = uri.pathSegments.single;
      final page = fields['page']?.single;
      final view = fields['view']?.single;
      final edition = fields['edition']?.single;
      final pdf = fields['pdf']?.single;
      validateId(id);
      if (page != null) validateId(page);
      if (edition != null || pdf != null) {
        if (edition == null ||
            pdf == null ||
            page == null ||
            view != null ||
            uri.hasFragment) {
          return null;
        }
        validateId(edition);
        validateId(pdf);
        return NoteLink.officePage(id, (
          sourceRevisionId: edition,
          pdfBindingId: pdf,
          pageId: page,
        ));
      }
      if (view != null && view != 'markdown') return null;
      if (page != null && (view != null || uri.hasFragment)) return null;
      if (view != null || uri.hasFragment) {
        final anchor = Uri.decodeComponent(uri.fragment);
        if (anchor.length > 2048 ||
            anchor.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]')))
          return null;
        return NoteLink.markdown(id, anchor.isEmpty ? null : anchor);
      }
      return NoteLink(id, page);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() {
    if (officePageTarget case final target?) {
      return 'inkvault://note/$noteId?edition=${target.sourceRevisionId}'
          '&pdf=${target.pdfBindingId}&page=${target.pageId}';
    }
    return isMarkdown
        ? Uri(
            scheme: 'inkvault',
            host: 'note',
            path: '/$noteId',
            queryParameters: const {'view': 'markdown'},
            fragment: markdownAnchor == null
                ? null
                : Uri.encodeComponent(markdownAnchor!),
          ).toString()
        : 'inkvault://note/$noteId${pageId == null ? '' : '?page=$pageId'}';
  }
}

bool isSafeExternalLink(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}
