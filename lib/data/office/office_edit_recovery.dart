import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

enum OfficeEditRecoveryStage {
  started,
  nativeSaved,
  prepared,
  completed,
  unchanged,
  preserved,
}

class OfficeEditRecoveryEntry {
  const new _({
    required this.sessionId,
    required this.noteId,
    required this.sourceRevisionId,
    required this.workingPath,
    required this.stage,
    required this.resumableStage,
    required this.preparedRevisionId,
    required this.bindingId,
    required this.sourcePath,
    required this.pdfPath,
    required this.canResume,
  });

  final String sessionId;
  final String noteId;
  final String sourceRevisionId;
  final String workingPath;
  final OfficeEditRecoveryStage stage;
  final OfficeEditRecoveryStage resumableStage;
  final String? preparedRevisionId;
  final String? bindingId;
  final String? sourcePath;
  final String? pdfPath;
  final bool canResume;
}

class OfficeRecoveredEdit {
  const new _({
    required this.entry,
    required this.session,
    required this.nativeResult,
    required this.preparedEdition,
  });

  final OfficeEditRecoveryEntry entry;
  final OfficeEditSession session;
  final AndroidOfficeEditResult? nativeResult;
  final OfficePreparedEdition? preparedEdition;
}

/// Vault-local recovery state. Recording or reading a session never publishes
/// an edition and never deletes its input, native output, or retained payloads.
class OfficeEditRecoveryStore {
  new(this.repository) : _queue = _queues[repository] ??= _RecoveryQueue();

  final NoteRepository repository;
  final _RecoveryQueue _queue;
  static final _queues = Expando<_RecoveryQueue>();
  static const _maxPayload = 128 * 1024 * 1024;
  static const _maxReceipt = 1024 * 1024;

  String get _workspace => p.join(repository.root.path, '.workspace');
  String get _root => p.join(_workspace, 'office-recovery');
  String _folder(VaultNote note, String sessionId) =>
      p.join(_root, note.id, sessionId);
  File _receipt(VaultNote note, String sessionId) =>
      File(p.join(_folder(note, sessionId), 'receipt.json'));
  File _source(
    VaultNote note,
    String sessionId,
    OfficeRecoverySource session,
  ) => File(
    p.join(
      _folder(note, sessionId),
      'native',
      'edited${p.extension(session.originalFileName).toLowerCase()}',
    ),
  );
  File _pdf(VaultNote note, String sessionId) =>
      File(p.join(_folder(note, sessionId), 'native', 'preview.pdf'));
  File _editionMetadata(VaultNote note, String sessionId, String revisionId) =>
      File(
        p.join(
          _folder(note, sessionId),
          'prepared',
          revisionId,
          'edition.json',
        ),
      );

