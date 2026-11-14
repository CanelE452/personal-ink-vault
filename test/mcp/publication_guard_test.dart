import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));
Matcher _error(String code) =>
    isA<VaultMcpException>().having((error) => error.code, 'code', code);
Future<(Object?, Object?)> _capture(Future<Object?> pending) =>
    pending.then<(Object?, Object?)>(
      (result) => (result, null),
      onError: (Object error, StackTrace _) => (null, error),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in ['page', 'markdown']) {
    group('$kind MCP publication guard', () {
      late Directory temporary;
      late NoteRepository disk;
      late _PublicationRepository repository;
      late WorkspaceController controller;
      late VaultMcpService service;
      late VaultNote note;
      late RevisionRecord initial;
      late Map<String, Uint8List> original;
      late String entityId;
      late BlockPageDocument page;
      var active = true;
      var writable = true;
      late VaultMcpCallContext context;
      NoteRepository? replacement;

      Map<String, dynamic> arguments({String? requestId}) => {
        'noteId': note.id,
        'target': kind == 'page' ? 'body' : 'markdown',
        'expectedRevisionId': initial.revisionId,
        'requestId': requestId ?? newId(),
        'content': kind == 'page'
            ? page
                  .copyWith(
                    blocks: [
                      page.blocks.single.copyWith(text: 'Changed caption 😀'),
                    ],
                  )
                  .toJson()
            : 'Changed Markdown 😀',
      };
      Future<Object?> call(
        Map<String, dynamic> args, {
        VaultMcpCallContext? access,
      }) => service.call('update_document', args, context: access ?? context);
      Future<void> save(
        NoteSession session, {
        Map<String, List<String>>? expectedHeads,
        void Function()? requireWrite,
      }) => kind == 'page'
          ? session.saveInk(
              {
                ...original,
                'page.json': _bytes(jsonEncode(arguments()['content'])),
              },
              expectedHeads: expectedHeads,
              requireWrite: requireWrite,
            )
          : session.saveMarkdown(
              'Changed Markdown 😀',
              expectedHeads: expectedHeads,
              requireWrite: requireWrite,
            );
      Map<String, List<String>> observedHeads() => {
        note.id: [note.revision.revisionId],
        entityId: [initial.revisionId],
      };
      Future<Map<String, dynamic>> receipt(Map<String, dynamic> args) async =>
          jsonObject(
            jsonDecode(
              await File(
                p.join(
                  disk.root.path,
                  '.workspace',
                  'mcp',
                  'requests',
                  '${args['requestId']}.json',
                ),
              ).readAsString(),
            ),
          );
      Map<String, Uint8List> competingFiles() => kind == 'page'
          ? {
              ...original,
              'page.json': _bytes(
                jsonEncode(
                  page
                      .copyWith(
                        blocks: [
                          page.blocks.single.copyWith(text: 'Other writer'),
                        ],
                      )
                      .toJson(),
                ),
              ),
            }
          : {'summary.md': _bytes('Other writer')};

      setUp(() async {
        active = true;
        writable = true;
        replacement = null;
        temporary = await Directory.systemTemp.createTemp('mcp-publication-');
        disk = await NoteRepository.open(
          Directory(p.join(temporary.path, 'vault')),
          createFormatVersion: 2,
        );
        note = await WorkspaceStore(disk).create(
          'Document',
          documentKind: kind == 'page'
              ? VaultDocumentKind.page
              : VaultDocumentKind.markdown,
        );
        final session = await WorkspaceStore(disk).open(note);
        if (kind == 'page') {
          final asset = BlockPageMediaAsset.attachment(
            name: 'Source 😀.txt',
            bytes: _bytes('Immutable attachment 한글 😀'),
          );
          final block = BlockPageBlock.create(
            type: 'attachment',
            text: 'Original caption',
          );
          page = const BlockPageDocument.empty().copyWith(
            blocks: [block],
            media: {block.id: asset.reference},
          );
          await session.saveInk({
            'page.json': _bytes(jsonEncode(page.toJson())),
            asset.reference.path: asset.bytes,
            'future/opaque.bin': Uint8List.fromList([0, 255, 3]),
          });
        } else {
          await session.saveMarkdown('Original Markdown');
        }
        entityId = kind == 'page' ? note.inkEntityId : note.markdownEntityId;
        initial = (await disk.heads(entityId)).single;
        original = await disk.readFiles(initial);
        repository = _PublicationRepository(disk);
        controller = WorkspaceController(
          repository,
          directoryProvider: () async => temporary,
        );
        service = VaultMcpService(controller);
        context = VaultMcpCallContext(
          isActive: () => active,
          canWrite: () => writable,
        );
      });
      tearDown(() async {
        controller.dispose();
        await disk.close();
        await replacement?.close();
        await temporary.delete(recursive: true);
      });

      test('valid update and completed request replay publish once and preserve original files', () async {
        final args = arguments();
        final before = (await disk.revisions()).length;
        final result = jsonObject(await call(args));
        final saved = (await disk.heads(entityId)).single;
        expect(result['revisionId'], saved.revisionId);
        expect(saved.parentRevisionIds, [initial.revisionId]);
        expect((await disk.revisions()).length, before + 1);
        expect(await disk.readFiles(initial), original);
        final files = await disk.readFiles(saved);
        if (kind == 'page') {
          expect(
            BlockPageDocument.fromJson(
              jsonObject(jsonDecode(utf8.decode(files['page.json']!))),
            ).blocks.single.text,
            'Changed caption 😀',
          );
          for (final entry in original.entries) {
            if (entry.key != 'page.json') expect(files[entry.key], entry.value);
          }
        } else {
          expect(utf8.decode(files['summary.md']!), 'Changed Markdown 😀');
        }
        expect(await call(args), result);
        expect((await disk.revisions()).length, before + 1);
        expect((await receipt(args))['state'], 'completed');
      });

      for (final race in [
        'permission',
        'repository',
        'bodyHead',
        'metadataHead',
      ]) {
        test(
          '$race transition after observation prevents publication and completed receipt',
          () async {
            final args = arguments();
            final gate = repository.pauseNext(entityId);
            final completion = _capture(call(args));
            RevisionRecord? winner;
            final before = (await disk.revisions()).length;
            try {
              await gate.entered.future.timeout(const Duration(seconds: 5));
              if (race == 'permission') {
                writable = false;
              } else if (race == 'repository') {
                replacement = await NoteRepository.open(
                  Directory(p.join(temporary.path, 'replacement')),
                  createFormatVersion: 2,
                );
                // Models the service's captured repository becoming stale at an
                // asynchronous boundary; the original disk remains open.
                controller.repository = replacement!;
              } else if (race == 'bodyHead') {
                winner = await disk.commit(
                  entityId: entityId,
                  kind: kind == 'page' ? EntityKind.ink : EntityKind.markdown,
                  ownerNoteId: note.id,
                  files: competingFiles(),
                  parentRevisionIds: [initial.revisionId],
                );
              } else {
                await disk.commit(
                  entityId: note.id,
                  kind: EntityKind.metadata,
                  files: {
                    'note.json': _bytes(
                      jsonEncode({
                        ...note.json,
                        'title': 'Metadata changed during save',
                      }),
                    ),
                  },
                  parentRevisionIds: [note.revision.revisionId],
                );
              }
            } finally {
              gate.release.complete();
            }
            final (result, failure) = await completion;
            expect(result, isNull);
            expect(
              failure,
              _error(switch (race) {
                'permission' => 'read_only',
                'repository' => 'vault_changed',
                _ => 'revision_conflict',
              }),
            );
            expect(
              (await disk.heads(entityId)).map((record) => record.revisionId),
              [winner?.revisionId ?? initial.revisionId],
            );
            expect(
              (await disk.revisions()).length,
              before + (race == 'bodyHead' || race == 'metadataHead' ? 1 : 0),
            );
            expect(await disk.readFiles(initial), original);
            expect((await receipt(args))['state'], 'started');
            writable = true;
            controller.repository = repository;
            await expectLater(
              call(args),
              throwsA(_error('operation_state_unknown')),
            );
            expect(
              (await disk.revisions()).length,
              before + (race == 'bodyHead' || race == 'metadataHead' ? 1 : 0),
            );
          },
        );
      }

      test('write permission is checked again immediately before the final manifest rename', () async {
        var sawPreparedManifest = false;
        final guarded = VaultMcpCallContext(
          isActive: () => true,
          canWrite: () {
            if (Directory(p.join(disk.root.path, 'revisions'))
                .listSync()
                .any((file) => file.path.endsWith('.tmp'))) {
              sawPreparedManifest = true;
              writable = false;
            }
            return writable;
          },
        );
        final args = arguments();
        final before = (await disk.revisions()).length;
        final (result, failure) = await _capture(call(args, access: guarded));
        expect(sawPreparedManifest, true);
        expect(result, isNull);
        expect(failure, _error('read_only'));
        expect(
          (await disk.heads(entityId)).single.revisionId,
          initial.revisionId,
        );
        expect((await disk.revisions()).length, before);
        expect(await disk.readFiles(initial), original);
        expect((await receipt(args))['state'], 'started');
      });

      test('a callback without observed heads is rejected instead of silently losing the final guard', () async {
        final session = await WorkspaceStore(repository).open(note);
        final before = (await disk.revisions()).length;
        await expectLater(save(session, requireWrite: () {}), throwsStateError);
        expect((await disk.revisions()).length, before);
        expect(
          (await disk.heads(entityId)).single.revisionId,
          initial.revisionId,
        );
      });

      test('a pending guarded save retains its original context and also checks the retry context', () async {
        final session = await WorkspaceStore(repository).open(note);
        var originalWritable = true;
        var retryWritable = true;
        final originalContext = VaultMcpCallContext(
          isActive: () => true,
          canWrite: () => originalWritable,
        );
        final retryContext = VaultMcpCallContext(
          isActive: () => true,
          canWrite: () => retryWritable,
        );
        final before = (await disk.revisions()).length;
        final gate = repository.pauseNext(entityId);
        final first = _capture(
          save(
            session,
            expectedHeads: observedHeads(),
            requireWrite: () => originalContext.requireActive(write: true),
          ).then<Object?>((_) => null),
        );
        try {
          await gate.entered.future.timeout(const Duration(seconds: 5));
          originalWritable = false;
        } finally {
          gate.release.complete();
        }
        expect((await first).$2, _error('read_only'));
        Future<void> retry() => save(
          session,
          expectedHeads: observedHeads(),
          requireWrite: () => retryContext.requireActive(write: true),
        );
        await expectLater(retry(), throwsA(_error('read_only')));
        expect((await disk.revisions()).length, before);
        originalWritable = true;
        retryWritable = false;
        await expectLater(retry(), throwsA(_error('read_only')));
        expect((await disk.revisions()).length, before);
        retryWritable = true;
        await retry();
        final head = (await disk.heads(entityId)).single;
        expect((await disk.revisions()).length, before + 1);
        expect(kind == 'page' ? session.inkParents : session.markdownParents, [
          head.revisionId,
        ]);
        expect(await disk.readFiles(initial), original);
      });

      test('a lost guarded save response acknowledges the same published revision in the correct target', () async {
        final session = await WorkspaceStore(repository).open(note);
        final otherParents = List<String>.of(
          kind == 'page' ? session.markdownParents : session.inkParents,
        );
        final before = (await disk.revisions()).length;
        repository.loseNextResponseFor = entityId;
        Future<void> write() => save(
          session,
          expectedHeads: observedHeads(),
          requireWrite: () => context.requireActive(write: true),
        );
        await expectLater(write(), throwsStateError);
        final published = (await disk.heads(entityId)).single;
        expect((await disk.revisions()).length, before + 1);
        await write();
        expect(kind == 'page' ? session.inkParents : session.markdownParents, [
          published.revisionId,
        ]);
        expect(
          kind == 'page' ? session.markdownParents : session.inkParents,
          otherParents,
        );
        expect((await disk.revisions()).length, before + 1);
        expect(
          (await disk.heads(entityId)).single.revisionId,
          published.revisionId,
        );
        expect(await disk.readFiles(initial), original);
      });

      test('a concurrent same request cannot replace the original revoked publication context', () async {
        var originalWritable = true;
        final originalContext = VaultMcpCallContext(
          isActive: () => true,
          canWrite: () => originalWritable,
        );
        final args = arguments();
        final before = (await disk.revisions()).length;
        final gate = repository.pauseNext(entityId);
        final first = _capture(call(args, access: originalContext));
        Future<(Object?, Object?)>? second;
        try {
          await gate.entered.future.timeout(const Duration(seconds: 5));
          originalWritable = false;
          second = _capture(call(args));
        } finally {
          gate.release.complete();
        }
        final (firstResult, firstError) = await first;
        final (secondResult, secondError) = await second;
        expect(firstResult, isNull);
        expect(secondResult, isNull);
        expect(firstError, _error('read_only'));
        expect(secondError, _error('read_only'));
        expect(
          (await disk.heads(entityId)).single.revisionId,
          initial.revisionId,
        );
        expect((await disk.revisions()).length, before);
        expect((await receipt(args))['state'], 'started');
        await expectLater(
          call(args),
          throwsA(_error('operation_state_unknown')),
        );
        final fresh = jsonObject(await call(arguments()));
        expect(
          (await disk.heads(entityId)).single.revisionId,
          fresh['revisionId'],
        );
        expect((await disk.revisions()).length, before + 1);
      });
    });
  }
}

