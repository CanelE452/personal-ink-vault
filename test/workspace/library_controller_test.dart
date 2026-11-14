import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  late Directory temp;
  late WorkspaceController controller;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('library-controller-');
    controller = WorkspaceController(
      await NoteRepository.open(
        Directory('${temp.path}/v2'),
        createFormatVersion: 2,
      ),
    );
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });

  test(
    'Markdown creates in the current folder without a blank ink snapshot',
    () async {
      final folder = await controller.createFolder('Research');
      await controller.openFolder(folder.id);
      final note = await controller.createNote(
        'Ideas',
        documentKind: VaultDocumentKind.markdown,
      );
      expect(note.folderId, folder.id);
      expect(note.documentKind, VaultDocumentKind.markdown);
      expect(await controller.repository.heads(note.inkEntityId), isEmpty);
      controller.editMarkdown('# Persisted ideas');
      await controller.flush();
      await controller.closeNote(session: controller.activeSession!);
      expect(controller.currentFolderId, folder.id);
      expect(controller.folders.single.id, folder.id);
      await controller.openNote((await controller.store.list()).single);
      expect(controller.markdown, '# Persisted ideas');
    },
  );

  test('opening a document selects its folder and deleted folders close clean sessions', () async {
    final folder = await controller.createFolder('Lectures');
    final note = await controller.store.create(
      'Paper',
      folderId: folder.id,
      documentKind: VaultDocumentKind.markdown,
    );
    await controller.openNote(note);
    expect(controller.currentFolderId, folder.id);
    await controller.library.setDeleted(folder, true);
    await controller.refresh();
    expect(controller.activeSession, isNull);
    expect(controller.notes, isEmpty);
    expect(controller.currentFolderId, isNull);
  });

  test('v1 is cloned to a separate v2 vault with complete history before selection', () async {
    final root = Directory('${temp.path}/original');
    final original = await NoteRepository.open(root);
    final store = WorkspaceStore(original);
    final note = await store.create('Original');
    await store.rename(note, 'Renamed');
    final before = await original.revisions();
    final vaultId = original.vaultId;
    await original.close();
    final migrated = await WorkspaceController.openLibrary(root);
    try {
      expect(migrated.repository.formatVersion, 2);
      expect(migrated.repository.root.path, isNot(root.path));
      expect(migrated.repository.vaultId, isNot(vaultId));
      expect(
        (await migrated.repository.revisions())
            .map((r) => r.revisionId)
            .toSet(),
        before.map((r) => r.revisionId).toSet(),
      );
      expect(migrated.notes.single.title, 'Renamed');
      final untouched = await NoteRepository.open(root);
      expect(untouched.formatVersion, 1);
      expect(untouched.vaultId, vaultId);
      expect(await untouched.revisions(), hasLength(before.length));
      await untouched.close();
    } finally {
      migrated.dispose();
      await migrated.repository.close();
    }
  });

  test('startup keeps the selected v1 vault that is bound to Drive', () async {
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _SupportPath(temp.path);
    addTearDown(() => PathProviderPlatform.instance = previousPaths);
    final original = await NoteRepository.open(
      Directory('${temp.path}/vaults/legacy'),
    );
    final note = await WorkspaceStore(original).create('Legacy lecture');
    final root = original.root.path;
    final vaultId = original.vaultId;
    await original.close();
    final selection = File('${temp.path}/vault-selection.json');
    final selected = jsonEncode({'root': root});
    await selection.writeAsString(selected);
    final settingsDirectory = Directory('${temp.path}/drive');
    await (DriveConnectionSettings()
          ..folderId = 'test-drive-folder'
          ..vaultId = vaultId
          ..rootPath = root)
        .save(settingsDirectory);
    final settings = File('${settingsDirectory.path}/connection.json');
    final binding = await settings.readAsString();

    final reopened = await WorkspaceController.openDefault(
      loadNative: () => null,
    );
    try {
      expect(reopened.repository.formatVersion, 1);
      expect(reopened.repository.root.path, root);
      expect(reopened.repository.vaultId, vaultId);
      expect(reopened.notes.single.id, note.id);
      expect(await selection.readAsString(), selected);
      expect(await settings.readAsString(), binding);
    } finally {
      reopened.dispose();
      await reopened.repository.close();
    }
  });

  test('opening a v1 PDF vault exceeding the portable backup cap preserves the original', () async {
    final root = Directory('${temp.path}/large-original');
    final original = await NoteRepository.open(root);
    final note = await WorkspaceStore(original).create('Large lecture PDF');
    final vaultId = original.vaultId;
    await original.close();
    final payload = File('${root.path}/lecture.seed');
    final output = await payload.open(mode: FileMode.write);
    final chunk = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 37);
    try {
      for (var i = 0; i < 100; i++) {
        await output.writeFrom(chunk);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    final hash = (await sha256.bind(payload.openRead()).single).toString();
    await payload.rename('${root.path}/blobs/$hash');
    final revision = RevisionRecord(
      vaultId: vaultId,
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      revisionId: newId(),
      parentRevisionIds: [],
      deviceId: original.deviceId,
      ownerNoteId: note.id,
      blobs: {'original.pdf': BlobRef(hash: hash, length: 100 * 1024 * 1024)},
    );
    await File('${root.path}/revisions/${revision.revisionId}.json')
        .writeAsString(jsonEncode(revision.toJson()), flush: true);
    final migrated = await WorkspaceController.openLibrary(root);
    try {
      expect(migrated.repository.formatVersion, 2);
      expect(migrated.repository.vaultId, isNot(vaultId));
      expect(migrated.repository.deviceId, isNot(original.deviceId));
      expect(migrated.notes.single.id, note.id);
      expect(migrated.notes.single.title, 'Large lecture PDF');
      final copied = (await migrated.repository.heads(note.inkEntityId)).single;
      expect(copied.revisionId, revision.revisionId);
      final copiedFile = File('${migrated.repository.root.path}/blobs/$hash');
      expect(await copiedFile.length(), 100 * 1024 * 1024);
      expect(
        (await sha256.bind(copiedFile.openRead()).single).toString(),
        hash,
      );
      final source = await NoteRepository.open(root);
      try {
        expect(source.formatVersion, 1);
        expect(source.vaultId, vaultId);
        expect(
          (await source.heads(note.inkEntityId)).single.toJson(),
          revision.toJson(),
        );
        final sourceFile = File('${root.path}/blobs/$hash');
        expect(
          (await sha256.bind(sourceFile.openRead()).single).toString(),
          hash,
        );
      } finally {
        await source.close();
      }
    } finally {
      migrated.dispose();
      await migrated.repository.close();
    }
  });
}

final class _SupportPath extends PathProviderPlatform {
  new(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
