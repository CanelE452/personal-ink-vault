import 'package:flutter/material.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/docx_find_replace.dart';

typedef DocxFindReplaceDraft = ({
  DocxFindReplacePreview preview,
  String replacement,
});

Future<DocxFindReplaceDraft?> chooseDocxFindReplace(
  BuildContext context,
  Future<DocxFindReplacePreview> Function(String) preview,
) async {
  Future<DocxFindReplacePreview>? pending;
  final draft = await showDialog<DocxFindReplaceDraft>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _DocxFindReplaceDialog(preview: (find) => pending = preview(find)),
  );
  try {
    // Keep the working file alive until a canceled preview releases it.
    await pending;
  } on Object {
    // The dialog handles preview failures.
  }
  return draft;
}

class _DocxFindReplaceDialog extends StatefulWidget {
  const new({required this.preview});

  final Future<DocxFindReplacePreview> Function(String) preview;

  @override
  State<_DocxFindReplaceDialog> createState() => _DocxFindReplaceDialogState();
}

class _DocxFindReplaceDialogState extends State<_DocxFindReplaceDialog> {
  var _find = '';
  var _replacement = '';
  var _findVersion = 0;
  var _searching = false;
  String? _searchError;
  DocxFindReplacePreview? _preview;

  bool get _canSearch => !_searching && DocxFindReplaceEngine.validFind(_find);

  Future<void> _search() async {
    if (!_canSearch) return;
    final find = _find;
    final version = _findVersion;
    FocusScope.of(context).unfocus();
    setState(() {
      _preview = null;
      _searching = true;
      _searchError = null;
    });
    const failed = '찾기 결과를 불러오지 못했습니다.';
    DocxFindReplacePreview? result;
    String? failure;
    try {
      result = await widget.preview(find);
    } catch (error) {
      failure =
          error is InkVaultNativeException && error.code == 'docx_match_limit'
          ? '검색 결과가 200곳을 넘습니다. 찾을 말을 더 구체적으로 입력하세요.'
          : failed;
    }
    if (!mounted) return;
    setState(() {
      _searching = false;
      if (version != _findVersion) return;
      _searchError = result?.find == find ? null : failure ?? failed;
      _preview = _searchError == null ? result : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final validFind = DocxFindReplaceEngine.validFind(_find);
    final validReplacement = DocxFindReplaceEngine.validReplacement(
      _replacement,
    );
    final canReplace =
        preview != null &&
        preview.matchCount > 0 &&
        validReplacement &&
        _replacement != _find;
    const invalidText = '줄바꿈 없이 2,000자 이내로 입력하세요.';
    return AlertDialog(
      title: const Text('DOCX 찾아 바꾸기'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('일반 본문에서 대소문자까지 같은 글자를 찾습니다. 표, 머리글, 필드 등은 제외됩니다.'),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('docx-find-replace-find'),
              autocorrect: false,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: '찾을 말',
                errorText: _find.isNotEmpty && !validFind ? invalidText : null,
              ),
              onChanged: (value) {
                if (value == _find) return;
                setState(() {
                  _find = value;
                  _findVersion++;
                  _preview = null;
                  _searchError = null;
                });
              },
              onSubmitted: (_) => _search(),
            ),
            TextField(
              key: const ValueKey('docx-find-replace-replacement'),
              decoration: InputDecoration(
                labelText: '바꿀 말',
                helperText: '비워 두면 찾은 글자를 지웁니다.',
                errorText: validReplacement ? null : invalidText,
              ),
              onChanged: (value) => setState(() => _replacement = value),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              key: const ValueKey('docx-find-replace-preview'),
              onPressed: _canSearch ? _search : null,
              child: const Text('찾기 미리보기'),
            ),
            if (_searching) const LinearProgressIndicator(),
            if (_searchError case final error?) Text(error),
            if (preview != null)
              if (preview.matchCount == 0)
                const Text('일치하는 본문 글자가 없습니다.')
              else ...[
                Text('${preview.matchCount}곳 · ${preview.paragraphCount}개 문단'),
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    primary: false,
                    itemCount: preview.paragraphCount,
                    itemBuilder: (context, index) {
                      final match = preview.matches[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '문단 ${match.paragraphIndex + 1} · ${match.count}곳\n'
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
          key: const ValueKey('docx-find-replace-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('docx-find-replace-confirm'),
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
