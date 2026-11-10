import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';

class DailyNoteTemplateSettingsDialog extends StatefulWidget {
  const new({
    required this.store,
    required this.settings,
    required this.folders,
    super.key,
  });

  final WorkspaceMarkdownTemplateStore store;
  final WorkspaceDailyNoteTemplateSettings settings;
  final List<({String id, String label})> folders;

  @override
  State<DailyNoteTemplateSettingsDialog> createState() =>
      _DailyNoteTemplateSettingsDialogState();
}

class _DailyNoteTemplateSettingsDialogState
    extends State<DailyNoteTemplateSettingsDialog> {
  String? _folderId;
  Future<List<WorkspaceMarkdownTemplateChoice>>? _choices;
  WorkspaceMarkdownTemplateChoice? _selection;

  @override
  void initState() {
    super.initState();
    final savedFolder = widget.settings.folderId;
    final folder = widget.folders.any((folder) => folder.id == savedFolder)
        ? savedFolder
        : savedFolder == null
        ? widget.folders.singleOrNull?.id
        : null;
    _loadFolder(folder);
  }

  void _loadFolder(String? folder) {
    _folderId = folder;
    _selection = null;
    _choices = folder == null ? null : widget.store.templates(folder);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    final configured = settings.noteId != null;
    return AlertDialog(
      key: const ValueKey('daily-note-template-settings'),
      title: const Text('날짜별 노트 템플릿'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('새로 만드는 오늘 노트와 날짜별 노트에 적용됩니다.'),
            if (settings.conflicted)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('설정이 충돌했습니다. 템플릿을 다시 선택하거나 해제하세요.'),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('daily-note-template-folder'),
              initialValue: _folderId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '템플릿 폴더'),
              items: [
                for (final folder in widget.folders)
                  DropdownMenuItem(
                    value: folder.id,
                    child: Text(folder.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (folder) => setState(() => _loadFolder(folder)),
            ),
            const SizedBox(height: 12),
            if (_choices == null)
              Text(
                configured
                    ? '저장된 템플릿의 폴더를 찾을 수 없습니다.'
                    : widget.folders.isEmpty
                    ? '템플릿으로 쓸 Markdown 노트를 폴더에 넣어 주세요.'
                    : '템플릿이 있는 폴더를 선택하세요.',
              )
            else
              FutureBuilder<List<WorkspaceMarkdownTemplateChoice>>(
                future: _choices,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const Text('템플릿 목록을 열 수 없습니다. 폴더를 다시 선택하세요.');
                  }
                  final choices = snapshot.requireData;
                  final missing =
                      configured &&
                      settings.folderId == _folderId &&
                      !choices.any(
                        (choice) => choice.noteId == settings.noteId,
                      );
                  if (choices.isEmpty) {
                    return Text(
                      missing
                          ? '저장된 템플릿을 찾을 수 없습니다.'
                          : '이 폴더에 선택할 Markdown 템플릿이 없습니다.',
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (missing) const Text('저장된 템플릿을 찾을 수 없습니다.'),
                      SizedBox(
                        width: double.infinity,
                        height: min(choices.length * 72.0, 250.0),
                        child: ListView.builder(
                          primary: false,
                          padding: EdgeInsets.zero,
                          itemCount: choices.length,
                          itemBuilder: (context, index) {
                            final choice = choices[index];
                            final selected = identical(choice, _selection);
                            final current =
                                settings.folderId == _folderId &&
                                settings.noteId == choice.noteId;
                            return ListTile(
                              key: ValueKey(
                                'daily-note-template-choice-${choice.noteId}',
                              ),
                              title: Text(choice.label),
                              subtitle: current ? const Text('현재 템플릿') : null,
                              selected: selected,
                              trailing: selected
                                  ? const Icon(Icons.check)
                                  : null,
                              onTap: () => setState(() => _selection = choice),
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('daily-note-template-clear'),
          onPressed: configured || settings.conflicted
              ? () =>
                    Navigator.pop<({WorkspaceMarkdownTemplateChoice? choice})>(
                      context,
                      (choice: null),
                    )
              : null,
          child: const Text('템플릿 해제'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('daily-note-template-save'),
          onPressed: _selection == null
              ? null
              : () => Navigator.pop(context, (choice: _selection)),
          child: const Text('저장'),
        ),
      ],
    );
  }
}
