import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

export 'workspace_controller.dart';

class StudyWorkspace extends StatefulWidget {
  static final pendingPdfImport = ValueNotifier<String?>(null);
  final WorkspaceController? controller;
  final Widget Function(BuildContext, WorkspaceController)? driveActions;
  const new({super.key, this.controller, this.driveActions});
  @override
  State<StudyWorkspace> createState() => _StudyWorkspaceState();
}

class _StudyWorkspaceState extends State<StudyWorkspace>
    with WidgetsBindingObserver, WindowListener {
  WorkspaceController? controller;
  var _editor = GlobalKey<EditorState>();
  String? _editorIdentity;
  String? _pendingPdf;
  String? _targetPage;
  String? _startupError;
  String? _closeError;
  var markdownTab = false;
  var busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    StudyWorkspace.pendingPdfImport.addListener(_sharedPdf);
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final value =
          widget.controller ?? await WorkspaceController.openDefault();
      if (!mounted) {
        if (widget.controller == null) value.dispose();
        return;
      }
      controller = value;
      value.addListener(_changed);
      setState(() {});
      _sharedPdf();
    } catch (e) {
      if (mounted) setState(() => _startupError = '$e');
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _sharedPdf() {
    final path = StudyWorkspace.pendingPdfImport.value;
    if (path == null || controller == null || busy) return;
    unawaited(
      _run(() async {
        await _save();
        _pendingPdf = await _retainPdf(path);
        await controller!.createNote(
          p.basenameWithoutExtension(path),
          importingPdf: true,
        );
        StudyWorkspace.pendingPdfImport.value = null;
      }),
    );
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await operation();
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save() async {
    await _editor.currentState?.saveToFile();
    await controller!.flush();
  }

  Future<void> _open(VaultNote note) async {
    await _save();
    _pendingPdf = null;
    _targetPage = null;
    await controller!.openNote(note);
    if (mounted) Navigator.maybePop(context);
  }

  Future<void> _create({bool pdf = false}) async {
    await _save();
    String? path;
    if (pdf) {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (picked == null) return;
      path = picked.path;
      if (path == null) throw StateError('PDF 파일을 읽을 수 없습니다.');
    }
    _pendingPdf = path == null ? null : await _retainPdf(path);
    await controller!.createNote(
      path == null ? '새 노트' : p.basenameWithoutExtension(path),
      importingPdf: path != null,
    );
  }

  Future<String> _retainPdf(String path) async {
    final target = FileManager.getFile(
      '/.working/imports/${newId()}/original.pdf',
    );
    await target.parent.create(recursive: true);
    await File(path).copy(target.path);
    return target.path;
  }

  Future<void> _localVaults() async {
    await _save();
    final support = await getApplicationSupportDirectory();
    final parent = Directory('${support.path}/vaults');
    final roots = <Directory>[];
    if (parent.existsSync()) {
      await for (final entry in parent.list(followLinks: false)) {
        if (entry is Directory && File('${entry.path}/vault.json').existsSync())
          roots.add(entry);
      }
    }
    if (!mounted) return;
    final chosen = await showDialog<Directory>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('기기의 저장소'),
        children: [
          for (final root in roots)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, root),
              child: Text(p.basename(root.path)),
            ),
        ],
      ),
    );
    if (chosen != null &&
        chosen.absolute.path != controller!.repository.root.path) {
      await controller!.replaceRepository(await NoteRepository.open(chosen));
    }
  }

  Future<String?> _input(String title, String initial) async {
    final text = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: text,
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    text.dispose();
    return result;
  }

  Future<void> _openLink(String value) async {
    final link = NoteLink.parse(value);
    if (link != null) {
      await _save();
      final notes = await controller!.store.list();
      final match = notes.where((n) => n.id == link.noteId);
      if (match.isEmpty) throw StateError('이 저장소에서 노트를 찾을 수 없습니다.');
      _pendingPdf = null;
      _targetPage = link.pageId;
      await controller!.openNote(match.first);
    } else if (isSafeExternalLink(value)) {
      await launchUrl(Uri.parse(value), mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _conflicts() async {
    await _save();
    final c = controller!, session = controller!.activeSession!;
    final heads = <RevisionRecord>[];
    for (final id in [
      session.note.id,
      session.note.inkEntityId,
      session.note.markdownEntityId,
    ]) {
      final values = await c.repository.heads(id);
      if (values.length > 1) heads.addAll(values);
    }
    final previews = <String, String>{};
    for (final head in heads) {
      if (head.kind == EntityKind.markdown) {
        final files = await c.repository.readFiles(head);
        final text = utf8.decode(files['summary.md']!);
        previews[head.revisionId] = text.length > 500
            ? '${text.substring(0, 500)}…'
            : text;
      }
    }
    if (!mounted) return;
    final chosen = await showDialog<Object>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('충돌 버전 선택'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '선택한 내용으로 새 리비전을 만듭니다. 양쪽 원본은 이력에 보존됩니다. Markdown은 원문을 비교하고 합친 뒤 저장할 수 있습니다.',
            ),
          ),
          for (final h in heads)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${h.kind.name} · ${h.revisionId.substring(0, 8)} · ${h.deviceId.substring(0, 8)}${h.deleted ? ' · 삭제' : ''}',
                  ),
                  if (previews[h.revisionId] != null)
                    SelectableText(previews[h.revisionId]!),
                  Wrap(
                    children: [
                      if (h.kind != EntityKind.metadata)
                        TextButton(
                          onPressed: () => Navigator.pop(context, ('view', h)),
                          child: const Text('이 버전 열람'),
                        ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, h),
                        child: const Text('이 내용을 선택해 해결'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (heads.any((r) => r.kind == EntityKind.markdown))
            TextButton(
              onPressed: () => Navigator.pop(context, 'merge'),
              child: const Text('현재 Markdown을 합친 결과로 확정'),
            ),
        ],
      ),
    );
    if (chosen is RevisionRecord) await c.chooseRevision(chosen);
    if (chosen case ('view', final RevisionRecord head))
      await c.viewRevision(head);
    if (chosen == 'merge') await c.mergeMarkdown();
  }

  Future<void> _backup() async {
    await _save();
    final bytes = await BackupService.exportSnapshot(controller!.repository);
    if (!mounted) return;
    await FileManager.exportFile(
      'ink-vault-backup.json',
      bytes,
      context: context,
    );
  }

  Future<void> _restore() async {
    await _save();
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (file == null) return;
    if (file.path == null ||
        await File(file.path!).length() > BackupService.defaultMaxBytes) {
      throw const FormatException('백업 파일이 너무 큽니다 (최대 128 MiB).');
    }
    final support = await getApplicationSupportDirectory();
    final restored = await BackupService.restoreToEmpty(
      await file.readAsBytes(),
      Directory('${support.path}/vaults/restored-${newId()}'),
    );
    await controller!.replaceRepository(restored);
  }

  Widget _library(WorkspaceController c) => Column(
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 28, 16, 8),
        child: Text(
          'Personal Ink Vault',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: '제목·Markdown 검색',
          ),
          onChanged: (value) {
            c.query = value;
            unawaited(c.refresh());
          },
        ),
      ),
      Wrap(
        spacing: 8,
        children: [
          FilledButton.icon(
            onPressed: busy ? null : () => _run(() => _create(pdf: true)),
            icon: const Icon(Icons.picture_as_pdf),
            label: const Text('PDF 가져오기'),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => _run(_create),
            child: const Text('새 노트'),
          ),
        ],
      ),
      SwitchListTile(
        title: const Text('삭제한 노트 포함'),
        value: c.showDeleted,
        onChanged: (value) {
          c.showDeleted = value;
          unawaited(c.refresh());
        },
      ),
      Expanded(
        child: c.notes.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'PDF를 가져오거나 새 노트를 만드세요.\n기기에 저장한 뒤 Drive를 연결할 수 있습니다.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.builder(
                itemCount: c.notes.length,
                itemBuilder: (context, index) {
                  final note = c.notes[index];
                  return ListTile(
                    selected: c.activeSession?.note.id == note.id,
                    leading: Icon(
                      note.deletionConflict
                          ? Icons.warning_amber
                          : note.revision.deleted
                          ? Icons.restore_from_trash
                          : Icons.description_outlined,
                    ),
                    title: Text(note.title),
                    subtitle: Text(
                      note.deletionConflict
                          ? '삭제 충돌 · 오프라인 수정 보존됨'
                          : note.revision.deleted
                          ? '삭제됨 · 복원 가능'
                          : note.id.substring(0, 8),
                    ),
                    onTap: note.revision.deleted
                        ? null
                        : () => _run(() => _open(note)),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) => _run(() async {
                        await _save();
                        if (action == 'rename') {
                          final title = await _input('노트 이름', note.title);
                          if (title != null) await c.store.rename(note, title);
                        } else {
                          await c.store.setDeleted(
                            note,
                            !note.revision.deleted,
                          );
                        }
                        await c.refresh();
                      }),
                      itemBuilder: (context) => [
                        if (!note.revision.deleted)
                          const PopupMenuItem(
                            value: 'rename',
                            child: Text('이름 변경'),
                          ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(note.revision.deleted ? '복원' : '삭제'),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      if (widget.driveActions != null) widget.driveActions!(context, c),
      Wrap(
        children: [
          TextButton(
            onPressed: () => _run(_localVaults),
            child: const Text('기기의 저장소'),
          ),
          TextButton(
            onPressed: () => _run(_backup),
            child: const Text('백업 내보내기'),
          ),
          TextButton(
            onPressed: () => _run(_restore),
            child: const Text('별도 저장소로 복원'),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null)
      return Scaffold(
        body: Center(
          child: _startupError == null
              ? const CircularProgressIndicator()
              : Text('저장소를 열 수 없습니다: $_startupError'),
        ),
      );
    final session = c.activeSession;
    final desktop = !Platform.isAndroid;
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    Widget body;
    if (session == null) {
      body = const Center(
        child: Text(
          'PDF와 필기, Markdown을 함께 보관하세요.\n목록에서 노트를 선택하세요.',
          textAlign: TextAlign.center,
        ),
      );
    } else {
      final identity = '${session.note.id}/${c.editorGeneration}';
      if (_editorIdentity != identity) {
        _editor = GlobalKey<EditorState>();
        _editorIdentity = identity;
      }
      final ink = Editor(
        key: _editor,
        path: '/.working/${session.note.id}/new/main',
        customTitle: session.note.title,
        pdfPath: _pendingPdf,
        workspaceReadOnly: desktop,
        loadSnapshot: () async {
          final core = await c.loadInk(session: session);
          if (_targetPage != null) {
            final index = core.pages.indexWhere(
              (page) => page.pageId == _targetPage,
            );
            if (index < 0) throw StateError('연결된 페이지를 찾을 수 없습니다.');
            core.initialPageIndex = index;
          }
          return core;
        },
        onSaveSnapshot: (core, page) => c.saveInk(core, page, session: session),
        onDirtyChanged: (value) => c.setInkDirty(value, session: session),
        onBusyChanged: (value) => c.setInkBusy(value, session: session),
        onLoaded: (_) {
          if (identical(c.activeSession, session)) _pendingPdf = null;
        },
      );
      final markdown = MarkdownEditor(
        key: ValueKey(session.note.id),
        source: c.markdown,
        readOnly: !desktop,
        dirty: c.markdownDirty,
        onChanged: c.editMarkdown,
        onSave: () => _run(c.saveMarkdown),
        onOpenLink: (url) => _run(() => _openLink(url)),
      );
      body = desktop && wide
          ? Row(
              children: [
                Expanded(flex: 3, child: ink),
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: markdown),
              ],
            )
          : IndexedStack(index: markdownTab ? 1 : 0, children: [ink, markdown]);
    }
    return PopScope(
      canPop: !c.dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _run(_save);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(session?.note.title ?? 'Personal Ink Vault'),
          actions: [
            if (session != null) ...[
              IconButton(
                tooltip: '기기에 저장',
                onPressed: () => _run(_save),
                icon: const Icon(Icons.save_outlined),
              ),
              IconButton(
                tooltip: '현재 페이지 링크 복사',
                onPressed: () => _run(() async {
                  final editor = _editor.currentState;
                  final page = editor?.coreInfo.pages
                      .elementAtOrNull(editor.currentPageIndex)
                      ?.pageId;
                  await Clipboard.setData(
                    ClipboardData(
                      text: NoteLink(session.note.id, page).toString(),
                    ),
                  );
                }),
                icon: const Icon(Icons.link),
              ),
            ],
            IconButton(
              tooltip: '노트 링크 열기',
              onPressed: () => _run(() async {
                final link = await _input('inkvault 링크 열기', '');
                if (link != null) await _openLink(link);
              }),
              icon: const Icon(Icons.open_in_new),
            ),
          ],
        ),
        drawer: wide ? null : Drawer(child: _library(c)),
        body: Row(
          children: [
            if (wide) SizedBox(width: 300, child: _library(c)),
            if (wide) const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  if (busy) const LinearProgressIndicator(),
                  if (_closeError != null)
                    MaterialBanner(
                      content: Text(_closeError!),
                      actions: [
                        TextButton(
                          onPressed: busy ? null : onWindowClose,
                          child: const Text('다시 저장하고 닫기'),
                        ),
                      ],
                    ),
                  if (c.error != null)
                    MaterialBanner(
                      content: Text(c.error!),
                      actions: [
                        TextButton(
                          onPressed: () => _run(c.refresh),
                          child: const Text('다시 읽기'),
                        ),
                      ],
                    ),
                  if (c.remoteConflict)
                    MaterialBanner(
                      content: const Text(
                        '다른 버전이 있습니다. 작업본과 기존 부모 리비전을 보존합니다.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => _run(_conflicts),
                          child: const Text('충돌 확인'),
                        ),
                      ],
                    ),
                  Expanded(child: body),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: session == null || desktop && wide
            ? null
            : NavigationBar(
                selectedIndex: markdownTab ? 1 : 0,
                onDestinationSelected: (i) =>
                    setState(() => markdownTab = i == 1),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.draw_outlined),
                    label: 'PDF·필기',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.notes),
                    label: 'Markdown',
                  ),
                ],
              ),
      ),
    );
  }

  @override
  void onWindowClose() {
    if (controller == null) {
      unawaited(windowManager.destroy());
      return;
    }
    if (busy) return;
    unawaited(
      _run(() async {
        try {
          await _save();
          await windowManager.destroy();
        } catch (e) {
          if (mounted) setState(() => _closeError = '닫기 전에 저장하지 못했습니다: $e');
        }
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (controller != null && !busy) unawaited(_run(_save));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) windowManager.removeListener(this);
    StudyWorkspace.pendingPdfImport.removeListener(_sharedPdf);
    controller?.removeListener(_changed);
    if (widget.controller == null) controller?.dispose();
    super.dispose();
  }
}
