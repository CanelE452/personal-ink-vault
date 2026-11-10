import 'dart:isolate';
import 'dart:typed_data';

import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';

Future<BlockPageMediaSnapshot> decodeBlockPageMediaInWorker(
  Map<String, Uint8List> files,
) => Isolate.run(() => BlockPageMediaSnapshot.fromFiles(files));

Future<BlockPageMediaSnapshot> prepareBlockPageMediaInWorker(
  BlockPageDocument document, {
  required Map<String, Uint8List> existingFiles,
  required Map<String, Uint8List> addedFiles,
}) => Isolate.run(
  () => BlockPageMediaSnapshot.prepare(
    document,
    existingFiles: existingFiles,
    addedFiles: addedFiles,
  ),
);

Future<void> verifyBlockPageMediaBytes(BlockPageMedia media, Uint8List bytes) =>
    Isolate.run(() => media.verifyBytes(bytes));

Future<BlockPageMediaAsset> createBlockPageMediaAssetInWorker({
  required String name,
  required Uint8List bytes,
  required bool image,
}) => Isolate.run(
  () => image
      ? BlockPageMediaAsset.image(name: name, bytes: bytes)
      : BlockPageMediaAsset.attachment(name: name, bytes: bytes),
);