  Future<OfficeEditRecoveryEntry> start(
    OfficeEditSession session, {
    required String sessionId,
    required String workingPath,
  }) {
    final descriptor = _copyJson(session.toRecoveryDescriptor());
    final note = session.note;
    return _queue.run(() async {
      _validateIds(note, sessionId);
      final captured = await OfficeDocumentStore(repository)
          .resumeEditSession(note, descriptor: descriptor);
      await _safeFolders(note, sessionId, create: false);
      final receipt = _receipt(note, sessionId);
      if (FileSystemEntity.typeSync(receipt.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        final loaded = await _load(note, sessionId);
        if (!_sameJson(loaded.$1['session'], descriptor) ||
            !p.equals(loaded.$1['workingPath'] as String, workingPath))
          throw const FormatException(
            'The recovery session ID is already in use',
          );
        return _entry(note, sessionId, loaded.$1, loaded.$2);
      }
      if (!p.isAbsolute(workingPath))
        throw const FormatException('Expected an absolute Office working path');
      await _readFile(
        File(workingPath),
        hash: descriptor['originalSha256'] as String,
        length: captured.originalBytes.length,
      );
      final data = <String, dynamic>{
        'version': 1,
        'sessionId': sessionId,
        'workingPath': workingPath,
        'stage': OfficeEditRecoveryStage.started.name,
        'retainedStage': null,
        'session': descriptor,
        'native': null,
        'prepared': null,
        'bindingId': null,
        'completedRevisionId': null,
      };
      await _save(note, sessionId, data);
      final loaded = await _load(note, sessionId);
      return _entry(note, sessionId, loaded.$1, loaded.$2);
    });
  }

  Future<List<OfficeEditRecoveryEntry>> list(VaultNote note) => _queue.run(
    () async {
      _validateIds(note, null);
      await _safeFolders(note, null, create: false);
      final directory = Directory(p.join(_root, note.id));
      if (!directory.existsSync()) return const [];
      final entries = <OfficeEditRecoveryEntry>[];
      await for (final item in directory.list(followLinks: false)) {
        if (item is! Directory)
          throw const FormatException('Invalid Office recovery directory');
        final sessionId = p.basename(item.path);
        validateId(sessionId);
        await _safeFolders(note, sessionId, create: false);
        if (FileSystemEntity.typeSync(
              _receipt(note, sessionId).path,
              followLinks: false,
            ) ==
            FileSystemEntityType.notFound)
          continue;
        final loaded = await _load(note, sessionId);
        entries.add(await _entry(note, sessionId, loaded.$1, loaded.$2));
      }
      entries.sort((left, right) => left.sessionId.compareTo(right.sessionId));
      return List.unmodifiable(entries);
    },
  );

  Future<OfficeRecoveredEdit> read(
    VaultNote note,
    String sessionId, {
    void Function()? beforePublish,
  }) => _queue.run(() async {
    final loaded = await _load(note, sessionId);
    final data = loaded.$1;
    final source = loaded.$2;
    if (note.documentKind != VaultDocumentKind.office ||
        note.trashed ||
        note.deletionConflict)
      throw const FormatException(
        'The current note does not allow resuming an Office edit',
      );
    final session = await OfficeDocumentStore(repository)
        .resumeEditSession(note, descriptor: jsonObject(data['session']));
    AndroidOfficeEditResult? nativeResult;
    OfficePreparedEdition? prepared;
    if (data['native'] != null) {
      final native = jsonObject(data['native']);
      await _verifyNativeFiles(note, sessionId, source, native);
      nativeResult = AndroidOfficeEditResult(
        status: AndroidOfficeEditStatus.saved,
        sessionId: sessionId,
        inputSourceSha256: native['inputSourceSha256'] as String,
        engineVersion: native['engineVersion'] as String,
        sourcePath: _source(note, sessionId, source).path,
        pdfPath: _pdf(note, sessionId).path,
        sourceSha256: native['sourceSha256'] as String,
        pdfSha256: native['pdfSha256'] as String,
        pdfPageCount: native['pdfPageCount'] as int,
      );
    }
    if (data['prepared'] != null) {
      final files = await _preparedFiles(note, sessionId, data, source);
      prepared = await OfficeDocumentStore(repository).resumePreparedEdition(
        note,
        descriptor: jsonObject(data['prepared']),
        files: files,
        beforePublish: beforePublish,
      );
      if (_resumableStage(data) == OfficeEditRecoveryStage.completed)
        await _verifyPublished(note, data, source, files);
    }
    return OfficeRecoveredEdit._(
      entry: await _entry(note, sessionId, data, source),
      session: session,
      nativeResult: nativeResult,
      preparedEdition: prepared,
    );
  });

  Future<OfficeEditRecoveryEntry> recordNativeSaved(
    VaultNote note,
    String sessionId,
    AndroidOfficeEditResult result,
  ) => _queue.run(() async {
    final loaded = await _load(note, sessionId);
    final data = loaded.$1;
    final session = loaded.$2;
    final native = _nativeMetadata(
      result,
      sessionId,
      jsonObject(data['session']),
    );
    final sourcePath = result.sourcePath, pdfPath = result.pdfPath;
    if (sourcePath == null ||
        pdfPath == null ||
        !p.isAbsolute(sourcePath) ||
        !p.isAbsolute(pdfPath) ||
        p.equals(sourcePath, pdfPath) ||
        p.equals(sourcePath, data['workingPath'] as String) ||
        p.basename(sourcePath) !=
            'edited${p.extension(session.originalFileName).toLowerCase()}' ||
        p.basename(pdfPath) != 'preview.pdf')
      throw const FormatException('Invalid native Office output paths');
    final source = File(sourcePath), pdf = File(pdfPath);
    await _requireRegular(source);
    await _requireRegular(pdf);
    if (!p.equals(
      await source.parent.resolveSymbolicLinks(),
      await pdf.parent.resolveSymbolicLinks(),
    ))
      throw const FormatException(
        'Native Office outputs must share their directory',
      );
    final originalBytes = await _readFile(
      source,
      hash: native['sourceSha256'] as String,
    );
    final pdfBytes = await _readFile(pdf, hash: native['pdfSha256'] as String);
    native['sourceLength'] = originalBytes.length;
    native['pdfLength'] = pdfBytes.length;
    if (data['native'] != null) {
      if (!_sameJson(data['native'], native))
        throw const FormatException('The native Office snapshot is immutable');
      await _verifyNativeFiles(
        note,
        sessionId,
        session,
        jsonObject(data['native']),
      );
      return _entry(note, sessionId, data, session);
    }
    if (_resumableStage(data) != OfficeEditRecoveryStage.started)
      throw StateError(
        'The recovery session is not waiting for a native result',
      );
    await _safeFolders(
      note,
      sessionId,
      create: true,
      payloadDirectory: 'native',
    );
    await _savePayload(_source(note, sessionId, session), originalBytes);
    await _savePayload(_pdf(note, sessionId), pdfBytes);
    final next = {
      ...data,
      'native': native,
      'stage': data['stage'] == OfficeEditRecoveryStage.preserved.name
          ? OfficeEditRecoveryStage.preserved.name
          : OfficeEditRecoveryStage.nativeSaved.name,
      'retainedStage': data['stage'] == OfficeEditRecoveryStage.preserved.name
          ? OfficeEditRecoveryStage.nativeSaved.name
          : null,
    };
    await _save(note, sessionId, next);
    return _entry(note, sessionId, next, session);
  });

  Future<bool> completeIfIdentical(VaultNote note, String sessionId) =>
      _queue.run(() async {
        final (data, session) = await _load(note, sessionId);
        final stage = _resumableStage(data);
        if (stage == OfficeEditRecoveryStage.unchanged) return true;
        if (stage != OfficeEditRecoveryStage.nativeSaved ||
            note.documentKind != VaultDocumentKind.office ||
            note.trashed ||
            note.deletionConflict ||
            note.sourceEntityId != session.sourceEntityId) {
          return false;
        }
        final native = jsonObject(data['native']);
        if (native['sourceSha256'] != session.originalSha256 ||
            native['sourceLength'] != session.originalLength) {
          return false;
        }

        final documents = OfficeDocumentStore(repository);
        final original = await documents.readLatest(
          note,
          revisionId: session.sourceRevisionId,
        );
        final pdfHash = native['pdfSha256'] as String;
        final pdfLength = native['pdfLength'] as int;
        final variants = await documents.readPdfVariants(note, original);
        final match = variants.where((variant) {
          final pdf = variant.revision.blobs['preview.pdf']!;
          return variant.sourceRevisionId == session.sourceRevisionId &&
              pdf.hash == pdfHash &&
              pdf.length == pdfLength &&
              (variant.pageCount == null ||
                  variant.pageCount == native['pdfPageCount']);
        }).singleOrNull;
        if (match == null) return false;
        final pdf = await documents.readPdfVariantBytes(note, original, match);
        if (!_matches(pdf, pdfHash, pdfLength)) return false;
        await _verifyNativeFiles(note, sessionId, session, native);
        await _save(note, sessionId, {
          ...data,
          'stage': OfficeEditRecoveryStage.unchanged.name,
          'retainedStage': null,
        });
        return true;
      });

  Future<OfficeEditRecoveryEntry> recordPrepared(
    VaultNote note,
    String sessionId,
    OfficePreparedEdition prepared,
  ) {
    final descriptor = _copyJson(prepared.toRecoveryDescriptor());
    final files = prepared.copyRecoveryFiles();
    return _queue.run(() async {
      final loaded = await _load(note, sessionId);
      final data = loaded.$1;
      final session = loaded.$2;
      if (_resumableStage(data) == OfficeEditRecoveryStage.unchanged) {
        throw StateError('An unchanged Office result is already complete');
      }
      if (data['native'] == null)
        throw StateError(
          'Validate the native Office result before preparing publication',
        );
      _validatePreparedBinding(data, descriptor);
      await OfficeDocumentStore(repository)
          .resumePreparedEdition(note, descriptor: descriptor, files: files);
      final native = jsonObject(data['native']);
      await _verifyNativeFiles(note, sessionId, session, native);
      if (files.length != 3 ||
          !files.keys.toSet().containsAll({
            session.originalFileName,
            'preview.pdf',
            'edition.json',
          }) ||
          !_matches(
            files[session.originalFileName]!,
            native['sourceSha256'] as String,
            native['sourceLength'] as int,
          ) ||
          !_matches(
            files['preview.pdf']!,
            native['pdfSha256'] as String,
            native['pdfLength'] as int,
          ))
        throw const FormatException(
          'Prepared Office files differ from the native snapshot',
        );
      final metadata = jsonObject(
        jsonDecode(utf8.decode(files['edition.json']!)),
      );
      if (metadata['engineVersion'] != native['engineVersion'] ||
          metadata['pageCount'] != native['pdfPageCount'])
        throw const FormatException(
          'Prepared Office metadata differs from the native observation',
        );
      final binding = metadata['bindingId'];
      if (binding is! String)
        throw const FormatException('Missing prepared Office binding');
      validateId(binding);
      if (data['prepared'] != null) {
        if (!_sameJson(data['prepared'], descriptor) ||
            data['bindingId'] != binding)
          throw const FormatException(
            'The prepared Office identity is immutable',
          );
        return _entry(note, sessionId, data, session);
      }
      await _safeFolders(
        note,
        sessionId,
        create: true,
        payloadDirectory: 'prepared',
        preparedRevisionId: _preparedRecord(descriptor).revisionId,
      );
      // Original/PDF bytes already live in the immutable native snapshot. Only
      // edition.json is additional; its three logical files remain exact.
      await _savePayload(
        _editionMetadata(
          note,
          sessionId,
          _preparedRecord(descriptor).revisionId,
        ),
        files['edition.json']!,
      );
      final next = {
        ...data,
        'prepared': descriptor,
        'bindingId': binding,
        'stage': data['stage'] == OfficeEditRecoveryStage.preserved.name
            ? OfficeEditRecoveryStage.preserved.name
            : OfficeEditRecoveryStage.prepared.name,
        'retainedStage': data['stage'] == OfficeEditRecoveryStage.preserved.name
            ? OfficeEditRecoveryStage.prepared.name
            : null,
      };
      await _save(note, sessionId, next);
      return _entry(note, sessionId, next, session);
    });
  }

  Future<OfficeEditRecoveryEntry> complete(
    VaultNote note,
    String sessionId,
    OfficeEdition edition,
  ) => _queue.run(() async {
    final loaded = await _load(note, sessionId);
    final data = loaded.$1;
    final session = loaded.$2;
    if (data['prepared'] == null)
      throw StateError('No prepared Office publication is recorded');
    final planned = _preparedRecord(jsonObject(data['prepared']));
    if (!_sameJson(edition.revision.toJson(), planned.toJson()) ||
        edition.bindingId != data['bindingId'])
      throw const FormatException(
        'The completed Office edition is not the recorded publication',
      );
    final files = await _preparedFiles(note, sessionId, data, session);
    await _verifyPublished(note, data, session, files);
    final next = {
      ...data,
      'stage': OfficeEditRecoveryStage.completed.name,
      'retainedStage': null,
      'completedRevisionId': planned.revisionId,
    };
    await _save(note, sessionId, next);
    return _entry(note, sessionId, next, session);
  });

  Future<OfficeEditRecoveryEntry> preserve(VaultNote note, String sessionId) =>
      _queue.run(() async {
        final loaded = await _load(note, sessionId);
        final data = loaded.$1;
        final session = loaded.$2;
        final stage = _stage(data['stage']);
        if (stage == OfficeEditRecoveryStage.completed ||
            stage == OfficeEditRecoveryStage.unchanged ||
            stage == OfficeEditRecoveryStage.preserved)
          return _entry(note, sessionId, data, session);
        final next = {
          ...data,
          'stage': OfficeEditRecoveryStage.preserved.name,
          'retainedStage': stage.name,
        };
        await _save(note, sessionId, next);
        return _entry(note, sessionId, next, session);
      });

  Future<(Map<String, dynamic>, OfficeRecoverySource)> _load(
    VaultNote note,
    String sessionId,
  ) async {
    _validateIds(note, sessionId);
    await _safeFolders(note, sessionId, create: false);
    final data = jsonObject(
      jsonDecode(
        utf8.decode(
          await _readFile(_receipt(note, sessionId), limit: _maxReceipt),
        ),
      ),
    );
    _requireFields(data, const {
      'version',
      'sessionId',
      'workingPath',
      'stage',
      'retainedStage',
      'session',
      'native',
      'prepared',
      'bindingId',
      'completedRevisionId',
      'digest',
    });
    final digest = data['digest'];
    if (data['version'] is! int ||
        data['version'] != 1 ||
        data['sessionId'] != sessionId ||
        data['workingPath'] is! String ||
        !p.isAbsolute(data['workingPath'] as String) ||
        digest is! String ||
        digest != _receiptDigest(data))
      throw const FormatException('Invalid Office recovery receipt');
    final stage = _stage(data['stage']);
    if (stage == OfficeEditRecoveryStage.preserved) {
      final retained = _stage(data['retainedStage']);
      if (retained == OfficeEditRecoveryStage.preserved ||
          retained == OfficeEditRecoveryStage.completed ||
          retained == OfficeEditRecoveryStage.unchanged)
        throw const FormatException('Invalid preserved Office recovery stage');
    } else if (data['retainedStage'] != null) {
      throw const FormatException('Unexpected retained Office recovery stage');
    }
    final effective = _resumableStage(data);
    final hasNative = effective != OfficeEditRecoveryStage.started;
    final hasPrepared =
        effective == OfficeEditRecoveryStage.prepared ||
        effective == OfficeEditRecoveryStage.completed;
    if ((data['native'] != null) != hasNative ||
        (data['prepared'] != null) != hasPrepared ||
        (data['bindingId'] != null) != hasPrepared ||
        (data['completedRevisionId'] != null) !=
            (effective == OfficeEditRecoveryStage.completed))
      throw const FormatException('Incomplete Office recovery receipt');
    final descriptor = jsonObject(data['session']);
    final session = await OfficeDocumentStore(repository)
        .readRecoverySource(note, descriptor: descriptor);
    if (hasNative) {
      final native = jsonObject(data['native']);
      _validateNativeMetadata(native, descriptor);
      if (effective == OfficeEditRecoveryStage.unchanged &&
          (native['sourceSha256'] != session.originalSha256 ||
              native['sourceLength'] != session.originalLength)) {
        throw const FormatException('Invalid unchanged Office recovery result');
      }
    }
    if (hasPrepared) {
      _validatePreparedBinding(data, jsonObject(data['prepared']));
      if (data['bindingId'] is! String)
        throw const FormatException('Invalid Office PDF binding');
      validateId(data['bindingId'] as String);
      if (effective == OfficeEditRecoveryStage.completed &&
          data['completedRevisionId'] !=
              _preparedRecord(jsonObject(data['prepared'])).revisionId)
        throw const FormatException('Invalid completed Office revision');
    }
    return (data, session);
  }

  void _validatePreparedBinding(
    Map<String, dynamic> data,
    Map<String, dynamic> prepared,
  ) {
    final session = jsonObject(data['session']);
    final record = _preparedRecord(prepared);
    if (prepared['requireCurrentHeads'] != false ||
        prepared['noteRevisionId'] != session['noteRevisionId'] ||
        prepared['sourceRevisionId'] != session['sourceRevisionId'] ||
        record.entityId != session['sourceEntityId'] ||
        record.ownerNoteId != session['noteId'] ||
        !_sameJson(
          record.toJson()['parentRevisionIds'],
          session['parentRevisionIds'],
        ))
      throw const FormatException(
        'The Office recovery publication changed its captured policy or source',
      );
  }

  RevisionRecord _preparedRecord(Map<String, dynamic> descriptor) =>
      RevisionRecord.fromJson(
        jsonObject(jsonObject(descriptor['prepared'])['record']),
      );

  Map<String, dynamic> _nativeMetadata(
    AndroidOfficeEditResult result,
    String sessionId,
    Map<String, dynamic> session,
  ) {
    if (result.status != AndroidOfficeEditStatus.saved ||
        result.sessionId != sessionId)
      throw const FormatException(
        'The native Office result belongs to another session',
      );
    final native = <String, dynamic>{
      'engineVersion': result.engineVersion,
      'inputSourceSha256': result.inputSourceSha256,
      'sourceSha256': result.sourceSha256,
      'pdfSha256': result.pdfSha256,
      'pdfPageCount': result.pdfPageCount,
      'sourceLength': 1,
      'pdfLength': 1,
    };
    _validateNativeMetadata(native, session);
    return native;
  }

  void _validateNativeMetadata(
    Map<String, dynamic> native,
    Map<String, dynamic> session,
  ) {
    _requireFields(native, const {
      'engineVersion',
      'inputSourceSha256',
      'sourceSha256',
      'pdfSha256',
      'pdfPageCount',
      'sourceLength',
      'pdfLength',
    });
    if (native['engineVersion'] is! String ||
        (native['engineVersion'] as String).trim().isEmpty ||
        native['inputSourceSha256'] != session['originalSha256'] ||
        native['pdfPageCount'] is! int ||
        (native['pdfPageCount'] as int) < 1)
      throw const FormatException('Invalid native Office result binding');
    for (final key in ['inputSourceSha256', 'sourceSha256', 'pdfSha256']) {
      if (native[key] is! String)
        throw const FormatException('Missing native Office hash');
      validateHash(native[key] as String);
    }
    for (final key in ['sourceLength', 'pdfLength']) {
      if (native[key] is! int ||
          (native[key] as int) < 1 ||
          (native[key] as int) > _maxPayload)
        throw const FormatException('Invalid native Office payload length');
    }
  }

  Future<void> _verifyNativeFiles(
    VaultNote note,
    String sessionId,
    OfficeRecoverySource session,
    Map<String, dynamic> native,
  ) async {
    await _safeFolders(
      note,
      sessionId,
      create: false,
      payloadDirectory: 'native',
    );
    await _verifyFile(
      _source(note, sessionId, session),
      native['sourceSha256'] as String,
      native['sourceLength'] as int,
    );
    await _verifyFile(
      _pdf(note, sessionId),
      native['pdfSha256'] as String,
      native['pdfLength'] as int,
    );
  }

  Future<Map<String, Uint8List>> _preparedFiles(
    VaultNote note,
    String sessionId,
    Map<String, dynamic> data,
    OfficeRecoverySource session,
  ) async {
    final record = _preparedRecord(jsonObject(data['prepared']));
    await _safeFolders(
      note,
      sessionId,
      create: false,
      payloadDirectory: 'native',
    );
    await _safeFolders(
      note,
      sessionId,
      create: false,
      payloadDirectory: 'prepared',
      preparedRevisionId: record.revisionId,
    );
    final native = jsonObject(data['native']);
    final metadataRef = record.blobs['edition.json'];
    if (metadataRef == null)
      throw const FormatException('Missing prepared Office metadata');
    final files = {
      session.originalFileName: await _readFile(
        _source(note, sessionId, session),
        hash: native['sourceSha256'] as String,
        length: native['sourceLength'] as int,
      ),
      'preview.pdf': await _readFile(
        _pdf(note, sessionId),
        hash: native['pdfSha256'] as String,
        length: native['pdfLength'] as int,
      ),
      'edition.json': await _readFile(
        _editionMetadata(note, sessionId, record.revisionId),
        hash: metadataRef.hash,
        length: metadataRef.length,
        limit: _maxReceipt,
      ),
    };
    final metadata = jsonObject(
      jsonDecode(utf8.decode(files['edition.json']!)),
    );
    if (metadata['bindingId'] != data['bindingId'] ||
        metadata['engineVersion'] != native['engineVersion'] ||
        metadata['pageCount'] != native['pdfPageCount'])
      throw const FormatException(
        'The retained Office binding differs from its prepared metadata',
      );
    return files;
  }

  Future<void> _verifyPublished(
    VaultNote note,
    Map<String, dynamic> data,
    OfficeRecoverySource session,
    Map<String, Uint8List> files,
  ) async {
    final planned = _preparedRecord(jsonObject(data['prepared']));
    final manifest = File(
      p.join(repository.root.path, 'revisions', '${planned.revisionId}.json'),
    );
    final actual = RevisionRecord.fromJson(
      jsonObject(
        jsonDecode(utf8.decode(await _readFile(manifest, limit: _maxReceipt))),
      ),
    );
    if (!_sameJson(actual.toJson(), planned.toJson()))
      throw const FormatException(
        'The actual Office publication differs from its recovery plan',
      );
    final actualFiles = await repository.readFiles(actual);
    if (actualFiles.length != files.length ||
        files.entries.any((entry) {
          final bytes = actualFiles[entry.key];
          return bytes == null ||
              !_matches(
                bytes,
                sha256.convert(entry.value).toString(),
                entry.value.length,
              );
        }))
      throw const FormatException(
        'The actual Office publication has different payloads',
      );
    final edition = await OfficeDocumentStore(repository)
        .readLatest(note, revisionId: planned.revisionId);
    if (edition.bindingId != data['bindingId'] ||
        edition.originalFileName != session.originalFileName)
      throw const FormatException(
        'The actual Office publication has a different PDF binding',
      );
  }

  Future<OfficeEditRecoveryEntry> _entry(
    VaultNote note,
    String sessionId,
    Map<String, dynamic> data,
    OfficeRecoverySource session,
  ) async {
    var canResume = false;
    final stage = _stage(data['stage']);
    if (stage != OfficeEditRecoveryStage.completed &&
        stage != OfficeEditRecoveryStage.unchanged &&
        note.documentKind == VaultDocumentKind.office &&
        !note.trashed &&
        !note.deletionConflict &&
        note.sourceEntityId == session.sourceEntityId) {
      try {
        await OfficeDocumentStore(repository)
            .resumeEditSession(note, descriptor: jsonObject(data['session']));
        canResume = true;
      } on FormatException {
        // Historical files remain available when the current association changes.
      } on FileSystemException {
        // Reading a current note is not required to retain its old snapshot.
      } on StateError {
        // A current conflict cannot grant a resumable session.
      }
    }
    return OfficeEditRecoveryEntry._(
      sessionId: sessionId,
      noteId: note.id,
      sourceRevisionId: session.sourceRevisionId,
      workingPath: data['workingPath'] as String,
      stage: stage,
      resumableStage: _resumableStage(data),
      preparedRevisionId: data['prepared'] == null
          ? null
          : _preparedRecord(jsonObject(data['prepared'])).revisionId,
      bindingId: data['bindingId'] as String?,
      sourcePath: data['native'] == null
          ? null
          : _source(note, sessionId, session).path,
      pdfPath: data['native'] == null ? null : _pdf(note, sessionId).path,
      canResume: canResume,
    );
  }

  void _validateIds(VaultNote note, String? sessionId) {
    validateId(note.id);
    if (sessionId != null) validateId(sessionId);
    if (note.revision.vaultId != repository.vaultId)
      throw const FormatException('Foreign Office recovery note');
  }

  Future<void> _safeFolders(
    VaultNote note,
    String? sessionId, {
    required bool create,
    String? payloadDirectory,
    String? preparedRevisionId,
  }) async {
    _validateIds(note, sessionId);
    if (preparedRevisionId != null) validateId(preparedRevisionId);
    final paths = [
      repository.root.path,
      _workspace,
      _root,
      p.join(_root, note.id),
      if (sessionId != null) _folder(note, sessionId),
      if (sessionId != null && payloadDirectory != null)
        p.join(_folder(note, sessionId), payloadDirectory),
      if (sessionId != null && preparedRevisionId != null)
        p.join(_folder(note, sessionId), 'prepared', preparedRevisionId),
    ];
    for (final path in paths) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        if (!create) return;
        await Directory(path).create();
      } else if (type != FileSystemEntityType.directory) {
        throw const FormatException(
          'Office recovery directories must not be links or files',
        );
      }
    }
  }

  Future<void> _save(
    VaultNote note,
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    await _safeFolders(note, sessionId, create: true);
    final checked = {...data}..remove('digest');
    checked['digest'] = _receiptDigest(checked);
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(checked)));
    if (bytes.length > _maxReceipt)
      throw const FormatException('Office recovery receipt is too large');
    await _atomicWrite(_receipt(note, sessionId), bytes);
  }

  Future<void> _savePayload(File file, Uint8List bytes) async {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await _verifyFile(file, sha256.convert(bytes).toString(), bytes.length);
      return;
    }
    await _atomicWrite(file, bytes);
  }

  Future<void> _requireRegular(File file) async {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file)
      throw const FormatException(
        'Office recovery payload must be a regular file',
      );
  }

  Future<Uint8List> _readFile(
    File file, {
    String? hash,
    int? length,
    int limit = _maxPayload,
  }) async {
    await _requireRegular(file);
    final size = await file.length();
    if (size < 1 || size > limit || length != null && size != length)
      throw const FormatException('Office recovery payload length mismatch');
    final builder = BytesBuilder(copy: false);
    await for (final part in file.openRead(0, limit + 1)) {
      builder.add(part);
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty ||
        bytes.length > limit ||
        length != null && bytes.length != length ||
        hash != null && sha256.convert(bytes).toString() != hash)
      throw const FormatException(
        'Office recovery payload hash or length mismatch',
      );
    return bytes;
  }

  Future<void> _verifyFile(File file, String hash, int length) async {
    await _requireRegular(file);
    if (length < 1 || length > _maxPayload || await file.length() != length)
      throw const FormatException('Office recovery payload length mismatch');
    var read = 0;
    final digest = await sha256
        .bind(
          file.openRead(0, _maxPayload + 1).map((part) {
            read += part.length;
            if (read > _maxPayload)
              throw const FormatException(
                'Office recovery payload is too large',
              );
            return part;
          }),
        )
        .single;
    if (read != length || digest.toString() != hash)
      throw const FormatException('Office recovery payload hash mismatch');
  }

  Future<void> _atomicWrite(File target, Uint8List bytes) async {
    final type = FileSystemEntity.typeSync(target.path, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file)
      throw const FormatException('Invalid Office recovery target');
    final pending = File('${target.path}.${newId()}.pending');
    try {
      await pending.writeAsBytes(bytes, flush: true);
      await pending.rename(target.path);
    } catch (error, stack) {
      try {
        if (pending.existsSync()) await pending.delete();
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
  }
}

class _RecoveryQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

Map<String, dynamic> _copyJson(Map<String, Object?> value) =>
    jsonObject(jsonDecode(jsonEncode(value)));

bool _matches(Uint8List bytes, String hash, int length) =>
    bytes.length == length && sha256.convert(bytes).toString() == hash;

Object? _canonical(Object? value) {
  if (value is Map<String, dynamic>)
    return {
      for (final key in value.keys.toList()..sort())
        key: _canonical(value[key]),
    };
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _receiptDigest(Map<String, dynamic> value) {
  final copy = {...value}..remove('digest');
  return sha256.convert(utf8.encode(jsonEncode(_canonical(copy)))).toString();
}

bool _sameJson(Object? left, Object? right) =>
    jsonEncode(_canonical(left)) == jsonEncode(_canonical(right));

void _requireFields(Map<String, dynamic> value, Set<String> fields) {
  if (value.length != fields.length || !value.keys.every(fields.contains))
    throw const FormatException('Invalid Office recovery fields');
}

OfficeEditRecoveryStage _stage(Object? value) {
  for (final stage in OfficeEditRecoveryStage.values) {
    if (stage.name == value) return stage;
  }
  throw const FormatException('Invalid Office recovery stage');
}

OfficeEditRecoveryStage _resumableStage(Map<String, dynamic> value) => _stage(
  value['stage'] == OfficeEditRecoveryStage.preserved.name
      ? value['retainedStage']
      : value['stage'],
);
