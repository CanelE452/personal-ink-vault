import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/pdf_document_cache.dart';

class OfficeOriginalPreview extends StatefulWidget {
  const new({
    super.key,
    required this.sourceKey,
    required this.pdfBytes,
    this.presentation = false,
    this.initialPage = 1,
    this.onPageChanged,
    this.onAnnotatePage,
  }) : _expanded = false;

  const new _fullScreen({
    required this.sourceKey,
    required this.pdfBytes,
    required this.presentation,
    required this.initialPage,
    required this.onPageChanged,
  }) : _expanded = true,
       onAnnotatePage = null;

  final String sourceKey;
  final Uint8List pdfBytes;
  final bool presentation;
  final int initialPage;
  final ValueChanged<int>? onPageChanged;
  final ValueChanged<int>? onAnnotatePage;
  final bool _expanded;

  @override
  State<OfficeOriginalPreview> createState() => _OfficeOriginalPreviewState();
}

class _OfficeOriginalPreviewState extends State<OfficeOriginalPreview> {
  late PdfDocumentCache _cache;
  late Future<PdfDocument> _document;
  late int _page;

  @override
  void initState() {
    super.initState();
    _open();
  }

  void _open() {
    _page = widget.initialPage;
    // Resolve the page metadata up front so an arbitrary page can be rendered.
    _cache = PdfDocumentCache(useProgressiveLoading: false);
    _document = Future.value(
      _cache.load(widget.sourceKey, pdfBytes: widget.pdfBytes),
    );
  }

  @override
  void didUpdateWidget(covariant OfficeOriginalPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sourceKey != widget.sourceKey) {
      _cache.dispose();
      _open();
    }
  }

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  void _goToPage(int page, int count) {
    final target = page.clamp(1, count);
    if (target == _page.clamp(1, count)) return;
    setState(() => _page = target);
    widget.onPageChanged?.call(target);
  }

  Future<void> _choosePage(int count) async {
    final document = _document;
    final title = widget.presentation ? '슬라이드로 이동' : '페이지로 이동';
    final initial = '${_page.clamp(1, count)}';
    final field = GlobalKey<FormFieldState<String>>();
    final target = await showDialog<int>(
      context: context,
      builder: (context) {
        void submit() {
          final state = field.currentState!;
          if (state.validate())
            Navigator.of(context).pop(int.parse(state.value!));
        }

        return AlertDialog(
          title: Text(title),
          content: TextFormField(
            key: field,
            initialValue: initial,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: '1–$count'),
            validator: (value) {
              final page = int.tryParse(value ?? '');
              return page != null && page >= 1 && page <= count
                  ? null
                  : '1부터 $count 사이의 번호를 입력하세요.';
            },
            onFieldSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            FilledButton(onPressed: submit, child: const Text('이동')),
          ],
        );
      },
    );
    if (mounted && identical(document, _document) && target != null) {
      _goToPage(target, count);
    }
  }

  void _expand(int count) {
    final document = _document;
    final source = widget.sourceKey;
    final bytes = widget.pdfBytes;
    final page = _page.clamp(1, count);
    final presentation = widget.presentation;
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => OfficeOriginalPreview._fullScreen(
            sourceKey: source,
            pdfBytes: bytes,
            presentation: presentation,
            initialPage: page,
            onPageChanged: (target) {
              if (mounted && identical(document, _document)) {
                _goToPage(target, count);
              }
            },
          ),
        ),
      ),
    );
  }

  Widget _keyboard(BuildContext context, Widget child, int count) =>
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _goToPage(_page.clamp(1, count) - 1, count),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _goToPage(_page.clamp(1, count) + 1, count),
          const SingleActivator(LogicalKeyboardKey.pageUp): () =>
              _goToPage(_page.clamp(1, count) - 1, count),
          const SingleActivator(LogicalKeyboardKey.pageDown): () =>
              _goToPage(_page.clamp(1, count) + 1, count),
          const SingleActivator(LogicalKeyboardKey.home): () =>
              _goToPage(1, count),
          const SingleActivator(LogicalKeyboardKey.end): () =>
              _goToPage(count, count),
          if (widget._expanded)
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(context).pop(),
        },
        child: Focus(autofocus: widget._expanded, child: child),
      );

  Widget _buildPages(BuildContext context, PdfDocument document) {
    final count = document.pages.length;
    final page = _page.clamp(1, count);
    final previous = widget.presentation ? '이전 슬라이드' : '이전 페이지';
    final next = widget.presentation ? '다음 슬라이드' : '다음 페이지';
    final annotatePage = widget.onAnnotatePage;
    return Column(
      children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragEnd: (details) {
              final velocity = details.primaryVelocity ?? 0;
              if (velocity.abs() >= 100) {
                _goToPage(page + (velocity < 0 ? 1 : -1), count);
              }
            },
            child: PdfPageView(
              key: ValueKey((widget.sourceKey, page)),
              document: document,
              pageNumber: page,
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
            ),
          ),
        ),
        Row(
          children: [
            IconButton(
              key: const ValueKey('office-preview-previous'),
              tooltip: previous,
              onPressed: page > 1 ? () => _goToPage(page - 1, count) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: TextButton(
                key: const ValueKey('office-preview-jump'),
                onPressed: count > 1
                    ? () => unawaited(_choosePage(count))
                    : null,
                child: Text('$page / $count', maxLines: 1),
              ),
            ),
            IconButton(
              key: const ValueKey('office-preview-next'),
              tooltip: next,
              onPressed: page < count ? () => _goToPage(page + 1, count) : null,
              icon: const Icon(Icons.chevron_right),
            ),
            if (!widget._expanded) ...[
              if (annotatePage != null)
                IconButton(
                  key: const ValueKey('office-preview-annotate-page'),
                  tooltip: '현재 쪽에 필기',
                  onPressed: () => annotatePage(page),
                  icon: const Icon(Icons.draw_outlined),
                ),
              IconButton(
                key: const ValueKey('office-preview-fullscreen'),
                tooltip: '전체 화면 미리보기',
                onPressed: () => _expand(count),
                icon: const Icon(Icons.fullscreen),
              ),
            ],
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = FutureBuilder<PdfDocument>(
      key: ValueKey(widget.sourceKey),
      future: _document,
      builder: (context, snapshot) {
        final document = snapshot.data;
        final count = document?.pages.length ?? 0;
        Widget body;
        if (snapshot.hasError || document != null && document.pages.isEmpty) {
          body = const Center(
            key: ValueKey('office-original-preview-error'),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('원본 미리보기를 열지 못했습니다. 원본 편집은 계속할 수 있습니다.'),
            ),
          );
        } else if (document == null) {
          body = const Center(
            key: ValueKey('office-original-preview-loading'),
            child: CircularProgressIndicator(),
          );
        } else {
          body = _buildPages(context, document);
        }
        if (widget._expanded) {
          body = Scaffold(
            appBar: AppBar(
              leading: IconButton(
                key: const ValueKey('office-preview-close'),
                tooltip: '전체 화면 닫기',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
              title: Text(widget.presentation ? '슬라이드 미리보기' : '원본 미리보기'),
            ),
            body: SafeArea(child: body),
          );
        }
        return count > 0 ? _keyboard(context, body, count) : body;
      },
    );
    return widget._expanded
        ? preview
        : SizedBox(height: 400, width: double.infinity, child: preview);
  }
}
