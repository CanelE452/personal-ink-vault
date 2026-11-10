import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/mcp/discussion_mcp_read.dart';
import 'package:saber/data/mcp/discussion_mcp_receipt.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_media.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/docx_table_structure.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_asset_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/pptx_shape_text.dart';
import 'package:saber/data/office/pptx_slide_reorder.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_history.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_media_worker.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/database_media_worker.dart';
import 'package:saber/data/vault/database_query_native.dart';
import 'package:saber/data/vault/dataview.dart';
import 'package:saber/data/vault/dataview_query.dart';
import 'package:saber/data/vault/dataview_result.dart';
import 'package:saber/data/vault/discussion_anchor.dart';
import 'package:saber/data/vault/discussion_store.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/knowledge_rename.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/structured_document_text.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

typedef McpBodyValidator = Map<String, dynamic> Function(
  Map<String, dynamic> body,
);

class VaultMcpService {
  new(
    this.controller, {
    this.prepareMutation,
    this.onOpenNote,
    this.officeEngine,
    this.hwpEngine,
    this.docxTableStructure = const DocxTableStructureEngine(),
    this.pptxTableStructure = const PptxTableStructureEngine(),
    this.pptxSlideReorder = const PptxSlideReorderEngine(),
    this.actionRuntime,
    this.bodyValidators = const {},
    this.pageMediaVerifier,
  }) : _repository = controller.repository,
       _vaultId = controller.repository.vaultId;
  final WorkspaceController controller;
  final NoteRepository _repository;
  final String _vaultId;
  final Future<void> Function()? prepareMutation;
  final Future<void> Function(String noteId)? onOpenNote;
  final WindowsOfficeEngine? officeEngine;
  final WindowsOfficeEngine? hwpEngine;
  final DocxTableStructureEngine docxTableStructure;
  final PptxTableStructureEngine pptxTableStructure;
  final PptxSlideReorderEngine pptxSlideReorder;
  final DatabaseActionRuntime? actionRuntime;
  final Map<String, McpBodyValidator> bodyValidators;
  final Future<void> Function(BlockPageMedia, Uint8List)? pageMediaVerifier;
  final _inFlight = <String, (String, Future<Object?>)>{};
  final _pageMediaChecks = <String, Future<void>>{};
  static const _readOperations = {
    'vault_status',
    'list_documents',
    'search_documents',
    'list_folders',
    'read_daily_note',
    'read_document',
    'read_page_media',
    'list_revisions',
    'read_revision',
    'compare_page_revision',
    'database_query',
    'database_task_links',
    'query_dataview',
    'list_page_discussions',
  };
  static const _writeOperations = {
    'create_document',
    'ensure_daily_note',
    'update_document',
    'document_action',
    'office_edit',
    'office_asset',
    'database_action',
    'restore_page_revision',
    'mutate_page_discussion',
  };
  static const _bodyFiles = {
    'infinite': 'infinite.json',
    'canvas': 'board.canvas',
    'page': 'page.json',
    'database': 'database.json',
  };
  static const _textFiles = {
    'summary.md',
    'note.json',
    'folder.json',
    'infinite.json',
    'canvas.json',
    'board.canvas',
    'page.json',
    'database.json',
    'edition.json',
  };
  Future<Object?> call(
    String operation,
    Map<String, dynamic> arguments, {
    required VaultMcpCallContext context,
  }) async {
    try {
      _requireRepository();
      if (!_readOperations.contains(operation) &&
          !_writeOperations.contains(operation)) {
        throw const VaultMcpException('unknown_operation', '지원하지 않는 앱 작업입니다.');
      }
      context.requireActive(write: _writeOperations.contains(operation));
      if (utf8.encode(jsonEncode(arguments)).length >
          VaultMcpBridge.maxBodyBytes) {
        throw const VaultMcpException(
          'invalid_arguments',
          '요청 크기가 지원 범위를 넘습니다.',
        );
      }
      final args = jsonObject(jsonDecode(jsonEncode(arguments)));
      if (operation == 'read_daily_note' || operation == 'ensure_daily_note') {
        _keys(args, {
          'date',
          if (operation == 'ensure_daily_note') 'requestId',
        });
        _dailyDate(args);
        if (_repository.formatVersion < 2) {
          throw const VaultMcpException(
            'unsupported',
            '날짜별 노트를 사용하려면 보관함을 형식 2로 업그레이드하세요.',
          );
        }
      }
      final repo = _repository;
      final result = _writeOperations.contains(operation)
          ? await _journaled(repo, operation, args, context)
          : await _read(repo, operation, args, context);
      _requireRepository();
      context.requireActive(write: operation == 'mutate_page_discussion');
      return result;
    } on VaultMcpException {
      rethrow;
    } on DailyNoteUnavailable catch (error) {
      throw VaultMcpException(
        error.trashed ? 'not_found' : 'revision_conflict',
        error.message,
      );
    } on JsonUnsupportedObjectError {
      throw const VaultMcpException('invalid_arguments', '지원하지 않는 요청 값입니다.');
    } on FormatException {
      throw const VaultMcpException(
        'invalid_arguments',
        '요청의 문서 ID·판본·내용 형식을 확인하세요.',
      );
    } on StateError {
      throw const VaultMcpException(
        'workspace_busy',
        '현재 문서를 저장하고 진행 중인 작업을 마친 뒤 다시 시도하세요.',
      );
    } on FileSystemException {
      throw const VaultMcpException(
        'storage_error',
        '기기에 저장된 자료를 읽거나 기록하지 못했습니다.',
      );
    } on WindowsOfficeException catch (error) {
      throw VaultMcpException(
        error.code,
        '문서 편집을 완료하지 못했습니다. 원본과 작업 파일은 보관됩니다.',
      );
    } on OfficeAssetException catch (error) {
      throw VaultMcpException(error.code, '이미지 전송 상태·문서 판본·파일 내용을 확인하세요.');
    } on DatabaseActionException catch (error) {
      throw VaultMcpException(error.code, error.message);
    } on DatabaseQueryNativeException catch (error) {
      throw VaultMcpException(error.code, error.message);
    }
  }

  void _requireRepository() {
    if (!identical(controller.repository, _repository) ||
        controller.repository.vaultId != _vaultId) {
      throw const VaultMcpException(
        'vault_changed',
        '연결된 저장소가 바뀌었습니다. 앱에서 MCP를 다시 연결하세요.',
      );
    }
  }

  Future<Object?> _read(
    NoteRepository repo,
    String operation,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    switch (operation) {
      case 'vault_status':
        _keys(args, {});
        return {
          'vaultId': repo.vaultId,
          'deviceId': repo.deviceId,
          'formatVersion': repo.formatVersion,
          'documentCount': (await WorkspaceStore(repo).list()).length,
          'folderCount': (await LibraryStore(repo).listFolders()).length,
          'pendingRevisionCount': repo.pendingRevisionCount,
          'integrityIssueCount': repo.integrityIssues.length,
          'activeNoteId': controller.activeSession?.note.id,
          'unsavedChanges': controller.dirty,
          'writeEnabled': context.writeEnabled,
          'automation': ?controller.lastAutomationPass?.toJson(),
        };
      case 'list_documents':
        _keys(args, {'query', 'folderId', 'includeDeleted', 'limit', 'offset'});
        final query =
            _optionalString(args, 'query')?.trim().toLowerCase() ?? '';
        final folder = _optionalId(args, 'folderId');
        final includeDeleted = _boolean(
          args,
          'includeDeleted',
          fallback: false,
        );
        final limit = _integer(args, 'limit', fallback: 50, max: 200);
        final offset = _integer(
          args,
          'offset',
          fallback: 0,
          min: 0,
          max: 1000000,
        );
        final all = await WorkspaceStore(repo)
            .list(includeDeleted: includeDeleted);
        final matches = <VaultNote>[];
        for (final note in all) {
          if (args.containsKey('folderId') && note.folderId != folder) continue;
          if (query.isNotEmpty && !note.title.toLowerCase().contains(query)) {
            final heads = await repo.heads(note.markdownEntityId);
            var found = false;
            for (final head in heads) {
              final part = await _revisionData(repo, head);
              if ((part['content'] as String? ?? '').toLowerCase().contains(
                query,
              ))
                found = true;
            }
            if (!found &&
                const {
                  'page',
                  'canvas',
                  'database',
                }.contains(note.documentKind.name)) {
              for (final head in await repo.heads(note.inkEntityId)) {
                final file = _bodyFiles[note.documentKind.name]!;
                final blob = head.blobs[file];
                if (head.deleted || blob == null || blob.length > 1024 * 1024)
                  continue;
                if (head.vaultId != repo.vaultId || !_owned(head, note.id))
                  throw const VaultMcpException(
                    'revision_not_owned',
                    '이 문서에 속한 본문이 아닙니다.',
                  );
                final bytes = await repo.readBlob(blob.hash);
                if (structuredDocumentText(note.documentKind.name, {
                  file: bytes,
                }).toLowerCase().contains(query)) {
                  found = true;
                  break;
                }
              }
            }
            if (!found) continue;
          }
          matches.add(note);
        }
        return {
          'documents': [
            for (final note in matches.skip(offset).take(limit))
              _noteData(note),
          ],
          'total': matches.length,
          'offset': offset,
          'limit': limit,
        };
      case 'list_page_discussions':
        _keys(args, {
          'noteId',
          'threadId',
          'afterThreadId',
          'afterReplyId',
          'limit',
        });
        final noteId = _id(args, 'noteId');
        if (args.containsKey('limit') && args['limit'] == null) {
          throw const FormatException('Invalid discussion limit');
        }
        final limit = _integer(args, 'limit', fallback: 30, max: 100);
        final threadId = args.containsKey('threadId')
            ? _id(args, 'threadId')
            : null;
        final afterThreadId = args.containsKey('afterThreadId')
            ? _id(args, 'afterThreadId')
            : null;
        final afterReplyId = args.containsKey('afterReplyId')
            ? _id(args, 'afterReplyId')
            : null;
        if ((threadId == null && afterReplyId != null) ||
            (threadId != null && afterThreadId != null)) {
          throw const VaultMcpException(
            'invalid_arguments',
            '댓글 목록과 커서가 맞는지 확인하세요.',
          );
        }
        final snapshot = await DiscussionStore(repo).readSnapshot(noteId);
        return {
          'noteId': noteId,
          'metadataRevisionId': snapshot.metadataRevisionId,
          'deleted': snapshot.deleted,
          'body': {
            'kind': !snapshot.bodyAvailable
                ? 'unavailable'
                : snapshot.bodyRevisionId == null
                ? 'empty'
                : 'saved',
            'revisionId': ?snapshot.bodyRevisionId,
          },
          ...discussionReadPage(
            snapshot.threads,
            threadId: threadId,
            afterThreadId: afterThreadId,
            afterReplyId: afterReplyId,
            limit: limit,
          ),
        };
      case 'list_folders':
        _keys(args, {'includeDeleted', 'limit', 'offset'});
        final all = await LibraryStore(repo).listFolders(
          includeDeleted: _boolean(args, 'includeDeleted', fallback: false),
        );
        final limit = _integer(args, 'limit', fallback: 100, max: 200),
            offset = _integer(
              args,
              'offset',
              fallback: 0,
              min: 0,
              max: 1000000,
            );
        return {
          'folders': [
            for (final folder in all.skip(offset).take(limit))
              {
                'id': folder.id,
                'title': folder.title,
                'parentId': folder.parentId,
                'revisionId': folder.revision.revisionId,
                'trashed': folder.trashed,
                'conflict': folder.deletionConflict,
              },
          ],
          'total': all.length,
          'offset': offset,
          'limit': limit,
        };
      case 'database_query':
        return _databaseQuery(repo, args, context);
      case 'database_task_links':
        return _readDatabaseTaskLinks(repo, args);
      case 'query_dataview':
        return _queryDataview(repo, args, context);
      case 'search_documents':
        return _searchDocuments(repo, args, context);
      case 'read_page_media':
        return _readPageMedia(repo, args, context);
      case 'read_daily_note':
        final note = await WorkspaceStore(repo).readDailyNote(_dailyDate(args));
        if (note == null) {
          throw const VaultMcpException(
            'not_found',
            '해당 날짜의 저장된 노트를 찾을 수 없습니다.',
          );
        }
        final markdown = (await repo.heads(note.markdownEntityId)).singleOrNull;
        if (markdown == null ||
            markdown.kind != EntityKind.markdown ||
            markdown.ownerNoteId != note.id ||
            markdown.deleted ||
            markdown.blobs.length != 1 ||
            !markdown.blobs.containsKey('summary.md')) {
          throw const VaultMcpException(
            'revision_conflict',
            '날짜별 노트의 저장된 Markdown 판본을 확인하세요.',
          );
        }
        final data = await _revisionData(repo, markdown);
        await _expected(repo, note.id, note.revision.revisionId);
        await _expected(repo, note.markdownEntityId, markdown.revisionId);
        return {..._noteData(note), 'date': args['date'], 'markdown': data};
      case 'read_document':
        _keys(args, {
          'noteId',
          'revisionId',
          'docxTableStructure',
          'pptxTableStructure',
          'pptxSlideOrder',
        });
        final id = _id(args, 'noteId');
        if (args.containsKey('pptxSlideOrder')) {
          final slideOrder = args['pptxSlideOrder'];
          if (slideOrder is! bool) {
            throw const FormatException('Expected a PPTX slide order selector');
          }
          if (slideOrder) {
            if (args.containsKey('revisionId') ||
                args.containsKey('docxTableStructure') ||
                args.containsKey('pptxTableStructure')) {
              throw const FormatException(
                'PPTX slide order discovery requires the current source only',
              );
            }
            return _readPptxSlideOrder(repo, id, context);
          }
        }
        if (args.containsKey('docxTableStructure')) {
          if (args.containsKey('revisionId') ||
              args.containsKey('pptxTableStructure')) {
            throw const FormatException(
              'DOCX table discovery requires one selector and the current source',
            );
          }
          return _readDocxTableStructure(
            repo,
            id,
            jsonObject(args['docxTableStructure']),
            context,
          );
        }
        if (args.containsKey('pptxTableStructure')) {
          if (args['revisionId'] != null) {
            throw const FormatException(
              'PPTX table discovery requires the current source',
            );
          }
          return _readPptxTableStructure(
            repo,
            id,
            jsonObject(args['pptxTableStructure']),
            context,
          );
        }
        if (args['revisionId'] != null)
          return _readRevision(repo, id, _id(args, 'revisionId'));
        final note = await _note(repo, id);
        final result = {
          ..._noteData(note),
          'markdown': await _part(repo, note.markdownEntityId),
          'body': await _part(repo, note.inkEntityId),
        };
        if (note.sourceEntityId != null)
          result['source'] = await _part(repo, note.sourceEntityId!);
        if (note.documentKind == VaultDocumentKind.office)
          result['office'] = await _inspectOffice(repo, note);
        return result;
      case 'list_revisions':
        _keys(args, {'noteId', 'target', 'offset', 'limit'});
        final id = _id(args, 'noteId');
        await _assertNoteExists(repo, id);
        final paginated = args.keys.any((key) => key != 'noteId');
        if (args.containsKey('target') && args['target'] != 'body' ||
            args.containsKey('offset') && args['offset'] == null ||
            args.containsKey('limit') && args['limit'] == null)
          throw const FormatException('Invalid history pagination');
        final bodyEntity = args['target'] == 'body'
            ? (await _note(repo, id)).inkEntityId
            : null;
        final offset = _integer(
          args,
          'offset',
          fallback: 0,
          min: 0,
          max: 1000000,
        );
        final limit = paginated
            ? _integer(args, 'limit', fallback: 100, max: 100)
            : 500;
        final revisions = (await repo.revisions())
            .where(
              (r) =>
                  _owned(r, id) &&
                  (bodyEntity == null ||
                      r.entityId == bodyEntity && r.kind == EntityKind.ink),
            )
            .toList();
        return {
          'noteId': id,
          'revisions': [
            for (final revision in revisions.reversed.skip(offset).take(limit))
              _record(revision),
          ],
          'total': revisions.length,
          'truncated': offset + limit < revisions.length,
          if (paginated) ...{
            'offset': offset,
            'limit': limit,
            'nextOffset': offset + limit < revisions.length
                ? offset + limit
                : null,
          },
        };
      case 'compare_page_revision':
        return _comparePageRevision(repo, args, context);
      case 'read_revision':
        _keys(args, {'noteId', 'revisionId'});
        return _readRevision(
          repo,
          _id(args, 'noteId'),
          _id(args, 'revisionId'),
        );
      default:
        throw const VaultMcpException('unknown_operation', '지원하지 않는 앱 작업입니다.');
    }
  }

  Future<Map<String, Object?>> _comparePageRevision(
    NoteRepository repo,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    _keys(args, {
      'noteId',
      'revisionId',
      'expectedRevisionId',
      'offset',
      'limit',
    });
    if (args.containsKey('offset') && args['offset'] == null ||
        args.containsKey('limit') && args['limit'] == null)
      throw const FormatException('Invalid comparison pagination');
    final id = _id(args, 'noteId'), selectedId = _id(args, 'revisionId');
    final expected = _id(args, 'expectedRevisionId');
    final offset = _integer(args, 'offset', fallback: 0, min: 0, max: 1000000);
    final limit = _integer(args, 'limit', fallback: 100, max: 100);
    final session = await _pageHistorySession(repo, id);
    final records = await repo.revisions();
    final chosen = _ownedPageRecord(records, session.note, selectedId);
    final observed = _ownedPageRecord(records, session.note, expected);
    for (final record in [chosen, observed]) {
      final blob = record.blobs['page.json'];
      if (blob == null) throw const FormatException('Missing saved page body');
      if (blob.length > 1024 * 1024)
        throw const VaultMcpException(
          'content_too_large',
          'MCP 이력 비교는 판본당 1MiB 이하의 페이지를 지원합니다. 앱에서 이력을 여세요.',
        );
    }
    try {
      await _expected(repo, session.note.inkEntityId, expected);
      final history = await BlockPageHistorySnapshot.read(session);
      if (history.currentRevision.revisionId != expected)
        throw StateError('The saved page changed while comparing');
      final diff = await history.compare(chosen);
      await session.validateInkRevisionRestoreHeads(history.expectedHeads);
      _requireRepository();
      context.requireActive();
      var remainingBytes = 256 * 1024;
      final changes = <Map<String, Object?>>[];
      for (final change in diff.changes.skip(offset).take(limit)) {
        Map<String, dynamic>? shallow(BlockPageBlock? block) =>
            block == null ? null : (block.toJson()..remove('children'));
        final before = shallow(change.before), after = shallow(change.after);
        final payloadBytes = utf8.encode(jsonEncode([before, after])).length;
        final includePayload = payloadBytes <= remainingBytes;
        if (includePayload) remainingBytes -= payloadBytes;
        changes.add({
          'blockId': change.blockId,
          'kinds': [for (final kind in change.kinds) kind.name],
          'beforeParentId': change.beforeParentId,
          'afterParentId': change.afterParentId,
          'beforeIndex': change.beforeIndex,
          'afterIndex': change.afterIndex,
          if (includePayload) ...{'before': before, 'after': after},
          'payloadOmitted': !includePayload,
        });
      }
      return {
        'noteId': id,
        'beforeRevisionId': chosen.revisionId,
        'afterRevisionId': observed.revisionId,
        'expectedHeads': history.expectedHeads,
        'pageMetadataChanged': diff.pageMetadataChanged,
        'changes': changes,
        'totalChanges': diff.changes.length,
        'offset': offset,
        'limit': limit,
        'nextOffset': offset + limit < diff.changes.length
            ? offset + limit
            : null,
        'truncated':
            offset + limit < diff.changes.length ||
            changes.any((c) => c['payloadOmitted'] == true),
      };
    } on StateError {
      throw const VaultMcpException(
        'revision_conflict',
        '페이지나 폴더가 변경되었습니다. 이력을 다시 비교하세요.',
      );
    }
  }

  Future<NoteSession> _pageHistorySession(
    NoteRepository repo,
    String id, {
    bool historical = false,
  }) async {
    final notes = (await WorkspaceStore(repo).list(includeDeleted: true))
        .where((n) => n.id == id)
        .toList();
    if (notes.isEmpty)
      throw const VaultMcpException('not_found', '문서를 찾을 수 없습니다.');
    if (!historical &&
        (notes.length != 1 ||
            notes.single.trashed ||
            notes.single.deletionConflict))
      throw const VaultMcpException(
        'revision_conflict',
        '살아 있는 단일 페이지 판본에서 이력을 다시 비교하세요.',
      );
    final note = notes.first;
    if (note.documentKind != VaultDocumentKind.page)
      throw const VaultMcpException(
        'unsupported',
        '이력 비교·본문 복원은 블록 페이지에서 지원합니다.',
      );
    return NoteSession(repo, note, await repo.heads(note.inkEntityId), []);
  }

  RevisionRecord _ownedPageRecord(
    List<RevisionRecord> records,
    VaultNote note,
    String id,
  ) {
    final record = records.where((r) => r.revisionId == id).singleOrNull;
    if (record == null ||
        record.vaultId != _vaultId ||
        record.entityId != note.inkEntityId ||
        record.kind != EntityKind.ink ||
        record.ownerNoteId != note.id ||
        record.deleted)
      throw const VaultMcpException(
        'revision_not_owned',
        '이 페이지에 속한 살아 있는 본문 판본이 아닙니다.',
      );
    return record;
  }

  Future<Map<String, Object?>> _queryDataview(
    NoteRepository repo,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    _keys(args, {'query'});
    final query = DataviewQuery.parse(_string(args, 'query', max: 4096));
    final native = controller.native;
    if (native == null) {
      throw const VaultMcpException(
        'native_unavailable',
        '공통 계산 엔진을 사용할 수 없습니다. 앱 설치 상태를 확인하세요.',
      );
    }
    final index = await KnowledgeIndex.build(repo, native);
    _requireRepository();
    context.requireActive();
    final DataviewResult view;
    try {
      view = evaluateDataview(index, native, query);
    } on DataviewTaskGroupLimitException catch (error) {
      throw VaultMcpException('result_too_large', error.message);
    } on DataviewDocumentGroupLimitException catch (error) {
      throw VaultMcpException('result_too_large', error.message);
    }
    Map<String, Object?> serializeRow(DataviewRow row) => {
      'noteId': row.noteId,
      'title': row.title,
      'path': row.path,
      'values': row.values,
      if (row.task case final task?)
        'task': {
          'text': task.text,
          'status': task.status,
          'checked': task.checked,
          'completed': task.completed,
          'line': task.line,
          'revisionId': task.revisionId,
        },
    };
    final result = <String, Object?>{
      'mode': query.layout.name,
      'columns': [
        for (final column in query.columns)
          {'field': column.property, 'label': column.label},
      ],
      if (query.groupBy case final groupBy?)
        'groupBy': {'field': groupBy.property, 'label': groupBy.label},
      if (view.documentGroups case final groups?)
        'groups': [
          for (final group in groups)
            {
              'key': group.key,
              'values': group.values,
              'rows': group.rows.map(serializeRow).toList(),
            },
        ]
      else if (view.groups case final groups?)
        'groups': [
          for (final group in groups)
            {'key': group.key, 'rows': group.rows.map(serializeRow).toList()},
        ]
      else
        'rows': view.rows.map(serializeRow).toList(),
    };
    _requireMcpTextEncoding(result);
    if (utf8.encode(jsonEncode(result)).length > 512 * 1024) {
      throw const VaultMcpException(
        'result_too_large',
        'Dataview 결과가 512KiB를 넘습니다. LIMIT 또는 표시할 열을 줄이세요.',
      );
    }
    return result;
  }

  Future<Map<String, Object?>> _searchDocuments(
    NoteRepository repo,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    _keys(args, {'query', 'limit', 'offset'});
    final query = _string(args, 'query', max: 2048);
    final limit = _integer(args, 'limit', fallback: 50, max: 100);
    final offset = _integer(args, 'offset', fallback: 0, min: 0, max: 1000000);
    const unavailable = VaultMcpException(
      'native_unavailable',
      '검색 엔진을 사용할 수 없습니다. 앱 설치 상태를 확인하세요.',
    );
    final native = controller.native;
    if (native == null) throw unavailable;

    try {
      native.invoke({'op': 'validate_search_expression', 'query': query});
      final index = await KnowledgeIndex.build(
        repo,
        native,
        readLimits: (documents: 4000, bytes: 16 * 1024 * 1024),
      );
      _requireRepository();
      context.requireActive();
      final matches = index.search(query, expression: true);
      final result = {
        'matches': [
          for (final match in matches.skip(offset).take(limit))
            {
              'noteId': match.id,
              'title': match.title,
              'snippet': match.snippet,
              'score': match.score,
              'path': ?index.documents[match.id]?.searchPath,
            },
        ],
        'total': matches.length,
        'offset': offset,
        'limit': limit,
      };
      _requireMcpTextEncoding(result);
      if (utf8.encode(jsonEncode(result)).length > 512 * 1024) {
        throw const VaultMcpException(
          'result_too_large',
          '검색 결과가 512KiB를 넘습니다. limit를 줄여 다시 검색하세요.',
        );
      }
      return result;
    } on KnowledgeIndexReadLimitExceeded {
      throw const VaultMcpException(
        'result_too_large',
        '보관함이 검색 범위인 문서 4,000개 또는 본문 16MiB를 넘습니다.',
      );
    } on InkVaultNativeException catch (error) {
      switch (error.code) {
        case 'invalid_search_expression':
          throw const VaultMcpException(
            'invalid_search_expression',
            '검색식 문법을 확인하세요.',
          );
        case 'unknown_operation':
        case 'library_unavailable':
          throw unavailable;
        default:
          throw const VaultMcpException('search_failed', '검색식을 실행할 수 없습니다.');
      }
    }
  }

  Future<Map<String, Object?>> _readDatabaseTaskLinks(
    NoteRepository repo,
    Map<String, dynamic> args,
  ) async {
    _keys(args, {'noteId', 'expectedRevisionId', 'rowId'});
    final note = await _note(repo, _id(args, 'noteId'));
    final revisionId = _id(args, 'expectedRevisionId');
    final rowId = _id(args, 'rowId');
    if (note.documentKind != VaultDocumentKind.database) {
      throw const VaultMcpException(
        'invalid_document_kind',
        '데이터베이스 문서를 선택하세요.',
      );
    }
    if (note.trashed || note.deletionConflict) {
      throw const VaultMcpException('not_found', '데이터베이스의 삭제 상태를 먼저 확인하세요.');
    }
    final head = await _head(repo, note.inkEntityId);
    if (head.revisionId != revisionId) {
      throw const VaultMcpException(
        'revision_conflict',
        '데이터베이스가 변경되었습니다. 최신 본문 판본을 읽고 다시 요청하세요.',
      );
    }
    final blob = head.blobs['database.json'];
    if (head.kind != EntityKind.ink ||
        head.vaultId != repo.vaultId ||
        !_owned(head, note.id) ||
        blob == null) {
      throw const VaultMcpException('not_found', '저장된 데이터베이스 본문을 찾을 수 없습니다.');
    }
    if (blob.length > DatabaseQueryRuntime.maxRequestBytes) {
      throw const VaultMcpException(
        'query_too_large',
        '데이터베이스 본문이 32MiB를 넘습니다.',
      );
    }
    final database = WorkspaceDatabase.fromJson(
      jsonObject(jsonDecode(utf8.decode(await repo.readBlob(blob.hash)))),
    );
    if (!database.supportsTaskLinks) {
      throw const VaultMcpException(
        'unsupported_task_links',
        '이 데이터베이스의 작업 연결 형식을 읽을 수 없습니다.',
      );
    }
    final row = database.rows.where((row) => row.id == rowId).singleOrNull;
    if (row == null) {
      throw const VaultMcpException('not_found', '저장된 작업을 찾을 수 없습니다.');
    }
    final ids = database.rows.map((row) => row.id).toSet();
    final links = database.taskLinks[rowId];
    final parent = links?.parentId;
    await _expected(repo, note.id, note.revision.revisionId);
    await _expected(repo, note.inkEntityId, revisionId);
    return {
      'noteId': note.id,
      'revisionId': revisionId,
      'rowId': rowId,
      'archived': row.archived,
      'parentId': ids.contains(parent) ? parent : null,
      'predecessorIds': [
        for (final id in links?.predecessorIds ?? const <String>[])
          if (ids.contains(id)) id,
      ],
    };
  }

