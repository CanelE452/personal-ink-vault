import 'package:flutter/material.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/pptx_find_replace.dart';

typedef PptxFindReplaceDraft = ({
  PptxFindReplacePreview preview,
  String replacement,
});

Future<PptxFindReplaceDraft?> choosePptxFindReplace(
  BuildContext context,
  Future<PptxFindReplacePreview> Function(String) preview,
) async {
  Future<PptxFindReplacePreview>? pending;
  final draft = await showDialog<PptxFindReplaceDraft>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _PptxFindReplaceDialog(preview: (find) => pending = preview(find)),
  );
  try {
    // The workspace owns the temporary source until the preview finishes.
    await pending;
  } on Object {
    // Preview failures are shown by the dialog.
  }
  return draft;
}

class _PptxFindReplaceDialog extends StatefulWidget {
  const new({required this.preview});

  final Future<PptxFindReplacePreview> Function(String) preview;

  @override
  State<_PptxFindReplaceDialog> createState() => _PptxFindReplaceDialogState();
}

class _PptxFindReplaceDialogState extends State<_PptxFindReplaceDialog> {
  var _find = '';
  var _replacement = '';
  var _queryVersion = 0;
  var _searching = false;
  String? _searchError;
  PptxFindReplacePreview? _preview;

  bool get _canSearch => !_searching && PptxFindReplaceEngine.validFind(_find);

  Future<void> _search() async {
    if (!_canSearch) return;
    final find = _find;
    final version = _queryVersion;
    FocusScope.of(context).unfocus();
    setState(() {
      _preview = null;
      _searching = true;
      _searchError = null;
    });
    const failed = '찾기 결과를 불러오지 못했습니다.';
    PptxFindReplacePreview? result;
    String? failure;
    try {
      result = await widget.preview(find);
    } catch (error) {
      failure =
          error is InkVaultNativeException && error.code == 'pptx_match_limit'
          ? '검색 결과가 200곳을 넘습니다. 찾을 말을 더 구체적으로 입력하세요.'
          : failed;
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      if (version != _queryVersion) return;
      _searchError = result?.find == find ? null : failure ?? failed;
      _preview = _searchError == null ? result : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final validFind = PptxFindReplaceEngine.validFind(_find);
    final validReplacement = PptxFindReplaceEngine.validReplacement(
      _replacement,
    );
    final canReplace =
        preview != null &&
        preview.matchCount > 0 &&
        validReplacement &&
        _replacement != _find;
    const invalidText = '줄바꿈 없이 2,000자 이내로 입력하세요.';
    return AlertDialog(
      title: const Text('PPTX 찾아 바꾸기'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '슬라이드의 일반 도형 텍스트에서 대소문자까지 같은 글자를 찾습니다. '
              '그룹 안 도형과 표·차트·발표자 노트는 제외됩니다.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('pptx-find-replace-find'),
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: '찾을 말',
                errorText: _find.isNotEmpty && !validFind ? invalidText : null,
              ),
              onChanged: (value) {
                if (value == _find) return;
                setState(() {
                  _find = value;
                  _queryVersion++;
                  _preview = null;
                  _searchError = null;
                });
              },
              onSubmitted: (_) => _search(),
            ),
            TextField(
              key: const ValueKey('pptx-find-replace-replacement'),
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              decoration: InputDecoration(
                labelText: '바꿀 말',
                helperText: '비워 두면 찾은 글자를 지웁니다.',
                errorText: validReplacement ? null : invalidText,
              ),
              onChanged: (value) => setState(() => _replacement = value),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('pptx-find-replace-preview'),
              onPressed: _canSearch ? _search : null,
              child: const Text('찾기 미리보기'),
            ),
            if (_searching) const LinearProgressIndicator(),
            if (_searchError case final error?) Text(error),
            if (preview != null)
              if (preview.matchCount == 0)
                const Text('일치하는 슬라이드 글자가 없습니다.')
              else ...[
                Text(
                  '${preview.matchCount}곳 · ${preview.matches.length}개 슬라이드',
                ),
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    primary: false,
                    itemCount: preview.matches.length,
                    itemBuilder: (context, index) {
                      final match = preview.matches[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '슬라이드 ${match.slideIndex + 1} · ${match.count}곳\n'
                          '${match.snippet}',
                        ),
                      );
                    },
                  ),
                ),
              ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('pptx-find-replace-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('pptx-find-replace-confirm'),
          onPressed: canReplace
              ? () => Navigator.pop(context, (
                  preview: preview,
                  replacement: _replacement,
                ))
              : null,
          child: const Text('모두 바꾸기'),
        ),
      ],
    );
  }
}
