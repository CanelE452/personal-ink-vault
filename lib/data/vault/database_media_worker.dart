import 'dart:isolate';
import 'dart:typed_data';

import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/workspace_database.dart';

Future<DatabaseMediaSnapshot> decodeDatabaseMediaInWorker(
  Map<String, Uint8List> files,
) => Isolate.run(() => DatabaseMediaSnapshot.fromFiles(files));

Future<DatabaseMediaSnapshot> prepareDatabaseMediaInWorker(
  WorkspaceDatabase database, {
  required Map<String, Uint8List> existingFiles,
  required Map<String, Uint8List> addedFiles,
}) => Isolate.run(
  () => DatabaseMediaSnapshot.prepare(
    database,
    existingFiles: existingFiles,
    addedFiles: addedFiles,
  ),
);