  Future<Map<String, Object?>> _databaseQuery(
    NoteRepository repo,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    _keys(args, {
      'noteId',
      'expectedRevisionId',
      'relatedDatabases',
      'capturedAtUtc',
      'maxDepth',
      'budget',
      'operations',
    });
    final rawOperations = args['operations'];
    final rawRelated = args['relatedDatabases'] ?? const [];
    if (rawOperations is! List ||
        rawOperations.isEmpty ||
        rawOperations.length > DatabaseQueryRuntime.maxOperations ||
        rawRelated is! List ||
        rawRelated.length > 64)
      throw const FormatException('Invalid query scope');
    final operations = <Map<String, Object?>>[
      for (final value in rawOperations) jsonObject(value),
    ];
    for (final operation in operations) {
      final optional = switch (operation['type']) {
        'aggregate' => {'calculation', 'rowIds', 'from', 'view'},
        'calendar' => {'view'},
        'chart' => {'calculation', 'valuePropertyId', 'view'},
        _ => <String>{},
      };
      operation.removeWhere(
        (key, value) => value == null && optional.contains(key),
      );
    }
    final main = {
      'noteId': _id(args, 'noteId'),
      'expectedRevisionId': _id(args, 'expectedRevisionId'),
    };
    final references = <Map<String, dynamic>>[main];
    final noteIds = {main['noteId']};
    for (final raw in rawRelated) {
      final reference = jsonObject(raw);
      _keys(reference, {'noteId', 'expectedRevisionId'});
      final id = _id(reference, 'noteId');
      _id(reference, 'expectedRevisionId');
      if (!noteIds.add(id))
        throw const FormatException('Duplicate query document');
      references.add(reference);
    }
    final depth = _integer(args, 'maxDepth', fallback: 32, max: 128);
    final budget = _integer(args, 'budget', fallback: 10000, max: 1000000);
    final suppliedClock = _optionalString(args, 'capturedAtUtc');
    final captured = suppliedClock == null
        ? DateTime.now().toUtc()
        : DateTime.tryParse(suppliedClock);
    if (captured == null ||
        !captured.isUtc ||
        captured.year < 1 ||
        captured.year > 9999 ||
        suppliedClock != null && captured.toIso8601String() != suppliedClock)
      throw const FormatException('Expected a canonical UTC clock');
    final inputs = <_McpQueryInput>[];
    final databases = <String, WorkspaceDatabase>{};
    var sourceBytes = 0;
    for (final reference in references) {
      _requireRepository();
      context.requireActive();
      final note = await _note(repo, _id(reference, 'noteId'));
      if (note.documentKind != VaultDocumentKind.database)
        throw const VaultMcpException(
          'invalid_document_kind',
          '데이터베이스 문서를 선택하세요.',
        );
      if (note.trashed || note.revision.deleted)
        throw const VaultMcpException(
          'not_found',
          '휴지통에 있는 데이터베이스는 계산할 수 없습니다.',
        );
      if (note.deletionConflict)
        throw const VaultMcpException(
          'revision_conflict',
          '데이터베이스의 삭제 충돌을 먼저 확인하세요.',
        );
      final head = await _head(repo, note.inkEntityId);
      if (head.vaultId != repo.vaultId ||
          head.kind != EntityKind.ink ||
          !_owned(head, note.id) ||
          head.deleted)
        throw const VaultMcpException(
          'revision_not_owned',
          '이 문서에 속한 데이터베이스 본문이 아닙니다.',
        );
      if (head.revisionId != reference['expectedRevisionId'])
        throw const VaultMcpException(
          'revision_conflict',
          '데이터베이스가 변경되었습니다. 최신 본문 판본을 읽고 다시 요청하세요.',
        );
      final blob = head.blobs['database.json'];
      if (blob == null)
        throw const VaultMcpException('not_found', '저장된 데이터베이스 본문을 찾을 수 없습니다.');
      sourceBytes += blob.length;
      if (sourceBytes > DatabaseQueryRuntime.maxRequestBytes)
        throw const VaultMcpException(
          'query_too_large',
          '계산할 데이터베이스 본문의 총 크기가 32MiB를 넘습니다.',
        );
      final database = WorkspaceDatabase.fromJson(
        jsonObject(jsonDecode(utf8.decode(await repo.readBlob(blob.hash)))),
      );
      if (databases.containsKey(database.id))
        throw const VaultMcpException(
          'ambiguous_database',
          '같은 데이터베이스 ID가 두 문서에 있습니다. 관계 대상을 확인하세요.',
        );
      databases[database.id] = database;
      inputs.add(_McpQueryInput(note, head, database));
    }
    await _verifyQueryInputs(repo, inputs, context);
    final native = controller.native;
    if (native == null)
      throw const VaultMcpException(
        'native_unavailable',
        '공통 계산 엔진을 사용할 수 없습니다. 앱 설치 상태를 확인하세요.',
      );
    final batch = DatabaseQueryRuntime(invoke: native.invoke).evaluate(
      inputs.first.database,
      operations: operations,
      databases: databases,
      now: captured,
      maxDepth: depth,
      budget: budget,
    );
    await _verifyQueryInputs(repo, inputs, context);
    final result = <String, Object?>{
      'noteId': inputs.first.note.id,
      'databaseId': inputs.first.database.id,
      'revisionId': inputs.first.revision.revisionId,
      'capturedAtUtc': captured.toIso8601String(),
      'inputs': [
        for (final input in inputs)
          {
            'noteId': input.note.id,
            'databaseId': input.database.id,
            'revisionId': input.revision.revisionId,
            'metadataRevisionId': input.note.revision.revisionId,
          },
      ],
      'results': batch.results,
      'errors': [for (final error in batch.errors) error.toJson()],
      'remainingBudget': batch.remainingBudget,
    };
    _requireMcpTextEncoding(result);
    return result;
  }

  Future<void> _verifyQueryInputs(
    NoteRepository repo,
    List<_McpQueryInput> inputs,
    VaultMcpCallContext context,
  ) async {
    for (final input in inputs) {
      _requireRepository();
      context.requireActive();
      final current = await _note(repo, input.note.id);
      if (current.trashed ||
          current.deletionConflict ||
          current.revision.revisionId != input.note.revision.revisionId ||
          current.documentKind != VaultDocumentKind.database ||
          current.inkEntityId != input.note.inkEntityId)
        throw const VaultMcpException(
          'revision_conflict',
          '계산 중 데이터베이스가 변경되었습니다. 최신 판본을 읽고 다시 요청하세요.',
        );
      await _expected(repo, input.note.inkEntityId, input.revision.revisionId);
    }
    _requireRepository();
    context.requireActive();
  }

