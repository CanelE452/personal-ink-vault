import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_media_worker.dart';
import 'package:saber/data/vault/block_page_table.dart';
import 'package:saber/data/vault/discussion_anchor.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/synced_block_store.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/block_inline_controller.dart';
import 'package:saber/pages/workspace/block_table_editor.dart';
import 'package:saber/pages/workspace/linked_database_block.dart';
import 'package:saber/pages/workspace/synced_block_view.dart';
import 'package:url_launcher/url_launcher.dart';

typedef _InlineTarget = ({
  BlockPageDocument owner,
  int session,
  int generation,
  String blockId,
  String text,
  TextSelection selection,
});

typedef _DeferredInline = ({
  _InlineTarget target,
  BlockInlineText range,
  void Function(_InlineTarget) command,
});

class BlockPageNote {
  const new(this.id, this.title);
  final String id;
  final String title;
}

class BlockPageEditor extends StatefulWidget {
  const new({
    super.key,
    required this.initialDocument,
    required this.onSave,
    required this.onBack,
    this.onDirtyChanged,
    this.onBusyChanged,
    this.onHistory,
    this.onDiscussion,
    this.notes = const [],
    this.onOpenNote,
    this.onSaveWithMedia,
    this.onReadMedia,
    this.onPickMedia,
    this.onExportMedia,
    this.databaseNotes = const [],
    this.linkedDatabaseAccess,
    this.syncedBlockAccess,
    this.onDiscardChanges,
    this.enableColumns = false,
    this.autosaveDelay = const Duration(milliseconds: 700),
  });
  final BlockPageDocument initialDocument;
  final Future<void> Function(BlockPageDocument) onSave;
  final VoidCallback onBack;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<bool>? onBusyChanged;
  final VoidCallback? onHistory;
  final void Function(String? blockId, TextSelection? selection)? onDiscussion;
  final List<BlockPageNote> notes;
  final ValueChanged<String>? onOpenNote;
  final Future<void> Function(BlockPageDocument, Map<String, Uint8List>)?
  onSaveWithMedia;
  final Future<Uint8List> Function(BlockPageMedia)? onReadMedia;
  final Future<BlockPageMediaAsset?> Function(bool image)? onPickMedia;
  final Future<void> Function(BlockPageMedia, Uint8List)? onExportMedia;
  final List<BlockPageNote> databaseNotes;
  final LinkedDatabaseAccess? linkedDatabaseAccess;
  final SyncedBlockAccess? syncedBlockAccess;
  final VoidCallback? onDiscardChanges;
  final bool enableColumns;
  final Duration autosaveDelay;
  @override
  State<BlockPageEditor> createState() => BlockPageEditorState();
}

class BlockPageEditorState extends State<BlockPageEditor> {
  static const _teal = Color(0xff237d82);
  late BlockPageDocument _document;
  final _undo = <BlockPageDocument>[];
  final _redo = <BlockPageDocument>[];
  final _text = <String, BlockInlineController>{};
  final _focus = <String, FocusNode>{};
  var _session = 0;
  String? _activeInlineId;
  _DeferredInline? _deferredInline;
  var _syncingControllers = false;
  BlockPageDocument? _promotionCheckedDocument;
  var _promotionAllowed = false;
  var _generation = 0;
  var _savedGeneration = 0;
  var _saving = false;
  var _saveFailed = false;
  var _reportedDirty = false;
  var _reportedBusy = false;
  var _choosingType = false;
  var _pickingMedia = false;
  var _exportingMedia = false;
  ValueChanged<bool>? _busyOwner;
  final _pendingMedia = <String, Uint8List>{};
  final _mediaLoads = <String, Future<Uint8List>>{};
  Timer? _autosave;
  Future<void>? _saveFuture;
  final _linkedKeys = <String, GlobalKey<LinkedDatabaseBlockState>>{};
  final _syncedKeys = <String, GlobalKey<SyncedBlockViewState>>{};
  final _linkedDirty = <String, bool>{};
  final _linkedBusy = <String, bool>{};
  var _choosingLinkedDatabase = false;
  var _choosingSyncedBlock = false;
  var _detachingSyncedBlock = false;

  BlockPageDocument get document => _document;
  bool get _dirty =>
      _generation != _savedGeneration || _linkedDirty.values.any((v) => v);
  bool get _linkedPending =>
      _linkedDirty.values.any((v) => v) || _linkedBusy.values.any((v) => v);
  bool get _structuralBusy =>
      _mediaOperation ||
      _linkedPending ||
      _choosingLinkedDatabase ||
      _choosingSyncedBlock ||
      _detachingSyncedBlock;
  bool get _isComposing => _text.values.any((controller) {
    final composing = controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  });

  bool get _canDetachSyncedBlock =>
      !_dirty &&
      !_busy &&
      !_choosingType &&
      !_saveFailed &&
      _saveFuture == null &&
      !_isComposing;

  @override
  void initState() {
    super.initState();
    _document = widget.initialDocument;
  }

