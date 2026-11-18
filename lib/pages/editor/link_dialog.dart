import 'package:flutter/material.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/vault/note_link.dart';

/// Notein's 「링크」 dialog: a page of this note ([pages]), another note of the
/// vault ([listNotes]; null where the host gives none) or a web address.
/// [current] is the number of the page the link sits on. Editing a link
/// ([initial]) also offers 「삭제」.
///
/// Returns the link's target, `''` for 「삭제」, or null when cancelled.
Future<String?> showPageLinkDialog(
  BuildContext context, {
  required List<({String pageId, int number})> pages,
  required Future<List<({String id, String title})>> Function()? listNotes,
  String? initial,
  int? current,
}) => showDialog<String>(
  context: context,
  builder: (context) => _PageLinkDialog(
    pages: pages,
    listNotes: listNotes,
    initial: initial,
    current: current,
  ),
);

class _PageLinkDialog extends StatefulWidget {
  const new({
    required this.pages,
    required this.listNotes,
    required this.initial,
    required this.current,
  });

  final List<({String pageId, int number})> pages;
  final Future<List<({String id, String title})>> Function()? listNotes;
  final String? initial;
  final int? current;

  @override
  State<_PageLinkDialog> createState() => _PageLinkDialogState();
}

class _PageLinkDialogState extends State<_PageLinkDialog> {
  late final _initialKind = PageLink.kindOf(widget.initial ?? '');
  late var _tab = _initialKind ?? PageLinkKind.page;
  late String? _pageId = _initialKind == PageLinkKind.page
      ? widget.initial!.substring(PageLink.pagePrefix.length)
      : null;
  late String? _noteId = _initialKind == PageLinkKind.note
      ? NoteLink.parse(widget.initial!)!.noteId
      : null;
  final _search = TextEditingController();
  late final _web = TextEditingController(
    text: _initialKind == PageLinkKind.web ? widget.initial : '',
  );

  /// Read the first time the 「노트」 tab shows.
  Future<List<({String id, String title})>>? _notes;

  @override
  void dispose() {
    _search.dispose();
    _web.dispose();
    super.dispose();
  }

  String? get _target => switch (_tab) {
    PageLinkKind.page =>
      _pageId == null ? null : '${PageLink.pagePrefix}$_pageId',
    PageLinkKind.note => _noteTarget,
    PageLinkKind.web => _webTarget,
  };

  /// A pasted `inkvault://` link (it may name a page of the note) wins over
  /// the chosen note. Editing a link to a page of a note keeps that page while
  /// the same note stays chosen.
  String? get _noteTarget {
    final pasted = _search.text.trim();
    if (NoteLink.parse(pasted) != null) return pasted;
    final id = _noteId;
    if (id == null) return null;
    final initial = widget.initial;
    if (_initialKind == PageLinkKind.note &&
        NoteLink.parse(initial!)!.noteId == id) {
      return initial;
    }
    return NoteLink(id).toString();
  }

  /// http and https only; an address typed without one gets https.
  String? get _webTarget {
    final text = _web.text.trim();
    if (text.isEmpty) return null;
    final address = text.contains('://') ? text : 'https://$text';
    return isSafeExternalLink(address) ? address : null;
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    return AlertDialog(
      key: const ValueKey('link-dialog'),
      title: const Text('링크'),
      scrollable: true,
      content: SizedBox(
        width: 360,
        height: 320,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<PageLinkKind>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: PageLinkKind.page,
                  label: Text('페이지', key: ValueKey('link-tab-page')),
                ),
                ButtonSegment(
                  value: PageLinkKind.note,
                  label: Text('노트', key: ValueKey('link-tab-note')),
                ),
                ButtonSegment(
                  value: PageLinkKind.web,
                  label: Text('웹', key: ValueKey('link-tab-web')),
                ),
              ],
              selected: {_tab},
              onSelectionChanged: (selected) =>
                  setState(() => _tab = selected.single),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: switch (_tab) {
                PageLinkKind.page => _pageTab(context),
                PageLinkKind.note => _noteTab(context),
                PageLinkKind.web => _webTab(),
              },
            ),
          ],
        ),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(
            key: const ValueKey('link-dialog-delete'),
            style: TextButton.styleFrom(
              foregroundColor: ColorScheme.of(context).error,
            ),
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('삭제'),
          ),
        TextButton(
          key: const ValueKey('link-dialog-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('link-dialog-add'),
          onPressed: target == null ? null : () => Navigator.pop(context, target),
          child: const Text('추가'),
        ),
      ],
    );
  }

  Widget _pageTab(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.current case final current?)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '지금 페이지: $current',
            style: TextTheme.of(context).bodySmall,
          ),
        ),
      Expanded(
        child: SingleChildScrollView(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final page in widget.pages)
                ChoiceChip(
                  key: ValueKey('link-page-${page.number}'),
                  label: Text('${page.number}'),
                  selected: page.pageId == _pageId,
                  onSelected: (_) => setState(() => _pageId = page.pageId),
                ),
            ],
          ),
        ),
      ),
    ],
  );

  Widget _noteTab(BuildContext context) {
    _notes ??= widget.listNotes?.call();
    final notes = _notes;
    final query = _search.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('link-note-search'),
          controller: _search,
          autocorrect: false,
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '노트 검색 또는 inkvault:// 링크',
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: NoteLink.parse(query) != null
              ? const Center(child: Text('붙여 넣은 노트 링크로 연결합니다'))
              : notes == null
              ? const Center(child: Text('이 화면에서는 노트 목록을 볼 수 없습니다'))
              : FutureBuilder(
                  future: notes,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const Center(child: Text('노트 목록을 읽지 못했습니다'));
                    }
                    final all = snapshot.data;
                    if (all == null) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final words = query.toLowerCase();
                    final shown = [
                      for (final note in all)
                        if (note.title.toLowerCase().contains(words)) note,
                    ];
                    if (shown.isEmpty) {
                      return const Center(child: Text('맞는 노트가 없습니다'));
                    }
                    return ListView(
                      children: [
                        for (final note in shown)
                          ListTile(
                            key: ValueKey('link-note-${note.id}'),
                            dense: true,
                            title: Text(
                              note.title.isEmpty ? '제목 없음' : note.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            selected: note.id == _noteId,
                            onTap: () => setState(() => _noteId = note.id),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _webTab() {
    final typed = _web.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('link-web-url'),
          controller: _web,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(
            hintText: 'https://',
            errorText: typed && _webTarget == null
                ? 'http·https 주소만 넣을 수 있습니다'
                : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}