  Future<Object?> _journaled(
    NoteRepository repo,
    String operation,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    final requestId = _id(args, 'requestId');
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode(_canonical({'operation': operation, 'arguments': args})),
          ),
        )
        .toString();
    final key = '${repo.vaultId}/$requestId';
    final running = _inFlight[key];
    if (running != null) {
      if (running.$1 != digest)
        throw const VaultMcpException(
          'request_id_reused',
          '같은 요청 ID에 다른 내용을 사용할 수 없습니다.',
        );
      return running.$2;
    }
    final pending = _recorded(
      repo,
      operation,
      args,
      requestId,
      digest,
      context,
    );
    _inFlight[key] = (digest, pending);
    try {
      return await pending;
    } finally {
      if (identical(_inFlight[key]?.$2, pending)) _inFlight.remove(key);
    }
  }

  Future<Object?> _recorded(
    NoteRepository repo,
    String operation,
    Map<String, dynamic> args,
    String requestId,
    String digest,
    VaultMcpCallContext context,
  ) async {
    final file = File(
      p.join(
        repo.root.path,
        '.workspace',
        'mcp',
        'requests',
        '$requestId.json',
      ),
    );
    if (operation == 'mutate_page_discussion')
      return _recordedDiscussion(repo, args, file, requestId, digest, context);
    if (operation == 'restore_page_revision')
      return _recordedPageRestore(repo, args, file, requestId, digest, context);
    if (operation == 'office_edit')
      return _recordedOffice(repo, args, file, requestId, digest, context);
    if (operation == 'document_action' &&
        const {'rename', 'move', 'trash', 'restore'}.contains(args['action']))
      return _recordedPathChange(repo, args, file, requestId, digest, context);
    if (file.existsSync()) {
      if (await file.length() > VaultMcpBridge.maxBodyBytes)
        throw const VaultMcpException(
          'operation_state_unknown',
          '이전 요청 기록을 확인하지 못했습니다. 같은 요청을 자동 반복하지 마세요.',
        );
      final record = jsonObject(jsonDecode(await file.readAsString()));
      if (record['requestId'] != requestId)
        throw const VaultMcpException(
          'operation_state_unknown',
          '이전 요청 기록을 확인하지 못했습니다.',
        );
      if (record['digest'] != digest)
        throw const VaultMcpException(
          'request_id_reused',
          '같은 요청 ID에 다른 내용을 사용할 수 없습니다.',
        );
      if (record['version'] != 1)
        throw const VaultMcpException(
          'operation_state_unknown',
          '이전 요청 기록의 형식을 확인하지 못했습니다.',
        );
      if (record['state'] == 'completed') return record['result'];
      if (operation != 'ensure_daily_note' ||
          record['state'] != 'started' ||
          record['version'] is! int ||
          record.length != 4) {
        throw const VaultMcpException(
          'operation_state_unknown',
          '이전 요청이 어디까지 처리됐는지 확인하지 못했습니다. 문서 이력을 확인한 뒤 새 요청으로 진행하세요.',
        );
      }
    } else {
      context.requireActive(write: true);
      await _writeRecord(file, {
        'version': 1,
        'requestId': requestId,
        'state': 'started',
        'digest': digest,
      });
    }
    context.requireActive(write: true);
    await prepareMutation?.call();
    context.requireActive(write: true);
    if (!identical(controller.repository, repo))
      throw const VaultMcpException('vault_changed', '연결된 저장소가 바뀌었습니다.');
    final Object? result;
    if (operation == 'document_action' && args['action'] == 'open') {
      _keys(args, {
        'noteId',
        'action',
        'title',
        'folderId',
        'expectedRevisionId',
        'requestId',
      });
      final id = _id(args, 'noteId');
      await controller.externalMutation((current) async {
        _requireCurrent(repo, current, context);
        final note = await _note(repo, id);
        if (note.trashed)
          throw const VaultMcpException('not_found', '휴지통의 문서는 먼저 복원하세요.');
        if (args['expectedRevisionId'] != null)
          await _expected(repo, id, _id(args, 'expectedRevisionId'));
      });
      if (onOpenNote == null)
        throw const VaultMcpException(
          'unsupported',
          '앱 화면에서 문서 열기를 지원하지 않는 연결입니다.',
        );
      context.requireActive(write: true);
      await onOpenNote!(id);
      result = {'noteId': id, 'opened': true};
    } else {
      result = await controller.externalMutation((current) async {
        _requireCurrent(repo, current, context);
        return _mutate(repo, operation, args, context);
      });
    }
    try {
      await _writeRecord(file, {
        'version': 1,
        'requestId': requestId,
        'state': 'completed',
        'digest': digest,
        'result': result,
      });
    } on FileSystemException {
      throw const VaultMcpException(
        'operation_state_unknown',
        '문서 변경 후 요청 기록을 확정하지 못했습니다. 같은 요청을 자동 반복하지 말고 문서 이력을 확인하세요.',
      );
    }
    return result;
  }

  Future<Map<String, Object?>> _recordedDiscussion(
    NoteRepository repo,
    Map<String, dynamic> args,
    File file,
    String requestId,
    String digest,
    VaultMcpCallContext context,
  ) async {
    _keys(args, {
      'noteId',
      'expectedMetadataRevisionId',
      'expectedBody',
      'requestId',
      'action',
    });
    final noteId = _id(args, 'noteId');
    final metadataId = _id(args, 'expectedMetadataRevisionId');
    final body = jsonObject(args['expectedBody']);
    final String? bodyId;
    switch (body['kind']) {
      case 'empty':
        _keys(body, {'kind'});
        bodyId = null;
      case 'saved':
        _keys(body, {'kind', 'revisionId'});
        bodyId = _id(body, 'revisionId');
      default:
        throw const FormatException('Invalid expected discussion body');
    }
    final action = jsonObject(args['action']);
    _validateDiscussionAction(action);

    const receiptDirectory = ['.workspace', 'mcp', 'requests'];
    final store = DiscussionStore(repo);
    void requireWrite() {
      _requireCurrent(repo, controller.repository, context);
      _pathPrivateDirectory(repo, const ['revisions'], create: false);
    }

    Map<String, Object?> result(String threadId, RevisionRecord record) => {
      'noteId': noteId,
      'threadId': threadId,
      'eventId': record.entityId,
      'revisionId': record.revisionId,
    };
    const unknown = VaultMcpException(
      'operation_state_unknown',
      '이전 댓글 요청의 저장 여부를 확인하지 못했습니다. 앱에서 댓글을 확인하세요.',
    );

    requireWrite();
    _pathPrivateDirectory(repo, receiptDirectory, create: true);
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      if (type != FileSystemEntityType.file ||
          file.lengthSync() > VaultMcpBridge.maxBodyBytes) {
        throw unknown;
      }
      try {
        final receipt = readDiscussionMcpReceipt(
          jsonObject(jsonDecode(await file.readAsString())),
          noteId: noteId,
          requestId: requestId,
          digest: digest,
          action: action,
        );
        final record = await store.confirmPublication(
          descriptor: receipt.descriptor,
          eventBytes: receipt.eventBytes,
          pageId: noteId,
          eventId: receipt.eventId,
          expectedKind: receipt.kind,
          requireWrite: requireWrite,
        );
        return result(receipt.threadId, record);
      } on FormatException {
        throw unknown;
      } on FileSystemException {
        throw unknown;
      }
    }

    await prepareMutation?.call();
    requireWrite();
    final published = await controller.externalMutation((current) async {
      _requireCurrent(repo, current, context);
      final page = await _head(repo, noteId);
      if (page.revisionId != metadataId ||
          page.deleted ||
          page.kind != EntityKind.metadata ||
          page.ownerNoteId != null) {
        throw const VaultMcpException(
          'revision_conflict',
          '문서가 변경되었습니다. 최신 판본을 읽고 다시 요청하세요.',
        );
      }
      final metadata = jsonObject(
        jsonDecode(utf8.decode(await repo.readRevisionFile(page, 'note.json'))),
      );
      if (metadata['documentKind'] != 'page') {
        throw const VaultMcpException('unsupported', '블록 페이지에만 댓글을 달 수 있습니다.');
      }
      final inkHeads = await repo.heads(_id(metadata, 'inkEntityId'));
      final ink = inkHeads.singleOrNull;
      final bodyMatches = bodyId == null
          ? inkHeads.isEmpty
          : ink != null &&
                ink.revisionId == bodyId &&
                !ink.deleted &&
                ink.kind == EntityKind.ink &&
                ink.ownerNoteId == noteId &&
                ink.blobs.containsKey('page.json');
      if (!bodyMatches) {
        throw const VaultMcpException(
          'revision_conflict',
          '페이지 본문이 변경되었습니다. 최신 판본을 읽고 다시 요청하세요.',
        );
      }

      final eventId = newId();
      final expectedBodyRevision = (revisionId: bodyId);
      RevisionRecord? preparedRecord;
      Future<void> recordBeforePublish(
        PreparedCommit prepared,
        Uint8List eventBytes,
      ) async {
        void requireUnusedReceipt() {
          requireWrite();
          _pathPrivateDirectory(repo, receiptDirectory, create: false);
          if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            throw unknown;
          }
        }

        requireUnusedReceipt();
        await _writeRecord(file, {
          'version': 1,
          'operation': 'mutate_page_discussion',
          'requestId': requestId,
          'digest': digest,
          'descriptor': prepared.toRecoveryDescriptor(),
          'eventBytes': base64Encode(eventBytes),
        }, beforeRename: requireUnusedReceipt);
        preparedRecord = prepared.record;
      }

      switch (action['type']) {
        case 'create_thread':
          final target = jsonObject(action['anchor']);
          final DiscussionAnchor anchor;
          if (target['kind'] == 'page') {
            anchor = DiscussionAnchor.page(pageId: noteId);
          } else {
            if (ink == null) {
              throw const FormatException(
                'Expected saved text for a discussion anchor',
              );
            }
            final document = BlockPageDocument.fromJson(
              jsonObject(
                jsonDecode(
                  utf8.decode(await repo.readRevisionFile(ink, 'page.json')),
                ),
              ),
            );
            final blockId = _id(target, 'blockId');
            anchor = target['kind'] == 'block'
                ? DiscussionAnchor.block(
                    pageId: noteId,
                    document: document,
                    blockId: blockId,
                  )
                : DiscussionAnchor.quote(
                    pageId: noteId,
                    document: document,
                    blockId: blockId,
                    startUtf16: target['startUtf16'] as int,
                    endUtf16: target['endUtf16'] as int,
                  );
          }
          await store.createThread(
            page: page,
            anchor: anchor,
            body: action['body'] as String,
            eventId: eventId,
            expectedBodyRevision: expectedBodyRevision,
            beforePublish: requireWrite,
            onPrepared: recordBeforePublish,
          );
        case 'reply':
          await store.reply(
            page: page,
            threadId: action['threadId'] as String,
            replyToId: action['replyToId'] as String,
            body: action['body'] as String,
            eventId: eventId,
            expectedBodyRevision: expectedBodyRevision,
            beforePublish: requireWrite,
            onPrepared: recordBeforePublish,
          );
        case 'set_resolved':
          await store.setResolved(
            page: page,
            threadId: action['threadId'] as String,
            resolved: action['resolved'] as bool,
            expectedStatusIds: (action['expectedStatusIds'] as List)
                .cast<String>(),
            eventId: eventId,
            expectedBodyRevision: expectedBodyRevision,
            beforePublish: requireWrite,
            onPrepared: recordBeforePublish,
          );
      }
      final record = preparedRecord;
      if (record == null) throw unknown;
      return result(action['threadId'] as String? ?? eventId, record);
    });
    requireWrite();
    return published;
  }

  Future<Object?> _recordedPathChange(
    NoteRepository repo,
    Map<String, dynamic> args,
    File file,
    String requestId,
    String digest,
    VaultMcpCallContext context,
  ) async {
    _keys(args, {
      'noteId',
      'action',
      'title',
      'folderId',
      'expectedRevisionId',
      'requestId',
    });
    final id = _id(args, 'noteId'),
        action = _string(args, 'action', max: 20),
        sourceRevisionId = _id(args, 'expectedRevisionId');
    final changes = <String, Object?>{
      if (action == 'rename') 'title': _string(args, 'title', max: 500).trim(),
      if (action == 'move') 'folderId': _optionalId(args, 'folderId'),
    };
    final bool? deleted = action == 'trash'
        ? true
        : action == 'restore'
        ? false
        : null;
    final requestedOperation = action == 'rename'
        ? jsonEncode(['rename', id, changes['title']])
        : jsonEncode(['metadata', id, changes, deleted]);
    if (action == 'rename' && (changes['title'] as String).isEmpty)
      throw const FormatException('Expected a nonempty document title');
    final binding = <String, Object?>{
      'version': 2,
      'operation': 'document_action',
      'requestId': requestId,
      'digest': digest,
      'rootUri': repo.root.absolute.uri.normalizePath().toString(),
      'vaultId': repo.vaultId,
      'deviceId': repo.deviceId,
      'formatVersion': repo.formatVersion,
      'noteId': id,
      'sourceRevisionId': sourceRevisionId,
      'action': action,
      'changes': changes,
      'deleted': deleted,
    };
    void requireWrite() {
      _requireCurrent(repo, controller.repository, context);
      _pathPrivateDirectory(repo, const ['revisions'], create: false);
    }

    Future<void> saveRecord(Map<String, Object?> record) async {
      requireWrite();
      _pathPrivateDirectory(repo, const [
        '.workspace',
        'mcp',
        'requests',
      ], create: false);
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file)
        throw const FormatException('Unsafe document action receipt target');
      if (utf8.encode(jsonEncode(record)).length > VaultMcpBridge.maxBodyBytes)
        throw const VaultMcpException(
          'content_too_large',
          '경로 변경 복구 기록이 요청 기록 한도를 넘습니다.',
        );
      await _writeRecord(file, record);
    }

    try {
      _pathPrivateDirectory(repo, const [
        '.workspace',
        'mcp',
        'requests',
      ], create: true);
      Map<String, dynamic>? receipt;
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        if (type != FileSystemEntityType.file ||
            file.lengthSync() > VaultMcpBridge.maxBodyBytes)
          throw const FormatException('Unsafe document action receipt');
        receipt = jsonObject(jsonDecode(await file.readAsString()));
        if (receipt['requestId'] == requestId && receipt['digest'] != digest)
          throw const VaultMcpException(
            'request_id_reused',
            '같은 요청 ID에 다른 내용을 사용할 수 없습니다.',
          );
        if (receipt['requestId'] != requestId || receipt['digest'] != digest)
          throw const FormatException(
            'The document action receipt identity changed',
          );
        if (receipt['version'] == 1 && receipt['version'] is int) {
          _keys(receipt, {
            'version',
            'requestId',
            'digest',
            'state',
            'result',
            'startedAt',
          });
          if (receipt['state'] != 'completed' || !receipt.containsKey('result'))
            throw const FormatException(
              'The legacy document action outcome is unknown',
            );
          return receipt['result'];
        }
        _keys(receipt, {
          ...binding.keys,
          'state',
          'baselineRevisionIds',
          'recoveryId',
          'plan',
          'files',
          'planDigest',
          'noOp',
          'sourceRecord',
          'sourceFiles',
          'result',
        });
        if (binding.entries.any(
              (entry) => !const DeepCollectionEquality().equals(
                receipt![entry.key],
                entry.value,
              ),
            ) ||
            !{'started', 'prepared', 'completed'}.contains(receipt['state']))
          throw const FormatException(
            'The document action receipt scope changed',
          );
        _pathRevisionIds(receipt['baselineRevisionIds']);
        validateId(receipt['recoveryId'] as String);
        if (receipt['state'] != 'started') {
          if (receipt['planDigest'] != _pathReceiptDigest(receipt) ||
              receipt['noOp'] is! bool ||
              receipt['state'] != 'completed' && receipt.containsKey('result'))
            throw const FormatException(
              'Invalid prepared document action receipt',
            );
        } else if (receipt.keys.any(
          (key) => !{
            ...binding.keys,
            'state',
            'baselineRevisionIds',
            'recoveryId',
          }.contains(key),
        )) {
          throw const FormatException(
            'Invalid started document action receipt',
          );
        }
      }

      Future<void> requireBaseline(List<String> baseline) async {
        requireWrite();
        if (repo.pendingRevisionCount != 0 ||
            repo.integrityIssues.isNotEmpty ||
            !const SetEquality<String>().equals(
              (await repo.revisions()).map((r) => r.revisionId).toSet(),
              baseline.toSet(),
            ))
          throw StateError('The original document action snapshot changed');
      }

      Future<Map<String, dynamic>> finishPrepared(
        Map<String, dynamic> saved,
      ) async {
        if (saved['noOp'] != false ||
            saved['plan'] is! Map ||
            saved['files'] is! List ||
            saved.containsKey('sourceRecord') ||
            saved.containsKey('sourceFiles'))
          throw const FormatException('Invalid prepared document action files');
        final descriptor = jsonObject(saved['plan']);
        if (descriptor['operation'] != requestedOperation ||
            descriptor['oldRevision'] != sourceRevisionId ||
            !const SetEquality<String>().equals(
              _pathRevisionIds(descriptor['capturedRevisionIds']).toSet(),
              _pathRevisionIds(saved['baselineRevisionIds']).toSet(),
            ))
          throw const FormatException(
            'The prepared document action is associated with another request',
          );
        final rawSteps = descriptor['steps'];
        if (rawSteps is! List || rawSteps.isEmpty || rawSteps.length > 10000)
          throw const FormatException('Invalid prepared document action steps');
        final steps = [
          for (final raw in rawSteps)
            RevisionRecord.fromJson(jsonObject(jsonObject(raw)['record'])),
        ];
        final finalRecord = steps.last;
        if (finalRecord.entityId != id ||
            finalRecord.kind != EntityKind.metadata ||
            finalRecord.ownerNoteId != null ||
            finalRecord.parentRevisionIds.length != 1 ||
            finalRecord.parentRevisionIds.single != sourceRevisionId ||
            steps.any(
              (step) =>
                  step.vaultId != repo.vaultId ||
                  step.deviceId != repo.deviceId ||
                  step.formatVersion != repo.formatVersion,
            ))
          throw const FormatException(
            'The prepared metadata source association changed',
          );
        final manifests = _pathFileManifests(saved['files']);
        if (manifests.length != steps.length)
          throw const FormatException(
            'The prepared files do not match the steps',
          );
        final files = <Map<String, Uint8List>>[];
        for (var index = 0; index < steps.length; index++) {
          final step = steps[index];
          final published = await _pathPublishedFiles(
            repo,
            step,
            manifests[index],
            mustExist: saved['state'] == 'completed',
          );
          files.add(
            published ??
                await _readPathRecoveryFiles(
                  repo,
                  requestId,
                  saved['recoveryId'] as String,
                  index,
                  manifests[index],
                ),
          );
        }
        final prepared = await resumePreparedKnowledgeChange(
          repo,
          descriptor: descriptor,
          files: files,
          invoke: controller.native?.invoke,
          requireWrite: requireWrite,
        );
        requireWrite();
        await prepared.publish(repo, requireWrite: requireWrite);
        final captured = await readCapturedKnowledgeNote(
          repo,
          revisionIds: [
            ..._pathRevisionIds(saved['baselineRevisionIds']),
            for (final step in steps) step.revisionId,
          ],
          sourceRevisionId: finalRecord.revisionId,
        );
        final result = _noteData(captured);
        if (saved['state'] == 'completed' &&
            !const DeepCollectionEquality().equals(result, saved['result']))
          throw const FormatException(
            'The completed document action result changed',
          );
        return result;
      }

      Future<Map<String, dynamic>> finishNoOp(
        Map<String, dynamic> saved,
      ) async {
        if (saved['state'] != 'completed' ||
            saved['noOp'] != true ||
            saved['plan'] != null ||
            saved['files'] is! List ||
            (saved['files'] as List).isNotEmpty)
          throw const FormatException('Invalid no-op document action receipt');
        final source = RevisionRecord.fromJson(
          jsonObject(saved['sourceRecord']),
        );
        if (source.revisionId != sourceRevisionId ||
            source.entityId != id ||
            source.kind != EntityKind.metadata ||
            source.ownerNoteId != null ||
            source.vaultId != repo.vaultId ||
            source.formatVersion > repo.formatVersion)
          throw const FormatException('The no-op source association changed');
        final manifest = _pathFileManifests([saved['sourceFiles']]).single;
        final files = (await _pathPublishedFiles(
          repo,
          source,
          manifest,
          mustExist: true,
        ))!;
        final baseline = _pathRevisionIds(saved['baselineRevisionIds']);
        final captured = await readCapturedKnowledgeNote(
          repo,
          revisionIds: baseline,
          sourceRevisionId: sourceRevisionId,
        );
        final ids = baseline.toSet();
        final records = (await repo.revisions())
            .where((record) => ids.contains(record.revisionId))
            .toList();
        if (!_pathIsNoOp(action, changes, deleted, source, files, records))
          throw const FormatException(
            'The requested document action is not a no-op',
          );
        final result = _noteData(captured);
        if (captured.deletionConflict ||
            !const DeepCollectionEquality().equals(result, saved['result']))
          throw const FormatException('The no-op acknowledgement changed');
        return result;
      }

      if (receipt?['state'] == 'completed') {
        requireWrite();
        return await (receipt!['noOp'] == true
            ? finishNoOp(receipt)
            : finishPrepared(receipt));
      }
      if (receipt?['state'] == 'prepared') {
        await prepareMutation?.call();
        requireWrite();
        final result = await controller.externalMutation((current) async {
          _requireCurrent(repo, current, context);
          return finishPrepared(receipt!);
        });
        await saveRecord({...receipt!, 'state': 'completed', 'result': result});
        return result;
      }
      if (receipt != null)
        await requireBaseline(_pathRevisionIds(receipt['baselineRevisionIds']));
      await prepareMutation?.call();
      requireWrite();
      final result = await controller.externalMutation((current) async {
        _requireCurrent(repo, current, context);
        if (receipt != null)
          await requireBaseline(
            _pathRevisionIds(receipt!['baselineRevisionIds']),
          );
        final note = await _note(repo, id);
        await _expected(repo, id, sourceRevisionId);
        final baselineRecords = await repo.revisions();
        final baseline = baselineRecords.map((r) => r.revisionId).toList()
          ..sort();
        final recoveryId = newId();
        receipt = {
          ...binding,
          'state': 'started',
          'baselineRevisionIds': baseline,
          'recoveryId': recoveryId,
        };
        await saveRecord(receipt!);
        final sourceFiles = await repo.readFiles(note.revision);
        _pathFileManifests([_pathFileManifest(sourceFiles)]);
        if (_pathIsNoOp(
          action,
          changes,
          deleted,
          note.revision,
          sourceFiles,
          baselineRecords,
        )) {
          await requireBaseline(baseline);
          await _pathPublishedFiles(
            repo,
            note.revision,
            _pathFileManifest(sourceFiles),
            mustExist: true,
          );
          await requireBaseline(baseline);
          final captured = await readCapturedKnowledgeNote(
            repo,
            revisionIds: baseline,
            sourceRevisionId: sourceRevisionId,
          );
          await requireBaseline(baseline);
          final result = _noteData(captured);
          if (captured.deletionConflict)
            throw StateError(
              'Compare the current document branches before changing paths',
            );
          receipt = {
            ...receipt!,
            'noOp': true,
            'plan': null,
            'files': <Object?>[],
            'sourceRecord': note.revision.toJson(),
            'sourceFiles': _pathFileManifest(sourceFiles),
            'state': 'completed',
            'result': result,
          };
          receipt!['planDigest'] = _pathReceiptDigest(receipt!);
          return result;
        }
        final store = WorkspaceStore(repo, native: controller.native);
        var preparedSeen = false;
        Future<void> onPrepared(PreparedKnowledgeChange plan) async {
          requireWrite();
          final descriptor = plan.toRecoveryDescriptor();
          if (descriptor['operation'] != requestedOperation ||
              descriptor['oldRevision'] != sourceRevisionId)
            throw const FormatException(
              'The prepared action does not match its request',
            );
          final files = plan.copyRecoveryFiles();
          final manifests = [for (final step in files) _pathFileManifest(step)];
          _pathFileManifests(manifests);
          final captured = _pathRevisionIds(descriptor['capturedRevisionIds']);
          final initialIds = captured.toSet();
          final requestIds = baseline.toSet();
          var preparedBaseline = baseline;
          if (!const SetEquality<String>().equals(initialIds, requestIds)) {
            final steps = [
              for (final raw in descriptor['steps'] as List)
                RevisionRecord.fromJson(jsonObject(jsonObject(raw)['record'])),
            ];
            final publishedIds = requestIds.difference(initialIds);
            final prefix = steps.take(publishedIds.length).toList();
            if (!requestIds.containsAll(initialIds) ||
                publishedIds.isEmpty ||
                publishedIds.length >= steps.length ||
                prefix.any(
                  (step) =>
                      !const {
                        EntityKind.markdown,
                        EntityKind.ink,
                      }.contains(step.kind) ||
                      step.ownerNoteId == null,
                ) ||
                !const SetEquality<String>().equals(
                  publishedIds,
                  prefix.map((step) => step.revisionId).toSet(),
                ))
              throw const VaultMcpException(
                'revision_conflict',
                '요청 이후 문서 판본이 변경됐습니다. 최신 판본을 읽고 다시 요청하세요.',
              );
            await resumePreparedKnowledgeChange(
              repo,
              descriptor: descriptor,
              files: files,
              invoke: controller.native?.invoke,
              requireWrite: requireWrite,
            );
            await _expected(repo, id, sourceRevisionId);
            requireWrite();
            preparedBaseline = List.of(captured)..sort();
          }
          final record = <String, dynamic>{
            ...receipt!,
            'baselineRevisionIds': preparedBaseline,
            'state': 'prepared',
            'noOp': false,
            'plan': descriptor,
            'files': manifests,
          };
          record['planDigest'] = _pathReceiptDigest(record);
          if (utf8.encode(jsonEncode(record)).length >
              VaultMcpBridge.maxBodyBytes)
            throw const VaultMcpException(
              'content_too_large',
              '경로 변경 복구 기록이 요청 기록 한도를 넘습니다.',
            );
          await _writePathRecoveryFiles(repo, requestId, recoveryId, files);
          requireWrite();
          await saveRecord(record);
          receipt = record;
          preparedSeen = true;
        }

        switch (action) {
          case 'rename':
            await store.rename(
              note,
              changes['title'] as String,
              requireWrite: requireWrite,
              onPrepared: onPrepared,
            );
          case 'move':
            await store.moveNote(
              note,
              changes['folderId'] as String?,
              requireWrite: requireWrite,
              onPrepared: onPrepared,
            );
          case 'trash':
          case 'restore':
            await store.setDeleted(
              note,
              deleted!,
              requireWrite: requireWrite,
              onPrepared: onPrepared,
            );
        }
        if (!preparedSeen)
          throw const FormatException(
            'The document action did not provide a prepared edition',
          );
        return finishPrepared(receipt!);
      });
      await saveRecord({...receipt!, 'state': 'completed', 'result': result});
      return result;
    } on StateError {
      throw const VaultMcpException(
        'revision_conflict',
        '문서나 링크 원본이 변경됐습니다. 준비 판본을 최신 원본에 자동 연결하지 않습니다.',
      );
    } on FormatException {
      throw const VaultMcpException(
        'operation_state_unknown',
        '경로 변경 복구 기록이나 실제 저장 판본을 확인하지 못했습니다.',
      );
    } on TypeError {
      throw const VaultMcpException(
        'operation_state_unknown',
        '경로 변경 복구 기록의 형식을 확인하지 못했습니다.',
      );
    } on FileSystemException {
      throw const VaultMcpException(
        'operation_state_unknown',
        '경로 변경 기록을 확정하지 못했습니다. 같은 요청 ID와 내용으로 다시 확인하세요.',
      );
    }
  }

  Future<Object?> _recordedOffice(
    NoteRepository repo,
    Map<String, dynamic> args,
    File file,
    String requestId,
    String digest,
    VaultMcpCallContext context,
  ) async {
    _officePrivateDirectory(repo, const [
      '.workspace',
      'mcp',
      'requests',
    ], create: true);
    Map<String, dynamic>? saved;
    final receiptType = FileSystemEntity.typeSync(
      file.path,
      followLinks: false,
    );
    if (receiptType != FileSystemEntityType.notFound) {
      if (receiptType != FileSystemEntityType.file ||
          file.lengthSync() > VaultMcpBridge.maxBodyBytes)
        throw const VaultMcpException(
          'operation_state_unknown',
          'Office 요청 기록을 확인하지 못했습니다.',
        );
      saved = jsonObject(jsonDecode(await file.readAsString()));
      if (saved['requestId'] == requestId && saved['digest'] != digest)
        throw const VaultMcpException(
          'request_id_reused',
          '같은 요청 ID에 다른 내용을 사용할 수 없습니다.',
        );
      if (saved['requestId'] != requestId || saved['digest'] != digest)
        throw const VaultMcpException(
          'operation_state_unknown',
          'Office 요청 결합을 확인하지 못했습니다.',
        );
      if (saved['version'] == 1) {
        if (saved['state'] != 'completed' ||
            !saved.keys.toSet().containsAll({
              'version',
              'requestId',
              'digest',
              'state',
              'result',
            }) ||
            saved.keys.any(
              (key) => !{
                'version',
                'requestId',
                'digest',
                'state',
                'result',
                'startedAt',
              }.contains(key),
            ))
          throw const VaultMcpException(
            'operation_state_unknown',
            '이전 Office 요청의 처리 결과를 확인하지 못했습니다. 문서 이력을 확인하세요.',
          );
        return saved['result'];
      }
    }
    _keys(args, {'noteId', 'expectedRevisionId', 'operations', 'requestId'});
    final id = _id(args, 'noteId'),
        sourceRevisionId = _id(args, 'expectedRevisionId');
    final operations = _officeOperations(args);
    final assetIds = <String>{
      for (final operation in operations)
        if (operation.toJson()['assetId'] case final String id) id,
    }.toList()..sort();
    final binding = <String, Object?>{
      'version': 2,
      'operation': 'office_edit',
      'requestId': requestId,
      'digest': digest,
      'rootUri': repo.root.absolute.uri.normalizePath().toString(),
      'vaultId': repo.vaultId,
      'deviceId': repo.deviceId,
      'formatVersion': repo.formatVersion,
      'noteId': id,
      'sourceRevisionId': sourceRevisionId,
      'operations': [for (final operation in operations) operation.toJson()],
      'assetIds': assetIds,
    };
    const preparedKeys = {
      'noteRevisionId',
      'sourceEntityId',
      'sourceSha256',
      'assets',
      'plan',
      'planDigest',
      'files',
    };
    if (saved != null) {
      if (binding.entries.any(
            (entry) => !const DeepCollectionEquality().equals(
              saved![entry.key],
              entry.value,
            ),
          ) ||
          !{'started', 'prepared', 'completed'}.contains(saved['state']) ||
          saved.keys.any(
            (key) => !{
              ...binding.keys,
              ...preparedKeys,
              'state',
              'result',
            }.contains(key),
          ))
        throw const VaultMcpException(
          'operation_state_unknown',
          'Office 영수증의 저장소·요청 결합을 확인하지 못했습니다.',
        );
      if (saved['state'] == 'started')
        throw const VaultMcpException(
          'operation_state_unknown',
          'Office 엔진 완료 전 요청은 자동 반복하지 않습니다. 문서 이력을 확인하세요.',
        );
      if (!saved.keys.toSet().containsAll(preparedKeys) ||
          saved['plan'] is! Map ||
          saved['files'] is! Map ||
          saved['assets'] is! List ||
          saved['planDigest'] != _officeReceiptPlanDigest(saved) ||
          saved['state'] != 'completed' && saved.containsKey('result'))
        throw const VaultMcpException(
          'operation_state_unknown',
          'Office 준비 판본의 영수증을 확인하지 못했습니다.',
        );
    } else {
      final privatePath = p.join(file.parent.path, requestId);
      if (FileSystemEntity.typeSync(privatePath, followLinks: false) !=
          FileSystemEntityType.notFound)
        throw const VaultMcpException(
          'operation_state_unknown',
          '기존 Office 복구 파일이 있습니다. 같은 요청을 자동 반복하지 마세요.',
        );
      _requireCurrent(repo, controller.repository, context);
      await _writeRecord(file, {...binding, 'state': 'started'});
    }
    void requireWrite() {
      _requireCurrent(repo, controller.repository, context);
      if (FileSystemEntity.typeSync(
            p.join(repo.root.path, 'revisions'),
            followLinks: false,
          ) !=
          FileSystemEntityType.directory)
        throw const FormatException(
          'Office revisions must remain an owned directory',
        );
    }

    Map<String, dynamic>? receipt = saved;
    OfficePreparedEdition? prepared;
    Future<OfficePreparedEdition> resume() async {
      final record = receipt!;
      final planJson = jsonObject(record['plan']);
      if (planJson['requireCurrentHeads'] != true ||
          planJson['noteRevisionId'] != record['noteRevisionId'] ||
          planJson['sourceRevisionId'] != sourceRevisionId)
        throw const FormatException(
          'Office receipt plan policy or captured identity changed',
        );
      final planned = RevisionRecord.fromJson(
        jsonObject(jsonObject(planJson['prepared'])['record']),
      );
      if (planned.entityId != record['sourceEntityId'] ||
          planned.ownerNoteId != id ||
          planned.vaultId != repo.vaultId ||
          planned.deviceId != repo.deviceId ||
          planned.formatVersion != repo.formatVersion)
        throw const FormatException('Office receipt revision scope changed');
      _validateOfficeAssetBindings(record['assets'], assetIds);
      final note = await _note(repo, id);
      if (note.sourceEntityId != planned.entityId ||
          note.documentKind != VaultDocumentKind.office)
        throw StateError('The Office source association changed');
      final manifest = File(
        p.join(repo.root.path, 'revisions', '${planned.revisionId}.json'),
      );
      final manifestType = FileSystemEntity.typeSync(
        manifest.path,
        followLinks: false,
      );
      final Map<String, Uint8List> files;
      if (manifestType != FileSystemEntityType.notFound ||
          record['state'] == 'completed') {
        if (manifestType != FileSystemEntityType.file ||
            manifest.lengthSync() > VaultMcpBridge.maxBodyBytes)
          throw const FormatException(
            'The published Office manifest is missing or unsafe',
          );
        final actual = RevisionRecord.fromJson(
          jsonObject(jsonDecode(await manifest.readAsString())),
        );
        if (!const DeepCollectionEquality().equals(
          actual.toJson(),
          planned.toJson(),
        ))
          throw const FormatException('The published Office manifest changed');
        files = await repo.readFiles(actual);
        if (!const DeepCollectionEquality().equals(
          _officeFileManifest(files),
          record['files'],
        ))
          throw const FormatException('The published Office files changed');
      } else {
        files = await _readOfficeRecoveryFiles(
          repo,
          requestId,
          jsonObject(record['files']),
        );
      }
      final originalName = _officeOriginalName(files.keys);
      final sources = (await repo.revisions())
          .where((revision) => revision.revisionId == sourceRevisionId)
          .toList();
      if (sources.length != 1 ||
          sources.single.entityId != planned.entityId ||
          sources.single.ownerNoteId != id ||
          sources.single.kind != EntityKind.attachment ||
          sources.single.deleted ||
          sources.single.blobs[originalName]?.hash != record['sourceSha256'])
        throw const FormatException(
          'The original Office source binding changed',
        );
      return OfficeDocumentStore(repo).resumePreparedEdition(
        note,
        descriptor: planJson,
        files: files,
        beforePublish: requireWrite,
      );
    }

    try {
      if (saved?['state'] == 'completed') {
        requireWrite();
        prepared = await resume();
        final edition = await OfficeDocumentStore(repo)
            .commitPreparedEdition(prepared);
        final result = _officeEditionResult(id, edition);
        if (!const DeepCollectionEquality().equals(saved!['result'], result))
          throw const FormatException('The completed Office result changed');
        return result;
      }
      await prepareMutation?.call();
      requireWrite();
      final result = await controller.externalMutation((current) async {
        _requireCurrent(repo, current, context);
        if (saved?['state'] == 'prepared') {
          prepared = await resume();
        } else {
          final native = await _prepareOfficeEdit(
            repo,
            args,
            operations,
            context,
            beforePublish: requireWrite,
          );
          prepared = native.plan;
          requireWrite();
          final files = prepared!.copyRecoveryFiles();
          final fileManifest = _officeFileManifest(files);
          await _writeOfficeRecoveryFiles(repo, requestId, files);
          final planJson = prepared!.toRecoveryDescriptor();
          receipt = {
            ...binding,
            'state': 'prepared',
            'noteRevisionId': native.session.note.revision.revisionId,
            'sourceEntityId': native.session.sourceEntityId,
            'sourceSha256': sha256
                .convert(native.session.originalBytes)
                .toString(),
            'assets': native.assets,
            'plan': planJson,
            'files': fileManifest,
          };
          receipt!['planDigest'] = _officeReceiptPlanDigest(receipt!);
          if (utf8.encode(jsonEncode(receipt)).length >
              VaultMcpBridge.maxBodyBytes)
            throw const VaultMcpException(
              'content_too_large',
              'Office 복구 영수증이 요청 기록 한도를 넘습니다.',
            );
          requireWrite();
          await _writeRecord(file, receipt!);
        }
        requireWrite();
        final edition = await OfficeDocumentStore(repo)
            .commitPreparedEdition(prepared!);
        return _officeEditionResult(id, edition);
      });
      try {
        await _writeRecord(file, {
          ...receipt!,
          'state': 'completed',
          'result': result,
        });
      } on FileSystemException {
        throw const VaultMcpException(
          'operation_state_unknown',
          'Office 판본은 저장됐지만 완료 영수증을 기록하지 못했습니다. 같은 요청 ID와 내용으로 재확인하세요.',
        );
      }
      for (final assetId in assetIds) {
        try {
          await OfficeAssetStore(repo).discard(
            assetId: assetId,
            noteId: id,
            sourceRevisionId: sourceRevisionId,
            requireWrite: () async => requireWrite(),
          );
        } catch (_) {
          // A confirmed edition remains successful if staged asset cleanup fails.
        }
      }
      return result;
    } on StateError {
      throw const VaultMcpException(
        'revision_conflict',
        'Office 원본이나 메타데이터가 변경됐습니다. 준비 판본을 최신 원본에 자동 연결하지 않습니다.',
      );
    } on FormatException {
      throw const VaultMcpException(
        'operation_state_unknown',
        'Office 복구 기록이나 실제 저장 판본을 확인하지 못했습니다.',
      );
    }
  }

  Future<Object?> _recordedPageRestore(
    NoteRepository repo,
    Map<String, dynamic> args,
    File file,
    String requestId,
    String digest,
    VaultMcpCallContext context,
  ) async {
    _keys(args, {
      'noteId',
      'revisionId',
      'expectedRevisionId',
      'expectedHeads',
      'requestId',
    });
    final id = _id(args, 'noteId'), selected = _id(args, 'revisionId');
    final expected = _id(args, 'expectedRevisionId');
    final rawHeads = jsonObject(args['expectedHeads']);
    if (rawHeads.length < 2 || rawHeads.length > 1024)
      throw const FormatException('Invalid restore guard count');
    final heads = <String, List<String>>{};
    for (final entry in rawHeads.entries) {
      validateId(entry.key);
      final ids = entry.value;
      if (ids is! List || ids.length != 1 || ids.single is! String)
        throw const FormatException('Invalid restore guard');
      validateId(ids.single as String);
      heads[entry.key] = [ids.single as String];
    }
    final binding = <String, Object?>{
      'version': 2,
      'requestId': requestId,
      'digest': digest,
      'rootUri': repo.root.absolute.uri.normalizePath().toString(),
      'vaultId': repo.vaultId,
      'deviceId': repo.deviceId,
      'formatVersion': repo.formatVersion,
    };
    Map<String, dynamic>? saved;
    if (file.existsSync()) {
      if (await file.length() > VaultMcpBridge.maxBodyBytes)
        throw const VaultMcpException(
          'operation_state_unknown',
          '복원 영수증의 크기를 확인하지 못했습니다.',
        );
      saved = jsonObject(jsonDecode(await file.readAsString()));
      if (saved['requestId'] == requestId && saved['digest'] != digest)
        throw const VaultMcpException(
          'request_id_reused',
          '같은 요청 ID에 다른 내용을 사용할 수 없습니다.',
        );
      if (binding.entries.any((e) => saved![e.key] != e.value) ||
          !{'started', 'prepared', 'completed'}.contains(saved['state']) ||
          saved.keys.any(
            (key) => !{
              ...binding.keys,
              'state',
              'plan',
              'planDigest',
              'result',
            }.contains(key),
          ))
        throw const VaultMcpException(
          'operation_state_unknown',
          '복원 영수증의 저장소·요청 결합을 확인하지 못했습니다.',
        );
      if (saved['state'] == 'started' &&
              saved.keys.any(
                (key) => {'plan', 'planDigest', 'result'}.contains(key),
              ) ||
          saved['state'] != 'started' &&
              (saved['plan'] is! Map ||
                  saved['planDigest'] != _restorePlanDigest(saved['plan'])) ||
          saved['state'] != 'completed' && saved.containsKey('result'))
        throw const VaultMcpException(
          'operation_state_unknown',
          '복원 계획의 영수증을 확인하지 못했습니다.',
        );
    } else {
      context.requireActive(write: true);
      await _writeRecord(file, {...binding, 'state': 'started'});
    }
    PreparedPageRestore? plan;
    Future<PreparedPageRestore> resume(NoteSession session) async {
      final restored = await session.resumeInkRevisionRestore(
        jsonObject(saved!['plan']),
      );
      if (restored.selectedRevisionId != selected ||
          restored.record.parentRevisionIds.single != expected ||
          !const DeepCollectionEquality().equals(restored.expectedHeads, heads))
        throw const VaultMcpException(
          'operation_state_unknown',
          '복원 계획과 요청의 판본·비교 조건이 일치하지 않습니다.',
        );
      return restored;
    }

    Map<String, Object?> resultFor(PreparedPageRestore plan) => {
      'noteId': id,
      'target': 'body',
      'revisionId': plan.record.revisionId,
      'restoredFromRevisionId': selected,
      'previousRevisionId': expected,
    };
    void requireWrite() =>
        _requireCurrent(repo, controller.repository, context);
    try {
      if (saved?['state'] == 'completed') {
        final session = await _pageHistorySession(repo, id, historical: true);
        plan = await resume(session);
        if (!(await repo.revisions()).any(
              (r) => r.revisionId == plan!.record.revisionId,
            ) ||
            !const DeepCollectionEquality().equals(
              saved!['result'],
              resultFor(plan),
            ))
          throw const VaultMcpException(
            'operation_state_unknown',
            '완료된 복원의 실제 판본을 확인하지 못했습니다.',
          );
        await session.publishInkRevisionRestore(
          plan,
          requireWrite: requireWrite,
        );
        return resultFor(plan);
      }
      await prepareMutation?.call();
      requireWrite();
      final result = await controller.externalMutation((current) async {
        _requireCurrent(repo, current, context);
        final session = await _pageHistorySession(
          repo,
          id,
          historical: saved?['state'] == 'prepared',
        );
        if (saved?['state'] == 'prepared') {
          plan = await resume(session);
        } else {
          final records = await repo.revisions();
          final chosen = _ownedPageRecord(records, session.note, selected);
          if (heads[session.note.inkEntityId]?.single != expected)
            throw const FormatException('Missing observed body guard');
          plan = await session.prepareInkRevisionRestore(
            chosen,
            expectedHeadRevisionIds: [expected],
            expectedHeads: heads,
          );
          final json = plan!.toJson();
          final preparedReceipt = <String, Object?>{
            ...binding,
            'state': 'prepared',
            'plan': json,
            'planDigest': _restorePlanDigest(json),
          };
          if (utf8.encode(jsonEncode(preparedReceipt)).length >
              VaultMcpBridge.maxBodyBytes)
            throw const VaultMcpException(
              'content_too_large',
              '복원 계획이 MCP 요청 기록 한도를 넘습니다. 앱에서 복원하세요.',
            );
          await _writeRecord(file, preparedReceipt);
        }
        requireWrite();
        await session.publishInkRevisionRestore(
          plan!,
          requireWrite: requireWrite,
        );
        return resultFor(plan!);
      });
      try {
        final json = plan!.toJson();
        await _writeRecord(file, {
          ...binding,
          'state': 'completed',
          'plan': json,
          'planDigest': _restorePlanDigest(json),
          'result': result,
        });
      } on FileSystemException {
        throw const VaultMcpException(
          'operation_state_unknown',
          '복원 후 완료 영수증을 기록하지 못했습니다. 같은 요청 ID와 내용으로 다시 시도하세요.',
        );
      }
      return result;
    } on StateError {
      throw const VaultMcpException(
        'revision_conflict',
        '페이지나 폴더가 변경되었거나 복원 응답을 확인하지 못했습니다. 같은 요청으로 재확인하거나 이력을 다시 비교하세요.',
      );
    }
  }

  String _restorePlanDigest(Object? plan) =>
      sha256.convert(utf8.encode(jsonEncode(_canonical(plan)))).toString();

  void _requireCurrent(
    NoteRepository expected,
    NoteRepository current,
    VaultMcpCallContext context,
  ) {
    _requireRepository();
    context.requireActive(write: true);
    if (!identical(expected, current))
      throw const VaultMcpException('vault_changed', '연결된 저장소가 바뀌었습니다.');
  }

  Future<Object?> _mutate(
    NoteRepository repo,
    String operation,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    final store = WorkspaceStore(repo, native: controller.native);
    switch (operation) {
      case 'ensure_daily_note':
        final now = DateTime.now();
        final templates = WorkspaceMarkdownTemplateStore(repo);
        final note = await store.openDailyNote(
          _dailyDate(args),
          loadInitialMarkdown: (title) async {
            try {
              return await templates.initialDailyMarkdown(title, now);
            } on FormatException {
              throw const VaultMcpException(
                'revision_conflict',
                '날짜별 노트 템플릿을 확인할 수 없습니다. 앱에서 설정을 다시 선택하거나 해제하세요.',
              );
            }
          },
          beforePublish: () =>
              _requireCurrent(repo, controller.repository, context),
        );
        return {'date': args['date'], 'noteId': note.id};
      case 'create_document':
        _keys(args, {'title', 'kind', 'folderId', 'body', 'requestId'});
        final title = _string(args, 'title', max: 500),
            kindName = _string(args, 'kind', max: 30);
        final officeKind = const {
          'word': OfficeTemplateKind.document,
          'presentation': OfficeTemplateKind.presentation,
          'hwpx': OfficeTemplateKind.hwpx,
        }[kindName];
        if (officeKind != null) {
          if (args['body'] != null)
            throw const FormatException(
              'Use office_edit for Office body changes',
            );
          final folderId = _optionalId(args, 'folderId');
          await LibraryStore(repo).validateDestination(folderId);
          final file = OfficeTemplates.create(officeKind, title: title);
          context.requireActive(write: true);
          final note = await OfficeDocumentStore(repo).importDocument(
            title: title,
            fileName: file.fileName,
            bytes: file.bytes,
            folderId: folderId,
          );
          final source = (await repo.heads(note.sourceEntityId!)).single;
          return {
            ..._noteData(note),
            'noteId': note.id,
            'sourceRevisionId': source.revisionId,
            'originalFileName': file.fileName,
          };
        }
        if (!{'markdown', 'handwriting', ..._bodyFiles.keys}.contains(kindName))
          throw const VaultMcpException(
            'unsupported',
            '이 문서 종류는 앱의 가져오기 기능을 사용하세요.',
          );
        final kind = VaultDocumentKind.values
            .where((value) => value.name == kindName)
            .firstOrNull;
        if (kind == null)
          throw const VaultMcpException(
            'unsupported',
            '현재 앱에서 지원하지 않는 문서 종류입니다.',
          );
        final body = _initialBody(kindName, args['body']);
        final folderId = _optionalId(args, 'folderId');
        await LibraryStore(repo).validateDestination(folderId);
        context.requireActive(write: true);
        final note = await store.create(
          title,
          folderId: folderId,
          documentKind: kind,
        );
        final session = await store.open(note);
        if (kindName == 'markdown')
          await session.saveMarkdown(body as String);
        else if (kindName == 'handwriting') {
          final core = EditorCoreInfo(filePath: '/.working/${note.id}/new/main')
            ..pages.add(EditorPage());
          try {
            await session.saveInk(await SaberInkAdapter.capture(core, 0));
          } finally {
            core.dispose();
          }
        } else {
          await session.saveInk({
            _bodyFiles[kindName]!: Uint8List.fromList(
              utf8.encode(jsonEncode(body)),
            ),
          });
        }
        return {
          ..._noteData(note),
          'noteId': note.id,
          'bodyRevisionId': session.inkParents.firstOrNull,
          'markdownRevisionId': session.markdownParents.firstOrNull,
        };
      case 'update_document':
        _keys(args, {
          'noteId',
          'target',
          'content',
          'expectedRevisionId',
          'requestId',
        });
        final note = await _note(repo, _id(args, 'noteId'));
        if (note.trashed)
          throw const VaultMcpException('not_found', '휴지통의 문서는 먼저 복원하세요.');
        final target = _string(args, 'target', max: 20);
        final expected = _id(args, 'expectedRevisionId');
        final session = await store.open(note);
        void requireWrite() =>
            _requireCurrent(repo, controller.repository, context);
        if (target == 'markdown') {
          final content = _string(
            args,
            'content',
            allowEmpty: true,
            max: 1024 * 1024,
          );
          await _expected(repo, note.markdownEntityId, expected);
          requireWrite();
          try {
            await session.saveMarkdown(
              content,
              expectedHeads: {
                note.id: [note.revision.revisionId],
                note.markdownEntityId: [expected],
              },
              requireWrite: requireWrite,
            );
          } on StateError {
            throw const VaultMcpException(
              'revision_conflict',
              '문서나 메타데이터가 변경되었습니다. 최신 판본을 읽고 다시 요청하세요.',
            );
          }
          return {
            'noteId': note.id,
            'target': target,
            'revisionId': session.markdownParents.single,
          };
        }
        if (target != 'body')
          throw const FormatException('Unknown document target');
        final fileName = _bodyFiles[note.documentKind.name];
        if (fileName == null)
          throw const VaultMcpException(
            'unsupported',
            '이 문서의 원본은 전용 필기·Office 편집 기능을 사용하세요.',
          );
        final content = _validateBody(
          note.documentKind.name,
          jsonObject(args['content']),
        );
        await _expected(repo, note.inkEntityId, expected);
        final record = (await repo.revisions()).singleWhere(
          (r) => r.revisionId == expected,
        );
        final files = await repo.readFiles(record);
        if (note.documentKind == VaultDocumentKind.database) {
          final previous = WorkspaceDatabase.fromJson(
            jsonObject(jsonDecode(utf8.decode(files['database.json']!))),
          );
          if (content['id'] != previous.id) {
            throw const VaultMcpException(
              'identity_changed',
              '연결된 데이터베이스의 ID는 변경할 수 없습니다.',
            );
          }
          final previousContent = previous.toJson();
          if (!const DeepCollectionEquality().equals(
            content['automationExecutions'],
            previousContent['automationExecutions'],
          )) {
            throw const FormatException(
              'Automation execution receipts are managed by the app',
            );
          }
          final next = WorkspaceDatabase.fromJson(content);
          final nextIds = next.rows.map((row) => row.id).toSet();
          final removed = {
            for (final row in previous.rows)
              if (!nextIds.contains(row.id)) row.id,
          };
          if (previousContent.containsKey('pivTaskLinks') !=
                  content.containsKey('pivTaskLinks') ||
              !const DeepCollectionEquality().equals(
                previousContent['pivTaskLinks'],
                content['pivTaskLinks'],
              ) ||
              (removed.isNotEmpty &&
                  (!previous.supportsTaskLinks ||
                      previous.taskLinks.entries.any(
                        (entry) =>
                            removed.contains(entry.key) ||
                            removed.contains(entry.value.parentId) ||
                            entry.value.predecessorIds.any(removed.contains),
                      )))) {
            throw const VaultMcpException(
              'task_links_managed',
              '작업 연결을 수정하거나 연결된 행을 지우려면 작업 연결을 먼저 변경하세요.',
            );
          }
        }
        final Map<String, Uint8List> updatedFiles;
        if (note.documentKind == VaultDocumentKind.page) {
          updatedFiles = (await prepareBlockPageMediaInWorker(
            BlockPageDocument.fromJson(content),
            existingFiles: files,
            addedFiles: const {},
          )).files;
        } else if (note.documentKind == VaultDocumentKind.database) {
          updatedFiles = (await prepareDatabaseMediaInWorker(
            WorkspaceDatabase.fromJson(content),
            existingFiles: files,
            addedFiles: const {},
          )).files;
        } else {
          updatedFiles = {
            ...files,
            fileName: Uint8List.fromList(utf8.encode(jsonEncode(content))),
          };
        }
        await _expected(repo, note.inkEntityId, expected);
        _requireRepository();
        context.requireActive(write: true);
        final bodySession = NoteSession(repo, note, [record], []);
        try {
          await bodySession.saveInk(
            updatedFiles,
            expectedHeads: {
              note.id: [note.revision.revisionId],
              note.inkEntityId: [expected],
            },
            requireWrite: requireWrite,
          );
        } on StateError {
          throw const VaultMcpException(
            'revision_conflict',
            '문서나 메타데이터가 변경되었습니다. 최신 판본을 읽고 다시 요청하세요.',
          );
        }
        return {
          'noteId': note.id,
          'target': target,
          'revisionId': bodySession.inkParents.single,
        };
      case 'database_action':
        return _databaseAction(repo, args, context);
      case 'document_action':
        _keys(args, {
          'noteId',
          'action',
          'title',
          'folderId',
          'expectedRevisionId',
          'requestId',
        });
        final id = _id(args, 'noteId'),
            action = _string(args, 'action', max: 20);
        final note = await _note(repo, id);
        await _expected(repo, id, _id(args, 'expectedRevisionId'));
        context.requireActive(write: true);
        switch (action) {
          case 'rename':
            await store.rename(
              note,
              _string(args, 'title', max: 500),
              requireWrite: () {
                _requireRepository();
                context.requireActive(write: true);
              },
            );
          case 'move':
            await store.moveNote(
              note,
              _optionalId(args, 'folderId'),
              requireWrite: () =>
                  _requireCurrent(repo, controller.repository, context),
            );
          case 'trash':
            await store.setDeleted(
              note,
              true,
              requireWrite: () =>
                  _requireCurrent(repo, controller.repository, context),
            );
          case 'restore':
            await store.setDeleted(
              note,
              false,
              requireWrite: () =>
                  _requireCurrent(repo, controller.repository, context),
            );
          default:
            throw const FormatException('Unknown document action');
        }
        return {..._noteData(await _note(repo, id)), 'noteId': id};
      case 'office_asset':
        return _officeAsset(repo, args, context);
      default:
        throw const VaultMcpException('unknown_operation', '지원하지 않는 앱 작업입니다.');
    }
  }

  Future<Object?> _databaseAction(
    NoteRepository repo,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    void requireWrite() =>
        _requireCurrent(repo, controller.repository, context);

    final action = _string(args, 'action', max: 30);
    final actionKeys = switch (action) {
      'run_button' => {'ruleId', 'rowId'},
      'add_row' => {'values', 'templateId', 'parentTaskId'},
      'create_row_template' => {'rowId', 'name'},
      'delete_row_template' => {'templateId'},
      'set_cell' => {'rowId', 'propertyId', 'value'},
      'set_task_links' => {'rowId', 'parentId', 'predecessorIds'},
      'put_rule' => {'rule'},
      'archive_rule' => {'ruleId'},
      _ => throw const FormatException('Unknown database action'),
    };
    _keys(args, {
      'noteId',
      'expectedRevisionId',
      'requestId',
      'action',
      ...actionKeys,
    });
    final note = await _note(repo, _id(args, 'noteId'));
    if (note.trashed)
      throw const VaultMcpException('not_found', '휴지통의 문서는 먼저 복원하세요.');
    if (note.documentKind != VaultDocumentKind.database)
      throw const VaultMcpException('unsupported', '데이터베이스 문서에서 사용하는 작업입니다.');
    final expected = _id(args, 'expectedRevisionId');
    await _expected(repo, note.inkEntityId, expected);
    final head = await _head(repo, note.inkEntityId);
    final files = await repo.readFiles(head);
    final bytes = files['database.json'];
    if (bytes == null) throw const FormatException('Missing database body');
    final database = WorkspaceDatabase.fromJson(
      jsonObject(jsonDecode(utf8.decode(bytes))),
    );
    final native = controller.native;
    final runtime =
        actionRuntime ??
        (native == null
            ? null
            : DatabaseActionRuntime(
                deviceId: repo.deviceId,
                invoke: native.invoke,
              ));
    if (runtime == null)
      throw const VaultMcpException(
        'unsupported',
        '데이터베이스 공통 엔진이 준비되지 않은 연결입니다.',
      );
    if (runtime.deviceId != repo.deviceId)
      throw const VaultMcpException(
        'vault_changed',
        '자동화 엔진의 기기와 연결된 저장소가 다릅니다.',
      );
    requireWrite();
    final eventId = newId();
    final capturedAtUtcMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    var changed = database;
    var receipts = <Map<String, dynamic>>[];
    String? rowId;
    String? templateId;
    switch (action) {
      case 'run_button':
        rowId = _optionalId(args, 'rowId');
        if (rowId != null) _databaseRow(database, rowId);
        final prepared = runtime.prepareManual(
          database,
          ruleId: _id(args, 'ruleId'),
          eventId: eventId,
          rowId: rowId,
          inputRevision: expected,
          capturedAtUtcMs: capturedAtUtcMs,
        );
        changed = prepared.database;
        receipts = prepared.receipts;
      case 'add_row':
        final values = args.containsKey('values')
            ? jsonObject(args['values'])
            : <String, dynamic>{};
        for (final entry in values.entries) {
          final property = _databaseProperty(database, entry.key);
          property.validateValue(entry.value);
        }
        templateId = _optionalId(args, 'templateId');
        final row = templateId == null
            ? DatabaseRow.create(values: values)
            : database.instantiateRowTemplate(
                templateId: templateId,
                rowId: newId(),
                overrides: values,
              );
        rowId = row.id;
        final parentId = _optionalId(args, 'parentTaskId');
        var next = database.addRow(row);
        if (parentId != null) {
          next = runtime.setTaskLinks(
            next,
            rowId: rowId,
            parentId: parentId,
            predecessorIds: const [],
          );
        }
        final prepared = runtime.prepareRowAdded(
          next,
          rowId: row.id,
          inputRevision: expected,
          capturedAtUtcMs: capturedAtUtcMs,
        );
        changed = prepared.database;
        receipts = prepared.receipts;
      case 'create_row_template':
        rowId = _id(args, 'rowId');
        templateId = eventId;
        changed = database.captureRowTemplate(
          rowId: rowId,
          templateId: templateId,
          name: _string(args, 'name', max: 120),
        );
      case 'delete_row_template':
        templateId = _id(args, 'templateId');
        changed = database.removeRowTemplate(templateId);
      case 'set_cell':
        if (!args.containsKey('value'))
          throw const FormatException('Missing cell value');
        rowId = _id(args, 'rowId');
        final row = _databaseRow(database, rowId);
        final property = _databaseProperty(database, _id(args, 'propertyId'));
        final value = args['value'];
        property.validateValue(value);
        if (!const DeepCollectionEquality().equals(
          row.values[property.id],
          value,
        )) {
          final prepared = runtime.preparePropertyChanged(
            database.setCell(rowId, property.id, value),
            eventId: eventId,
            rowId: rowId,
            propertyId: property.id,
            oldValue: row.values[property.id],
            value: value,
            inputRevision: expected,
            capturedAtUtcMs: capturedAtUtcMs,
          );
          changed = prepared.database;
          receipts = prepared.receipts;
        }
      case 'set_task_links':
        rowId = _id(args, 'rowId');
        final rawPredecessors = args['predecessorIds'];
        if (!args.containsKey('parentId') ||
            rawPredecessors is! List ||
            rawPredecessors.length > DatabaseTaskLink.maxPredecessors) {
          throw const FormatException('Expected parent and predecessor IDs');
        }
        final predecessors = <String>[];
        for (final id in rawPredecessors) {
          if (id is! String) throw const FormatException('Expected task ID');
          validateId(id);
          predecessors.add(id);
        }
        changed = runtime.setTaskLinks(
          database,
          rowId: rowId,
          parentId: _optionalId(args, 'parentId'),
          predecessorIds: predecessors,
        );
      case 'put_rule':
        final rule = jsonObject(args['rule']);
        _id(rule, 'id');
        changed = runtime.putRule(database, rule);
      case 'archive_rule':
        changed = runtime.archiveRule(database, _id(args, 'ruleId'));
    }
    final hasChanges = !const DeepCollectionEquality().equals(
      database.toJson(),
      changed.toJson(),
    );
    final snapshot = hasChanges
        ? await prepareDatabaseMediaInWorker(
            changed,
            existingFiles: files,
            addedFiles: const {},
          )
        : null;
    await _expected(repo, note.inkEntityId, expected);
    requireWrite();
    var revisionId = expected;
    if (snapshot != null) {
      final session = NoteSession(repo, note, [head], []);
      try {
        await session.saveInk(
          snapshot.files,
          expectedHeads: {
            note.id: [note.revision.revisionId],
            note.inkEntityId: [expected],
          },
          requireWrite: requireWrite,
        );
      } on StateError {
        throw const VaultMcpException(
          'revision_conflict',
          '문서나 메타데이터가 변경되었습니다. 최신 판본을 읽고 다시 요청하세요.',
        );
      }
      revisionId = session.inkParents.single;
    }
    return {
      'noteId': note.id,
      'revisionId': revisionId,
      'action': action,
      'receipts': receipts,
      'rowId': ?rowId,
      'templateId': ?templateId,
    };
  }

  Future<Object?> _readPageMedia(
    NoteRepository repo,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    _keys(args, {
      'noteId',
      'revisionId',
      'blockId',
      'rowId',
      'mode',
      'offset',
      'limit',
      'maxDimension',
    });
    final noteId = _id(args, 'noteId');
    final revisionId = _id(args, 'revisionId');
    final blockId = _id(args, 'blockId');
    final rowId = args.containsKey('rowId') ? _id(args, 'rowId') : null;
    if (args.containsKey('mode') && args['mode'] is! String) {
      throw const FormatException('Invalid page media mode');
    }
    final mode = args['mode'] as String? ?? 'metadata';
    for (final key in ['offset', 'limit', 'maxDimension']) {
      if (args.containsKey(key) && args[key] is! int) {
        throw const FormatException('Invalid page media read range');
      }
    }
    final allowed = switch (mode) {
      'metadata' => !args.keys.any(
        {'offset', 'limit', 'maxDimension'}.contains,
      ),
      'bytes' => !args.containsKey('maxDimension'),
      'preview' => !args.containsKey('offset') && !args.containsKey('limit'),
      _ => false,
    };
    if (!allowed)
      throw const FormatException('Incompatible page media arguments');
    final offset = _integer(
      args,
      'offset',
      fallback: 0,
      min: 0,
      max: BlockPageMediaAsset.maxAttachmentBytes,
    );
    final limit = _integer(
      args,
      'limit',
      fallback: 64 * 1024,
      min: 1,
      max: 256 * 1024,
    );
    final dimension = _integer(
      args,
      'maxDimension',
      fallback: 1024,
      min: 64,
      max: 2048,
    );
    final note = await _note(repo, noteId);
    final database = note.documentKind == VaultDocumentKind.database;
    if (note.documentKind != VaultDocumentKind.page && !database) {
      throw const VaultMcpException(
        'unsupported',
        '이 도구는 블록 페이지와 데이터베이스 행의 이미지·첨부를 읽습니다.',
      );
    }
    if (database != (rowId != null)) {
      throw const FormatException('Only database media requires a rowId');
    }
    final revisions = (await repo.revisions())
        .where((r) => r.revisionId == revisionId)
        .toList();
    if (revisions.length != 1) {
      throw const VaultMcpException('not_found', '페이지 판본을 찾을 수 없습니다.');
    }
    final revision = revisions.single;
    if (revision.vaultId != repo.vaultId ||
        revision.entityId != note.inkEntityId ||
        revision.kind != EntityKind.ink ||
        revision.deleted ||
        !_owned(revision, note.id)) {
      throw const VaultMcpException(
        'revision_not_owned',
        '이 페이지에 속한 본문 판본이 아닙니다.',
      );
    }
    final bodyBlob = revision.blobs[database ? 'database.json' : 'page.json'];
    if (bodyBlob == null || bodyBlob.length > 1024 * 1024) {
      throw const VaultMcpException(
        'media_integrity_error',
        '페이지 본문을 확인할 수 없습니다.',
      );
    }
    final raw = jsonObject(
      jsonDecode(utf8.decode(await repo.readBlob(bodyBlob.hash))),
    );
    final BlockPageDocument document;
    if (database) {
      final rows = WorkspaceDatabase.fromJson(raw).rows
          .where((row) => row.id == rowId)
          .toList();
      if (rows.isEmpty) {
        throw const VaultMcpException('not_found', '이 판본에서 행을 찾을 수 없습니다.');
      }
      document = BlockPageDocument.fromJson(rows.single.body);
    } else {
      document = BlockPageDocument.fromJson(raw);
    }
    final media = document.media[blockId];
    if (media == null)
      throw const VaultMcpException('not_found', '이 블록에는 등록된 미디어가 없습니다.');
    final blob = revision.blobs[media.path];
    if (blob == null ||
        blob.hash != media.sha256 ||
        blob.length != media.byteLength) {
      throw const VaultMcpException(
        'media_integrity_error',
        '첨부 파일과 페이지 정보가 일치하지 않습니다.',
      );
    }
    final Uint8List bytes;
    try {
      bytes = await repo.readBlob(blob.hash);
      await _verifyPageMedia(revision, media, bytes);
    } on FormatException {
      throw const VaultMcpException(
        'media_integrity_error',
        '첨부 파일의 내용을 확인하지 못했습니다.',
      );
    } on FileSystemException {
      throw const VaultMcpException(
        'media_integrity_error',
        '첨부 파일을 읽지 못했습니다.',
      );
    }
    context.requireActive();
    _requireRepository();
    final result = <String, Object?>{
      'noteId': note.id,
      'revisionId': revision.revisionId,
      'blockId': blockId,
      'rowId': ?rowId,
      'mode': mode,
      'media': media.toJson(),
    };
    if (mode == 'bytes') {
      if (offset > bytes.length)
        throw const FormatException('Page media offset exceeds file length');
      final end = (offset + limit).clamp(offset, bytes.length);
      return {
        ...result,
        'offset': offset,
        'dataBase64': base64Encode(Uint8List.sublistView(bytes, offset, end)),
        'eof': end == bytes.length,
        'nextOffset': end == bytes.length ? null : end,
      };
    }
    if (mode == 'preview') {
      BlockPageBlock? find(List<BlockPageBlock> blocks) {
        for (final block in blocks) {
          if (block.id == blockId) return block;
          final child = find(block.children);
          if (child != null) return child;
        }
        return null;
      }

      if (!media.isImage || find(document.blocks)?.type != 'image') {
        throw const VaultMcpException(
          'unsupported',
          '이 첨부는 이미지 미리보기를 지원하지 않습니다.',
        );
      }
      final preview = await renderBlockPageMediaPreview(bytes, dimension);
      context.requireActive();
      _requireRepository();
      return {
        ...result,
        'width': preview.$2,
        'height': preview.$3,
        'image': {'mimeType': 'image/png', 'data': base64Encode(preview.$1)},
      };
    }
    return result;
  }

  Future<void> _verifyPageMedia(
    RevisionRecord revision,
    BlockPageMedia media,
    Uint8List bytes,
  ) async {
    final key = jsonEncode([
      revision.vaultId,
      revision.revisionId,
      media.path,
      media.sha256,
      media.byteLength,
      media.mimeType,
      media.width,
      media.height,
    ]);
    final pending =
        _pageMediaChecks.remove(key) ??
        (pageMediaVerifier ?? verifyBlockPageMediaBytes)(media, bytes);
    _pageMediaChecks[key] = pending;
    while (_pageMediaChecks.length > 64) {
      _pageMediaChecks.remove(_pageMediaChecks.keys.first);
    }
    try {
      await pending;
    } catch (_) {
      if (identical(_pageMediaChecks[key], pending))
        _pageMediaChecks.remove(key);
      rethrow;
    }
  }

  Object _initialBody(String kind, Object? content) {
    if (kind == 'markdown') {
      if (content == null) return '';
      if (content is! String || content.length > 1024 * 1024)
        throw const FormatException('Invalid Markdown body');
      return content;
    }
    if (kind == 'handwriting') {
      if (content != null)
        throw const FormatException(
          'Handwriting content requires the ink editor',
        );
      return const <String, dynamic>{};
    }
    final raw = content == null
        ? switch (kind) {
            'infinite' => const InfiniteDocument.empty().toJson(),
            'canvas' => const CardCanvasDocument.empty().toJson(),
            'page' => const BlockPageDocument.empty().toJson(),
            'database' => WorkspaceDatabase.empty().toJson(),
            _ => throw const VaultMcpException(
              'unsupported',
              '이 문서는 정확한 형식의 본문이 필요합니다.',
            ),
          }
        : jsonObject(content);
    if (kind == 'database' && raw.containsKey('automationExecutions')) {
      final executions = raw['automationExecutions'];
      if (executions is! List || executions.isNotEmpty)
        throw const FormatException(
          'New database execution receipts must be absent or empty',
        );
    }
    if (kind == 'database' && raw.containsKey('pivTaskLinks')) {
      throw const VaultMcpException(
        'task_links_managed',
        '데이터베이스를 만든 뒤 작업 연결 동작으로 연결을 설정하세요.',
      );
    }
    final validated = _validateBody(kind, raw);
    if (kind == 'page') {
      BlockPageMediaSnapshot.prepare(BlockPageDocument.fromJson(validated));
    } else if (kind == 'database') {
      DatabaseMediaSnapshot.prepare(WorkspaceDatabase.fromJson(validated));
    }
    return validated;
  }

  Map<String, dynamic> _validateBody(String kind, Map<String, dynamic> raw) {
    if (kind == 'database') {
      return WorkspaceDatabase.fromJson(raw).toJson();
    }
    return switch (kind) {
      'infinite' => InfiniteDocument.fromJson(raw).toJson(),
      'canvas' => CardCanvasDocument.fromJson(raw).toJson(),
      'page' => BlockPageDocument.fromJson(raw).toJson(),
      _ when bodyValidators.containsKey(kind) => bodyValidators[kind]!(raw),
      _ => throw const VaultMcpException(
        'unsupported',
        '이 문서 본문의 형식 검증 도구가 준비되지 않았습니다.',
      ),
    };
  }

  Future<VaultNote> _note(NoteRepository repo, String id) async {
    await _head(repo, id);
    final notes = (await WorkspaceStore(repo).list(includeDeleted: true))
        .where((note) => note.id == id)
        .toList();
    if (notes.length != 1)
      throw const VaultMcpException(
        'revision_conflict',
        '여러 문서 판본이 있습니다. 앱에서 판본을 선택하세요.',
      );
    return notes.single;
  }

  Future<void> _assertNoteExists(NoteRepository repo, String id) async {
    if (!(await repo.revisions()).any(
      (r) => r.entityId == id && r.kind == EntityKind.metadata,
    ))
      throw const VaultMcpException('not_found', '문서를 찾을 수 없습니다.');
  }

  Future<RevisionRecord> _head(NoteRepository repo, String entityId) async {
    final heads = await repo.heads(entityId);
    if (heads.isEmpty)
      throw const VaultMcpException('not_found', '저장된 판본을 찾을 수 없습니다.');
    if (heads.length != 1)
      throw const VaultMcpException(
        'revision_conflict',
        '여러 판본이 있습니다. 앱에서 충돌을 확인하세요.',
      );
    return heads.single;
  }

  Future<void> _expected(
    NoteRepository repo,
    String id,
    String expected,
  ) async {
    if ((await _head(repo, id)).revisionId != expected)
      throw const VaultMcpException(
        'revision_conflict',
        '문서가 변경되었습니다. 최신 판본을 읽고 다시 요청하세요.',
      );
  }

  bool _owned(RevisionRecord revision, String noteId) =>
      revision.ownerNoteId == noteId ||
      revision.entityId == noteId && revision.kind == EntityKind.metadata;
  Future<Map<String, dynamic>> _readRevision(
    NoteRepository repo,
    String noteId,
    String revisionId,
  ) async {
    await _assertNoteExists(repo, noteId);
    final revision = (await repo.revisions())
        .where((r) => r.revisionId == revisionId)
        .firstOrNull;
    if (revision == null ||
        revision.vaultId != repo.vaultId ||
        !_owned(revision, noteId))
      throw const VaultMcpException('revision_not_owned', '이 문서에 속한 판본이 아닙니다.');
    return {'noteId': noteId, 'revision': await _revisionData(repo, revision)};
  }

  Future<Map<String, dynamic>> _part(NoteRepository repo, String id) async {
    if ((await repo.heads(id)).isEmpty)
      return {
        'revisionId': null,
        'content': null,
        'files': <String, dynamic>{},
      };
    return _revisionData(repo, await _head(repo, id));
  }

  Map<String, Object?> _record(RevisionRecord revision) => {
    'revisionId': revision.revisionId,
    'entityId': revision.entityId,
    'kind': revision.kind.name,
    'ownerNoteId': revision.ownerNoteId,
    'parentRevisionIds': revision.parentRevisionIds,
    'deleted': revision.deleted,
    'files': {
      for (final entry in revision.blobs.entries)
        entry.key: {'sha256': entry.value.hash, 'length': entry.value.length},
    },
  };
  Future<Map<String, dynamic>> _revisionData(
    NoteRepository repo,
    RevisionRecord revision,
  ) async {
    final result = <String, dynamic>{..._record(revision)};
    final text = <String, Object?>{};
    for (final entry in revision.blobs.entries) {
      if (!_textFiles.contains(entry.key)) continue;
      if (entry.value.length > 1024 * 1024) {
        result['contentUnavailable'] = 'too_large';
        continue;
      }
      final bytes = await repo.readBlob(entry.value.hash);
      final decoded = utf8.decode(bytes);
      text[entry.key] =
          entry.key.endsWith('.json') || entry.key.endsWith('.canvas')
          ? jsonDecode(decoded)
          : decoded;
    }
    if (text.length == 1)
      result['content'] = text.values.single;
    else if (text.isNotEmpty)
      result['contentFiles'] = text;
    return result;
  }

  Map<String, dynamic> _noteData(VaultNote note) => {
    'id': note.id,
    'noteId': note.id,
    'title': note.title,
    'kind': note.documentKind.name,
    'folderId': note.folderId,
    'metadataRevisionId': note.revision.revisionId,
    'trashed': note.trashed,
    'conflict': note.deletionConflict,
  };

  Future<Map<String, Object?>> _readDocxTableStructure(
    NoteRepository repo,
    String noteId,
    Map<String, dynamic> options,
    VaultMcpCallContext context,
  ) async {
    _keys(options, {'tableOffset', 'tableLimit'});
    final offset = options.containsKey('tableOffset')
        ? _integer(options, 'tableOffset', fallback: -1, min: 0, max: 512)
        : 0;
    final limit = options.containsKey('tableLimit')
        ? _integer(options, 'tableLimit', fallback: 0, max: 32)
        : 16;
    final note = await _note(repo, noteId);
    final entity = note.sourceEntityId;
    const wrongFormat = VaultMcpException(
      'unsupported_operation',
      'DOCX 원본이 필요합니다.',
    );
    if (note.documentKind != VaultDocumentKind.office ||
        note.trashed ||
        entity == null) {
      throw wrongFormat;
    }
    final head = await _head(repo, entity);
    if (head.deleted) {
      throw const VaultMcpException('not_found', '저장된 원본을 찾을 수 없습니다.');
    }
    final edition = await OfficeDocumentStore(repo)
        .readLatest(note, revisionId: head.revisionId);
    if (p.extension(edition.originalFileName).toLowerCase() != '.docx') {
      throw wrongFormat;
    }
    if (_engine(edition.originalFileName) == null) {
      throw const VaultMcpException(
        'unsupported_on_platform',
        '현재 연결에서는 DOCX 표 조회를 지원하지 않습니다.',
      );
    }
    final work = await Directory.systemTemp.createTemp(
      'piv-mcp-docx-table-read-',
    );
    try {
      context.requireActive();
      final source = await File(p.join(work.path, 'source.docx'))
          .writeAsBytes(edition.originalBytes, flush: true);
      final plan = await docxTableStructure.inspect(
        sourcePath: source.path,
        sourceSha256: edition.originalSha256,
      );
      if (plan.sourceSha256 != edition.originalSha256) {
        throw _docxTableSourceMismatch;
      }
      final page = plan.tables.skip(offset).take(limit).toList();
      await _expected(repo, entity, head.revisionId);
      await _expected(repo, noteId, note.revision.revisionId);
      context.requireActive();
      return {
        'noteId': noteId,
        'sourceRevisionId': head.revisionId,
        'sourceSha256': edition.originalSha256,
        'tableTotal': plan.tables.length,
        'tableOffset': offset,
        'tableLimit': limit,
        'nextTableOffset': offset + page.length < plan.tables.length
            ? offset + page.length
            : null,
        'tables': [
          for (final table in page)
            {
              'tableIndex': table.tableIndex,
              'rowCount': table.rowCount,
              'columnCount': table.columnCount,
              'preview': table.preview,
              'supportedActions': [
                for (final action in DocxTableStructureAction.values)
                  if (table.allows(action)) action.name,
              ],
            },
        ],
      };
    } on InkVaultNativeException catch (error) {
      throw _docxTableStructureError(error);
    } finally {
      try {
        if (p.isWithin(Directory.systemTemp.path, work.path) &&
            p.basename(work.path).startsWith('piv-mcp-docx-table-read-') &&
            FileSystemEntity.typeSync(work.path, followLinks: false) ==
                FileSystemEntityType.directory) {
          await work.delete(recursive: true);
        }
      } on FileSystemException {
        // A private draft cleanup failure does not change the current source.
      }
    }
  }

  Future<Map<String, Object?>> _readPptxTableStructure(
    NoteRepository repo,
    String noteId,
    Map<String, dynamic> options,
    VaultMcpCallContext context,
  ) async {
    _keys(options, {'slideIndex', 'tableOffset', 'tableLimit'});
    final slideIndex = options.containsKey('slideIndex')
        ? _integer(options, 'slideIndex', fallback: -1, min: 0, max: 255)
        : null;
    if (slideIndex == null && options.isNotEmpty) {
      throw const FormatException('PPTX table pagination requires a slide');
    }
    final offset = options.containsKey('tableOffset')
        ? _integer(options, 'tableOffset', fallback: -1, min: 0, max: 400)
        : 0;
    final limit = options.containsKey('tableLimit')
        ? _integer(options, 'tableLimit', fallback: 0, max: 32)
        : 16;
    final note = await _note(repo, noteId);
    final entity = note.sourceEntityId;
    if (note.documentKind != VaultDocumentKind.office ||
        note.trashed ||
        entity == null) {
      throw const VaultMcpException('unsupported_operation', 'PPTX 원본이 필요합니다.');
    }
    final head = await _head(repo, entity);
    if (head.deleted) {
      throw const VaultMcpException('not_found', '저장된 원본을 찾을 수 없습니다.');
    }
    final edition = await OfficeDocumentStore(repo)
        .readLatest(note, revisionId: head.revisionId);
    if (p.extension(edition.originalFileName).toLowerCase() != '.pptx') {
      throw const VaultMcpException('unsupported_operation', 'PPTX 원본이 필요합니다.');
    }
    if (_engine(edition.originalFileName) == null) {
      throw const VaultMcpException(
        'unsupported_on_platform',
        '현재 연결에서는 PPTX 표 조회를 지원하지 않습니다.',
      );
    }
    final work = await Directory.systemTemp.createTemp(
      'piv-mcp-pptx-table-read-',
    );
    try {
      final source = await File(p.join(work.path, 'source.pptx'))
          .writeAsBytes(edition.originalBytes, flush: true);
      final plan = await pptxTableStructure.inspect(
        sourcePath: source.path,
        sourceSha256: edition.originalSha256,
      );
      if (plan.sourceSha256 != edition.originalSha256) {
        throw const VaultMcpException(
          'office_source_mismatch',
          '조회한 원본과 현재 판본이 일치하지 않습니다.',
        );
      }
      final result = <String, Object?>{
        'noteId': noteId,
        'sourceRevisionId': head.revisionId,
        'sourceSha256': edition.originalSha256,
        'slideCount': plan.slideCount,
      };
      if (slideIndex == null) {
        result['slides'] = [
          for (final slide in plan.slides)
            {
              'index': slide.index,
              'hidden': slide.hidden,
              'title': slide.title,
            },
        ];
      } else {
        if (slideIndex >= plan.slideCount) {
          throw const VaultMcpException(
            'invalid_arguments',
            '조회할 슬라이드를 확인하세요.',
          );
        }
        final tables = await pptxTableStructure.inspectSlide(
          sourcePath: source.path,
          plan: plan,
          slideIndex: slideIndex,
        );
        final page = tables.skip(offset).take(limit).toList();
        result.addAll({
          'slideIndex': slideIndex,
          'tableOffset': offset,
          'tableLimit': limit,
          'nextTableOffset': offset + page.length < tables.length
              ? offset + page.length
              : null,
          'tables': [
            for (final table in page)
              {
                'shapeId': table.shapeId,
                'name': table.name,
                'rows': table.rows,
                'columns': table.columns,
                'positions': {
                  for (final action in PptxTableStructureAction.values)
                    action.name: table.positions(action),
                },
              },
          ],
        });
      }
      await _expected(repo, entity, head.revisionId);
      await _expected(repo, noteId, note.revision.revisionId);
      context.requireActive();
      return result;
    } on InkVaultNativeException catch (error) {
      throw _pptxTableStructureError(error);
    } finally {
      try {
        if (FileSystemEntity.typeSync(work.path, followLinks: false) ==
            FileSystemEntityType.directory) {
          await work.delete(recursive: true);
        }
      } on FileSystemException {
        // A private draft cleanup failure does not change the current source.
      }
    }
  }

  Future<Map<String, Object?>> _readPptxSlideOrder(
    NoteRepository repo,
    String noteId,
    VaultMcpCallContext context,
  ) async {
    const unsupported = VaultMcpException(
      'unsupported_operation',
      '슬라이드 순서 조회에는 PPTX 원본이 필요합니다.',
    );
    final note = await _note(repo, noteId);
    final entity = note.sourceEntityId;
    if (note.documentKind != VaultDocumentKind.office ||
        note.trashed ||
        entity == null) {
      throw unsupported;
    }
    final head = await _head(repo, entity);
    if (head.deleted) {
      throw const VaultMcpException('not_found', '저장된 원본을 찾을 수 없습니다.');
    }
    final edition = await OfficeDocumentStore(repo)
        .readLatest(note, revisionId: head.revisionId);
    if (p.extension(edition.originalFileName).toLowerCase() != '.pptx') {
      throw unsupported;
    }
    final work = await Directory.systemTemp.createTemp('piv-mcp-pptx-order-');
    try {
      final source = await File(p.join(work.path, 'source.pptx'))
          .writeAsBytes(edition.originalBytes, flush: true);
      final plan = await _inspectPptxSlideOrder(source, edition.originalSha256);
      await _expected(repo, entity, head.revisionId);
      await _expected(repo, noteId, note.revision.revisionId);
      context.requireActive();
      return {
        'noteId': noteId,
        'sourceRevisionId': head.revisionId,
        'sourceSha256': edition.originalSha256,
        'slideCount': plan.slideCount,
        'slides': [
          for (final slide in plan.slides)
            {
              'index': slide.index,
              'hidden': slide.hidden,
              'title': ?slide.title,
              'sectionTitle': ?slide.sectionTitle,
              'sectionGroup': ?slide.sectionGroup,
            },
        ],
      };
    } on InkVaultNativeException catch (error) {
      throw _pptxSlideOrderError(error);
    } finally {
      try {
        if (p.isWithin(Directory.systemTemp.path, work.path) &&
            p.basename(work.path).startsWith('piv-mcp-pptx-order-') &&
            FileSystemEntity.typeSync(work.path, followLinks: false) ==
                FileSystemEntityType.directory) {
          await work.delete(recursive: true);
        }
      } on FileSystemException {
        // A private inspection copy does not affect the saved source.
      }
    }
  }

  Future<PptxSlideReorderPlan> _inspectPptxSlideOrder(
    File source,
    String sourceSha256,
  ) async {
    if ((await sha256.bind(source.openRead()).first).toString() !=
        sourceSha256) {
      throw _pptxSlideSourceMismatch;
    }
    final plan = await pptxSlideReorder.inspect(
      sourcePath: source.path,
      sourceSha256: sourceSha256,
    );
    if (plan.sourceSha256 != sourceSha256 ||
        (await sha256.bind(source.openRead()).first).toString() !=
            sourceSha256) {
      throw _pptxSlideSourceMismatch;
    }
    return plan;
  }

  Future<Map<String, dynamic>> _inspectOffice(
    NoteRepository repo,
    VaultNote note,
  ) async {
    final documents = OfficeDocumentStore(repo);
    final edition = await documents.readLatest(note);
    final engine = _engine(edition.originalFileName);
    if (engine == null || !await engine.available)
      return {'available': false, 'reason': 'unsupported_on_platform'};
    final work = await Directory.systemTemp.createTemp('piv-mcp-office-read-');
    try {
      final source = await File(p.join(work.path, edition.originalFileName))
          .writeAsBytes(edition.originalBytes, flush: true);
      final snapshot = await engine.inspect(source.path);
      if (snapshot.sourceSha256 != edition.originalSha256)
        throw const VaultMcpException(
          'office_source_mismatch',
          '검사한 원본 판본이 일치하지 않습니다.',
        );
      final variants = await documents.readPdfVariants(note, edition);
      return {
        'available': true,
        'sourceRevisionId': edition.revision.revisionId,
        'pdfVariantCount': variants.length,
        'pdfVariants': [
          for (final variant in variants.take(100))
            {
              'revisionId': variant.revision.revisionId,
              'bindingId': variant.bindingId,
              'pdfSha256': variant.pdfSha256,
              if (variant.pageCount != null) 'pageCount': variant.pageCount,
            },
        ],
        ..._snapshot(snapshot),
      };
    } on WindowsOfficeException catch (error) {
      final diagnostics = error.safeDiagnostics;
      return {
        'available': false,
        'reason': error.code,
        'diagnostics': ?diagnostics,
      };
    } finally {
      if (p.isWithin(Directory.systemTemp.path, work.path) &&
          p.basename(work.path).startsWith('piv-mcp-office-read-'))
        await work.delete(recursive: true);
    }
  }

  WindowsOfficeEngine? _engine(String fileName) {
    final extension = p.extension(fileName).toLowerCase();
    if (extension == '.hwp' || extension == '.hwpx')
      return hwpEngine ?? HwpStructuredOfficeEngine();
    return officeEngine ?? (Platform.isWindows ? WindowsOfficeEngine() : null);
  }

  Future<Object?> _officeAsset(
    NoteRepository repo,
    Map<String, dynamic> args,
    VaultMcpCallContext context,
  ) async {
    final action = _string(args, 'action', max: 10);
    final extraKeys = switch (action) {
      'begin' => {'mimeType', 'byteLength', 'sha256'},
      'append' => {'assetId', 'offset', 'base64Data'},
      'seal' || 'status' || 'discard' => {'assetId'},
      _ => throw const FormatException('Unknown image upload action'),
    };
    _keys(args, {
      'action',
      'noteId',
      'expectedRevisionId',
      'requestId',
      ...extraKeys,
    });
    final note = await _note(repo, _id(args, 'noteId'));
    if (note.documentKind != VaultDocumentKind.office ||
        note.sourceEntityId == null)
      throw const VaultMcpException(
        'unsupported',
        'Office 문서의 이미지만 준비할 수 있습니다.',
      );
    final expected = _id(args, 'expectedRevisionId');
    final assetId = action == 'begin'
        ? _id(args, 'requestId')
        : _id(args, 'assetId');
    final store = OfficeAssetStore(repo);
    Future<void> requireWrite() async {
      _requireCurrent(repo, controller.repository, context);
      if (action != 'status' && action != 'discard') {
        final current = await _note(repo, note.id);
        if (current.trashed || current.sourceEntityId != note.sourceEntityId)
          throw const VaultMcpException('not_found', 'Office 문서가 변경되었습니다.');
        await _expected(repo, note.sourceEntityId!, expected);
        _requireCurrent(repo, controller.repository, context);
      }
    }

    await requireWrite();
    return switch (action) {
      'begin' => store.begin(
        assetId: assetId,
        noteId: note.id,
        sourceRevisionId: expected,
        mimeType: _string(args, 'mimeType', max: 30),
        sha256: _string(args, 'sha256', max: 64),
        byteLength: _integer(
          args,
          'byteLength',
          fallback: -1,
          min: 1,
          max: WindowsOfficeImageAsset.maxBytes,
        ),
        requireWrite: requireWrite,
      ),
      'append' => store.append(
        assetId: assetId,
        noteId: note.id,
        sourceRevisionId: expected,
        offset: _integer(
          args,
          'offset',
          fallback: -1,
          min: 0,
          max: WindowsOfficeImageAsset.maxBytes,
        ),
        base64Data: _string(args, 'base64Data', max: 175000),
        requireWrite: requireWrite,
      ),
      'seal' => store.seal(
        assetId: assetId,
        noteId: note.id,
        sourceRevisionId: expected,
        requireWrite: requireWrite,
      ),
      'status' => store.status(
        assetId: assetId,
        noteId: note.id,
        sourceRevisionId: expected,
      ),
      'discard' => store.discard(
        assetId: assetId,
        noteId: note.id,
        sourceRevisionId: expected,
        requireWrite: requireWrite,
      ),
      _ => throw const FormatException('Unknown image upload action'),
    };
  }

  Future<
    ({
      OfficePreparedEdition plan,
      OfficeEditSession session,
      List<Map<String, Object?>> assets,
    })
  >
  _prepareOfficeEdit(
    NoteRepository repo,
    Map<String, dynamic> args,
    List<WindowsOfficeOperation> operations,
    VaultMcpCallContext context, {
    required void Function() beforePublish,
  }) async {
    final note = await _note(repo, _id(args, 'noteId'));
    if (note.documentKind != VaultDocumentKind.office ||
        note.sourceEntityId == null ||
        note.trashed)
      throw const VaultMcpException('unsupported', '편집할 Office 원본을 찾을 수 없습니다.');
    final expected = _id(args, 'expectedRevisionId');
    await _expected(repo, note.sourceEntityId!, expected);
    final assetIds = <String>{
      for (final operation in operations)
        if (operation.toJson()['assetId'] case final String id) id,
    };
    final assetStore = OfficeAssetStore(repo);
    final images = <String, WindowsOfficeImageAsset>{};
    for (final id in assetIds) {
      images[id] = await assetStore.readSealed(
        assetId: id,
        noteId: note.id,
        sourceRevisionId: expected,
      );
    }
    final store = OfficeDocumentStore(repo),
        session = await OfficeDocumentStore(repo)
            .beginEdit(note, revisionId: expected);
    final soleOperation = operations.length == 1
        ? operations.single.toJson()['op']
        : null;
    final editsPptxTable = soleOperation == 'presentationTableStructureEdit';
    final movesPptxSection = soleOperation == 'pptxSlideSectionMove';
    final editsDocxTable = soleOperation == 'docxTableStructureEdit';
    final extension = p.extension(session.originalFileName).toLowerCase();
    if (soleOperation == 'tableInsert' && extension != '.hwpx') {
      throw const VaultMcpException(
        'unsupported_operation',
        '표 추가는 HWPX 문서에서만 지원합니다.',
      );
    }
    if (soleOperation == 'tableStructure' &&
        extension != '.hwpx' &&
        (extension != '.hwp' ||
            !const {
              'insertRow',
              'deleteRow',
            }.contains(operations.single.toJson()['action']))) {
      throw const VaultMcpException(
        'unsupported_operation',
        '한글 표의 행은 HWP5와 HWPX에서, 열은 HWPX에서 편집할 수 있습니다.',
      );
    }
    if (soleOperation == 'slideDuplicate' && extension != '.pptx') {
      throw const VaultMcpException(
        'unsupported_operation',
        '슬라이드 복제는 PPTX 문서에서만 지원합니다.',
      );
    }
    if (editsPptxTable && extension != '.pptx') {
      throw const VaultMcpException(
        'unsupported_operation',
        '표 행·열 편집에는 PPTX 원본이 필요합니다.',
      );
    }
    if (movesPptxSection && extension != '.pptx') {
      throw const VaultMcpException(
        'unsupported_operation',
        '슬라이드 구역 이동에는 PPTX 원본이 필요합니다.',
      );
    }
    if (editsDocxTable && extension != '.docx') {
      throw const VaultMcpException(
        'unsupported_operation',
        'Word 표 행·열 편집에는 DOCX 원본이 필요합니다.',
      );
    }
    final expectedSourceSha256 = sha256
        .convert(session.originalBytes)
        .toString();
    for (final operation in operations) {
      final value = operation.toJson();
      if (value['op'] == 'presentationCellTextPatch' &&
          value['expectedSourceSha256'] != expectedSourceSha256) {
        throw const VaultMcpException(
          'office_source_mismatch',
          'Source text patch guards do not match this captured edition.',
        );
      }
      if (value['op'] == 'presentationSourceTableAdd' &&
          value['expectedSourceSha256'] != expectedSourceSha256) {
        throw const VaultMcpException(
          'office_source_mismatch',
          'Source table creation guards do not match this captured edition.',
        );
      }
      if (editsPptxTable &&
          value['expectedSourceSha256'] != expectedSourceSha256) {
        throw const VaultMcpException(
          'office_source_mismatch',
          '조회한 PPTX 원본 해시와 현재 판본이 일치하지 않습니다.',
        );
      }
      if (movesPptxSection &&
          value['expectedSourceSha256'] != expectedSourceSha256) {
        throw _pptxSlideSourceMismatch;
      }
      if (editsDocxTable &&
          value['expectedSourceSha256'] != expectedSourceSha256) {
        throw _docxTableSourceMismatch;
      }
    }
    final engine = _engine(session.originalFileName);
    if (engine == null || !await engine.available)
      throw const VaultMcpException(
        'unsupported_on_platform',
        '현재 연결에서는 이 원본의 자동 편집을 지원하지 않습니다.',
      );
    final work = await Directory.systemTemp.createTemp('piv-mcp-office-edit-');
    try {
      final source = await File(
        p.join(work.path, switch (soleOperation) {
          'presentationTableStructureEdit' ||
          'pptxSlideSectionMove' => 'source.pptx',
          'docxTableStructureEdit' => 'source.docx',
          _ => session.originalFileName,
        }),
      ).writeAsBytes(session.originalBytes, flush: true);
      context.requireActive(write: true);
      late final Uint8List original, pdf;
      late final String engineVersion;
      late final int pageCount;
      final sessionId = args['requestId'] as String;
      Future<void> requireCurrent() async {
        await _expected(repo, session.sourceEntityId, expected);
        await _expected(repo, note.id, note.revision.revisionId);
        context.requireActive(write: true);
      }

      if (editsPptxTable) {
        (
          original,
          pdf,
          engineVersion,
          pageCount,
        ) = await _applyPptxTableStructure(
          source,
          engine,
          sessionId,
          expectedSourceSha256,
          operations.single.toJson(),
          context,
        );
      } else if (movesPptxSection) {
        (
          original,
          pdf,
          engineVersion,
          pageCount,
        ) = await _applyPptxSlideSectionMove(
          source,
          engine,
          sessionId,
          expectedSourceSha256,
          operations.single.toJson(),
          requireCurrent,
          context,
        );
      } else if (editsDocxTable) {
        (
          original,
          pdf,
          engineVersion,
          pageCount,
        ) = await _applyDocxTableStructure(
          source,
          engine,
          sessionId,
          expectedSourceSha256,
          operations.single.toJson(),
          requireCurrent,
        );
      } else {
        final result = await engine.apply(
          source.path,
          operations: operations,
          sessionId: sessionId,
          expectedSourceSha256: expectedSourceSha256,
          imageAssets: images,
        );
        original = await File(result.sourcePath).readAsBytes();
        pdf = await File(result.pdfPath).readAsBytes();
        if (sha256.convert(original).toString() != result.sourceSha256 ||
            sha256.convert(pdf).toString() != result.pdfSha256) {
          throw const VaultMcpException(
            'office_payload_mismatch',
            '편집 결과와 원본의 바이트를 확인하지 못했습니다.',
          );
        }
        engineVersion = result.engineVersion;
        pageCount = result.pdfPageCount;
      }
      if ((await sha256.bind(source.openRead()).first).toString() !=
          expectedSourceSha256) {
        throw const VaultMcpException(
          'office_payload_mismatch',
          '편집 결과와 원본의 바이트를 확인하지 못했습니다.',
        );
      }
      context.requireActive(write: true);
      await _expected(repo, note.sourceEntityId!, expected);
      final prepared = store.prepareEdited(
        session,
        originalBytes: original,
        pdfBytes: pdf,
        engineVersion: engineVersion,
        pageCount: pageCount,
        requireCurrentHeads: true,
        beforePublish: beforePublish,
      );
      final sortedAssets = images.keys.toList()..sort();
      return (
        plan: prepared,
        session: session,
        assets: [
          for (final id in sortedAssets)
            {
              'assetId': id,
              'sha256': images[id]!.sha256,
              'byteLength': images[id]!.byteLength,
              'mimeType': images[id]!.mimeType,
              'width': images[id]!.width,
              'height': images[id]!.height,
            },
        ],
      );
    } finally {
      try {
        if (p.isWithin(Directory.systemTemp.path, work.path) &&
            p.basename(work.path).startsWith('piv-mcp-office-edit-') &&
            FileSystemEntity.typeSync(work.path, followLinks: false) ==
                FileSystemEntityType.directory)
          await work.delete(recursive: true);
      } catch (_) {
        // The immutable source and prepared bytes do not depend on this input copy.
      }
    }
  }

  Future<(Uint8List, Uint8List, String, int)> _applyDocxTableStructure(
    File source,
    WindowsOfficeEngine renderer,
    String sessionId,
    String expectedSourceSha256,
    Map<String, Object?> operation,
    Future<void> Function() requireCurrent,
  ) async {
    final tableIndex = operation['tableIndex'] as int;
    final action = DocxTableStructureAction.values.byName(
      operation['action'] as String,
    );
    final index = operation['index'] as int;
    final anchorIndex = operation['anchorIndex'] as int?;
    final output = File(p.join(source.parent.path, 'edited.docx'));
    const invalidOutput = VaultMcpException(
      'office_payload_mismatch',
      '편집한 DOCX와 PDF를 확인하지 못했습니다.',
    );
    OfficePreviewResult? preview;
    try {
      final plan = await docxTableStructure.inspect(
        sourcePath: source.path,
        sourceSha256: expectedSourceSha256,
      );
      if (plan.sourceSha256 != expectedSourceSha256) {
        throw _docxTableSourceMismatch;
      }
      final table = plan.tables
          .where((table) => table.tableIndex == tableIndex)
          .singleOrNull;
      if (table == null ||
          !table.allowsPosition(action, index, anchorIndex: anchorIndex)) {
        throw const VaultMcpException(
          'invalid_arguments',
          '현재 DOCX 표에서 편집할 행·열과 기준 위치를 다시 조회하세요.',
        );
      }
      await requireCurrent();
      final edited = await docxTableStructure.edit(
        sourcePath: source.path,
        plan: plan,
        outputPath: output.path,
        tableIndex: tableIndex,
        action: action,
        index: index,
        anchorIndex: anchorIndex,
      );
      if (edited.sourceSha256 != expectedSourceSha256 ||
          edited.outputSha256 == expectedSourceSha256 ||
          edited.tableIndex != tableIndex ||
          edited.rowCount != table.rowCount + action.rowDelta ||
          edited.columnCount != table.columnCount + action.columnDelta ||
          FileSystemEntity.typeSync(output.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await output.length() > 128 * 1024 * 1024 ||
          (await sha256.bind(output.openRead()).first).toString() !=
              edited.outputSha256) {
        throw invalidOutput;
      }
      await requireCurrent();
      preview = await OfficePreviewEngine(
        windowsEngine: renderer,
        isWindows: true,
      ).preview(sourcePath: output.path, sessionId: sessionId);
      if (preview == null || preview.sourceSha256 != edited.outputSha256) {
        throw invalidOutput;
      }
      await requireCurrent();
      final original = await output.readAsBytes();
      final pdf = await File(preview.pdfPath).readAsBytes();
      if (sha256.convert(original).toString() != edited.outputSha256 ||
          sha256.convert(pdf).toString() != preview.pdfSha256) {
        throw invalidOutput;
      }
      return (original, pdf, preview.engineVersion, preview.pageCount);
    } on InkVaultNativeException catch (error) {
      throw _docxTableStructureError(error);
    } on PlatformException catch (error) {
      if (error.code == 'office_unavailable') {
        throw const VaultMcpException(
          'unsupported_on_platform',
          '문서 미리보기 엔진이 준비되지 않았습니다.',
        );
      }
      throw invalidOutput;
    } finally {
      await preview?.dispose();
    }
  }

  Future<(Uint8List, Uint8List, String, int)> _applyPptxSlideSectionMove(
    File source,
    WindowsOfficeEngine renderer,
    String sessionId,
    String expectedSourceSha256,
    Map<String, Object?> operation,
    Future<void> Function() requireCurrent,
    VaultMcpCallContext context,
  ) async {
    final sourceIndex = operation['sourceIndex'] as int;
    final targetIndex = operation['targetIndex'] as int;
    final after = operation['after'] as bool;
    final output = File(p.join(source.parent.path, 'edited.pptx'));
    try {
      final plan = await _inspectPptxSlideOrder(source, expectedSourceSha256);
      if (!plan.canMove(sourceIndex, targetIndex, after: after)) {
        throw const VaultMcpException(
          'invalid_arguments',
          '현재 PPTX에서 순서를 유지하며 이동할 수 있는 구역을 다시 조회하세요.',
        );
      }
      await requireCurrent();
      final edited = await pptxSlideReorder.move(
        sourcePath: source.path,
        plan: plan,
        outputPath: output.path,
        sourceIndex: sourceIndex,
        targetIndex: targetIndex,
        after: after,
      );
      if (edited.sourceSha256 != expectedSourceSha256 ||
          edited.sourceIndex != sourceIndex ||
          edited.destinationIndex != sourceIndex ||
          edited.slideCount != plan.slideCount) {
        throw const VaultMcpException(
          'office_payload_mismatch',
          '구역을 이동한 PPTX의 판본과 슬라이드 위치를 확인하지 못했습니다.',
        );
      }
      await requireCurrent();
      return await _previewEditedPptx(
        output,
        renderer,
        sessionId,
        expectedSourceSha256,
        edited.outputSha256,
        plan.slideCount,
        context,
      );
    } on InkVaultNativeException catch (error) {
      throw _pptxSlideOrderError(error);
    } on PlatformException catch (error) {
      throw _pptxPreviewError(error);
    }
  }

  Future<(Uint8List, Uint8List, String, int)> _applyPptxTableStructure(
    File source,
    WindowsOfficeEngine renderer,
    String sessionId,
    String expectedSourceSha256,
    Map<String, Object?> operation,
    VaultMcpCallContext context,
  ) async {
    final slideIndex = operation['slideIndex'] as int;
    final shapeId = operation['shapeId'] as int;
    final action = PptxTableStructureAction.values.byName(
      operation['action'] as String,
    );
    final index = operation['index'] as int;
    final output = File(p.join(source.parent.path, 'edited.pptx'));
    try {
      final plan = await pptxTableStructure.inspect(
        sourcePath: source.path,
        sourceSha256: expectedSourceSha256,
      );
      if (plan.sourceSha256 != expectedSourceSha256) {
        throw const VaultMcpException(
          'office_source_mismatch',
          '조회한 PPTX 원본 해시와 현재 판본이 일치하지 않습니다.',
        );
      }
      if (slideIndex >= plan.slideCount) {
        throw const VaultMcpException(
          'invalid_arguments',
          '편집할 슬라이드를 다시 조회하세요.',
        );
      }
      final tables = await pptxTableStructure.inspectSlide(
        sourcePath: source.path,
        plan: plan,
        slideIndex: slideIndex,
      );
      final table = tables
          .where((table) => table.shapeId == shapeId)
          .singleOrNull;
      if (table == null || !table.allows(action, index)) {
        throw const VaultMcpException(
          'invalid_arguments',
          '현재 표에서 허용되는 행·열과 위치를 다시 조회하세요.',
        );
      }
      context.requireActive(write: true);
      final edited = await pptxTableStructure.edit(
        sourcePath: source.path,
        plan: plan,
        outputPath: output.path,
        slideIndex: slideIndex,
        table: table,
        action: action,
        index: index,
      );
      return await _previewEditedPptx(
        output,
        renderer,
        sessionId,
        expectedSourceSha256,
        edited.outputSha256,
        plan.slideCount,
        context,
      );
    } on InkVaultNativeException catch (error) {
      throw _pptxTableStructureError(error);
    } on PlatformException catch (error) {
      throw _pptxPreviewError(error);
    }
  }

  Future<(Uint8List, Uint8List, String, int)> _previewEditedPptx(
    File output,
    WindowsOfficeEngine renderer,
    String sessionId,
    String sourceSha256,
    String outputSha256,
    int slideCount,
    VaultMcpCallContext context,
  ) async {
    OfficePreviewResult? preview;
    try {
      if (outputSha256 == sourceSha256 ||
          FileSystemEntity.typeSync(output.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await output.length() > 128 * 1024 * 1024 ||
          (await sha256.bind(output.openRead()).first).toString() !=
              outputSha256) {
        throw const VaultMcpException(
          'office_payload_mismatch',
          '편집한 PPTX의 바이트를 확인하지 못했습니다.',
        );
      }
      context.requireActive(write: true);
      preview = await OfficePreviewEngine(
        windowsEngine: renderer,
        isWindows: true,
      ).preview(sourcePath: output.path, sessionId: sessionId);
      if (preview == null ||
          preview.sourceSha256 != outputSha256 ||
          preview.pageCount != slideCount) {
        throw const VaultMcpException(
          'office_payload_mismatch',
          '편집한 PPTX와 PDF 쪽 수를 확인하지 못했습니다.',
        );
      }
      final original = await output.readAsBytes();
      final pdf = await File(preview.pdfPath).readAsBytes();
      if (sha256.convert(original).toString() != outputSha256 ||
          sha256.convert(pdf).toString() != preview.pdfSha256) {
        throw const VaultMcpException(
          'office_payload_mismatch',
          '편집한 PPTX와 PDF 바이트를 확인하지 못했습니다.',
        );
      }
      return (original, pdf, preview.engineVersion, preview.pageCount);
    } finally {
      await preview?.dispose();
    }
  }
}

const _pptxSlideSourceMismatch = VaultMcpException(
  'office_source_mismatch',
  '조회한 PPTX 원본 해시와 현재 판본이 일치하지 않습니다.',
);

VaultMcpException _pptxPreviewError(PlatformException error) =>
    error.code == 'office_unavailable'
    ? const VaultMcpException(
        'unsupported_on_platform',
        '문서 미리보기 엔진이 준비되지 않았습니다.',
      )
    : const VaultMcpException(
        'office_payload_mismatch',
        '편집한 PPTX와 PDF를 다시 열지 못했습니다.',
      );

VaultMcpException _pptxSlideOrderError(InkVaultNativeException error) =>
    switch (error.code) {
      'library_unavailable' || 'unknown_operation' => const VaultMcpException(
        'unsupported_on_platform',
        'PPTX 슬라이드 엔진이 준비되지 않았습니다.',
      ),
      'source_changed' => _pptxSlideSourceMismatch,
      'invalid_pptx' || 'unsupported_document' => const VaultMcpException(
        'unsupported_operation',
        '이 PPTX에서는 슬라이드 순서와 구역을 안전하게 확인할 수 없습니다.',
      ),
      'invalid_request' => const VaultMcpException(
        'invalid_arguments',
        '현재 PPTX에서 이동할 슬라이드와 대상 구역을 확인하세요.',
      ),
      _ => const VaultMcpException(
        'office_payload_mismatch',
        'PPTX 슬라이드 목록과 편집 결과를 확인하지 못했습니다.',
      ),
    };

const _docxTableSourceMismatch = VaultMcpException(
  'office_source_mismatch',
  '조회한 DOCX 원본 해시와 현재 판본이 일치하지 않습니다.',
);

VaultMcpException _docxTableStructureError(InkVaultNativeException error) =>
    switch (error.code) {
      'library_unavailable' || 'unknown_operation' => const VaultMcpException(
        'unsupported_on_platform',
        'DOCX 표 편집 엔진이 준비되지 않았습니다.',
      ),
      'source_changed' => _docxTableSourceMismatch,
      'unsupported_document' => const VaultMcpException(
        'unsupported_operation',
        '현재 형식의 DOCX 표는 편집할 수 없습니다.',
      ),
      _ => const VaultMcpException(
        'office_payload_mismatch',
        'DOCX 표와 편집 결과를 확인하지 못했습니다.',
      ),
    };

VaultMcpException _pptxTableStructureError(InkVaultNativeException error) =>
    switch (error.code) {
      'library_unavailable' || 'unknown_operation' => const VaultMcpException(
        'unsupported_on_platform',
        'PPTX 표 편집 엔진이 준비되지 않았습니다.',
      ),
      'source_changed' => const VaultMcpException(
        'office_source_mismatch',
        '작업 PPTX와 조회한 원본 해시가 일치하지 않습니다.',
      ),
      _ => const VaultMcpException(
        'office_payload_mismatch',
        'PPTX 표와 편집 결과를 확인하지 못했습니다.',
      ),
    };

List<WindowsOfficeOperation> _officeOperations(Map<String, dynamic> args) {
  final raw = args['operations'];
  if (raw is! List || raw.isEmpty || raw.length > 128)
    throw const FormatException('Expected bounded Office operations');
  final operations = [
    for (final operation in raw) _officeOperation(jsonObject(operation)),
  ];
  if (operations.length != 1 &&
      operations.any(
        (value) => switch (value.toJson()['op']) {
          'tableInsert' || 'tableStructure' => true,
          _ => false,
        },
      )) {
    throw const FormatException(
      'HWPX table creation and structure editing require a single operation',
    );
  }
  if (operations.length != 1 &&
      operations.any((value) => value.toJson()['op'] == 'slideDuplicate')) {
    throw const FormatException(
      'PPTX slide duplication requires a single operation',
    );
  }
  if (operations.length != 1 &&
      operations.any(
        (value) => value.toJson()['op'] == 'pptxSlideSectionMove',
      )) {
    throw const FormatException(
      'PPTX slide section moves require a single operation',
    );
  }
  if (operations.length != 1 &&
      operations.any(
        (value) => value.toJson()['op'] == 'docxTableStructureEdit',
      )) {
    throw const FormatException(
      'DOCX table structure editing requires a single operation',
    );
  }
  if (operations.length != 1 &&
      operations.any(
        (value) => value.toJson()['op'] == 'presentationTableStructureEdit',
      )) {
    throw const FormatException(
      'PPTX table structure editing requires a single operation',
    );
  }
  final sourceCount = operations
      .where((value) => value.toJson()['op'] == 'presentationCellTextPatch')
      .length;
  if (sourceCount != 0 &&
      (operations.length > 100 || sourceCount != operations.length)) {
    throw const FormatException(
      'Source text patches require a source-only batch of at most 100 operations',
    );
  }
  final structure = operations
      .where(
        (operation) => operation.toJson()['op'] == 'presentationSourceTableAdd',
      )
      .toList();
  if (structure.isNotEmpty) {
    if (structure.length != operations.length || structure.length > 100) {
      throw const FormatException(
        'Source table creation requires a source-only batch of at most 100 operations',
      );
    }
    final aliases = <String>{};
    if (structure.any(
      (operation) => !aliases.add(operation.toJson()['id'] as String),
    )) {
      throw const FormatException(
        'Source table creation aliases must be unique',
      );
    }
  }
  return operations;
}

Map<String, Object?> _officeEditionResult(
  String noteId,
  OfficeEdition edition,
) => {
  'noteId': noteId,
  'sourceEntityId': edition.revision.entityId,
  'revisionId': edition.revision.revisionId,
  'bindingId': edition.bindingId,
  'sourceSha256': edition.originalSha256,
  'pdfSha256': edition.pdfSha256,
  'pageCount': edition.pageCount,
  'engineVersion': edition.engineVersion,
};

String _pathReceiptDigest(Map<String, dynamic> receipt) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _canonical({
            for (final entry in receipt.entries)
              if (!{'state', 'result', 'planDigest'}.contains(entry.key))
                entry.key: entry.value,
          }),
        ),
      ),
    )
    .toString();