  @override
  void didUpdateWidget(BlockPageEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.initialDocument, widget.initialDocument)) return;
    _autosave?.cancel();
    final oldBusyOwner = _busyOwner;
    if (_reportedBusy) scheduleMicrotask(() => oldBusyOwner?.call(false));
    if (_reportedDirty) {
      scheduleMicrotask(() => oldWidget.onDirtyChanged?.call(false));
    }
    final retiredText = _text.values.toList();
    final retiredFocus = _focus.values.toList();
    _text.clear();
    _focus.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in retiredText) {
        controller.dispose();
      }
      for (final focus in retiredFocus) {
        focus.dispose();
      }
    });
    _session++;
    _document = widget.initialDocument;
    _undo.clear();
    _redo.clear();
    _generation = _savedGeneration = 0;
    _saving = _saveFailed = _reportedDirty = _reportedBusy = false;
    _pickingMedia = _exportingMedia = false;
    _choosingType = false;
    _busyOwner = null;
    _saveFuture = null;
    _activeInlineId = null;
    _deferredInline = null;
    _pendingMedia.clear();
    _mediaLoads.clear();
    _linkedKeys.clear();
    _syncedKeys.clear();
    _linkedDirty.clear();
    _linkedBusy.clear();
    _choosingLinkedDatabase = false;
    _choosingSyncedBlock = false;
    _detachingSyncedBlock = false;
  }

  void _notify() {
    if (_reportedDirty != _dirty) {
      _reportedDirty = _dirty;
      widget.onDirtyChanged?.call(_dirty);
    }
    if (_reportedBusy != _busy) {
      _reportedBusy = _busy;
      if (_busy) {
        _busyOwner = widget.onBusyChanged;
        _busyOwner?.call(true);
      } else {
        _busyOwner?.call(false);
        _busyOwner = null;
      }
    }
  }

  void _commit(BlockPageDocument next) {
    if (_detachingSyncedBlock) return;
    BlockPageBlock? find(List<BlockPageBlock> blocks, String id) {
      for (final block in blocks) {
        if (block.id == id) return block;
        final child = find(block.children, id);
        if (child != null) return child;
      }
      return null;
    }

    for (final id in {..._linkedKeys.keys, ..._syncedKeys.keys}) {
      if (_linkedDirty[id] != true && _linkedBusy[id] != true) continue;
      bool visible(List<BlockPageBlock> blocks) {
        for (final block in blocks) {
          if (block.id == id) return true;
          if ((block.type != 'toggle' || !block.collapsed) &&
              visible(block.children))
            return true;
        }
        return false;
      }

      final before = _find(id);
      final after = find(next.blocks, id);
      if (before?.linkedDatabase?.noteId != after?.linkedDatabase?.noteId ||
          before?.syncedBlock?.sourceNoteId !=
              after?.syncedBlock?.sourceNoteId ||
          before?.syncedBlock?.sourceBlockId !=
              after?.syncedBlock?.sourceBlockId ||
          !visible(next.blocks)) {
        _mediaError(
          _syncedKeys.containsKey(id)
              ? '동기화 블록의 편집 내용을 먼저 저장하세요.'
              : '연결된 데이터베이스의 편집 내용을 먼저 저장하세요.',
        );
        return;
      }
    }
    setState(() {
      _undo.add(_document);
      _redo.clear();
      _document = next;
      _generation++;
      _syncControllers();
      _pruneLinkedKeys();
    });
    _notify();
    _scheduleSave();
  }

  void _pruneLinkedKeys() {
    final live = <String>{};
    void visit(BlockPageBlock block) {
      if (block.linkedDatabase != null || block.syncedBlock != null) {
        live.add(block.id);
      }
      for (final child in block.children) {
        visit(child);
      }
    }

    for (final block in _document.blocks) {
      visit(block);
    }
    _linkedKeys.removeWhere((id, _) => !live.contains(id));
    _syncedKeys.removeWhere((id, _) => !live.contains(id));
    _linkedDirty.removeWhere((id, _) => !live.contains(id));
    _linkedBusy.removeWhere((id, _) => !live.contains(id));
  }

  void _scheduleSave() {
    _autosave?.cancel();
    _autosave = Timer(widget.autosaveDelay, () {
      if (mounted) unawaited(_saveFromUi());
    });
  }

  void _undoOrRedo({required bool redo}) {
    if (_structuralBusy) return;
    final source = redo ? _redo : _undo;
    if (source.isEmpty) return;
    final BlockPageDocument next;
    try {
      next = source.last.copyWith(minimumVersion: _document.version);
    } on FormatException {
      _mediaError('이전 데이터 형식을 보존하기 위해 이 작업을 되돌릴 수 없습니다.');
      return;
    }
    setState(() {
      (redo ? _undo : _redo).add(_document);
      source.removeLast();
      _document = next;
      _generation++;
      _deferredInline = null;
      _syncControllers();
      _pruneLinkedKeys();
    });
    _notify();
    _scheduleSave();
  }

  Future<void> save() {
    if (_detachingSyncedBlock) {
      return Future.error(StateError('동기화 블록 연결 해제를 먼저 마치세요.'));
    }
    if (_mediaOperation) {
      return Future.error(StateError('파일 선택 또는 저장을 먼저 마치세요.'));
    }
    _autosave?.cancel();
    final pending = _saveFuture;
    if (pending != null) return pending;
    final saving = _saveCurrent();
    _saveFuture = saving;
    saving.then(
      (_) {
        if (identical(_saveFuture, saving)) _saveFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_saveFuture, saving)) _saveFuture = null;
      },
    );
    return saving;
  }

  Future<void> _saveCurrent() async {
    final owner = widget.initialDocument;
    final session = _session;
    final saveMedia = widget.onSaveWithMedia;
    final saveText = widget.onSave;
    _saving = true;
    _notify();
    if (mounted) setState(() {});
    try {
      Future<void> saveLinked() async {
        for (final key in List.of(_linkedKeys.values)) {
          await key.currentState?.save();
        }
      }

      await saveLinked();
      while (_dirty) {
        if (!mounted ||
            _session != session ||
            !identical(widget.initialDocument, owner)) {
          throw StateError('페이지 편집 세션이 바뀌었습니다.');
        }
        await saveLinked();
        if (_generation == _savedGeneration) {
          // The source write must be able to prove that the host reference
          // exists in the committed page.
          for (final entry in List.of(_syncedKeys.entries)) {
            if (_linkedDirty[entry.key] != true) continue;
            final view = entry.value.currentState;
            if (view == null) throw StateError('동기화 블록 편집기를 찾을 수 없습니다.');
            await view.save();
          }
          continue;
        }
        final generation = _generation;
        final document = _document;
        final pending = <String, Uint8List>{
          for (final reference in document.media.values)
            if (_pendingMedia[reference.path] case final Uint8List bytes)
              reference.path: bytes,
        };
        if (saveMedia != null) {
          await saveMedia(
            document,
            Map.unmodifiable({
              for (final entry in pending.entries)
                entry.key: Uint8List.fromList(entry.value),
            }),
          );
        } else {
          if (pending.isNotEmpty) {
            throw StateError('첨부 파일을 함께 저장할 수 없습니다.');
          }
          await saveText(document);
        }
        if (!mounted ||
            _session != session ||
            !identical(widget.initialDocument, owner)) {
          throw StateError('페이지 편집 세션이 바뀌었습니다.');
        }
        for (final entry in pending.entries) {
          if (identical(_pendingMedia[entry.key], entry.value)) {
            _pendingMedia.remove(entry.key);
          }
        }
        _savedGeneration = generation;
        _saveFailed = false;
        if (mounted) _notify();
      }
      _saveFailed = false;
    } catch (_) {
      if (_session == session) _saveFailed = true;
      rethrow;
    } finally {
      if (mounted && _session == session) {
        _saving = false;
        _notify();
        setState(() {});
      }
    }
  }

  Future<void> _saveFromUi() async {
    try {
      await save();
    } catch (_) {
      /* The document remains open with its retry action. */
    }
  }

  Future<void> _back() async {
    try {
      await save();
      if (mounted) widget.onBack();
    } catch (_) {
      /* Keep the current draft. */
    }
  }

  bool get _mediaOperation => _pickingMedia || _exportingMedia;
  bool get _busy =>
      _saving ||
      _mediaOperation ||
      _choosingLinkedDatabase ||
      _choosingSyncedBlock ||
      _detachingSyncedBlock ||
      _linkedBusy.values.any((v) => v);

  Future<BlockPageMediaAsset?> _pickMedia(bool image) async {
    final file = await FilePicker.pickFile(
      dialogTitle: image ? '이미지 추가' : '파일 첨부',
      type: image ? FileType.custom : FileType.any,
      allowedExtensions: image ? ['png', 'jpg', 'jpeg'] : null,
    );
    if (file == null) return null;
    final maximum = image
        ? 20 * 1024 * 1024
        : BlockPageMediaAsset.maxAttachmentBytes;
    final length = file.lengthSync() ?? await file.length();
    if (length != null && (length < 1 || length > maximum)) {
      throw const FormatException('파일 크기를 확인하세요.');
    }
    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in file.readAsByteStream()) {
      received += chunk.length;
      if (received > maximum) {
        throw const FormatException('파일 크기를 확인하세요.');
      }
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    final name = file.name;
    return createBlockPageMediaAssetInWorker(
      name: name,
      bytes: bytes,
      image: image,
    );
  }

  Future<void> _importMedia(bool image, {String? blockId}) async {
    if (widget.onSaveWithMedia == null || _busy) return;
    final owner = widget.initialDocument;
    final session = _session;
    final previous = blockId == null ? null : _document.media[blockId];
    if (blockId != null && previous == null) return;
    setState(() => _pickingMedia = true);
    _notify();
    try {
      final asset = await (widget.onPickMedia ?? _pickMedia)(image);
      if (!mounted ||
          !identical(widget.initialDocument, owner) ||
          asset == null) {
        return;
      }
      if (blockId != null &&
          (_find(blockId) == null ||
              _document.media[blockId]?.path != previous!.path)) {
        return;
      }
      final reference = asset.reference;
      if (image && !reference.isImage) {
        throw const FormatException('PNG 또는 JPEG 이미지를 선택하세요.');
      }
      final bytes = asset.bytes;
      await verifyBlockPageMediaBytes(reference, bytes);
      if (!mounted || !identical(widget.initialDocument, owner)) return;
      final current = blockId == null ? null : _find(blockId);
      if (blockId != null &&
          (current == null ||
              _document.media[blockId]?.path != previous!.path)) {
        return;
      }
      final pendingBytes = _pendingMedia.entries.fold<int>(
        bytes.length,
        (sum, entry) =>
            entry.key == reference.path ? sum : sum + entry.value.length,
      );
      if (pendingBytes > 128 * 1024 * 1024) {
        throw const FormatException('첨부 파일 용량을 줄인 뒤 다시 시도하세요.');
      }
      final block =
          current?.copyWith(type: image ? 'image' : 'attachment') ??
          BlockPageBlock.create(type: image ? 'image' : 'attachment');
      final next = _document.copyWith(
        blocks: current == null
            ? [..._document.blocks, block]
            : _replace(_document.blocks, block.id, (_) => block),
        media: {..._document.media, block.id: reference},
      );
      _pendingMedia[reference.path] = bytes;
      _mediaLoads.remove(_mediaKey(reference));
      _commit(next);
    } catch (_) {
      if (mounted && identical(widget.initialDocument, owner)) {
        _mediaError(
          image
              ? '이미지를 추가하지 못했습니다. PNG·JPEG 파일과 크기를 확인하세요.'
              : '파일을 첨부하지 못했습니다. 파일 크기와 읽기 권한을 확인하세요.',
        );
      }
    } finally {
      if (mounted && _session == session) {
        setState(() => _pickingMedia = false);
        _notify();
        if (_dirty) _scheduleSave();
      }
    }
  }

  String _mediaKey(BlockPageMedia media) => '${media.path}:${media.sha256}';

  Future<Uint8List> _readMedia(BlockPageMedia media) async {
    final owner = widget.initialDocument;
    final pending = _pendingMedia[media.path];
    final reader = widget.onReadMedia;
    if (pending == null && reader == null) {
      throw StateError('첨부 파일을 읽을 수 없습니다.');
    }
    final bytes = Uint8List.fromList(pending ?? await reader!(media));
    if (!mounted || !identical(widget.initialDocument, owner)) {
      throw StateError('페이지 편집 세션이 바뀌었습니다.');
    }
    await verifyBlockPageMediaBytes(media, bytes);
    if (!mounted || !identical(widget.initialDocument, owner)) {
      throw StateError('페이지 편집 세션이 바뀌었습니다.');
    }
    return bytes;
  }

  Future<void> _exportMedia(BlockPageBlock block, BlockPageMedia media) async {
    if (_busy) return;
    final owner = widget.initialDocument;
    final session = _session;
    setState(() => _exportingMedia = true);
    _notify();
    try {
      final bytes = await _readMedia(media);
      if (!mounted ||
          !identical(widget.initialDocument, owner) ||
          _document.media[block.id]?.path != media.path) {
        return;
      }
      final exporter = widget.onExportMedia;
      if (exporter != null) {
        await exporter(media, Uint8List.fromList(bytes));
      } else {
        await FilePicker.saveFile(
          dialogTitle: '첨부 파일 저장',
          fileName: _mediaFileName(media),
          bytes: bytes,
          mimeType: media.mimeType,
        );
      }
    } catch (_) {
      if (mounted && identical(widget.initialDocument, owner)) {
        _mediaError('파일을 저장하지 못했습니다. 다시 시도하세요.');
      }
    } finally {
      if (mounted && _session == session) {
        setState(() => _exportingMedia = false);
        _notify();
        if (_dirty) _scheduleSave();
      }
    }
  }

  String _mediaFileName(BlockPageMedia media) {
    var name = media.name
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    final stem = name.split('.').first.toUpperCase();
    if (name.isEmpty ||
        RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(stem)) {
      return '첨부파일.${media.path.split('.').last}';
    }
    if (name.length > 200) {
      name = name.substring(0, 180);
      if (RegExp(r'[\uD800-\uDBFF]$').hasMatch(name)) {
        name = name.substring(0, name.length - 1);
      }
      name += '.${media.path.split('.').last}';
    }
    return name;
  }

  void _mediaError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _mediaSize(int bytes) => bytes < 1024
      ? '$bytes B'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(1)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  Widget _mediaEditor(
    BlockPageBlock block,
    BlockPageMedia media,
    Widget caption,
  ) {
    final canRead =
        _pendingMedia.containsKey(media.path) || widget.onReadMedia != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                media.isImage ? Icons.image_outlined : Icons.attach_file,
                size: 20,
                color: _teal,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  media.name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        if (block.type == 'image')
          FutureBuilder<Uint8List>(
            future: _mediaLoads.putIfAbsent(
              _mediaKey(media),
              () => _readMedia(media),
            ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.hasData) {
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: Image.memory(
                    snapshot.data!,
                    key: ValueKey('block-media-image-${block.id}'),
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Text('이미지를 표시하지 못했습니다.'),
                  ),
                );
              }
              if (snapshot.connectionState == ConnectionState.done &&
                  snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [
                      const Text('이미지를 읽지 못했습니다.'),
                      if (canRead)
                        TextButton(
                          key: ValueKey('block-media-retry-${block.id}'),
                          onPressed: () => setState(() {
                            _mediaLoads.remove(_mediaKey(media));
                          }),
                          child: const Text('다시 불러오기'),
                        ),
                    ],
                  ),
                );
              }
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              );
            },
          ),
        Wrap(
          spacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              _mediaSize(media.byteLength),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton.icon(
              key: ValueKey('block-media-export-${block.id}'),
              onPressed: !canRead || _busy
                  ? null
                  : () => unawaited(_exportMedia(block, media)),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('파일 저장'),
            ),
          ],
        ),
        caption,
      ],
    );
  }

  BlockPageBlock? _find(String id, [List<BlockPageBlock>? blocks]) {
    for (final block in blocks ?? _document.blocks) {
      if (block.id == id) return block;
      final child = _find(id, block.children);
      if (child != null) return child;
    }
    return null;
  }

  List<BlockPageBlock> _replace(
    List<BlockPageBlock> blocks,
    String id,
    BlockPageBlock Function(BlockPageBlock) change,
  ) => [
    for (final block in blocks)
      if (block.id == id)
        change(block)
      else if (block.children.isNotEmpty)
        block.copyWith(children: _replace(block.children, id, change))
      else
        block,
  ];

  void _update(String id, BlockPageBlock Function(BlockPageBlock) change) {
    if (_find(id) == null) return;
    _commit(_document.copyWith(blocks: _replace(_document.blocks, id, change)));
  }

  BlockPageTable? _updateTable(
    String id,
    BlockPageTable expected,
    BlockPageTable next,
  ) {
    if (!mounted || _mediaOperation) return null;
    final block = _find(id);
    if (block == null || !identical(block.table, expected)) return null;
    _update(id, (current) => current.copyWith(table: next));
    return _find(id)?.table;
  }

  List<BlockPageBlock> _remove(List<BlockPageBlock> blocks, String id) => [
    for (final block in blocks)
      if (block.id != id)
        if (block.children.isEmpty)
          block
        else
          block.copyWith(children: _remove(block.children, id)),
  ];

  List<BlockPageBlock> _move(
    List<BlockPageBlock> blocks,
    String id,
    int delta,
  ) {
    final index = blocks.indexWhere((block) => block.id == id);
    if (index >= 0) {
      final destination = (index + delta).clamp(0, blocks.length - 1);
      final moved = List.of(blocks);
      moved.insert(destination, moved.removeAt(index));
      return moved;
    }
    return [
      for (final block in blocks)
        if (block.children.isEmpty)
          block
        else
          block.copyWith(children: _move(block.children, id, delta)),
    ];
  }

  void _add(String type) {
    if (_structuralBusy) return;
    if (type == 'columns') {
      if (!widget.enableColumns) return;
      _addColumnBlocks(
        () => [..._document.blocks, BlockPageBlock.createColumns()],
      );
      return;
    }
    if (type == 'linkedDatabase') {
      unawaited(_addLinkedDatabase());
      return;
    }
    if (type == 'syncedBlock') {
      unawaited(_addSyncedBlock());
      return;
    }
    if (type == 'image' || type == 'attachment') {
      unawaited(_importMedia(type == 'image'));
      return;
    }
    final block = type == 'table'
        ? BlockPageBlock.createTable()
        : BlockPageBlock.create(type: type);
    _commit(_document.copyWith(blocks: [..._document.blocks, block]));
    _focusAddedBlock(block.id);
  }

  void _focusAddedBlock(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus[id]?.requestFocus();
    });
  }

  Iterable<BlockPageBlock> get _columnGroups =>
      _document.blocks.where((block) => block.isColumnLayout);

  bool _addColumnBlocks(List<BlockPageBlock> Function() blocks) {
    final BlockPageDocument next;
    try {
      next = _document.copyWith(blocks: blocks());
    } on FormatException {
      _mediaError('블록 수 제한에 도달했습니다.');
      return false;
    }
    _commit(next);
    return true;
  }

  void _addColumnParagraph(String groupId, String columnId) {
    if (!widget.enableColumns || _structuralBusy) return;
    final group = _columnGroups
        .where((block) => block.id == groupId)
        .firstOrNull;
    if (group == null ||
        !group.children.any((column) => column.id == columnId)) {
      return;
    }
    final block = BlockPageBlock.create();
    final added = _addColumnBlocks(
      () => [
        for (final root in _document.blocks)
          if (root.id == groupId)
            root.copyWith(
              children: [
                for (final column in root.children)
                  if (column.id == columnId)
                    column.copyWith(children: [...column.children, block])
                  else
                    column,
              ],
            )
          else
            root,
      ],
    );
    if (added) _focusAddedBlock(block.id);
  }

  Future<void> _chooseColumn(String id, String? currentColumnId) async {
    if (!widget.enableColumns || _structuralBusy) return;
    final choices = [
      for (final (groupIndex, group) in _columnGroups.indexed)
        for (final (columnIndex, column) in group.children.indexed)
          if (column.id != currentColumnId)
            (
              id: column.id,
              label: '${groupIndex + 1}번째 2단 · ${_columnTitle(columnIndex)}',
            ),
    ];
    if (choices.isEmpty) return;
    final owner = _document;
    final session = _session;
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('이동할 단'),
        children: [
          for (final choice in choices)
            SimpleDialogOption(
              key: ValueKey('column-move-target-${choice.id}'),
              onPressed: () => Navigator.pop(context, choice.id),
              child: Text(choice.label),
            ),
        ],
      ),
    );
    if (!mounted ||
        selected == null ||
        _session != session ||
        !identical(_document, owner)) {
      return;
    }
    _moveToColumn(id, selected);
  }

  void _moveToColumn(String id, String? columnId) {
    if (!widget.enableColumns || _structuralBusy) return;
    final next = _document.moveBlockToColumn(blockId: id, columnId: columnId);
    if (!identical(next, _document)) _commit(next);
  }

  Future<void> _addLinkedDatabase() async {
    final access = widget.linkedDatabaseAccess;
    if (access == null || _structuralBusy) return;
    final owner = widget.initialDocument;
    final session = _session;
    final choices = List.of(widget.databaseNotes);
    _choosingLinkedDatabase = true;
    _notify();
    try {
      final noteId = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('연결할 데이터베이스'),
          children: [
            if (choices.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('먼저 데이터베이스를 만드세요.'),
              ),
            for (final note in choices)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, note.id),
                child: Text(note.title),
              ),
          ],
        ),
      );
      bool current() =>
          mounted &&
          _session == session &&
          identical(widget.initialDocument, owner) &&
          access.isCurrent();
      if (noteId == null || !current()) return;
      final source = await access.open(noteId);
      try {
        if (!current()) return;
        final views = source.database.views;
        final view = views.isEmpty ? DatabaseView.create() : views.first;
        final block = BlockPageBlock.createLinkedDatabase(
          noteId: noteId,
          view: view.copyWith(name: '이 페이지 보기'),
          text: source.target.note.title,
        );
        _commit(_document.copyWith(blocks: [..._document.blocks, block]));
      } finally {
        source.close();
      }
    } catch (error) {
      if (mounted && _session == session) {
        _mediaError('연결된 데이터베이스를 열 수 없습니다: $error');
      }
    } finally {
      if (mounted && _session == session) {
        setState(() => _choosingLinkedDatabase = false);
        _notify();
      }
    }
  }

  Widget _linkedDatabase(BlockPageBlock block) {
    final reference = block.linkedDatabase;
    final access = widget.linkedDatabaseAccess;
    if (reference == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('지원하지 않는 연결 DB 형식 · 원본 보관됨'),
      );
    }
    if (access == null) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('연결된 데이터베이스를 열 수 없습니다. 원본 연결은 보관됩니다.'),
      );
    }
    final key = _linkedKeys.putIfAbsent(
      block.id,
      () => GlobalKey<LinkedDatabaseBlockState>(),
    );
    final session = _session;
    bool current() =>
        mounted && _session == session && identical(_linkedKeys[block.id], key);
    void report(Map<String, bool> values, bool value) {
      if (!current() || values[block.id] == value) return;
      setState(() => values[block.id] = value);
      _notify();
    }

    return LinkedDatabaseBlock(
      key: key,
      reference: reference,
      access: access,
      notes: widget.notes,
      onOpenNote: (id) async {
        try {
          await save();
          if (current()) widget.onOpenNote?.call(id);
        } catch (_) {
          // The source editor and its failed draft stay open.
        }
      },
      onViewChanged: (view) {
        if (!current()) return;
        final source = _find(block.id)?.linkedDatabase;
        if (source == null || source.noteId != reference.noteId) return;
        _update(
          block.id,
          (value) =>
              value.copyWith(linkedDatabase: source.copyWith(view: view)),
        );
      },
      onDirtyChanged: (value) => report(_linkedDirty, value),
      onBusyChanged: (value) => report(_linkedBusy, value),
      onSaved: () {
        if (!current()) return;
        for (final entry in List.of(_linkedKeys.entries)) {
          if (entry.key != block.id &&
              _find(entry.key)?.linkedDatabase?.noteId == reference.noteId) {
            entry.value.currentState?.reloadIfClean();
          }
        }
      },
    );
  }

  Future<void> _addSyncedBlock() async {
    final access = widget.syncedBlockAccess;
    if (access == null || _structuralBusy) return;
    final session = _session;
    bool current() => mounted && session == _session && access.isCurrent();

    setState(() => _choosingSyncedBlock = true);
    _notify();
    try {
      final pages = await access.listPages();
      if (!current()) return;
      final page = await _chooseSyncedItem(
        title: '원본 페이지 선택',
        empty: '먼저 다른 블록 페이지를 만드세요.',
        items: pages,
        label: (page) => page.title,
      );
      if (page == null || !current()) return;
      final sources = await access.listSources(page.id);
      if (!current()) return;
      final source = await _chooseSyncedItem<SyncedBlockTarget>(
        title: '원본 블록 선택',
        empty: '연결할 수 있는 저장된 텍스트 블록이 없습니다.',
        items: sources,
        label: (source) =>
            source.block.text.isEmpty ? '빈 텍스트 블록' : source.block.text,
      );
      if (source == null || !current()) return;
      final latest = await access.open(source.reference);
      if (!current()) return;
      final block = BlockPageBlock.createSyncedBlock(
        reference: latest.reference,
      );
      _commit(_document.copyWith(blocks: [..._document.blocks, block]));
    } catch (error) {
      if (current()) _mediaError('동기화 블록을 추가할 수 없습니다. $error');
    } finally {
      if (mounted && session == _session) {
        setState(() => _choosingSyncedBlock = false);
        _notify();
      }
    }
  }

  Future<T?> _chooseSyncedItem<T>({
    required String title,
    required String empty,
    required List<T> items,
    required String Function(T) label,
  }) => showDialog<T>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: items.isEmpty
          ? Text(empty)
          : SizedBox(
              width: 480,
              height: 320,
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    title: Text(
                      label(item),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, item),
                  );
                },
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
      ],
    ),
  );

  Widget _syncedBlock(BlockPageBlock block) {
    final reference = block.syncedBlock;
    final access = widget.syncedBlockAccess;
    if (reference == null ||
        access == null ||
        reference.sourceNoteId == access.ownerNoteId) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('이 동기화 블록을 열 수 없습니다. 원본 연결은 보관됩니다.'),
      );
    }
    final key = _syncedKeys.putIfAbsent(
      block.id,
      () => GlobalKey<SyncedBlockViewState>(),
    );
    final session = _session;
    bool current() =>
        mounted && _session == session && identical(_syncedKeys[block.id], key);
    return SyncedBlockView(
      key: key,
      blockId: block.id,
      reference: reference,
      access: access,
      onSaveRequested: () => unawaited(_saveFromUi()),
      onDetachRequested: access.detach == null || !_canDetachSyncedBlock
          ? null
          : (target, requireWrite) =>
                _detachSyncedBlock(access, block.id, target, requireWrite),
      onDirtyChanged: (dirty) {
        if (!current() || (_linkedDirty[block.id] ?? false) == dirty) return;
        setState(() {
          _linkedDirty[block.id] = dirty;
          if (!_dirty) _saveFailed = false;
        });
        _notify();
      },
      onOpenSource: widget.onOpenNote == null
          ? null
          : () async {
              try {
                await save();
                if (current()) widget.onOpenNote?.call(reference.sourceNoteId);
              } catch (_) {
                // Keep a draft on the connected page if saving fails.
              }
            },
    );
  }

  Future<void> _detachSyncedBlock(
    SyncedBlockAccess access,
    String id,
    SyncedBlockTarget target,
    void Function() requireSource,
  ) async {
    final detach = access.detach;
    if (detach == null || !_canDetachSyncedBlock) {
      throw StateError('현재 페이지를 먼저 저장하세요.');
    }
    final session = _session;
    final before = _document;
    bool current() =>
        mounted &&
        _session == session &&
        identical(widget.syncedBlockAccess?.owner, access.owner) &&
        access.isCurrent() &&
        identical(_document, before);
    void requireWrite() {
      if (!current() || _dirty) {
        throw StateError('연결을 해제하는 동안 페이지가 바뀌었습니다.');
      }
      requireSource();
    }

    requireWrite();
    _autosave?.cancel();
    setState(() => _detachingSyncedBlock = true);
    _notify();
    try {
      final committed = await detach(target, id, requireWrite);
      if (!current()) return;
      setState(() {
        _undo.add(before);
        _redo.clear();
        _document = committed;
        _savedGeneration = ++_generation;
        _deferredInline = null;
        _saveFailed = false;
        _syncControllers();
        _pruneLinkedKeys();
      });
    } finally {
      if (mounted && _session == session) {
        setState(() => _detachingSyncedBlock = false);
        _notify();
      }
    }
  }

  bool get _canPromoteInline {
    if (identical(_promotionCheckedDocument, _document))
      return _promotionAllowed;
    _promotionCheckedDocument = _document;
    try {
      _document.copyWith(minimumVersion: 3);
      _promotionAllowed = true;
    } on FormatException {
      _promotionAllowed = false;
    }
    return _promotionAllowed;
  }

  bool _canFormat(BlockPageBlock block) =>
      _canPromoteInline &&
      (_blockLabels.containsKey(block.type) ||
          _document.media.containsKey(block.id)) &&
      !const {
        'code',
        'equation',
        'divider',
        'documentLink',
        'link',
      }.contains(block.type) &&
      (!block.toJson().containsKey('inlineData') || block.inlineText != null);

  BlockInlineController _textFor(BlockPageBlock block) =>
      _text.putIfAbsent(block.id, () {
        final controller = BlockInlineController(
          text: block.text,
          inlineText: block.inlineText,
        )..showFormatting = _canFormat(block);
        final session = _session;
        controller.addListener(() {
          if (_syncingControllers || !mounted || session != _session) return;
          final pending = _deferredInline;
          if (pending != null &&
              pending.target.blockId == block.id &&
              controller.value.composing.isCollapsed) {
            scheduleMicrotask(_flushDeferredInline);
          }
        });
        return controller;
      });

  FocusNode _focusFor(String id) => _focus.putIfAbsent(id, () {
    final focus = FocusNode();
    final session = _session;
    focus.addListener(() {
      if (mounted &&
          session == _session &&
          focus.hasFocus &&
          _activeInlineId != id) {
        setState(() => _activeInlineId = id);
      }
    });
    return focus;
  });

  void _syncControllers() {
    _syncingControllers = true;
    try {
      for (final entry in _text.entries) {
        final block = _find(entry.key);
        if (block != null) {
          entry.value.sync(
            block.text,
            block.inlineText,
            enabled: _canFormat(block),
          );
        }
      }
    } finally {
      _syncingControllers = false;
    }
  }

  _InlineTarget? _inlineTarget(String id, {bool requireSelection = true}) {
    final block = _find(id);
    final controller = _text[id];
    if (_mediaOperation ||
        block == null ||
        !_canFormat(block) ||
        controller == null)
      return null;
    final selection = controller.selection;
    if (!selection.isValid ||
        selection.end > block.text.length ||
        requireSelection && selection.isCollapsed)
      return null;
    return (
      owner: widget.initialDocument,
      session: _session,
      generation: _generation,
      blockId: id,
      text: block.text,
      selection: selection,
    );
  }

  bool _targetIsCurrent(_InlineTarget target) {
    final block = _find(target.blockId);
    return mounted &&
        _session == target.session &&
        identical(widget.initialDocument, target.owner) &&
        _generation == target.generation &&
        block != null &&
        block.text == target.text &&
        _canFormat(block) &&
        !_mediaOperation;
  }

  void _inlineCommand(String id, void Function(_InlineTarget) command) {
    final target = _inlineTarget(id);
    if (target == null) return;
    final composing = _text[id]!.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      _deferredInline = (
        target: target,
        range: BlockInlineText.plain(target.text).toggleMark(
          target.selection.start,
          target.selection.end,
          InlineMark.bold,
        ),
        command: command,
      );
      return;
    }
    command(target);
  }

  void _flushDeferredInline() {
    final pending = _deferredInline;
    if (pending == null) return;
    final controller = _text[pending.target.blockId];
    if (controller == null ||
        controller.value.composing.isValid &&
            !controller.value.composing.isCollapsed)
      return;
    _deferredInline = null;
    if (!_targetIsCurrent(pending.target) || pending.range.runs.isEmpty) return;
    final selection = TextSelection(
      baseOffset: pending.range.runs.first.start,
      extentOffset: pending.range.runs.last.end,
    );
    pending.command((
      owner: pending.target.owner,
      session: pending.target.session,
      generation: pending.target.generation,
      blockId: pending.target.blockId,
      text: pending.target.text,
      selection: selection,
    ));
  }

  void _applyInline(
    _InlineTarget target,
    BlockInlineText Function(BlockInlineText) change,
  ) {
    if (!_targetIsCurrent(target)) return;
    final block = _find(target.blockId)!;
    final before = block.inlineText ?? BlockInlineText.plain(block.text);
    final next = change(before);
    if (jsonEncode(before.toJson()) == jsonEncode(next.toJson())) return;
    try {
      _update(target.blockId, (block) => block.copyWith(inlineText: next));
    } on FormatException {
      _mediaError('이 페이지의 이전 서식 데이터를 보존하기 위해 서식을 적용할 수 없습니다.');
      return;
    }
    _focus[target.blockId]?.requestFocus();
    _text[target.blockId]?.selection = target.selection;
  }

  void _toggleInline(String id, InlineMark mark) => _inlineCommand(
    id,
    (target) => _applyInline(
      target,
      (inline) =>
          inline.toggleMark(target.selection.start, target.selection.end, mark),
    ),
  );

  Future<void> _chooseInlineLink(_InlineTarget target) async {
    final block = _find(target.blockId);
    if (!_targetIsCurrent(target) || block == null) return;
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _InlineLinkDialog(
        initialLink: _selectionLink(block, target.selection),
        notes: List.of(widget.notes),
      ),
    );
    if (value == null || !_targetIsCurrent(target)) return;
    _applyInline(
      target,
      (inline) => inline.setLink(
        target.selection.start,
        target.selection.end,
        value.isEmpty ? null : value,
      ),
    );
  }

  String? _selectionLink(BlockPageBlock block, TextSelection selection) {
    if (!selection.isValid) return null;
    final runs = block.inlineText?.runs;
    if (runs == null) return null;
    if (selection.isCollapsed) {
      for (final run in runs) {
        if (run.start <= selection.start && selection.start < run.end) {
          return run.link;
        }
      }
      return null;
    }
    String? link;
    var covered = selection.start;
    for (final run in runs) {
      if (run.end <= covered) continue;
      if (run.start > covered ||
          run.link == null ||
          link != null && link != run.link)
        return null;
      link = run.link;
      covered = run.end;
      if (covered >= selection.end) return link;
    }
    return null;
  }

  Future<void> _openInlineLink(_InlineTarget target, String value) async {
    if (!_targetIsCurrent(target)) return;
    final note = NoteLink.parse(value);
    final opener = widget.onOpenNote;
    if (note == null && !isSafeExternalLink(value)) return;
    if (note != null &&
        (opener == null ||
            !widget.notes.any((entry) => entry.id == note.noteId))) {
      _mediaError('연결된 문서를 찾을 수 없습니다.');
      return;
    }
    try {
      await save();
      if (!_targetIsCurrent(target)) return;
      if (note != null) {
        opener!(note.noteId);
      } else {
        await launchUrl(Uri.parse(value), mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (_targetIsCurrent(target) && !_saveFailed) {
        _mediaError('링크를 열지 못했습니다.');
      }
    }
  }

  Future<void> _changeType(String id) async {
    if (_choosingType || _structuralBusy) return;
    final original = _find(id);
    if (original == null) return;
    final owner = widget.initialDocument;
    final session = _session;
    var allowTable = true;
    if (original.toJson().containsKey('tableData')) {
      try {
        allowTable = original.copyWith(type: 'table').table != null;
      } on FormatException {
        allowTable = false;
      }
    }
    final originalRaw = original.toJson();
    final allowTextConversion =
        original.table == null ||
        !originalRaw.containsKey('tableTextConversion') ||
        _readTableTextConversion(originalRaw) != null;
    _choosingType = true;
    try {
      final type = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final entry in _blockLabels.entries)
                ListTile(
                  enabled: entry.key == 'table'
                      ? allowTable
                      : allowTextConversion,
                  leading: Icon(_icon(entry.key)),
                  title: Text(entry.value),
                  onTap: () => Navigator.pop(context, entry.key),
                ),
            ],
          ),
        ),
      );
      if (!mounted ||
          type == null ||
          !identical(widget.initialDocument, owner) ||
          !identical(_find(id), original))
        return;
      if (type == original.type) return;
      _update(id, (block) => _convertBlockType(block, type));
      _focus[id]?.requestFocus();
    } finally {
      if (_session == session) _choosingType = false;
    }
  }

  Future<void> _chooseNote(String id) async {
    final owner = widget.initialDocument;
    final generation = _generation;
    final session = _session;
    final notes = List.of(widget.notes);
    final noteId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('연결할 문서'),
        children: [
          if (widget.notes.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('먼저 다른 문서를 만드세요.'),
            ),
          for (final note in notes)
            SimpleDialogOption(
              child: Text(note.title),
              onPressed: () => Navigator.pop(context, note.id),
            ),
        ],
      ),
    );
    if (!mounted ||
        noteId == null ||
        _session != session ||
        _generation != generation ||
        !identical(widget.initialDocument, owner) ||
        !notes.any((note) => note.id == noteId))
      return;
    _update(
      id,
      (block) => block.copyWith(
        noteId: noteId,
        text: block.text.isEmpty
            ? notes.firstWhere((note) => note.id == noteId).title
            : block.text,
      ),
    );
  }

  Future<void> _openNote(BlockPageBlock block) async {
    final owner = widget.initialDocument;
    final session = _session;
    final opener = widget.onOpenNote;
    final id = block.noteId;
    if (id == null ||
        !widget.notes.any((note) => note.id == id) ||
        widget.onOpenNote == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('연결된 문서를 찾을 수 없습니다.')));
      return;
    }
    try {
      await save();
      if (mounted &&
          _session == session &&
          identical(widget.initialDocument, owner))
        opener!(id);
    } catch (_) {
      /* Keep unsaved text before following a link. */
    }
  }

  bool get _isComposingForDuplicate {
    if (_isComposing) return true;
    final focusedEditor = FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (focusedEditor?.context
            .findAncestorStateOfType<BlockPageEditorState>() !=
        this) {
      return false;
    }
    final composing = focusedEditor!.widget.controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  PopupMenuItem<String> _duplicateAction() => PopupMenuItem(
    key: const ValueKey('block-duplicate-action'),
    value: 'duplicate',
    enabled: !_structuralBusy && !_isComposingForDuplicate,
    child: const Text('블록 복제'),
  );

  void _action(String id, String action, int session) {
    if (!mounted || _session != session || _structuralBusy) return;
    switch (action) {
      case 'discussion':
        widget.onDiscussion?.call(id, null);
      case 'replaceMedia':
        final block = _find(id);
        if (block != null && _document.media.containsKey(id)) {
          unawaited(_importMedia(block.type == 'image', blockId: id));
        }
      case 'type':
        unawaited(_changeType(id));
      case 'up':
        _commit(_document.copyWith(blocks: _move(_document.blocks, id, -1)));
      case 'down':
        _commit(_document.copyWith(blocks: _move(_document.blocks, id, 1)));
      case 'duplicate':
        if (_isComposingForDuplicate) {
          _mediaError('글자 입력을 마친 뒤 블록을 복제하세요.');
          return;
        }
        _flushDeferredInline();
        final BlockPageDocument next;
        try {
          next = _document.duplicateBlock(id);
        } on FormatException {
          _mediaError('이 블록을 복제할 수 없습니다. 블록의 종류와 페이지 크기를 확인하세요.');
          return;
        }
        _commit(next);
      case 'outOfColumn':
        _moveToColumn(id, null);
      case 'unwrapColumns':
        if (!widget.enableColumns) return;
        final next = _document.unwrapColumns(id);
        if (!identical(next, _document)) _commit(next);
      case 'child':
        _update(
          id,
          (block) => block.copyWith(
            children: [...block.children, BlockPageBlock.create()],
          ),
        );
      case 'delete':
        _commit(_document.copyWith(blocks: _remove(_document.blocks, id)));
    }
  }

  void _textEdited(String id, String value) {
    final controller = _text[id]!;
    final previous = controller.previousTextValue;
    final pending = _deferredInline;
    final rebasedRange =
        pending != null &&
            pending.target.blockId == id &&
            pending.target.session == _session
        ? pending.range.replaceText(
            value,
            selectionStart: previous?.selection.isValid == true
                ? previous!.selection.start
                : null,
            selectionEnd: previous?.selection.isValid == true
                ? previous!.selection.end
                : null,
          )
        : null;
    _update(
      id,
      (block) => block.inlineText == null
          ? block.copyWith(text: value)
          : block.copyWith(text: value, inlineText: controller.inlineText),
    );
    if (pending != null && rebasedRange != null) {
      _deferredInline = (
        target: (
          owner: pending.target.owner,
          session: pending.target.session,
          generation: _generation,
          blockId: id,
          text: value,
          selection: pending.target.selection,
        ),
        range: rebasedRange,
        command: pending.command,
      );
      if (!controller.value.composing.isValid ||
          controller.value.composing.isCollapsed) {
        scheduleMicrotask(_flushDeferredInline);
      }
    }
    if (value == '/' && !_document.media.containsKey(id)) {
      unawaited(_changeType(id));
    }
  }

  Widget _inlineToolbar(
    BlockPageBlock block,
    BlockInlineController controller, {
    required bool showFormatting,
  }) {
    final selection = controller.selection;
    final enabled =
        !_mediaOperation &&
        selection.isValid &&
        !selection.isCollapsed &&
        selection.end <= block.text.length;
    Widget button(
      String label,
      IconData icon,
      VoidCallback? action, {
      bool selected = false,
    }) => IconButton(
      tooltip: label,
      isSelected: selected,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: const EdgeInsets.all(8),
      color: selected ? _teal : null,
      onPressed: action,
      icon: Icon(icon, size: 19),
    );
    final onDiscussion = widget.onDiscussion;
    final comment =
        onDiscussion == null || !DiscussionAnchor.supportsQuote(block)
        ? null
        : button(
            '선택 문구에 댓글',
            Icons.add_comment_outlined,
            enabled &&
                    !_busy &&
                    controller.value.composing.isCollapsed &&
                    selection.end - selection.start <=
                        DiscussionAnchor.maxQuoteUtf16 &&
                    block.text
                        .substring(selection.start, selection.end)
                        .trim()
                        .isNotEmpty
                ? () => onDiscussion(block.id, selection)
                : null,
          );
    if (!showFormatting) {
      return TextFieldTapRegion(
        child: Align(alignment: Alignment.centerLeft, child: comment),
      );
    }
    final inline = block.inlineText ?? BlockInlineText.plain(block.text);
    final link = _selectionLink(block, selection);
    return TextFieldTapRegion(
      child: Material(
        color: _teal.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(8),
        child: SingleChildScrollView(
          key: ValueKey('block-inline-toolbar-${block.id}'),
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ?comment,
              for (final entry in const [
                (InlineMark.bold, '굵게', Icons.format_bold),
                (InlineMark.italic, '기울임', Icons.format_italic),
                (InlineMark.underline, '밑줄', Icons.format_underlined),
                (InlineMark.strikethrough, '취소선', Icons.strikethrough_s),
                (InlineMark.code, '인라인 코드', Icons.code),
                (InlineMark.highlight, '강조', Icons.highlight),
              ])
                button(
                  entry.$2,
                  entry.$3,
                  enabled ? () => _toggleInline(block.id, entry.$1) : null,
                  selected:
                      enabled &&
                      inline.hasMark(selection.start, selection.end, entry.$1),
                ),
              button(
                '링크',
                Icons.link,
                enabled
                    ? () => _inlineCommand(
                        block.id,
                        (target) => unawaited(_chooseInlineLink(target)),
                      )
                    : null,
                selected: link != null,
              ),
              if (link != null) ...[
                button('링크 열기', Icons.open_in_new, () {
                  final target = _inlineTarget(
                    block.id,
                    requireSelection: false,
                  );
                  if (target != null) unawaited(_openInlineLink(target, link));
                }),
                button(
                  '링크 제거',
                  Icons.link_off,
                  enabled
                      ? () => _inlineCommand(
                          block.id,
                          (target) => _applyInline(
                            target,
                            (inline) => inline.setLink(
                              target.selection.start,
                              target.selection.end,
                              null,
                            ),
                          ),
                        )
                      : null,
                ),
              ],
              button(
                '서식 지우기',
                Icons.format_clear,
                enabled
                    ? () => _inlineCommand(
                        block.id,
                        (target) => _applyInline(
                          target,
                          (inline) => inline.clearFormatting(
                            target.selection.start,
                            target.selection.end,
                          ),
                        ),
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _input(BlockPageBlock block) {
    final controller = _textFor(block);
    final field = TextField(
      key: ValueKey('block-text-${block.id}'),
      controller: controller,
      focusNode: _focusFor(block.id),
      minLines: 1,
      maxLines: null,
      style: _style(block.type).copyWith(
        decoration: block.type == 'todo' && block.checked
            ? TextDecoration.lineThrough
            : null,
        color: block.type == 'todo' && block.checked
            ? Theme.of(context).colorScheme.onSurfaceVariant
            : null,
      ),
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: _document.media.containsKey(block.id)
            ? '설명 추가'
            : block.type == 'code'
            ? '코드'
            : block.type == 'equation'
            ? 'LaTeX 수식'
            : '내용을 입력하거나 /로 블록 선택',
        contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      ),
      onChanged: (value) => _textEdited(block.id, value),
    );
    final canFormat = _canFormat(block);
    if (!canFormat &&
        (widget.onDiscussion == null ||
            !DiscussionAnchor.supportsQuote(block))) {
      return field;
    }
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        if (_activeInlineId == block.id)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (_, _, _) =>
                _inlineToolbar(block, controller, showFormatting: canFormat),
          ),
      ],
    );
    if (!canFormat) return content;
    return CallbackShortcuts(
      bindings: {
        for (final control in [true, false]) ...{
          SingleActivator(
            LogicalKeyboardKey.keyB,
            control: control,
            meta: !control,
          ): () =>
              _toggleInline(block.id, InlineMark.bold),
          SingleActivator(
            LogicalKeyboardKey.keyI,
            control: control,
            meta: !control,
          ): () =>
              _toggleInline(block.id, InlineMark.italic),
          SingleActivator(
            LogicalKeyboardKey.keyU,
            control: control,
            meta: !control,
          ): () =>
              _toggleInline(block.id, InlineMark.underline),
        },
      },
      child: content,
    );
  }

  String _columnTitle(int index) => index == 0 ? '왼쪽 단' : '오른쪽 단';

  Widget _columns(BlockPageBlock group) {
    final canEdit = widget.enableColumns;
    final colors = Theme.of(context).colorScheme;
    final session = _session;
    return Padding(
      key: ValueKey('page-block-${group.id}'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(child: Text('2단')),
              if (canEdit)
                PopupMenuButton<String>(
                  key: ValueKey('column-actions-${group.id}'),
                  tooltip: '단 작업',
                  enabled: !_structuralBusy,
                  icon: const Icon(Icons.more_horiz, size: 20),
                  onSelected: (action) => _action(group.id, action, session),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'up', child: Text('위로 이동')),
                    const PopupMenuItem(value: 'down', child: Text('아래로 이동')),
                    if (group.canDuplicate) _duplicateAction(),
                    const PopupMenuItem(
                      value: 'unwrapColumns',
                      child: Text('단 나누기 해제'),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 12.0;
              final width = constraints.maxWidth >= 600
                  ? (constraints.maxWidth - gap) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final (index, column) in group.children.indexed)
                    SizedBox(
                      key: ValueKey('column-pane-${column.id}'),
                      width: width,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: colors.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                _columnTitle(index),
                                style: Theme.of(context).textTheme.labelMedium,
                              ),
                              for (final (index, child)
                                  in column.children.indexed)
                                _block(
                                  child,
                                  1,
                                  index,
                                  columnId: canEdit ? column.id : null,
                                ),
                              if (canEdit)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: TextButton.icon(
                                    key: ValueKey('column-add-${column.id}'),
                                    onPressed: _structuralBusy
                                        ? null
                                        : () => _addColumnParagraph(
                                            group.id,
                                            column.id,
                                          ),
                                    icon: const Icon(Icons.add, size: 18),
                                    label: const Text('문단 추가'),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _block(
    BlockPageBlock block,
    int depth,
    int siblingIndex, {
    String? columnId,
  }) {
    if (depth == 0 && block.isColumnLayout) return _columns(block);
    final showColumnActions =
        widget.enableColumns &&
        (depth == 0 || columnId != null) &&
        !const {'columnList', 'column'}.contains(block.type);
    final editable =
        block.type != 'table' && _blockLabels.containsKey(block.type);
    final table = block.table;
    final input = _input(block);
    final media = _document.media[block.id];
    final session = _session;
    final editor = media != null
        ? _mediaEditor(block, media, input)
        : table != null
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              input,
              BlockTableEditor(
                key: ValueKey('block-table-${block.id}'),
                blockId: block.id,
                table: table,
                enabled: !_mediaOperation,
                onChanged: (expected, next) =>
                    _updateTable(block.id, expected, next),
              ),
            ],
          )
        : switch (block.type) {
            'syncedBlock' => _syncedBlock(block),
            'linkedDatabase' => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [input, _linkedDatabase(block)],
            ),
            'divider' => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Divider(),
            ),
            'equation' => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                input,
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Math.tex(
                      block.text.isEmpty ? r'\square' : block.text,
                      textStyle: const TextStyle(fontSize: 20),
                      onErrorFallback: (_) => const Text('수식을 확인하세요.'),
                    ),
                  ),
                ),
              ],
            ),
            'documentLink' => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                input,
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      key: ValueKey('block-open-${block.id}'),
                      onPressed: () => unawaited(_openNote(block)),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: const Text('문서 열기'),
                    ),
                    TextButton(
                      onPressed: () => unawaited(_chooseNote(block.id)),
                      child: const Text('연결 선택'),
                    ),
                  ],
                ),
              ],
            ),
            'code' => DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: input,
              ),
            ),
            'quote' => DecoratedBox(
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: _teal, width: 3)),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: input,
              ),
            ),
            'callout' => DecoratedBox(
              decoration: BoxDecoration(
                color: _teal.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: input,
              ),
            ),
            _ when editable => input,
            _ => Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                block.text.isEmpty ? '지원하지 않는 블록 · 원본 보관됨' : block.text,
              ),
            ),
          };
    return Column(
      key: ValueKey('page-block-${block.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: (depth * 16).clamp(0, 64).toDouble(),
            top: block.type.startsWith('heading') ? 12 : 2,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (block.type == 'todo')
                SizedBox(
                  width: 36,
                  height: 42,
                  child: Checkbox(
                    key: ValueKey('block-check-${block.id}'),
                    value: block.checked,
                    onChanged: (value) => _update(
                      block.id,
                      (block) => block.copyWith(checked: value),
                    ),
                  ),
                )
              else if (block.type == 'toggle')
                SizedBox(
                  width: 36,
                  height: 42,
                  child: IconButton(
                    key: ValueKey('block-toggle-${block.id}'),
                    tooltip: block.collapsed ? '펼치기' : '접기',
                    padding: EdgeInsets.zero,
                    icon: Icon(
                      block.collapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 22,
                    ),
                    onPressed: () => _update(
                      block.id,
                      (block) => block.copyWith(collapsed: !block.collapsed),
                    ),
                  ),
                )
              else if (block.type == 'bullet' || block.type == 'numbered')
                SizedBox(
                  width: 30,
                  height: 42,
                  child: Center(
                    child: Text(
                      block.type == 'bullet' ? '•' : '${siblingIndex + 1}.',
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                )
              else if (block.type == 'callout')
                const SizedBox(
                  width: 30,
                  height: 42,
                  child: Icon(Icons.lightbulb_outline, size: 20),
                ),
              Expanded(child: editor),
              PopupMenuButton<String>(
                key: ValueKey('block-actions-${block.id}'),
                tooltip: '블록 작업',
                enabled: !_mediaOperation,
                icon: const Icon(Icons.more_horiz, size: 20),
                padding: EdgeInsets.zero,
                onSelected: (action) {
                  if (action == 'toColumn') {
                    unawaited(_chooseColumn(block.id, columnId));
                  } else {
                    _action(block.id, action, session);
                  }
                },
                itemBuilder: (_) => [
                  if (widget.onDiscussion != null)
                    PopupMenuItem(
                      value: 'discussion',
                      enabled: !_busy,
                      child: const Text('이 블록에 댓글'),
                    ),
                  if (media != null)
                    PopupMenuItem(
                      value: 'replaceMedia',
                      enabled: widget.onSaveWithMedia != null && !_busy,
                      child: Text(block.type == 'image' ? '이미지 바꾸기' : '파일 바꾸기'),
                    ),
                  if (block.type != 'syncedBlock')
                    const PopupMenuItem(value: 'type', child: Text('종류 바꾸기')),
                  const PopupMenuItem(value: 'up', child: Text('위로 이동')),
                  const PopupMenuItem(value: 'down', child: Text('아래로 이동')),
                  if (block.canDuplicate) _duplicateAction(),
                  if (showColumnActions && _columnGroups.isNotEmpty)
                    PopupMenuItem(
                      value: 'toColumn',
                      enabled: !_structuralBusy,
                      child: const Text('다른 단으로 이동'),
                    ),
                  if (showColumnActions && columnId != null)
                    PopupMenuItem(
                      value: 'outOfColumn',
                      enabled: !_structuralBusy,
                      child: const Text('본문으로 이동'),
                    ),
                  if (block.type != 'syncedBlock')
                    const PopupMenuItem(
                      value: 'child',
                      child: Text('하위 문단 추가'),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'delete', child: Text('삭제')),
                ],
              ),
            ],
          ),
        ),
        if (block.type != 'toggle' || !block.collapsed)
          for (var i = 0; i < block.children.length; i++)
            _block(block.children[i], depth + 1, i),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: _detachingSyncedBlock,
    child: AbsorbPointer(
      absorbing: _detachingSyncedBlock,
      child: _buildEditor(context),
    ),
  );

  Widget _buildEditor(BuildContext context) => Column(
    children: [
      Material(
        color: Theme.of(context).colorScheme.surface,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: '문서 목록으로',
                onPressed: _mediaOperation ? null : () => unawaited(_back()),
                icon: const Icon(Icons.arrow_back),
              ),
              if (widget.onDiscussion != null)
                IconButton(
                  tooltip: '페이지 댓글',
                  onPressed: _busy
                      ? null
                      : () => widget.onDiscussion?.call(null, null),
                  icon: const Icon(Icons.comment_outlined),
                ),
              if (widget.onHistory != null)
                IconButton(
                  tooltip: '페이지 저장 이력',
                  onPressed: _busy ? null : widget.onHistory,
                  icon: const Icon(Icons.history),
                ),
              PopupMenuButton<String>(
                tooltip: '블록 추가',
                enabled: !_structuralBusy,
                onSelected: _add,
                itemBuilder: (_) => [
                  if (widget.enableColumns)
                    const PopupMenuItem(
                      value: 'columns',
                      child: Row(
                        children: [
                          Icon(Icons.view_column_outlined, size: 20),
                          SizedBox(width: 12),
                          Text('2단'),
                        ],
                      ),
                    ),
                  if (widget.syncedBlockAccess != null)
                    const PopupMenuItem(
                      value: 'syncedBlock',
                      child: Row(
                        children: [
                          Icon(Icons.sync, size: 20),
                          SizedBox(width: 12),
                          Text('동기화 블록'),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    value: 'linkedDatabase',
                    enabled: widget.linkedDatabaseAccess != null,
                    child: const Row(
                      children: [
                        Icon(Icons.table_view_outlined, size: 20),
                        SizedBox(width: 12),
                        Text('연결된 데이터베이스'),
                      ],
                    ),
                  ),
                  for (final entry in _blockLabels.entries) ...[
                    PopupMenuItem(
                      value: entry.key,
                      child: Row(
                        children: [
                          Icon(_icon(entry.key), size: 20),
                          const SizedBox(width: 12),
                          Text(entry.value),
                        ],
                      ),
                    ),
                    if (entry.key == 'paragraph' &&
                        widget.onSaveWithMedia != null) ...[
                      PopupMenuItem(
                        value: 'image',
                        enabled: !_busy,
                        child: const Row(
                          children: [
                            Icon(Icons.image_outlined, size: 20),
                            SizedBox(width: 12),
                            Text('이미지'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'attachment',
                        enabled: !_busy,
                        child: const Row(
                          children: [
                            Icon(Icons.attach_file, size: 20),
                            SizedBox(width: 12),
                            Text('파일 첨부'),
                          ],
                        ),
                      ),
                    ],
                  ],
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.add, size: 20, color: _teal),
                      SizedBox(width: 4),
                      Text('블록 추가', style: TextStyle(color: _teal)),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '템플릿',
                enabled: !_structuralBusy,
                onSelected: (name) {
                  final template = BlockPageDocument.template(name);
                  _commit(
                    _document.copyWith(
                      blocks: [..._document.blocks, ...template.blocks],
                    ),
                  );
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'lecture', child: Text('강의 노트')),
                  PopupMenuItem(value: 'research', child: Text('연구 노트')),
                  PopupMenuItem(value: 'meeting', child: Text('회의록')),
                  PopupMenuItem(value: 'project', child: Text('프로젝트')),
                ],
                icon: const Icon(Icons.auto_awesome_mosaic_outlined),
              ),
              IconButton(
                tooltip: '실행 취소',
                onPressed: _structuralBusy || _undo.isEmpty
                    ? null
                    : () => _undoOrRedo(redo: false),
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: '다시 실행',
                onPressed: _structuralBusy || _redo.isEmpty
                    ? null
                    : () => _undoOrRedo(redo: true),
                icon: const Icon(Icons.redo),
              ),
              IconButton(
                tooltip: '저장',
                onPressed: _busy ? null : () => unawaited(_saveFromUi()),
                icon: Icon(
                  _saving
                      ? Icons.hourglass_top
                      : _dirty
                      ? Icons.save_outlined
                      : Icons.check_circle_outline,
                ),
              ),
            ],
          ),
        ),
      ),
      if (_mediaOperation || _detachingSyncedBlock)
        const LinearProgressIndicator(),
      if (_saveFailed)
        Material(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('저장하지 못했습니다. 작업 내용은 열려 있습니다.'),
                Wrap(
                  alignment: WrapAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => unawaited(_saveFromUi()),
                      child: const Text('다시 시도'),
                    ),
                    if (widget.onDiscardChanges != null)
                      TextButton(
                        onPressed: _busy ? null : widget.onDiscardChanges,
                        child: const Text('초안 버리고 다시 읽기'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      Expanded(
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final inset = constraints.maxWidth < 600 ? 12.0 : 32.0;
              return Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 840),
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(inset, 16, inset, 80),
                    children: [
                      if (_document.blocks.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 56),
                          child: Column(
                            children: [
                              const Text(
                                '생각을 블록으로 정리하세요.',
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text('문단, 할 일, 수식과 관련 문서를 한 페이지에 담으세요.'),
                              const SizedBox(height: 20),
                              OutlinedButton.icon(
                                onPressed: () => _add('paragraph'),
                                icon: const Icon(Icons.add),
                                label: const Text('첫 문단 추가'),
                              ),
                            ],
                          ),
                        ),
                      for (var i = 0; i < _document.blocks.length; i++)
                        _block(_document.blocks[i], 0, i),
                      if (_document.blocks.isNotEmpty)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => _add('paragraph'),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('문단 추가'),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    _autosave?.cancel();
    _deferredInline = null;
    final busyOwner = _busyOwner;
    _busyOwner = null;
    if (_reportedBusy && busyOwner != null) {
      _reportedBusy = false;
      scheduleMicrotask(() => busyOwner(false));
    }
    _pendingMedia.clear();
    _mediaLoads.clear();
    for (final text in _text.values) {
      text.dispose();
    }
    for (final focus in _focus.values) {
      focus.dispose();
    }
    super.dispose();
  }
}

class _InlineLinkDialog extends StatefulWidget {
  const new({required this.notes, this.initialLink});

  final List<BlockPageNote> notes;
  final String? initialLink;

  @override
  State<_InlineLinkDialog> createState() => _InlineLinkDialogState();
}

class _InlineLinkDialogState extends State<_InlineLinkDialog> {
  late final _url = TextEditingController(
    text: isSafeExternalLink(widget.initialLink ?? '')
        ? widget.initialLink
        : '',
  );
  String? _error;

  void _applyUrl() {
    final value = _url.text.trim();
    if (!isSafeExternalLink(value)) {
      setState(() => _error = 'http 또는 https 웹 주소를 입력하세요.');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('선택한 글자에 링크'),
    scrollable: true,
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('block-inline-link-url'),
            controller: _url,
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _applyUrl(),
            decoration: InputDecoration(
              labelText: '웹 주소 (http/https)',
              hintText: 'https://example.com',
              errorText: _error,
            ),
          ),
          if (widget.notes.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(top: 20, bottom: 4),
              child: Text('현재 보관함의 문서'),
            ),
            for (final note in widget.notes)
              if (NoteLink.parse(NoteLink(note.id).toString()) != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(note.title),
                  onTap: () =>
                      Navigator.pop(context, NoteLink(note.id).toString()),
                ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      if (widget.initialLink != null)
        TextButton(
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('링크 제거'),
        ),
      FilledButton(onPressed: _applyUrl, child: const Text('적용')),
    ],
  );

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }
}

const _tableTextConversionFormat = 'personal-ink-table-text-1';

({String tableSha256, String caption, String projectedText})?
_readTableTextConversion(Map<String, dynamic> raw) {
  final value = raw['tableTextConversion'];
  if (value is! Map ||
      value.length != 4 ||
      !value.keys.every(
        const {'format', 'tableSha256', 'caption', 'projectedText'}.contains,
      ) ||
      value['format'] != _tableTextConversionFormat ||
      value['tableSha256'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(value['tableSha256'] as String) ||
      value['caption'] is! String ||
      value['projectedText'] is! String) {
    return null;
  }
  return (
    tableSha256: value['tableSha256'] as String,
    caption: value['caption'] as String,
    projectedText: value['projectedText'] as String,
  );
}

String _tableFingerprint(BlockPageTable table) {
  Object? ordered(Object? value) {
    if (value is Map<String, dynamic>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: ordered(value[key])};
    }
    if (value is List) return [for (final item in value) ordered(item)];
    return value;
  }

  return crypto.sha256
      .convert(utf8.encode(jsonEncode(ordered(table.toJson()))))
      .toString();
}

BlockPageBlock _withTableTextConversion(
  BlockPageBlock block,
  Map<String, dynamic>? conversion,
) {
  final raw = block.toJson();
  final inline = block.inlineText;
  if (inline != null) raw.remove('inlineData');
  if (conversion == null) {
    raw.remove('tableTextConversion');
  } else {
    raw['tableTextConversion'] = conversion;
  }
  return BlockPageBlock.fromJson(raw)
      .copyWith(inlineText: inline, children: block.children);
}

BlockPageBlock _convertBlockType(BlockPageBlock block, String type) {
  final raw = block.toJson();
  final conversion = _readTableTextConversion(raw);
  final caption = block.table != null || block.text != '/' ? block.text : '';
  if (type == 'table') {
    var restored = raw.containsKey('tableData')
        ? block.copyWith(type: 'table', text: caption)
        : block.copyWith(
            type: 'table',
            text: caption,
            table: BlockPageTable.create(),
          );
    final table = restored.table;
    if (table == null) return block;
    if (conversion == null) return restored;
    if (conversion.tableSha256 == _tableFingerprint(table) &&
        block.text == conversion.projectedText &&
        [
              if (conversion.caption.isNotEmpty) conversion.caption,
              table.toPlainText(),
            ].join('\n') ==
            conversion.projectedText) {
      restored = restored.copyWith(text: conversion.caption);
    }
    return _withTableTextConversion(restored, null);
  }
  final table = block.table;
  if (table == null) return block.copyWith(type: type, text: caption);
  if (raw.containsKey('tableTextConversion') && conversion == null)
    return block;
  final projected = [
    if (caption.isNotEmpty) caption,
    table.toPlainText(),
  ].join('\n');
  return _withTableTextConversion(block.copyWith(type: type, text: projected), {
    'format': _tableTextConversionFormat,
    'tableSha256': _tableFingerprint(table),
    'caption': caption,
    'projectedText': projected,
  });
}

const _blockLabels = {
  'paragraph': '문단',
  'table': '표',
  'heading1': '제목 1',
  'heading2': '제목 2',
  'heading3': '제목 3',
  'todo': '할 일',
  'bullet': '글머리 목록',
  'numbered': '번호 목록',
  'toggle': '접기 목록',
  'quote': '인용',
  'callout': '콜아웃',
  'code': '코드',
  'equation': '수식',
  'divider': '구분선',
  'documentLink': '문서 링크',
};
IconData _icon(String type) => switch (type) {
  'heading1' || 'heading2' || 'heading3' => Icons.title,
  'todo' => Icons.check_box_outlined,
  'table' => Icons.table_chart_outlined,
  'bullet' => Icons.format_list_bulleted,
  'numbered' => Icons.format_list_numbered,
  'toggle' => Icons.expand_more,
  'quote' => Icons.format_quote,
  'callout' => Icons.lightbulb_outline,
  'code' => Icons.code,
  'equation' => Icons.functions,
  'divider' => Icons.horizontal_rule,
  'documentLink' => Icons.link,
  _ => Icons.notes,
};
TextStyle _style(String type) => switch (type) {
  'heading1' => const TextStyle(
    fontSize: 30,
    height: 1.3,
    fontWeight: FontWeight.w600,
  ),
  'heading2' => const TextStyle(
    fontSize: 25,
    height: 1.3,
    fontWeight: FontWeight.w600,
  ),
  'heading3' => const TextStyle(
    fontSize: 21,
    height: 1.3,
    fontWeight: FontWeight.w600,
  ),
  'code' => const TextStyle(fontSize: 15, height: 1.5, fontFamily: 'monospace'),
  _ => const TextStyle(fontSize: 17, height: 1.5),
};
