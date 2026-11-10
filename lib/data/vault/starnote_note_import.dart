part of 'obsidian_vault_import.dart';

final class StarNoteImportResult {
  const new(this.directory, this.documents);

  final Directory directory;
  final int documents;
}

Future<StarNoteImportResult> importStarNoteVault({
  required Uint8List archive,
  required Directory vaultsDirectory,
  void Function()? requireCurrent,
}) async {
  requireCurrent?.call();
  if (archive.length > starNoteArchiveMaxBytes) {
    throw const FormatException('StarNote 파일은 최대 128 MiB까지 가져올 수 있습니다.');
  }
  final files = await _readStarNoteArchive(archive);
  await _checkStarNotePdfs(files, requireCurrent);

  final directory = await _publishImportedVault(
    vaultsDirectory: vaultsDirectory,
    kind: 'starnote',
    sourceName: files.length == 1 ? files.single.title : 'PDF',
    requireCurrent: requireCurrent,
    write: (repository) async {
      final workspace = WorkspaceStore(repository);
      for (final file in files) {
        requireCurrent?.call();
        await workspace.createWithSource(
          file.title,
          fileName: file.fileName,
          bytes: file.bytes,
          documentKind: VaultDocumentKind.pdf,
        );
      }
    },
  );
  return StarNoteImportResult(directory, files.length);
}

Future<List<StarNotePdfFile>> _readStarNoteArchive(Uint8List archive) =>
    Isolate.run(() => readStarNotePdfSource(archive));

Future<void> _checkStarNotePdfs(
  List<StarNotePdfFile> files,
  void Function()? requireCurrent,
) async {
  requireCurrent?.call();
  final scratch = await Directory.systemTemp.createTemp('piv-starnote-pdf-');
  final input = File(p.join(scratch.path, 'source.pdf'));
  try {
    for (final file in files) {
      requireCurrent?.call();
      await input.writeAsBytes(file.bytes);
      requireCurrent?.call();
      await _checkStarNotePdf(input.path, file.fileName, requireCurrent);
    }
  } finally {
    if (input.existsSync()) await input.delete();
    await scratch.delete();
  }
}

Future<void> _checkStarNotePdf(
  String path,
  String fileName,
  void Function()? requireCurrent,
) async {
  final unreadable = FormatException('StarNote의 내장 PDF를 열 수 없습니다. ($fileName)');
  try {
    final document = await PdfDocument.openFile(
      path,
      useProgressiveLoading: true,
    );
    try {
      if (document.pages.isEmpty || document.pages.length > 10000) {
        throw FormatException('내장 PDF는 1~10000쪽까지 가져올 수 있습니다. ($fileName)');
      }
      await document.loadPagesProgressively<void>(
        onPageLoadProgress: (_, _, _) {
          requireCurrent?.call();
          return true;
        },
      );
      if (document.pages.any(
        (page) =>
            !page.isLoaded ||
            !page.width.isFinite ||
            !page.height.isFinite ||
            page.width <= 0 ||
            page.height <= 0,
      )) {
        throw unreadable;
      }
    } finally {
      await document.dispose();
    }
  } on PdfException {
    throw unreadable;
  }
}