List<String> _pathRevisionIds(Object? raw) {
  if (raw is! List || raw.length > 100000 || raw.any((id) => id is! String))
    throw const FormatException('Invalid captured revision identities');
  final ids = raw.cast<String>();
  for (final id in ids) validateId(id);
  if (ids.toSet().length != ids.length)
    throw const FormatException('Duplicate captured revision identity');
  return ids;
}

Directory _pathPrivateDirectory(
  NoteRepository repo,
  List<String> parts, {
  required bool create,
}) {
  var directory = repo.root;
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
      FileSystemEntityType.directory)
    throw const FormatException(
      'The document action root must remain an owned directory',
    );
  for (final part in parts) {
    directory = Directory(p.join(directory.path, part));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      directory.createSync();
    } else if (type != FileSystemEntityType.directory) {
      throw const FormatException(
        'Missing or unsafe document action directory',
      );
    }
  }
  return directory;
}

Map<String, dynamic> _pathFileManifest(Map<String, Uint8List> files) => {
  for (final entry in files.entries)
    entry.key: {
      'sha256': sha256.convert(entry.value).toString(),
      'byteLength': entry.value.length,
    },
};

List<Map<String, dynamic>> _pathFileManifests(Object? raw) {
  if (raw is! List || raw.length > 10000)
    throw const FormatException('Too many document action steps');
  var totalBytes = 0;
  var totalFiles = 0;
  final result = <Map<String, dynamic>>[];
  for (final value in raw) {
    final files = jsonObject(value);
    if (files.isEmpty || files.length > 1024)
      throw const FormatException('Invalid document action file count');
    totalFiles += files.length;
    if (totalFiles > 10000)
      throw const FormatException('Too many document action files');
    for (final entry in files.entries) {
      validateLogicalPath(entry.key);
      final metadata = jsonObject(entry.value);
      _keys(metadata, {'sha256', 'byteLength'});
      if (metadata.length != 2 ||
          metadata['sha256'] is! String ||
          metadata['byteLength'] is! int)
        throw const FormatException('Invalid document action file manifest');
      validateHash(metadata['sha256'] as String);
      final length = metadata['byteLength'] as int;
      if (length < 0 || length > 128 * 1024 * 1024)
        throw const FormatException('A document action file exceeds its limit');
      totalBytes += length;
      if (totalBytes > 256 * 1024 * 1024)
        throw const FormatException(
          'The document action files exceed their limit',
        );
    }
    result.add(files);
  }
  return result;
}

