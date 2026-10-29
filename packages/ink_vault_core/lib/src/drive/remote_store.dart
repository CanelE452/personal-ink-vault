import 'dart:typed_data';

import 'package:ink_vault_core/src/revision.dart';

enum RemoteFailure {
  authentication,
  retryable,
  missing,
  invalidCursor,
  permanent,
}

class RemoteException implements Exception {
  final RemoteFailure failure;
  final String message;
  final int? statusCode;
  final Duration? retryAfter;
  const RemoteException(
    this.failure,
    this.message, {
    this.statusCode,
    this.retryAfter,
  });
  factory RemoteException.authentication() => const RemoteException(
    RemoteFailure.authentication,
    'Drive authorization required',
  );
  factory RemoteException.retryable(String message) =>
      RemoteException(RemoteFailure.retryable, message);
  factory RemoteException.missing(String message) =>
      RemoteException(RemoteFailure.missing, message);
  factory RemoteException.invalidCursor() => const RemoteException(
    RemoteFailure.invalidCursor,
    'Drive change cursor expired',
  );
  @override
  String toString() => 'RemoteException(${failure.name}, $message)';
}

class RemoteChange {
  final String fileId;
  final bool removed;
  const RemoteChange(this.fileId, {this.removed = false});
}

class RemotePage {
  final List<RemoteChange> changes;
  final String? nextPageToken;
  final String? newStartPageToken;
  RemotePage(
    List<RemoteChange> changes, {
    this.nextPageToken,
    this.newStartPageToken,
  }) : changes = List.unmodifiable(changes);
}

abstract interface class RemoteStore {
  String get vaultId;
  String get remoteId;
  Future<String> generateId();
  Future<String?> findBlob(BlobRef ref);
  Future<void> putBlob(BlobRef ref, Uint8List bytes, String intentFileId);
  Future<void> publishRevision(RevisionRecord record, String intentFileId);
  Future<RevisionRecord> readManifest(String fileId);
  Future<Uint8List> readBlob(BlobRef ref);
  Future<String> startPageToken();
  Future<RemotePage> listManifests({String? pageToken});
  Future<RemotePage> readChanges(String pageToken);
  void close();
}
