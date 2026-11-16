import 'package:flutter/material.dart';

/// Exports the open note. [name] is the file name without its extension;
/// [background] keeps the paper's lines, grid or dots (PDF pages and
/// pictures are always kept).
typedef ExportFunction =
    Future<void> Function(
      BuildContext context, {
      String? name,
      bool background,
    });

/// [text] without the characters file systems refuse, or [fallback] (cleaned
/// the same way) when nothing is left.
String exportFileName(String text, {required String fallback}) {
  String clean(String value) => value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '')
      .trim();
  final name = clean(text);
  if (name.isNotEmpty) return name;
  final backup = clean(fallback);
  return backup.isNotEmpty ? backup : 'note';
}

enum _ExportFormat { pdf, image, original }

/// StarNote-like export: pick a format, name the file and choose whether the
/// paper's pattern goes along, then share it.
Future<void> showExportDialog(
  BuildContext context, {
  required String title,
  required ExportFunction? pdf,
  required ExportFunction? image,
  required ExportFunction? original,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ExportDialog(
    host: context,
    title: title,
    exports: {
      _ExportFormat.pdf: ?pdf,
      _ExportFormat.image: ?image,
      _ExportFormat.original: ?original,
    },
  ),
);

class _ExportDialog extends StatefulWidget {
  const new({required this.host, required this.title, required this.exports});

  /// The context that opened the dialog. The export runs with it, so the
  /// share or save still happens if the dialog is gone by then.
  final BuildContext host;
  final String title;
  final Map<_ExportFormat, ExportFunction> exports;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late final _name = TextEditingController(
    text: exportFileName(widget.title, fallback: ''),
  );
  late var _format = widget.exports.keys.first;
  var _background = true;
  var _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      await widget.exports[_format]!(
        widget.host,
        name: exportFileName(_name.text, fallback: widget.title),
        background: _background,
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = TextTheme.of(context);
    // While exporting, Back and taps outside do not close the dialog.
    return PopScope(
      canPop: !_busy,
      child: _dialog(text),
    );
  }

  Widget _dialog(TextTheme text) {
    return AlertDialog(
      title: const Text('파일 내보내기'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<_ExportFormat>(
              key: const ValueKey('export-format'),
              showSelectedIcon: false,
              segments: [
                for (final format in widget.exports.keys)
                  ButtonSegment(
                    value: format,
                    label: Text(switch (format) {
                      _ExportFormat.pdf => 'PDF',
                      _ExportFormat.image => '사진',
                      _ExportFormat.original => '원본 파일',
                    }),
                  ),
              ],
              selected: {_format},
              onSelectionChanged: _busy
                  ? null
                  : (selection) => setState(() => _format = selection.single),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('export-name'),
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '파일 이름'),
            ),
            if (_format != _ExportFormat.original)
              CheckboxListTile(
                key: const ValueKey('export-background'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _background,
                title: const Text('줄·격자 배경 포함'),
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _background = value ?? true),
              ),
            Text(switch (_format) {
              _ExportFormat.pdf => '모든 쪽을 PDF로 내보냅니다.',
              _ExportFormat.image => '지금 보고 있는 쪽을 그림으로 내보냅니다.',
              _ExportFormat.original => '다른 기기에서 다시 열 수 있는 노트 파일입니다.',
            }, style: text.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('export-go'),
          onPressed: _busy ? null : _export,
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('내보내기 및 공유'),
        ),
      ],
    );
  }
}