Future<Map<String, Uint8List>?> _pathPublishedFiles(
  NoteRepository repo,
  RevisionRecord expected,
  Map<String, dynamic> manifest, {
  required bool mustExist,
}) async {
  if (manifest.length != expected.blobs.length ||
      expected.blobs.entries.any((entry) {
        final metadata = jsonObject(manifest[entry.key]);
        return metadata['sha256'] != entry.value.hash ||
            metadata['byteLength'] != entry.value.length;
      }))
    throw const FormatException(
      'The document action manifest is not bound to its prepared files',
    );
  _pathPrivateDirectory(repo, const ['revisions'], create: false);
  final path = File(
    p.join(repo.root.path, 'revisions', '${expected.revisionId}.json'),
  );
  final type = FileSystemEntity.typeSync(path.path, followLinks: false);
  if (type == FileSystemEntityType.notFound && !mustExist) return null;
  if (type != FileSystemEntityType.file ||
      path.lengthSync() > VaultMcpBridge.maxBodyBytes)
    throw const FormatException(
      'The actual document action manifest is missing or unsafe',
    );
  final json = jsonObject(jsonDecode(await path.readAsString()));
  if (!const DeepCollectionEquality().equals(json, expected.toJson()))
    throw const FormatException('The actual document action manifest changed');
  final actual = RevisionRecord.fromJson(json);
  final files = await repo.readFiles(actual);
  if (!const DeepCollectionEquality().equals(
    _pathFileManifest(files),
    manifest,
  ))
    throw const FormatException('The actual document action files changed');
  return files;
}

