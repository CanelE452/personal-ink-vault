import 'dart:async';

import 'package:flutter/material.dart';
import 'package:saber/data/vault/pdf_import_state.dart';

class PdfTextSearchDialog extends StatefulWidget {
  final Future<PdfTextSearchResult?> Function(String, bool Function()) search;

  const new({super.key, required this.search});

  @override
  State<PdfTextSearchDialog> createState() => _PdfTextSearchDialogState();
}

class _PdfTextSearchDialogState extends State<PdfTextSearchDialog> {
  final _query = TextEditingController();
  PdfTextSearchResult? _result;
  String? _message;
  var _searching = false;
  var _request = 0;

  void _edit(String _) => setState(() {
    _request++;
    _result = null;
    _message = null;
  });

  Future<void> _submit() async {
    final query = _query.text.trim();
    if (_searching || query.isEmpty) return;
    final request = ++_request;
    final route = ModalRoute.of(context);
    bool current() =>
        mounted && request == _request && route?.isCurrent != false;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _result = null;
      _message = null;
    });
    try {
      final result = await widget.search(query, current);
      if (current()) {
        setState(() {
          _result = result;
          if (result == null) _message = '문서가 바뀌어 검색을 중단했습니다.';
        });
      }
    } catch (_) {
      if (current()) setState(() => _message = 'PDF 본문을 읽지 못했습니다.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: 440,
      height: 380,
      child: LayoutBuilder(
        builder: (context, constraints) {
          const minimumHeight = 240.0;
          return SingleChildScrollView(
            child: SizedBox(
              height: constraints.maxHeight < minimumHeight
                  ? minimumHeight
                  : constraints.maxHeight,
              child: _contents(context),
            ),
          );
        },
      ),
    ),
  );

  Widget _contents(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('PDF 본문 검색', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('pdf-text-search-query'),
          controller: _query,
          autofocus: true,
          maxLength: 160,
          decoration: const InputDecoration(
            hintText: '검색할 문구',
            counterText: '',
          ),
          textInputAction: TextInputAction.search,
          onChanged: _edit,
          onSubmitted: (_) => unawaited(_submit()),
        ),
        if (_searching) const LinearProgressIndicator(),
        Expanded(child: _results()),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기'),
            ),
            FilledButton(
              onPressed: _searching || _query.text.trim().isEmpty
                  ? null
                  : () => unawaited(_submit()),
              child: const Text('검색'),
            ),
          ],
        ),
      ],
    ),
  );

  String _emptyMessage(PdfTextSearchResult? result) {
    final message = _message;
    if (message != null) return message;
    if (_searching) return 'PDF 본문을 검색하고 있습니다.';
    if (result == null) return '검색 결과를 누르면 필기 페이지로 이동합니다.';
    if (result.unavailable) return '현재 필기에서 검색할 원본 PDF를 읽을 수 없습니다.';
    if (result.truncated) return '검색한 범위에서 일치하는 문구를 찾지 못했습니다.';
    if (!result.hasText) return '이 PDF에서 선택할 수 있는 텍스트를 찾지 못했습니다.';
    return '일치하는 문구가 없습니다.';
  }

  Widget _results() {
    final result = _result;
    if (result == null || result.hits.isEmpty) {
      return Center(
        child: Semantics(liveRegion: true, child: Text(_emptyMessage(result))),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: result.hits.length + (result.truncated ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == result.hits.length) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Text('일부 페이지는 검색 결과에 포함되지 않았습니다.'),
          );
        }
        final hit = result.hits[index];
        return ListTile(
          key: ValueKey('pdf-text-search-hit-${hit.pageNumber}'),
          contentPadding: EdgeInsets.zero,
          title: Text('원본 ${hit.pageNumber}페이지'),
          subtitle: Text(
            hit.snippet,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => Navigator.pop(context, hit),
        );
      },
    );
  }
}