class _PublicationGate {
  final entered = Completer<void>();
  final release = Completer<void>();
}

class _PublicationRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  String? loseNextResponseFor;
  RevisionRecord _respond(RevisionRecord record) {
    if (loseNextResponseFor == record.entityId) {
      loseNextResponseFor = null;
      throw StateError('Published, response lost');
    }
    return record;
  }

  (String, _PublicationGate)? _next;
  _PublicationGate pauseNext(String entityId) {
    final gate = _PublicationGate();
    _next = (entityId, gate);
    return gate;
  }

  Future<void> _pause(PreparedCommit prepared) async {
    final next = _next;
    if (next == null || next.$1 != prepared.record.entityId) return;
    _next = null;
    next.$2.entered.complete();
    await next.$2.release.future;
  }

  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  Stream<void> get changes => inner.changes;
  @override
  List<String> get integrityIssues => inner.integrityIssues;
  @override
  int get pendingRevisionCount => inner.pendingRevisionCount;
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) =>
      inner.readFiles(record);
  @override
  Future<Uint8List> readBlob(String hash) => inner.readBlob(hash);
  @override
  PreparedCommit prepareCommit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) => inner.prepareCommit(
    entityId: entityId,
    kind: kind,
    files: files,
    parentRevisionIds: parentRevisionIds,
    ownerNoteId: ownerNoteId,
    deleted: deleted,
    baseRefs: baseRefs,
  );
  @override
  Future<RevisionRecord> commitPrepared(PreparedCommit prepared) async {
    await _pause(prepared);
    return _respond(await inner.commitPrepared(prepared));
  }

  @override
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) async {
    await _pause(prepared);
    return _respond(
      await inner.commitPreparedIfHeads(
        prepared,
        expectedHeads: expectedHeads,
        expectedRevisionIds: expectedRevisionIds,
        beforePublish: beforePublish,
        allowHistoricalParents: allowHistoricalParents,
      ),
    );
  }

  @override
  Future<void> close() => inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