Future<void> _writePathRecoveryFiles(
  NoteRepository repo,
  String requestId,
  String recoveryId,
  List<Map<String, Uint8List>> steps,
) async {
  _pathFileManifests([for (final files in steps) _pathFileManifest(files)]);
  final directory = _pathPrivateDirectory(repo, [
    '.workspace',
    'mcp',
    'requests',
    requestId,
    'path',
    recoveryId,
  ], create: true);
  if (directory.listSync(followLinks: false).isNotEmpty)
    throw const FormatException('Private document action files already exist');
  for (var index = 0; index < steps.length; index++) {
    final stepDirectory = _pathPrivateDirectory(repo, [
      '.workspace',
      'mcp',
      'requests',
      requestId,
      'path',
      recoveryId,
      index.toString(),
    ], create: true);
    final seen = <String>{};
    for (final bytes in steps[index].values) {
      final hash = sha256.convert(bytes).toString();
      if (!seen.add(hash)) continue;
      final file = File(p.join(stepDirectory.path, hash));
      final pending = File('${file.path}.${newId()}.pending');
      try {
        await pending.writeAsBytes(bytes, flush: true);
        await pending.rename(file.path);
      } finally {
        if (pending.existsSync()) await pending.delete();
      }
    }
  }
}

Future<Map<String, Uint8List>> _readPathRecoveryFiles(
  NoteRepository repo,
  String requestId,
  String recoveryId,
  int index,
  Map<String, dynamic> manifest,
) async {
  final directory = _pathPrivateDirectory(repo, [
    '.workspace',
    'mcp',
    'requests',
    requestId,
    'path',
    recoveryId,
    index.toString(),
  ], create: false);
  final expected = {
    for (final value in manifest.values) jsonObject(value)['sha256'] as String,
  };
  final entries = directory.listSync(followLinks: false);
  if (entries.length != expected.length ||
      entries.any(
        (entry) =>
            FileSystemEntity.typeSync(entry.path, followLinks: false) !=
                FileSystemEntityType.file ||
            !expected.contains(p.basename(entry.path)),
      ))
    throw const FormatException(
      'Unsafe or unexpected document action recovery files',
    );
  final byHash = <String, Uint8List>{};
  final files = <String, Uint8List>{};
  for (final entry in manifest.entries) {
    final metadata = jsonObject(entry.value);
    final hash = metadata['sha256'] as String;
    var bytes = byHash[hash];
    if (bytes == null) {
      final file = File(p.join(directory.path, hash));
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          file.lengthSync() != metadata['byteLength'])
        throw const FormatException('The private document action file changed');
      bytes = await file.readAsBytes();
      if (bytes.length != metadata['byteLength'] ||
          sha256.convert(bytes).toString() != hash)
        throw const FormatException(
          'The private document action bytes changed',
        );
      byHash[hash] = bytes;
    }
    if (bytes.length != metadata['byteLength'])
      throw const FormatException('The document action file length changed');
    files[entry.key] = bytes;
  }
  return files;
}

bool _pathIsNoOp(
  String action,
  Map<String, Object?> changes,
  bool? deleted,
  RevisionRecord record,
  Map<String, Uint8List> files,
  List<RevisionRecord> revisions,
) {
  final metadata = jsonObject(jsonDecode(utf8.decode(files['note.json']!)));
  return switch (action) {
    'rename' => changes['title'] == metadata['title'],
    'move' => changes['folderId'] == metadata['folderId'],
    'trash' => knowledgeNoteDeletionObserved(record, revisions),
    'restore' => record.deleted == deleted,
    _ => false,
  };
}

String _officeReceiptPlanDigest(Map<String, dynamic> receipt) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _canonical({
            for (final entry in receipt.entries)
              if (!{'state', 'result', 'planDigest'}.contains(entry.key))
                entry.key: entry.value,
          }),
        ),
      ),
    )
    .toString();

Directory _officePrivateDirectory(
  NoteRepository repo,
  List<String> parts, {
  required bool create,
}) {
  var directory = repo.root;
  for (final part in parts) {
    directory = Directory(p.join(directory.path, part));
    final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      directory.createSync();
    } else if (type != FileSystemEntityType.directory) {
      throw const FormatException('Missing or unsafe private Office directory');
    }
  }
  return directory;
}

String _officeOriginalName(Iterable<String> names) {
  final keys = names.toSet();
  if (keys.length != 3 || !keys.containsAll({'preview.pdf', 'edition.json'}))
    throw const FormatException('Expected exactly three Office recovery files');
  for (final name in keys) {
    if (name.isEmpty ||
        name.length > 255 ||
        name.contains(RegExp(r'[\\/:\x00-\x1f]')) ||
        name == '.' ||
        name == '..')
      throw const FormatException('Unsafe Office recovery file name');
  }
  return keys.singleWhere(
    (name) => name != 'preview.pdf' && name != 'edition.json',
  );
}

Map<String, Object?> _officeFileManifest(Map<String, Uint8List> files) {
  _officeOriginalName(files.keys);
  return {
    for (final entry in files.entries)
      entry.key: {
        'sha256': sha256.convert(entry.value).toString(),
        'byteLength': entry.value.length,
      },
  };
}

void _officeRecoveryLength(String name, int length) {
  if (length < 1 ||
      length > (name == 'edition.json' ? 64 * 1024 : 128 * 1024 * 1024))
    throw const FormatException('Office recovery file exceeds its limit');
}

Future<void> _writeOfficeRecoveryFiles(
  NoteRepository repo,
  String requestId,
  Map<String, Uint8List> files,
) async {
  _officeOriginalName(files.keys);
  final directory = _officePrivateDirectory(repo, [
    '.workspace',
    'mcp',
    'requests',
    requestId,
    'files',
  ], create: true);
  if (directory.listSync(followLinks: false).isNotEmpty)
    throw const FormatException('Private Office recovery files already exist');
  for (final entry in files.entries) {
    _officeRecoveryLength(entry.key, entry.value.length);
    final target = File(p.join(directory.path, entry.key));
    final pending = File('${target.path}.${newId()}.pending');
    try {
      await pending.writeAsBytes(entry.value, flush: true);
      await pending.rename(target.path);
    } finally {
      if (pending.existsSync()) await pending.delete();
    }
  }
}

Future<Map<String, Uint8List>> _readOfficeRecoveryFiles(
  NoteRepository repo,
  String requestId,
  Map<String, dynamic> manifest,
) async {
  _officeOriginalName(manifest.keys);
  final directory = _officePrivateDirectory(repo, [
    '.workspace',
    'mcp',
    'requests',
    requestId,
    'files',
  ], create: false);
  final entries = directory.listSync(followLinks: false);
  if (entries.length != 3 ||
      entries.any(
        (entry) =>
            FileSystemEntity.typeSync(entry.path, followLinks: false) !=
                FileSystemEntityType.file ||
            !manifest.containsKey(p.basename(entry.path)),
      ))
    throw const FormatException('Unsafe or unexpected private Office files');
  final files = <String, Uint8List>{};
  for (final entry in manifest.entries) {
    final metadata = jsonObject(entry.value);
    _keys(metadata, {'sha256', 'byteLength'});
    if (metadata.length != 2 ||
        metadata['sha256'] is! String ||
        metadata['byteLength'] is! int)
      throw const FormatException('Invalid Office recovery file metadata');
    validateHash(metadata['sha256'] as String);
    _officeRecoveryLength(entry.key, metadata['byteLength'] as int);
    final file = File(p.join(directory.path, entry.key));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        file.lengthSync() != metadata['byteLength'])
      throw const FormatException('The private Office recovery file changed');
    final bytes = await file.readAsBytes();
    if (bytes.length != metadata['byteLength'] ||
        sha256.convert(bytes).toString() != metadata['sha256'])
      throw const FormatException('The private Office recovery bytes changed');
    files[entry.key] = bytes;
  }
  return files;
}

void _validateOfficeAssetBindings(Object? raw, List<String> ids) {
  if (raw is! List || raw.length != ids.length)
    throw const FormatException('Invalid Office asset bindings');
  var totalBytes = 0;
  for (var i = 0; i < ids.length; i++) {
    final asset = jsonObject(raw[i]);
    _keys(asset, {
      'assetId',
      'sha256',
      'byteLength',
      'mimeType',
      'width',
      'height',
    });
    if (asset.length != 6 ||
        asset['assetId'] != ids[i] ||
        asset['sha256'] is! String ||
        !{'image/png', 'image/jpeg'}.contains(asset['mimeType']) ||
        asset['byteLength'] is! int ||
        asset['width'] is! int ||
        asset['height'] is! int)
      throw const FormatException('Invalid Office sealed asset binding');
    validateHash(asset['sha256'] as String);
    final length = asset['byteLength'] as int,
        width = asset['width'] as int,
        height = asset['height'] as int;
    if (length < 1 ||
        length > WindowsOfficeImageAsset.maxBytes ||
        width < 1 ||
        height < 1 ||
        width > WindowsOfficeImageAsset.maxPixels ~/ height)
      throw const FormatException('Office sealed asset exceeds its limit');
    totalBytes += length;
    if (totalBytes > WindowsOfficeImageAsset.maxBatchBytes)
      throw const FormatException(
        'Office sealed assets exceed the batch limit',
      );
  }
}

class _McpQueryInput {
  const new(this.note, this.revision, this.database);
  final VaultNote note;
  final RevisionRecord revision;
  final WorkspaceDatabase database;
}

void _requireMcpTextEncoding(Object? value) {
  if (value is String) {
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= value.length ||
            value.codeUnitAt(i) < 0xdc00 ||
            value.codeUnitAt(i) > 0xdfff)
          throw const VaultMcpException(
            'unsupported_text_encoding',
            '계산 결과에 MCP JSON으로 전달할 수 없는 단독 UTF-16 문자가 있습니다. 원본은 보존됩니다.',
          );
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        throw const VaultMcpException(
          'unsupported_text_encoding',
          '계산 결과에 MCP JSON으로 전달할 수 없는 단독 UTF-16 문자가 있습니다. 원본은 보존됩니다.',
        );
      }
    }
  } else if (value is Map) {
    for (final entry in value.entries) {
      _requireMcpTextEncoding(entry.key);
      _requireMcpTextEncoding(entry.value);
    }
  } else if (value is List) {
    for (final item in value) _requireMcpTextEncoding(item);
  }
}

Future<void> _writeRecord(
  File file,
  Map<String, Object?> record, {
  void Function()? beforeRename,
}) async {
  await file.parent.create(recursive: true);
  final pending = File('${file.path}.${newId()}.pending');
  try {
    await pending.writeAsString(jsonEncode(record), flush: true);
    if (beforeRename == null) {
      await pending.rename(file.path);
    } else {
      beforeRename();
      pending.renameSync(file.path);
    }
  } finally {
    if (pending.existsSync()) await pending.delete();
  }
}

Object? _canonical(Object? value) {
  if (value is Map)
    return {
      for (final key in value.keys.cast<String>().toList()..sort())
        key: _canonical(value[key]),
    };
  if (value is List) return value.map(_canonical).toList();
  return value;
}

DatabaseProperty _databaseProperty(WorkspaceDatabase database, String id) {
  validateId(id);
  final property = database.properties
      .where((property) => property.id == id)
      .singleOrNull;
  if (property == null || !databaseActionPropertyTypes.contains(property.type))
    throw const FormatException('Missing or unsupported writable property');
  return property;
}

DatabaseRow _databaseRow(WorkspaceDatabase database, String id) {
  final row = database.rows.where((row) => row.id == id).singleOrNull;
  if (row == null || row.archived)
    throw const FormatException('Missing or archived database row');
  return row;
}

void _validateDiscussionAction(Map<String, dynamic> action) {
  switch (action['type']) {
    case 'create_thread':
      _keys(action, {'type', 'anchor', 'body'});
      _string(action, 'body', max: 8192);
      final anchor = jsonObject(action['anchor']);
      switch (anchor['kind']) {
        case 'page':
          _keys(anchor, {'kind'});
        case 'block':
          _keys(anchor, {'kind', 'blockId'});
          _id(anchor, 'blockId');
        case 'quote':
          _keys(anchor, {'kind', 'blockId', 'startUtf16', 'endUtf16'});
          _id(anchor, 'blockId');
          final start = anchor['startUtf16'];
          final end = anchor['endUtf16'];
          if (start is! int ||
              end is! int ||
              start < 0 ||
              end <= start ||
              end > 0xffffffff) {
            throw const FormatException('Invalid UTF-16 discussion range');
          }
        default:
          throw const FormatException('Invalid discussion anchor');
      }
    case 'reply':
      _keys(action, {'type', 'threadId', 'replyToId', 'body'});
      _id(action, 'threadId');
      _id(action, 'replyToId');
      _string(action, 'body', max: 8192);
    case 'set_resolved':
      _keys(action, {'type', 'threadId', 'resolved', 'expectedStatusIds'});
      _id(action, 'threadId');
      final ids = action['expectedStatusIds'];
      if (action['resolved'] is! bool ||
          ids is! List ||
          ids.isEmpty ||
          ids.length > 1024 ||
          ids.any((id) => id is! String) ||
          ids.toSet().length != ids.length) {
        throw const FormatException('Invalid discussion status request');
      }
      for (final id in ids.cast<String>()) {
        validateId(id);
      }
    default:
      throw const FormatException('Invalid discussion action');
  }
}

void _keys(Map<String, dynamic> arguments, Set<String> allowed) {
  if (arguments.keys.any((key) => !allowed.contains(key)))
    throw const FormatException('Unknown argument');
}

String _string(
  Map<String, dynamic> args,
  String name, {
  int max = 1024,
  bool allowEmpty = false,
}) {
  final value = args[name];
  if (value is! String ||
      value.length > max ||
      !allowEmpty && value.trim().isEmpty)
    throw const FormatException('Invalid string argument');
  return value;
}

String? _optionalString(Map<String, dynamic> args, String name) =>
    args[name] == null ? null : _string(args, name, allowEmpty: true);
DateTime _dailyDate(Map<String, dynamic> args) {
  final value = _string(args, 'date', max: 10);
  if (value.length != 10 ||
      !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(value)) {
    throw const FormatException('Expected a date in YYYY-MM-DD format');
  }
  final year = int.parse(value.substring(0, 4));
  final month = int.parse(value.substring(5, 7));
  final day = int.parse(value.substring(8, 10));
  final date = DateTime.utc(year, month, day);
  if (year == 0 ||
      date.year != year ||
      date.month != month ||
      date.day != day) {
    throw const FormatException('Expected a valid Gregorian date');
  }
  return date;
}

String _id(Map<String, dynamic> args, String name) {
  final id = _string(args, name, max: 36);
  validateId(id);
  return id;
}

String? _optionalId(Map<String, dynamic> args, String name) =>
    args[name] == null ? null : _id(args, name);
int _integer(
  Map<String, dynamic> args,
  String name, {
  required int fallback,
  int min = 1,
  required int max,
}) {
  final value = args[name] ?? fallback;
  if (value is! int || value < min || value > max)
    throw const FormatException('Invalid integer argument');
  return value;
}

bool _boolean(
  Map<String, dynamic> args,
  String name, {
  required bool fallback,
}) {
  final value = args[name] ?? fallback;
  if (value is! bool) throw const FormatException('Invalid boolean argument');
  return value;
}

double _number(Map<String, dynamic> args, String name) {
  final value = args[name];
  if (value is! num || !value.isFinite || value.abs() > 1000000)
    throw const FormatException('Invalid Office number');
  return value.toDouble();
}

WindowsOfficeOperation _officeOperation(Map<String, dynamic> operation) {
  final op = _string(operation, 'op', max: 30);
  String id() => _string(operation, 'id', max: 256);
  String text() => _string(operation, 'text', max: 100000, allowEmpty: true);
  double? fontSize() =>
      operation['fontSize'] == null ? null : _number(operation, 'fontSize');
  bool? bold() => operation['bold'] == null
      ? null
      : _boolean(operation, 'bold', fallback: false);
  int? color() => operation['color'] == null
      ? null
      : _integer(operation, 'color', fallback: 0, min: 0, max: 0xffffff);
  int? paintColor(String name) => operation[name] == null
      ? null
      : _integer(operation, name, fallback: 0, min: 0, max: 0xffffff);
  String? paintStyle(String name) {
    if (operation[name] == null) return null;
    final value = _string(operation, name, max: 10);
    if (value != 'none' && value != 'solid')
      throw const FormatException('Unsupported Office paint style');
    return value;
  }

  String textHash(String name) {
    final value = _string(operation, name, max: 64);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value))
      throw const FormatException('Missing current Office text digest');
    return value;
  }

  String paragraphChoice(String name, Set<String> choices) {
    final value = _string(operation, name, max: 16);
    if (!choices.contains(value))
      throw const FormatException('Unsupported Office paragraph property');
    return value;
  }

  switch (op) {
    case 'pptxSlideSectionMove':
      _keys(operation, {
        'op',
        'expectedSourceSha256',
        'sourceIndex',
        'targetIndex',
        'after',
      });
      final sourceIndex = _integer(
        operation,
        'sourceIndex',
        fallback: -1,
        min: 0,
        max: 255,
      );
      final targetIndex = _integer(
        operation,
        'targetIndex',
        fallback: -1,
        min: 0,
        max: 255,
      );
      final after = operation['after'];
      if (after is! bool ||
          sourceIndex == targetIndex ||
          PptxSlideReorderEngine.destinationIndex(
                sourceIndex,
                targetIndex,
                after: after,
              ) !=
              sourceIndex) {
        throw const FormatException(
          'A PPTX section move must keep the slide at the same position',
        );
      }
      return WindowsOfficeOperation.pptxSlideSectionMove(
        expectedSourceSha256: textHash('expectedSourceSha256'),
        sourceIndex: sourceIndex,
        targetIndex: targetIndex,
        after: after,
      );
    case 'docxTableStructureEdit':
      _keys(operation, {
        'op',
        'expectedSourceSha256',
        'tableIndex',
        'action',
        'index',
        'anchorIndex',
      });
      final actionName = _string(operation, 'action', max: 20);
      final action = DocxTableStructureAction.values
          .where((value) => value.name == actionName)
          .singleOrNull;
      if (action == null) {
        throw const FormatException('Unknown DOCX table structure action');
      }
      final maxCount = action.isRow
          ? DocxTableStructureEngine.maxRows
          : DocxTableStructureEngine.maxColumns;
      final index = _integer(
        operation,
        'index',
        fallback: -1,
        min: 0,
        max: action.isDelete ? maxCount - 1 : maxCount,
      );
      int? anchorIndex;
      if (action.isDelete) {
        if (operation.containsKey('anchorIndex')) {
          throw const FormatException('DOCX table deletion has no anchor');
        }
      } else {
        anchorIndex = _integer(
          operation,
          'anchorIndex',
          fallback: -1,
          min: 0,
          max: maxCount - 1,
        );
        if (index != anchorIndex && index != anchorIndex + 1) {
          throw const FormatException(
            'DOCX insertion must be beside its anchor',
          );
        }
      }
      return WindowsOfficeOperation.docxTableStructureEdit(
        expectedSourceSha256: textHash('expectedSourceSha256'),
        tableIndex: _integer(
          operation,
          'tableIndex',
          fallback: -1,
          min: 0,
          max: 511,
        ),
        action: actionName,
        index: index,
        anchorIndex: anchorIndex,
      );
    case 'presentationTableStructureEdit':
      _keys(operation, {
        'op',
        'expectedSourceSha256',
        'slideIndex',
        'shapeId',
        'action',
        'index',
      });
      final action = _string(operation, 'action', max: 20);
      if (!PptxTableStructureAction.values.any(
        (value) => value.name == action,
      )) {
        throw const FormatException('Unknown PPTX table structure action');
      }
      return WindowsOfficeOperation.presentationTableStructureEdit(
        expectedSourceSha256: textHash('expectedSourceSha256'),
        slideIndex: _integer(
          operation,
          'slideIndex',
          fallback: -1,
          min: 0,
          max: 255,
        ),
        shapeId: _integer(operation, 'shapeId', fallback: 0, max: 0xffffffff),
        action: action,
        index: _integer(operation, 'index', fallback: -1, min: 0, max: 255),
      );
    case 'presentationSourceTableAdd':
      const structureFields = {
        'op',
        'authorityVersion',
        'id',
        'ownerId',
        'expectedSourceSha256',
        'sourcePart',
        'expectedSourcePartSha256',
        'expectedShapeIdInventorySha256',
        'xMm',
        'yMm',
        'columnWidthsMm',
        'rowHeightsMm',
      };
      _keys(operation, structureFields);
      if (!operation.keys.toSet().containsAll(structureFields) ||
          operation['authorityVersion'] is! int) {
        throw const FormatException(
          'Missing exact source table creation guards',
        );
      }
      num sourceDimension(String name) {
        final value = operation[name];
        if (value is! num || !value.isFinite) {
          throw const FormatException(
            'Expected a finite source table dimension',
          );
        }
        return value;
      }
      List<num> sourceDimensions(String name) {
        final values = operation[name];
        if (values is! List ||
            values.isEmpty ||
            values.length > 100 ||
            values.any((value) => value is! num || !value.isFinite)) {
          throw const FormatException(
            'Expected a bounded source table dimension list',
          );
        }
        return List<num>.from(values);
      }
      return WindowsOfficeOperation.presentationSourceTableAdd(
        authorityVersion: operation['authorityVersion'] as int,
        id: _string(operation, 'id', max: 74),
        ownerId: _string(operation, 'ownerId', max: 256),
        expectedSourceSha256: textHash('expectedSourceSha256'),
        sourcePart: _string(operation, 'sourcePart', max: 1024),
        expectedSourcePartSha256: textHash('expectedSourcePartSha256'),
        expectedShapeIdInventorySha256: textHash(
          'expectedShapeIdInventorySha256',
        ),
        xMm: sourceDimension('xMm'),
        yMm: sourceDimension('yMm'),
        columnWidthsMm: sourceDimensions('columnWidthsMm'),
        rowHeightsMm: sourceDimensions('rowHeightsMm'),
      );
    case 'presentationCellTextPatch':
      const fields = {
        'op',
        'authorityVersion',
        'ownerId',
        'tableId',
        'cellId',
        'expectedSourceSha256',
        'sourcePart',
        'shapeId',
        'expectedSourceFrameSha256',
        'expectedTextSha256',
        'startUtf16',
        'endUtf16',
        'text',
      };
      _keys(operation, fields);
      if (!operation.keys.toSet().containsAll(fields) ||
          operation['authorityVersion'] is! int ||
          operation['startUtf16'] is! int ||
          operation['endUtf16'] is! int) {
        throw const FormatException('Missing exact source text patch guards');
      }
      return WindowsOfficeOperation.presentationCellTextPatch(
        authorityVersion: operation['authorityVersion'] as int,
        ownerId: _string(operation, 'ownerId', max: 256),
        tableId: _string(operation, 'tableId', max: 256),
        cellId: _string(operation, 'cellId', max: 256),
        expectedSourceSha256: textHash('expectedSourceSha256'),
        sourcePart: _string(operation, 'sourcePart', max: 1024),
        shapeId: _string(operation, 'shapeId', max: 256),
        expectedSourceFrameSha256: textHash('expectedSourceFrameSha256'),
        expectedTextSha256: textHash('expectedTextSha256'),
        startUtf16: operation['startUtf16'] as int,
        endUtf16: operation['endUtf16'] as int,
        text: _string(operation, 'text', max: 131072, allowEmpty: true),
      );
    case 'pageGeometry':
      const measurements = {
        'width',
        'height',
        'leftMargin',
        'rightMargin',
        'topMargin',
        'bottomMargin',
      };
      _keys(operation, {
        'op',
        'id',
        'expectedLayoutSha256',
        'landscape',
        ...measurements,
      });
      final supplied = <String, double>{};
      for (final name in measurements) {
        if (!operation.containsKey(name)) continue;
        final value = _number(operation, name);
        if (value < 0 ||
            value > 1000 ||
            ((name == 'width' || name == 'height') && value == 0) ||
            double.parse(value.toStringAsFixed(2)) != value) {
          throw const FormatException(
            'Page measurements require valid millimetres with at most two decimal places',
          );
        }
        supplied[name] = value;
      }
      final hasSize =
          operation.containsKey('width') ||
          operation.containsKey('height') ||
          operation.containsKey('landscape');
      bool? landscape;
      if (hasSize) {
        if (!supplied.containsKey('width') ||
            !supplied.containsKey('height') ||
            operation['landscape'] is! bool) {
          throw const FormatException(
            'Page width, height and orientation must be supplied together',
          );
        }
        landscape = operation['landscape'] as bool;
        final width = supplied['width']!;
        final height = supplied['height']!;
        if (width == height || landscape != (width > height)) {
          throw const FormatException(
            'Page dimensions do not match orientation',
          );
        }
        if ((supplied['leftMargin'] ?? 0) + (supplied['rightMargin'] ?? 0) >=
                width ||
            (supplied['topMargin'] ?? 0) + (supplied['bottomMargin'] ?? 0) >=
                height) {
          throw const FormatException('Page margins leave no content area');
        }
      }
      if (supplied.isEmpty) {
        throw const FormatException('No page geometry property supplied');
      }
      return WindowsOfficeOperation.pageGeometry(
        id: id(),
        expectedLayoutSha256: textHash('expectedLayoutSha256'),
        width: supplied['width'],
        height: supplied['height'],
        landscape: landscape,
        leftMargin: supplied['leftMargin'],
        rightMargin: supplied['rightMargin'],
        topMargin: supplied['topMargin'],
        bottomMargin: supplied['bottomMargin'],
      );
    case 'paragraphSplit':
      _keys(operation, {
        'op',
        'id',
        'newId',
        'offsetUtf16',
        'expectedTextSha256',
      });
      return WindowsOfficeOperation.paragraphSplit(
        id: id(),
        newId: _string(operation, 'newId', max: 256),
        offsetUtf16: _integer(
          operation,
          'offsetUtf16',
          fallback: -1,
          min: 0,
          max: 20000000,
        ),
        expectedTextSha256: textHash('expectedTextSha256'),
      );
    case 'paragraphInsert':
      _keys(operation, {
        'op',
        'id',
        'referenceId',
        'position',
        'expectedTextSha256',
        'text',
      });
      final content = text();
      if (content.contains('\n') || content.contains('\r'))
        throw const FormatException('Insert one paragraph at a time');
      return WindowsOfficeOperation.paragraphInsert(
        id: id(),
        referenceId: _string(operation, 'referenceId', max: 256),
        position: paragraphChoice('position', {'before', 'after'}),
        expectedTextSha256: textHash('expectedTextSha256'),
        text: content,
      );
    case 'tableInsert':
      _keys(operation, {
        'op',
        'id',
        'referenceId',
        'position',
        'expectedTextSha256',
        'rows',
        'columns',
        'cells',
      });
      paragraphChoice('position', {'after'});
      final draftId = id();
      final anchor = _string(operation, 'referenceId', max: 256);
      if (!HwpOfficeEngine.isValidTableInsertTarget(draftId, anchor)) {
        throw const FormatException('Invalid HWPX table insertion target');
      }
      final rows = _integer(operation, 'rows', fallback: 0, max: 8);
      final columns = _integer(operation, 'columns', fallback: 0, max: 6);
      final hasCells = operation.containsKey('cells');
      final rawCells = operation['cells'];
      if (hasCells &&
          !HwpOfficeEngine.isValidTableInsertCells(rawCells, rows, columns)) {
        throw const FormatException('Invalid HWPX table cells');
      }
      return WindowsOfficeOperation.hwpTableInsert(
        id: draftId,
        referenceId: anchor,
        expectedTextSha256: textHash('expectedTextSha256'),
        rows: rows,
        columns: columns,
        cells: hasCells
            ? [
                for (final row in rawCells as List)
                  List<String>.from(row as List),
              ]
            : null,
      );
    case 'tableStructure':
      _keys(operation, {'op', 'id', 'action', 'index'});
      final table = _string(operation, 'id', max: 128);
      final tableId = RegExp(
        r'^s(?:0|[1-9][0-9]*):p(?:0|[1-9][0-9]*):t(?:0|[1-9][0-9]*)$',
      );
      if (tableId.stringMatch(table) != table) {
        throw const FormatException('Expected a saved Hangul table ID');
      }
      final action = _string(operation, 'action', max: 16);
      if (!{
        'insertRow',
        'deleteRow',
        'insertColumn',
        'deleteColumn',
      }.contains(action)) {
        throw const FormatException('Unsupported Hangul table action');
      }
      return WindowsOfficeOperation.hwpTableStructure(
        id: table,
        action: action,
        index: _integer(operation, 'index', fallback: -1, min: 0, max: 64),
      );
    case 'paragraphJoin':
      _keys(operation, {
        'op',
        'id',
        'nextId',
        'expectedTextSha256',
        'expectedNextTextSha256',
      });
      return WindowsOfficeOperation.paragraphJoin(
        id: id(),
        nextId: _string(operation, 'nextId', max: 256),
        expectedTextSha256: textHash('expectedTextSha256'),
        expectedNextTextSha256: textHash('expectedNextTextSha256'),
      );
    case 'paragraphDelete':
      _keys(operation, {'op', 'id', 'expectedTextSha256'});
      return WindowsOfficeOperation.paragraphDelete(
        id: id(),
        expectedTextSha256: textHash('expectedTextSha256'),
      );
    case 'paragraphFormat':
      _keys(operation, {
        'op',
        'id',
        'expectedTextSha256',
        'styleName',
        'alignment',
        'listKind',
        'listLevel',
        'pageBreakBefore',
      });
      if (!{
        'styleName',
        'alignment',
        'listKind',
        'listLevel',
        'pageBreakBefore',
      }.any((key) => operation[key] != null))
        throw const FormatException('Select a paragraph property to change');
      return WindowsOfficeOperation.paragraphFormat(
        id: id(),
        expectedTextSha256: textHash('expectedTextSha256'),
        styleName: operation['styleName'] == null
            ? null
            : _string(operation, 'styleName', max: 256),
        alignment: operation['alignment'] == null
            ? null
            : paragraphChoice('alignment', {
                'left',
                'center',
                'right',
                'justify',
              }),
        listKind: operation['listKind'] == null
            ? null
            : paragraphChoice('listKind', {'none', 'bullet', 'number'}),
        listLevel: operation['listLevel'] == null
            ? null
            : _integer(operation, 'listLevel', fallback: -1, min: 0, max: 8),
        pageBreakBefore: operation['pageBreakBefore'] == null
            ? null
            : _boolean(operation, 'pageBreakBefore', fallback: false),
      );
    case 'textReplace':
    case 'textStyle':
      const rangeKeys = {
        'op',
        'targetKind',
        'id',
        'cell',
        'startUtf16',
        'endUtf16',
        'expectedTextSha256',
      };
      _keys(operation, {
        ...rangeKeys,
        if (op == 'textReplace') 'text',
        if (op == 'textStyle') ...{
          'fontSize',
          'bold',
          'italic',
          'underline',
          'color',
          'fontFamily',
        },
      });
      final target = _string(operation, 'targetKind', max: 20);
      if (!{'paragraph', 'shape', 'cell'}.contains(target))
        throw const FormatException('Unknown Office text owner');
      final cell = operation['cell'] == null
          ? null
          : _string(operation, 'cell', max: 32);
      if ((target == 'cell') != (cell != null))
        throw const FormatException('Office cell owner mismatch');
      final hash = _string(operation, 'expectedTextSha256', max: 64);
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))
        throw const FormatException('Missing current Office text digest');
      final start = _integer(
        operation,
        'startUtf16',
        fallback: -1,
        min: 0,
        max: 20000000,
      );
      final end = _integer(
        operation,
        'endUtf16',
        fallback: -1,
        min: start,
        max: 20000000,
      );
      if (op == 'textReplace')
        return WindowsOfficeOperation.textReplace(
          targetKind: target,
          id: id(),
          cell: cell,
          startUtf16: start,
          endUtf16: end,
          expectedTextSha256: hash,
          text: text(),
        );
      return WindowsOfficeOperation.textStyle(
        targetKind: target,
        id: id(),
        cell: cell,
        startUtf16: start,
        endUtf16: end,
        expectedTextSha256: hash,
        fontSize: fontSize(),
        bold: bold(),
        color: color(),
        italic: operation['italic'] == null
            ? null
            : _boolean(operation, 'italic', fallback: false),
        underline: operation['underline'] == null
            ? null
            : _boolean(operation, 'underline', fallback: false),
        fontFamily: operation['fontFamily'] == null
            ? null
            : _string(operation, 'fontFamily', max: 128),
      );
    case 'imageAdd':
      _keys(operation, {
        'op',
        'id',
        'slideId',
        'assetId',
        'x',
        'y',
        'width',
        'height',
      });
      return WindowsOfficeOperation.imageAdd(
        id: id(),
        slideId: _string(operation, 'slideId', max: 256),
        assetId: _id(operation, 'assetId'),
        x: _number(operation, 'x'),
        y: _number(operation, 'y'),
        width: _number(operation, 'width'),
        height: _number(operation, 'height'),
      );
    case 'imageReplace':
      _keys(operation, {'op', 'id', 'assetId'});
      return WindowsOfficeOperation.imageReplace(
        id: id(),
        assetId: _id(operation, 'assetId'),
      );
    case 'imageRotate':
      _keys(operation, {
        'op',
        'id',
        'expectedRotationHundredths',
        'rotationHundredths',
      });
      return WindowsOfficeOperation.imageRotate(
        id: id(),
        expectedRotationHundredths: _integer(
          operation,
          'expectedRotationHundredths',
          fallback: -1,
          min: 0,
          max: 35999,
        ),
        rotationHundredths: _integer(
          operation,
          'rotationHundredths',
          fallback: -1,
          min: 0,
          max: 35999,
        ),
      );
    case 'wordImageAdd':
      _keys(operation, {
        'op',
        'id',
        'ownerId',
        'paragraphId',
        'offsetUtf16',
        'expectedTextSha256',
        'assetId',
        'width',
        'height',
      });
      double millimetres(String name) {
        final value = _number(operation, name);
        if (value <= 0 ||
            value > 1000 ||
            double.parse(value.toStringAsFixed(2)) != value)
          throw const FormatException('Invalid Word image millimetres');
        return value;
      }
      return WindowsOfficeOperation.wordImageAdd(
        id: id(),
        ownerId: _string(operation, 'ownerId', max: 256),
        paragraphId: _string(operation, 'paragraphId', max: 256),
        offsetUtf16: _integer(
          operation,
          'offsetUtf16',
          fallback: -1,
          min: 0,
          max: 20000000,
        ),
        expectedTextSha256: textHash('expectedTextSha256'),
        assetId: _id(operation, 'assetId'),
        width: millimetres('width'),
        height: millimetres('height'),
      );
    case 'wordImageMove':
      _keys(operation, {
        'op',
        'id',
        'ownerId',
        'paragraphId',
        'offsetUtf16',
        'expectedTextSha256',
      });
      return WindowsOfficeOperation.wordImageMove(
        id: id(),
        ownerId: _string(operation, 'ownerId', max: 256),
        paragraphId: _string(operation, 'paragraphId', max: 256),
        offsetUtf16: _integer(
          operation,
          'offsetUtf16',
          fallback: -1,
          min: 0,
          max: 20000000,
        ),
        expectedTextSha256: textHash('expectedTextSha256'),
      );
    case 'wordImageDelete':
      _keys(operation, {'op', 'id'});
      return WindowsOfficeOperation.wordImageDelete(id: id());
    case 'paragraphText':
      _keys(operation, {'op', 'id', 'text'});
      return WindowsOfficeOperation.paragraphText(id(), text());
    case 'paragraphStyle':
      _keys(operation, {'op', 'id', 'fontSize', 'bold', 'color'});
      return WindowsOfficeOperation.paragraphStyle(
        id(),
        fontSize: fontSize(),
        bold: bold(),
        color: color(),
      );
    case 'tableCellText':
      _keys(operation, {'op', 'tableId', 'cell', 'text'});
      return WindowsOfficeOperation.tableCellText(
        _string(operation, 'tableId', max: 256),
        _string(operation, 'cell', max: 32),
        text(),
      );
    case 'shapeText':
      _keys(operation, {'op', 'id', 'text'});
      return WindowsOfficeOperation.shapeText(id(), text());
    case 'shapeStyle':
      _keys(operation, {'op', 'id', 'fontSize', 'bold', 'color'});
      return WindowsOfficeOperation.shapeStyle(
        id(),
        fontSize: fontSize(),
        bold: bold(),
        color: color(),
      );
    case 'shapeGeometry':
      _keys(operation, {'op', 'id', 'x', 'y', 'width', 'height'});
      return WindowsOfficeOperation.shapeGeometry(
        id(),
        x: _number(operation, 'x'),
        y: _number(operation, 'y'),
        width: _number(operation, 'width'),
        height: _number(operation, 'height'),
      );
    case 'shapeAdd':
      _keys(operation, {
        'op',
        'id',
        'slideId',
        'shapeKind',
        'x',
        'y',
        'width',
        'height',
        'text',
      });
      final kind = _string(operation, 'shapeKind', max: 20);
      if (!const {
        'text',
        'rectangle',
        'ellipse',
        'line',
        'roundedRectangle',
        'rightArrow',
      }.contains(kind)) {
        throw const FormatException('Unsupported Office shape kind');
      }
      return WindowsOfficeOperation.shapeAdd(
        id: id(),
        slideId: _string(operation, 'slideId', max: 256),
        shapeKind: kind,
        x: _number(operation, 'x'),
        y: _number(operation, 'y'),
        width: _number(operation, 'width'),
        height: _number(operation, 'height'),
        text: operation['text'] == null ? '' : text(),
      );
    case 'shapeDelete':
      _keys(operation, {'op', 'id'});
      return WindowsOfficeOperation.shapeDelete(id());
    case 'shapeAppearance':
      _keys(operation, {
        'op',
        'id',
        'fillStyle',
        'fillColor',
        'lineStyle',
        'lineColor',
        'lineWidth',
      });
      final lineWidth = operation['lineWidth'] == null
          ? null
          : _number(operation, 'lineWidth');
      if (lineWidth != null && (lineWidth < 0 || lineWidth > 100))
        throw const FormatException('Invalid Office line width');
      return WindowsOfficeOperation.shapeAppearance(
        id(),
        fillStyle: paintStyle('fillStyle'),
        fillColor: paintColor('fillColor'),
        lineStyle: paintStyle('lineStyle'),
        lineColor: paintColor('lineColor'),
        lineWidth: lineWidth,
      );
    case 'slideDesign':
      _keys(operation, {
        'op',
        'id',
        'changeId',
        'expectedDesignSha256',
        'masterId',
        'layoutCode',
      });
      if (operation['masterId'] == null && operation['layoutCode'] == null) {
        throw const FormatException(
          'Select a common design or standard layout',
        );
      }
      final layout = operation['layoutCode'] == null
          ? null
          : _integer(operation, 'layoutCode', fallback: -1, min: 0, max: 20);
      if (layout != null && !const {0, 1, 19, 20}.contains(layout)) {
        throw const FormatException('Unsupported standard slide layout');
      }
      return WindowsOfficeOperation.slideDesign(
        id: id(),
        changeId: _string(operation, 'changeId', max: 128),
        expectedDesignSha256: textHash('expectedDesignSha256'),
        masterId: operation['masterId'] == null
            ? null
            : _string(operation, 'masterId', max: 256),
        layoutCode: layout,
      );
    case 'slideDisplay':
      _keys(operation, {'op', 'id', 'visible', 'showMasterObjects'});
      if (operation['visible'] == null &&
          operation['showMasterObjects'] == null) {
        throw const FormatException('Select a slide display property');
      }
      return WindowsOfficeOperation.slideDisplay(
        id: id(),
        visible: operation['visible'] == null
            ? null
            : _boolean(operation, 'visible', fallback: false),
        showMasterObjects: operation['showMasterObjects'] == null
            ? null
            : _boolean(operation, 'showMasterObjects', fallback: false),
      );
    case 'slideBackground':
      _keys(operation, {'op', 'id', 'fillStyle', 'fillColor'});
      return WindowsOfficeOperation.slideBackground(
        id(),
        fillStyle: paintStyle('fillStyle'),
        fillColor: paintColor('fillColor'),
      );
    case 'slideAdd':
      _keys(operation, {'op', 'id', 'index', 'text'});
      return WindowsOfficeOperation.slideAdd(
        id: id(),
        index: _integer(operation, 'index', fallback: 0, min: 0, max: 10000),
        text: operation['text'] == null ? '' : text(),
      );
    case 'slideDuplicate':
      _keys(operation, {'op', 'id'});
      return WindowsOfficeOperation.slideDuplicate(id());
    case 'slideDelete':
      _keys(operation, {'op', 'id'});
      return WindowsOfficeOperation.slideDelete(id());
    case 'slideMove':
      _keys(operation, {'op', 'id', 'index'});
      return WindowsOfficeOperation.slideMove(
        id(),
        _integer(operation, 'index', fallback: 0, min: 0, max: 10000),
      );
    default:
      throw const VaultMcpException(
        'unsupported_operation',
        '지원하지 않는 Office 편집 작업입니다.',
      );
  }
}

Map<String, Object?> _snapshot(WindowsOfficeSnapshot snapshot) {
  var truncated =
      snapshot.paragraphs.length > 100 ||
      snapshot.tables.length > 20 ||
      snapshot.slides.length > 50;
  var remainingText = 256 * 1024;
  var remainingRuns = 4096;
  var remainingThumbnails = 1024 * 1024;
  var remainingParagraphMetadata = 64 * 1024;
  const rawUnknown = <String, dynamic>{
    'unknown': true,
    'error': 'mcp_read_budget_exhausted',
  };
  final rawMarkerBytes = utf8.encode(jsonEncode(rawUnknown)).length;
  var rawBytesLeft = 256 * 1024, rawNodesLeft = 32768;
  var sourceBytesLeft = 1024 * 1024, sourceNodesLeft = 32768;
  var structureBytesLeft = 64 * 1024, structureNodesLeft = 4096;
  var remainingStructurePositions = snapshot.slides
      .take(50)
      .where((slide) => slide.sourceStructureAuthority != null)
      .length;
  var remainingSourcePositions = 0;
  countSourceSlots:
  for (final catalog in <List<WindowsOfficePresentationTable>?>[
    for (final slide in snapshot.slides.take(50)) slide.presentationTables,
    for (final master
        in snapshot.masters?.take(20) ?? const <WindowsOfficeMaster>[])
      master.presentationTables,
  ]) {
    for (final table in catalog ?? const <WindowsOfficePresentationTable>[]) {
      if (table.sourceTextPatchAuthority != null) remainingSourcePositions++;
      for (final cell in table.cells.take(100)) {
        if (cell.sourceTextPatch != null) remainingSourcePositions++;
      }
      if (remainingSourcePositions >= 2020) {
        remainingSourcePositions = 2020;
        break countSourceSlots;
      }
    }
  }
  int sourceNodes(Object? value) =>
      1 +
      (value is Map
          ? value.entries.fold<int>(
              0,
              (sum, entry) => sum + 1 + sourceNodes(entry.value),
            )
          : value is List
          ? value.fold<int>(0, (sum, item) => sum + sourceNodes(item))
          : 0);
  Map<String, Object?>? sourceData(Map<String, Object?> value) {
    remainingSourcePositions--;
    final bytes = utf8.encode(jsonEncode(value)).length;
    final nodes = sourceNodes(value);
    if (sourceBytesLeft - bytes < remainingSourcePositions * 4 ||
        sourceNodesLeft - nodes < remainingSourcePositions) {
      if (sourceBytesLeft < 4 || sourceNodesLeft < 1) {
        throw StateError('The MCP source proof marker reserve was exhausted');
      }
      sourceBytesLeft -= 4;
      sourceNodesLeft--;
      truncated = true;
      return null;
    }
    sourceBytesLeft -= bytes;
    sourceNodesLeft -= nodes;
    return value;
  }

  Map<String, Object?>? structureData(Map<String, Object?> value) {
    remainingStructurePositions--;
    final bytes = utf8.encode(jsonEncode(value)).length;
    final nodes = sourceNodes(value);
    if (structureBytesLeft - bytes < remainingStructurePositions * 4 ||
        structureNodesLeft - nodes < remainingStructurePositions) {
      if (structureBytesLeft < 4 || structureNodesLeft < 1) {
        throw StateError(
          'The MCP structure authority marker reserve was exhausted',
        );
      }
      structureBytesLeft -= 4;
      structureNodesLeft--;
      truncated = true;
      return null;
    }
    structureBytesLeft -= bytes;
    structureNodesLeft -= nodes;
    return value;
  }

  var remainingRawPositions = 0;
  countRawSlots:
  for (final catalog in <List<WindowsOfficePresentationTable>?>[
    for (final slide in snapshot.slides.take(50)) slide.presentationTables,
    for (final master
        in snapshot.masters?.take(20) ?? const <WindowsOfficeMaster>[])
      master.presentationTables,
  ]) {
    for (final table in catalog ?? const <WindowsOfficePresentationTable>[]) {
      remainingRawPositions += 1 + table.cells.length.clamp(0, 100);
      if (remainingRawPositions >= 2020) {
        remainingRawPositions = 2020;
        break countRawSlots;
      }
    }
  }
  bool rawCharge(int bytes, [int nodes = 0]) {
    if (rawBytesLeft - bytes < remainingRawPositions * rawMarkerBytes ||
        rawNodesLeft - nodes < remainingRawPositions * 3)
      return false;
    rawBytesLeft -= bytes;
    rawNodesLeft -= nodes;
    return true;
  }

  bool rawString(String value) {
    if (!rawCharge(2)) return false;
    for (var start = 0; start < value.length;) {
      var end = (start + 256).clamp(0, value.length);
      if (end < value.length &&
          value.codeUnitAt(end - 1) >= 0xd800 &&
          value.codeUnitAt(end - 1) <= 0xdbff &&
          value.codeUnitAt(end) >= 0xdc00 &&
          value.codeUnitAt(end) <= 0xdfff)
        end--;
      final bytes =
          utf8.encode(jsonEncode(value.substring(start, end))).length - 2;
      if (!rawCharge(bytes)) return false;
      start = end;
    }
    return true;
  }

  bool measureRaw(Object? value, [int depth = 0]) {
    if (depth > 64 || !rawCharge(0, 1)) return false;
    if (value == null) return rawCharge(4);
    if (value is bool) return rawCharge(value ? 4 : 5);
    if (value is num) return rawCharge(jsonEncode(value).length);
    if (value is String) return rawString(value);
    if (value is List) {
      if (!rawCharge(1)) return false;
      var first = true;
      for (final item in value) {
        if (!first && !rawCharge(1)) return false;
        first = false;
        if (!measureRaw(item, depth + 1)) return false;
      }
      return rawCharge(1);
    }
    if (value is Map) {
      if (!rawCharge(1)) return false;
      var first = true;
      for (final entry in value.entries) {
        if (!first && !rawCharge(1)) return false;
        first = false;
        if (entry.key is! String ||
            !rawString(entry.key as String) ||
            !rawCharge(1) ||
            !measureRaw(entry.value, depth + 1))
          return false;
      }
      return rawCharge(1);
    }
    return false;
  }

  ({Map<String, dynamic> value, bool truncated}) rawData(
    Map<String, dynamic> value,
  ) {
    remainingRawPositions--;
    final bytesBefore = rawBytesLeft, nodesBefore = rawNodesLeft;
    if (measureRaw(value)) return (value: value, truncated: false);
    rawBytesLeft = bytesBefore;
    rawNodesLeft = nodesBefore;
    if (!rawCharge(rawMarkerBytes, 3)) {
      throw StateError('The MCP raw metadata marker reserve was exhausted');
    }
    truncated = true;
    return (value: rawUnknown, truncated: true);
  }

  String? paragraphMetadata(String? value, {int max = 256}) {
    if (value == null) return null;
    if (value.length > max) {
      truncated = true;
      return null;
    }
    final bytes = utf8.encode(value).length;
    if (bytes > remainingParagraphMetadata) {
      truncated = true;
      return null;
    }
    remainingParagraphMetadata -= bytes;
    return value;
  }

  Map<String, Object?> text(String value, WindowsOfficeTextDetails? details) {
    var end = value.length.clamp(0, remainingText.clamp(0, 4096));
    if (end > 0 &&
        end < value.length &&
        value.codeUnitAt(end - 1) >= 0xd800 &&
        value.codeUnitAt(end - 1) <= 0xdbff &&
        value.codeUnitAt(end) >= 0xdc00 &&
        value.codeUnitAt(end) <= 0xdfff)
      end--;
    final visible = value.substring(0, end);
    remainingText -= end;
    final hidden = end != value.length || details?.truncated == true;
    final runs = [
      for (final run
          in (details?.runs ?? const <WindowsOfficeTextRun>[])
              .where((run) {
                if (run.startUtf16 != run.endUtf16)
                  return run.startUtf16 < end && run.endUtf16 > 0;
                final point = run.startUtf16;
                if (point < 0 || point > end) return false;
                return point == 0 ||
                    point == end ||
                    !(value.codeUnitAt(point - 1) >= 0xd800 &&
                        value.codeUnitAt(point - 1) <= 0xdbff &&
                        value.codeUnitAt(point) >= 0xdc00 &&
                        value.codeUnitAt(point) <= 0xdfff);
              })
              .take(remainingRuns.clamp(0, 256)))
        {
          'startUtf16': run.startUtf16,
          'endUtf16': run.endUtf16.clamp(0, end),
          'fontSize': run.fontSize,
          'bold': run.bold,
          'italic': run.italic,
          'underline': run.underline,
          'color': run.color,
          'fontFamily': run.fontFamily,
        },
    ];
    remainingRuns -= runs.length;
    final protected = [
      for (final range
          in (details?.protectedRanges ?? const <WindowsOfficeProtectedRange>[])
              .where((range) => range.startUtf16 <= end)
              .take(256))
        {
          'startUtf16': range.startUtf16,
          'endUtf16': range.endUtf16.clamp(0, end),
          'type': range.type,
        },
    ];
    final detailsTruncated =
        hidden ||
        runs.length != (details?.runs.length ?? 0) ||
        protected.length != (details?.protectedRanges.length ?? 0);
    if (detailsTruncated) truncated = true;
    return {
      'text': visible,
      'textDetails': {
        'utf16Length': details?.utf16Length ?? value.length,
        'textSha256':
            details?.textSha256 ??
            sha256.convert(utf8.encode(value)).toString(),
        'visibleUtf16Length': end,
        'truncated': detailsTruncated,
        'canReplace': details?.canReplace ?? false,
        'canStyle': details?.canStyle ?? false,
        'totalRuns': details?.runs.length ?? 0,
        'runs': runs,
        'totalProtectedRanges': details?.protectedRanges.length ?? 0,
        'protectedRanges': protected,
      },
    };
  }

  Map<String, Object?> image(WindowsOfficeImageDetails value) {
    final encoded = value.thumbnailBase64;
    final include = encoded != null && encoded.length <= remainingThumbnails;
    if (include) remainingThumbnails -= encoded.length;
    if (encoded != null && !include) truncated = true;
    return {
      'mimeType': paragraphMetadata(value.mimeType, max: 128),
      'pixelWidth': value.pixelWidth,
      'pixelHeight': value.pixelHeight,
      'canReplace': value.canReplace,
      'rotationHundredths': ?value.rotationHundredths,
      if (value.rotationHundredths != null) 'canRotate': value.canRotate,
      'thumbnailMimeType': paragraphMetadata(value.thumbnailMimeType, max: 128),
      'thumbnailSha256': paragraphMetadata(value.thumbnailSha256, max: 64),
      if (include) 'thumbnailBase64': encoded,
      'thumbnailTruncated':
          value.thumbnailTruncated || encoded != null && !include,
    };
  }

  Map<String, Object?>? tableData(WindowsOfficeTable table) {
    final id = paragraphMetadata(table.id);
    if (id == null) return null;
    final cells = {
      for (final entry in table.cells.entries.take(100))
        entry.key: text(entry.value, table.cellTextDetails[entry.key]),
    };
    return {
      'id': id,
      if (table.ownerId != null) 'ownerId': paragraphMetadata(table.ownerId),
      if (table.structure case final structure?)
        'structure': {
          'rows': structure.rows,
          'columns': structure.columns,
          'canInsertRow': structure.canInsertRow,
          'canDeleteRow': structure.canDeleteRow,
          'canInsertColumn': structure.canInsertColumn,
          'canDeleteColumn': structure.canDeleteColumn,
        },
      'cells': {
        for (final entry in cells.entries) entry.key: entry.value['text'],
      },
      'cellTextDetails': {
        for (final entry in cells.entries)
          entry.key: entry.value['textDetails'],
      },
    };
  }

  Map<String, Object?>? paragraphData(WindowsOfficeParagraph paragraph) {
    final id = paragraphMetadata(paragraph.id);
    if (id == null) return null;
    return {
      'id': id,
      if (paragraph.ownerId != null)
        'ownerId': paragraphMetadata(paragraph.ownerId),
      ...text(paragraph.text, paragraph.textDetails),
      'fontSize': paragraph.fontSize,
      'bold': paragraph.bold,
      'color': paragraph.color,
      if (paragraph.tableInsertAnchor) 'tableInsertAnchor': true,
      if (paragraph.paragraphFormat case final format?)
        'paragraphFormat': {
          'styleName': paragraphMetadata(format.styleName),
          'alignment': paragraphMetadata(format.alignment, max: 16),
          'listKind': paragraphMetadata(format.listKind, max: 16),
          'listLevel': format.listLevel,
          'pageBreakBefore': format.pageBreakBefore,
        },
      if (paragraph.structure case final structure?)
        'structure': {
          'canSplit': structure.canSplit,
          'canDelete': structure.canDelete,
          'canInsertBefore': structure.canInsertBefore,
          'canInsertAfter': structure.canInsertAfter,
          'canJoinNext': structure.canJoinNext,
        },
    };
  }

  final paragraphs = [
    for (final paragraph in snapshot.paragraphs.take(100))
      ?paragraphData(paragraph),
  ];
  final tables = [
    for (final table in snapshot.tables.take(20)) ?tableData(table),
  ];
  Map<String, Object?> shapeData(WindowsOfficeShape shape) => {
    'id': shape.id,
    'type': shape.type,
    'shapeKind': shape.shapeKind,
    'ownerKind': paragraphMetadata(shape.ownerKind, max: 16),
    'ownerId': paragraphMetadata(shape.ownerId),
    'presentationObject': shape.presentationObject,
    'emptyPresentationObject': shape.emptyPresentationObject,
    ...text(shape.text, shape.textDetails),
    if (shape.image != null) 'image': image(shape.image!),
    'editableText': shape.editableText,
    'canEditGeometry': shape.canEditGeometry,
    'canDelete': shape.canDelete,
    'canEditTextStyle': shape.canEditTextStyle,
    'x': shape.x,
    'y': shape.y,
    'width': shape.width,
    'height': shape.height,
    'fontSize': shape.fontSize,
    'bold': shape.bold,
    'color': shape.color,
    'canEditFill': shape.canEditFill,
    'canEditLine': shape.canEditLine,
    'fillStyle': shape.fillStyle,
    'fillColor': shape.fillColor,
    'lineStyle': shape.lineStyle,
    'lineColor': shape.lineColor,
    'lineWidth': shape.lineWidth,
  };
  var remainingPresentationTables = 20 - tables.length;
  const presentationCapabilityKeys = <String>[
    'canEditText',
    'canEditTextStyle',
    'canEditAppearance',
    'canInsertRows',
    'canDeleteRows',
    'canInsertColumns',
    'canDeleteColumns',
    'canMerge',
    'canSplit',
    'canDeleteTable',
  ];
  Map<String, Object?> presentationCapabilities(
    WindowsOfficePresentationTableCapabilities value,
  ) => {
    'canEditText': value.canEditText,
    'canEditTextStyle': value.canEditTextStyle,
    'canEditAppearance': value.canEditAppearance,
    'canInsertRows': value.canInsertRows,
    'canDeleteRows': value.canDeleteRows,
    'canInsertColumns': value.canInsertColumns,
    'canDeleteColumns': value.canDeleteColumns,
    'canMerge': value.canMerge,
    'canSplit': value.canSplit,
    'canDeleteTable': value.canDeleteTable,
  };
  void closePresentationAccess(
    Map<String, Object?> table, {
    bool closeSource = false,
  }) {
    table['capabilities'] = {
      for (final key in presentationCapabilityKeys) key: false,
    };
    if (closeSource && table.containsKey('sourceTextPatchAuthority')) {
      table['sourceTextPatchAuthority'] = null;
    }
    for (final cell in table['cells'] as List<Map<String, Object?>>) {
      final details = cell['textDetails'];
      if (details is Map<String, Object?>) {
        details['canReplace'] = false;
        details['canStyle'] = false;
      }
      if (closeSource && cell.containsKey('sourceTextPatch')) {
        cell['sourceTextPatch'] = null;
      }
    }
  }

  Map<String, Object?>? presentationCellData(
    WindowsOfficePresentationCell value,
  ) {
    final id = paragraphMetadata(value.id);
    if (id == null) return null;
    final anchor = paragraphMetadata(value.anchorCellId);
    final content = value.text == null
        ? <String, Object?>{'text': null, 'textDetails': null}
        : text(value.text!, value.textDetails);
    final raw = rawData(value.rawStyle);
    var hidden =
        value.text == null ||
        value.textDetails == null ||
        value.anchorCellId != null && anchor == null ||
        raw.truncated ||
        (content['textDetails'] as Map?)?['truncated'] == true;
    if (value.textDetails == null) content['textDetails'] = null;
    final details = content['textDetails'];
    if (details is Map<String, Object?>) {
      final hash = paragraphMetadata(details['textSha256'] as String, max: 64);
      if (hash == null) {
        content['textDetails'] = null;
        hidden = true;
      } else {
        details['textSha256'] = hash;
        for (final run in details['runs'] as List) {
          final item = run as Map<String, Object?>;
          final original = item['fontFamily'] as String?;
          final family = paragraphMetadata(original);
          if (original != null && family == null) hidden = true;
          item['fontFamily'] = family;
        }
        final ranges = <Map<String, Object?>>[];
        for (final range in details['protectedRanges'] as List) {
          final item = range as Map<String, Object?>;
          final type = paragraphMetadata(item['type'] as String, max: 128);
          if (type == null) {
            hidden = true;
            continue;
          }
          item['type'] = type;
          ranges.add(item);
        }
        details['protectedRanges'] = ranges;
      }
    }
    if (hidden) {
      truncated = true;
      if (details is Map<String, Object?>) {
        details['truncated'] = true;
        details['canReplace'] = false;
        details['canStyle'] = false;
      }
    }
    return {
      'id': id,
      'row': value.row,
      'column': value.column,
      'rowSpan': value.rowSpan,
      'columnSpan': value.columnSpan,
      'covered': value.covered,
      'anchorCellId': anchor,
      ...content,
      'rawStyle': raw.value,
      if (value.sourceTextPatch != null)
        'sourceTextPatch': sourceData(value.sourceTextPatch!.toJson()),
      'truncated': hidden,
    };
  }

  Map<String, Object?>? presentationTableData(
    WindowsOfficePresentationTable value,
  ) {
    final id = paragraphMetadata(value.id),
        owner = paragraphMetadata(value.ownerId);
    if (id == null || owner == null) return null;
    final raw = rawData(value.rawStyle);
    final authority = value.sourceTextPatchAuthority == null
        ? null
        : sourceData(value.sourceTextPatchAuthority!.toJson());
    final cells = <Map<String, Object?>>[
      for (final cell in value.cells.take(100)) ?presentationCellData(cell),
    ];
    var hidden =
        value.truncated ||
        raw.truncated ||
        cells.length != value.cells.length ||
        cells.any((cell) => cell['truncated'] == true) ||
        value.rowHeightsHmm.length > 100 ||
        value.columnWidthsHmm.length > 100;
    Map<String, Object?>? authored;
    final geometry = value.authoredGeometry;
    if (geometry != null) {
      final part = paragraphMetadata(
        geometry['sourcePart'] as String,
        max: 1024,
      );
      final shapeId = paragraphMetadata(geometry['shapeId'] as String);
      final widths = geometry['columnWidthsEmu'] as List<int>;
      final heights = geometry['rowHeightsEmu'] as List<int>;
      if (part == null ||
          shapeId == null ||
          widths.length > 100 ||
          heights.length > 100) {
        hidden = true;
      } else {
        authored = {
          'sourcePart': part,
          'shapeId': shapeId,
          'positionEmu': geometry['positionEmu'],
          'extentEmu': geometry['extentEmu'],
          'columnWidthsEmu': widths,
          'rowHeightsEmu': heights,
        };
      }
    }
    final result = <String, Object?>{
      'id': id,
      'ownerId': owner,
      'tableSha256': hidden ? null : value.tableSha256,
      'rowCount': value.rowCount,
      'columnCount': value.columnCount,
      'totalCellCount': value.totalCellCount,
      'rowHeightsHmm': value.rowHeightsHmm.take(100).toList(growable: false),
      'columnWidthsHmm': value.columnWidthsHmm
          .take(100)
          .toList(growable: false),
      'cells': cells,
      'rawStyle': raw.value,
      'capabilities': presentationCapabilities(value.capabilities),
      'authoredGeometry': authored,
      if (value.sourceTextPatchAuthority != null)
        'sourceTextPatchAuthority': authority,
      'nativeBoundsHmm': value.nativeBoundsHmm,
      'truncated': hidden,
    };
    if (hidden || value.tableSha256 == null) closePresentationAccess(result);
    final sourceHidden =
        cells.length != value.cells.length ||
        value.cells.length != value.totalCellCount ||
        value.sourceTextPatchAuthority != null &&
            (authority == null || authored == null) ||
        cells.any(
          (cell) => cell['covered'] == true && cell['anchorCellId'] == null,
        );
    if (sourceHidden) {
      if (result.containsKey('sourceTextPatchAuthority'))
        result['sourceTextPatchAuthority'] = null;
      for (final cell in cells) {
        if (cell.containsKey('sourceTextPatch')) cell['sourceTextPatch'] = null;
      }
    }
    if (hidden) truncated = true;
    return result;
  }

  Map<String, Object?> presentationOwnerData(
    List<WindowsOfficePresentationTable>? values,
    int? count,
    bool sourceTruncated,
    String? reason,
    bool canAdd,
  ) {
    final visibleReason = paragraphMetadata(reason, max: 128);
    if (values == null) {
      truncated = true;
      return {
        'presentationTables': null,
        'presentationTableCount': count,
        'presentationTablesTruncated': sourceTruncated,
        'presentationTablesUnknownReason': visibleReason,
        'canAddTable': false,
      };
    }
    final result = <Map<String, Object?>>[];
    for (final value in values) {
      if (remainingPresentationTables == 0) break;
      remainingPresentationTables--;
      final item = presentationTableData(value);
      if (item != null) result.add(item);
    }
    final partial =
        sourceTruncated ||
        result.length != values.length ||
        reason != null && visibleReason == null;
    if (partial) {
      truncated = true;
      for (final item in result)
        closePresentationAccess(item, closeSource: true);
    }
    return {
      'presentationTables': result,
      'presentationTableCount': count,
      'presentationTablesTruncated': partial,
      'presentationTablesUnknownReason': visibleReason,
      'canAddTable':
          canAdd &&
          !partial &&
          !result.any(
            (table) =>
                table['truncated'] == true || table['tableSha256'] == null,
          ),
    };
  }

  final slides = [
    for (final slide in snapshot.slides.take(50))
      {
        'id': slide.id,
        'width': slide.width,
        'height': slide.height,
        'backgroundStyle': slide.backgroundStyle,
        'backgroundColor': slide.backgroundColor,
        'masterId': paragraphMetadata(slide.masterId),
        'layoutCode': slide.layoutCode,
        'designSha256': paragraphMetadata(slide.designSha256, max: 64),
        'visible': slide.visible,
        'showMasterObjects': slide.showMasterObjects,
        'canDuplicate': slide.canDuplicate,
        ...presentationOwnerData(
          slide.presentationTables,
          slide.presentationTableCount,
          slide.presentationTablesTruncated,
          slide.presentationTablesUnknownReason,
          slide.canAddTable,
        ),
        'shapes': [
          for (final shape in slide.shapes.take(100)) shapeData(shape),
        ],
      },
  ];
  final masters = snapshot.masters == null ? null : <Map<String, Object?>>[];
  if (masters != null) {
    for (final master in snapshot.masters!.take(20)) {
      final id = paragraphMetadata(master.id);
      if (id == null) continue;
      masters.add({
        'id': id,
        'name': paragraphMetadata(master.name, max: 512),
        'width': master.width,
        'height': master.height,
        'backgroundStyle': master.backgroundStyle,
        'backgroundColor': master.backgroundColor,
        ...presentationOwnerData(
          master.presentationTables,
          master.presentationTableCount,
          master.presentationTablesTruncated,
          master.presentationTablesUnknownReason,
          master.canAddTable,
        ),
        'shapes': [
          for (final shape in master.shapes.take(100)) shapeData(shape),
        ],
        'totalShapes': master.shapes.length,
      });
    }
  }
  for (final owner in <Map<String, Object?>>[...slides, ...?masters]) {
    final publishedTables = owner['presentationTables'];
    if (publishedTables is! List) continue;
    final publishedShapes = owner['shapes'] as List;
    for (final table in publishedTables.cast<Map<String, Object?>>()) {
      final cells = table['cells'] as List<Map<String, Object?>>;
      final hasSource =
          table['sourceTextPatchAuthority'] != null ||
          cells.any((cell) => cell['sourceTextPatch'] != null);
      if (!hasSource ||
          publishedShapes
                  .where(
                    (shape) =>
                        shape is Map &&
                        shape['id'] == table['id'] &&
                        shape['type'] == 'com.sun.star.drawing.TableShape',
                  )
                  .length ==
              1)
        continue;
      if (table.containsKey('sourceTextPatchAuthority'))
        table['sourceTextPatchAuthority'] = null;
      for (final cell in cells) {
        if (cell.containsKey('sourceTextPatch')) cell['sourceTextPatch'] = null;
      }
      truncated = true;
    }
  }
  bool sameStructureData(Object? original, Object? published) =>
      jsonEncode(_canonical(original)) == jsonEncode(_canonical(published));

  bool completeStructureOwner(
    WindowsOfficeSlide source,
    Map<String, Object?> owner,
  ) {
    final sourceTables = source.presentationTables;
    final tables = owner['presentationTables'];
    final shapes = owner['shapes'];
    if (owner['id'] != source.id ||
        sourceTables == null ||
        tables is! List ||
        source.presentationTableCount != sourceTables.length ||
        source.presentationTablesTruncated ||
        owner['presentationTablesTruncated'] != false ||
        owner['presentationTableCount'] != source.presentationTableCount ||
        tables.length != sourceTables.length ||
        shapes is! List ||
        shapes.length != source.shapes.length)
      return false;
    for (final shape in source.shapes) {
      if (shapes
              .where(
                (value) =>
                    value is Map &&
                    value['id'] == shape.id &&
                    value['type'] == shape.type,
              )
              .length !=
          1)
        return false;
    }
    for (final sourceTable in sourceTables) {
      final matches = tables
          .where(
            (value) =>
                value is Map &&
                value['id'] == sourceTable.id &&
                value['ownerId'] == sourceTable.ownerId,
          )
          .toList();
      if (matches.length != 1) return false;
      final table = matches.single as Map;
      final cells = table['cells'];
      if (table['rowCount'] != sourceTable.rowCount ||
          table['columnCount'] != sourceTable.columnCount ||
          table['totalCellCount'] != sourceTable.totalCellCount ||
          cells is! List ||
          cells.length != sourceTable.cells.length ||
          sourceTable.cells.length != sourceTable.totalCellCount ||
          sourceTable.authoredGeometry == null ||
          !sameStructureData(
            sourceTable.authoredGeometry,
            table['authoredGeometry'],
          ) ||
          sourceTable.sourceTextPatchAuthority == null ||
          !sameStructureData(
            sourceTable.sourceTextPatchAuthority!.toJson(),
            table['sourceTextPatchAuthority'],
          ))
        return false;
      for (final sourceCell in sourceTable.cells) {
        final matches = cells
            .where((value) => value is Map && value['id'] == sourceCell.id)
            .toList();
        if (matches.length != 1) return false;
        final cell = matches.single as Map;
        if (cell['row'] != sourceCell.row ||
            cell['column'] != sourceCell.column ||
            cell['rowSpan'] != sourceCell.rowSpan ||
            cell['columnSpan'] != sourceCell.columnSpan ||
            cell['covered'] != sourceCell.covered ||
            cell['anchorCellId'] != sourceCell.anchorCellId ||
            sourceCell.sourceTextPatch == null ||
            !sameStructureData(
              sourceCell.sourceTextPatch!.toJson(),
              cell['sourceTextPatch'],
            ))
          return false;
      }
    }
    return true;
  }

  var completeStructurePublication = snapshot.slides.length == slides.length;
  for (var index = 0; index < slides.length; index++) {
    if (!completeStructureOwner(snapshot.slides[index], slides[index])) {
      completeStructurePublication = false;
    }
  }
  for (var index = 0; index < slides.length; index++) {
    final source = snapshot.slides[index].sourceStructureAuthority;
    if (source == null) continue;
    final authority = Map<String, Object?>.of(source.toJson());
    authority['canAddTable'] =
        source.canAddTable && completeStructurePublication;
    slides[index]['sourceStructureAuthority'] = structureData(authority);
    slides[index]['canAddTable'] = false;
  }

  final layoutOptions = <Map<String, Object?>>[];
  for (final option in snapshot.layoutOptions.take(32)) {
    final label = paragraphMetadata(option.label);
    if (label != null) layoutOptions.add({'code': option.code, 'label': label});
  }
  if (snapshot.tables.any((t) => t.cells.length > 100) ||
      snapshot.slides.any((s) => s.shapes.length > 100) ||
      (snapshot.masters?.length ?? 0) > 20 ||
      (snapshot.masters?.any((master) => master.shapes.length > 100) ??
          false) ||
      snapshot.layoutOptions.length > 32 ||
      (snapshot.blocks?.length ?? 0) > 256 ||
      snapshot.paragraphStyles.length > 256)
    truncated = true;
  final blocks = snapshot.blocks == null ? null : <Map<String, Object?>>[];
  if (blocks != null) {
    for (final block in snapshot.blocks!.take(256)) {
      final kind = paragraphMetadata(block.kind, max: 16);
      final id = paragraphMetadata(block.id);
      if (kind == null || id == null) break;
      blocks.add({'kind': kind, 'id': id});
    }
  }
  final paragraphStyles = <Map<String, Object?>>[];
  for (final style in snapshot.paragraphStyles.take(256)) {
    final name = paragraphMetadata(style.name);
    final displayName = paragraphMetadata(style.displayName, max: 512);
    if (name != null && displayName != null)
      paragraphStyles.add({'name': name, 'displayName': displayName});
  }
  final wordOwners = snapshot.wordOwners == null
      ? null
      : <Map<String, Object?>>[];
  if (wordOwners != null) {
    if (snapshot.wordOwners!.length > 32) truncated = true;
    for (final owner in snapshot.wordOwners!.take(32)) {
      final id = paragraphMetadata(owner.id);
      final kind = paragraphMetadata(owner.kind, max: 16);
      if (id == null || kind == null) continue;
      final references = <Map<String, Object?>>[];
      for (final reference in owner.references.take(128)) {
        final styleId = paragraphMetadata(reference.pageStyleId);
        final variant = paragraphMetadata(reference.variant, max: 16);
        if (styleId != null && variant != null)
          references.add({'pageStyleId': styleId, 'variant': variant});
      }
      final ownerBlocks = <Map<String, Object?>>[];
      for (final block in owner.blocks.take(200)) {
        final blockId = paragraphMetadata(block.id);
        final blockKind = paragraphMetadata(block.kind, max: 16);
        if (blockId != null && blockKind != null)
          ownerBlocks.add({'id': blockId, 'kind': blockKind});
      }
      final tableIds = [
        for (final tableId in owner.tableIds.take(100))
          ?paragraphMetadata(tableId),
      ];
      if (owner.references.length > 128 ||
          owner.blocks.length > 200 ||
          owner.paragraphs.length > 100 ||
          owner.tableIds.length > 100)
        truncated = true;
      wordOwners.add({
        'id': id,
        'kind': kind,
        'references': references,
        'totalReferences': owner.references.length,
        'blocks': ownerBlocks,
        'totalBlocks': owner.blocks.length,
        'paragraphs': [
          for (final paragraph in owner.paragraphs.take(100))
            ?paragraphData(paragraph),
        ],
        'totalParagraphs': owner.paragraphs.length,
        'tableIds': tableIds,
        'totalTables': owner.tableIds.length,
      });
    }
  }
  final pageStyles = snapshot.pageStyles == null
      ? null
      : <Map<String, Object?>>[];
  if (pageStyles != null) {
    if (snapshot.pageStyles!.length > 32) truncated = true;
    for (final style in snapshot.pageStyles!.take(32)) {
      final id = paragraphMetadata(style.id);
      if (id == null) continue;
      pageStyles.add({
        'id': id,
        'name': paragraphMetadata(style.name),
        'displayName': paragraphMetadata(style.displayName, max: 512),
        'inUse': style.inUse,
        'canEditGeometry': style.canEditGeometry,
        'width': style.width,
        'height': style.height,
        'leftMargin': style.leftMargin,
        'rightMargin': style.rightMargin,
        'topMargin': style.topMargin,
        'bottomMargin': style.bottomMargin,
        'landscape': style.landscape,
        'headerIsOn': style.headerIsOn,
        'footerIsOn': style.footerIsOn,
        'headerIsShared': style.headerIsShared,
        'footerIsShared': style.footerIsShared,
        'firstIsShared': style.firstIsShared,
        'pageLayout': paragraphMetadata(style.pageLayout, max: 32),
        'layoutSha256': paragraphMetadata(style.layoutSha256, max: 64),
        'regions': {
          for (final kind in const ['header', 'footer'])
            kind: {
              for (final variant in const ['default', 'left', 'right', 'first'])
                variant: paragraphMetadata(style.regions[kind]?[variant]),
            },
        },
      });
    }
  }
  final bodyOwnerId = snapshot.bodyOwnerId == null
      ? null
      : paragraphMetadata(snapshot.bodyOwnerId);
  WindowsOfficeParagraph? completeImageParagraph(String? owner, String? id) {
    if (owner == null ||
        id == null ||
        bodyOwnerId == null ||
        owner != bodyOwnerId)
      return null;
    final original = snapshot.paragraphs
        .where((paragraph) => paragraph.id == id)
        .singleOrNull;
    final visible = paragraphs
        .where((paragraph) => paragraph['id'] == id)
        .singleOrNull;
    final details = original?.textDetails;
    if (original == null ||
        visible == null ||
        details == null ||
        original.ownerId != owner ||
        visible['ownerId'] != owner ||
        details.truncated ||
        details.utf16Length != original.text.length ||
        details.textSha256 !=
            sha256.convert(utf8.encode(original.text)).toString() ||
        (visible['textDetails'] as Map)['truncated'] == true ||
        visible['text'] != original.text)
      return null;
    return original;
  }

  bool completeImageOffset(
    WindowsOfficeWordImage image,
    WindowsOfficeParagraph? paragraph,
  ) {
    final offset = image.offsetUtf16;
    if (paragraph == null || offset == null || offset > paragraph.text.length)
      return false;
    return offset == 0 ||
        offset == paragraph.text.length ||
        !(paragraph.text.codeUnitAt(offset - 1) >= 0xd800 &&
            paragraph.text.codeUnitAt(offset - 1) <= 0xdbff &&
            paragraph.text.codeUnitAt(offset) >= 0xdc00 &&
            paragraph.text.codeUnitAt(offset) <= 0xdfff);
  }

  final wordImages = snapshot.wordImages == null
      ? null
      : <Map<String, Object?>>[];
  if (wordImages != null) {
    if (snapshot.wordImages!.length > 100) truncated = true;
    for (final value in snapshot.wordImages!.take(100)) {
      final id = paragraphMetadata(value.id);
      final ownerId = paragraphMetadata(value.ownerId);
      final paragraphId = paragraphMetadata(value.paragraphId);
      final tableId = paragraphMetadata(value.tableId);
      final cell = paragraphMetadata(value.cell);
      final paragraph =
          value.paragraphId != null &&
          paragraphId != null &&
          value.tableId == null &&
          value.cell == null;
      final table =
          value.paragraphId == null && tableId != null && cell != null;
      if (id == null ||
          !paragraph && !table ||
          value.ownerId != null && ownerId == null) {
        truncated = true;
        continue;
      }
      final nativeParagraph = completeImageParagraph(ownerId, paragraphId);
      final editable = paragraph && completeImageOffset(value, nativeParagraph);
      wordImages.add({
        'id': id,
        'ownerId': ?ownerId,
        if (paragraph) 'paragraphId': paragraphId,
        if (table) ...{'tableId': tableId, 'cell': cell},
        'anchorType': paragraphMetadata(value.anchorType, max: 32),
        'width': value.width,
        'height': value.height,
        if (value.offsetUtf16 != null) 'offsetUtf16': value.offsetUtf16,
        'canMove': value.canMove && editable,
        'canDelete': value.canDelete && editable,
        'nativeGraphicSha256': paragraphMetadata(
          value.nativeGraphicSha256,
          max: 64,
        ),
        if (value.image != null) 'image': image(value.image!),
      });
    }
  }
  final wordImageTargets = snapshot.wordImageTargets == null
      ? null
      : <Map<String, Object?>>[];
  if (wordImageTargets != null) {
    if (snapshot.wordImageTargets!.length > 100) truncated = true;
    for (final value in snapshot.wordImageTargets!.take(100)) {
      final owner = paragraphMetadata(value.ownerId);
      final paragraph = paragraphMetadata(value.paragraphId);
      if (owner == null || paragraph == null) {
        truncated = true;
        continue;
      }
      final complete = completeImageParagraph(owner, paragraph) != null;
      if (!complete && (value.canAdd || value.canMoveHere)) truncated = true;
      wordImageTargets.add({
        'ownerId': owner,
        'paragraphId': paragraph,
        'canAdd': value.canAdd && complete,
        'canMoveHere': value.canMoveHere && complete,
      });
    }
  }
  return {
    'kind': snapshot.kind,
    'sourceSha256': snapshot.sourceSha256,
    if (snapshot.supportsHwpTableInsert) 'supportsHwpTableInsert': true,
    'paragraphs': paragraphs,
    'tables': tables,
    'slides': slides,
    'masters': ?masters,
    'layoutOptions': layoutOptions,
    'totalMasters': snapshot.masters?.length,
    'totalLayoutOptions': snapshot.layoutOptions.length,
    'blocks': ?blocks,
    'paragraphStyles': paragraphStyles,
    if (snapshot.bodyOwnerId != null) 'bodyOwnerId': bodyOwnerId,
    'wordOwners': ?wordOwners,
    'wordImages': ?wordImages,
    if (wordImages != null) 'totalWordImages': snapshot.wordImages!.length,
    'wordImageTargets': ?wordImageTargets,
    if (wordImageTargets != null)
      'totalWordImageTargets': snapshot.wordImageTargets!.length,
    'pageStyles': ?pageStyles,
    if (wordOwners != null) 'totalWordOwners': snapshot.wordOwners!.length,
    if (pageStyles != null) 'totalPageStyles': snapshot.pageStyles!.length,
    'totalBlocks': snapshot.blocks?.length,
    'totalParagraphStyles': snapshot.paragraphStyles.length,
    'totalParagraphs': snapshot.paragraphs.length,
    'totalTables': snapshot.tables.length,
    'totalSlides': snapshot.slides.length,
    'truncated': truncated,
  };
}
