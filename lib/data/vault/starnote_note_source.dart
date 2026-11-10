part of 'obsidian_vault_source.dart';

const starNoteArchiveMaxBytes = obsidianVaultZipMaxBytes;
const _starNoteMaxNotes = 128;
const _starNoteMaxExpandedBytes = 256 * 1024 * 1024;
const _starNoteMaxVersionBytes = 1024;

final _starNoteId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _starNoteCollectionV2 = RegExp(
  r'^[ \t\r\n]*\{[ \t\r\n]*"version"[ \t\r\n]*:[ \t\r\n]*2[ \t\r\n]*\}[ \t\r\n]*$',
);

final class StarNotePdfFile {
  const new _(this.title, this.fileName, this.bytes);

  final String title;
  final String fileName;
  final Uint8List bytes;
}

/// Reads the original PDFs from the standalone and version 2 collection
/// layouts observed in StarNote 1.5.4. The caller validates PDF contents.
List<StarNotePdfFile> readStarNotePdfSource(Uint8List archive) {
  if (archive.length > starNoteArchiveMaxBytes) {
    throw const FormatException('StarNote 파일은 128 MiB까지 가져올 수 있습니다.');
  }
  final budget = _StarNoteZipBudget();
  final members = budget.members(archive);
  final version = members
      .where(
        (member) =>
            !member.directory &&
            member.path.length == 1 &&
            member.path.first == 'extraInfo',
      )
      .singleOrNull;
  if (version == null) {
    return List.unmodifiable([_readStarNotePdf(archive, members, budget).$2]);
  }
  if (version.size > _starNoteMaxVersionBytes ||
      !_starNoteCollectionV2.hasMatch(
        utf8.decode(version.read(archive, true)!),
      )) {
    throw const FormatException('지원하지 않는 StarNote 묶음 버전입니다.');
  }

  final notes = <_ZipMember>[];
  final names = <String>{};
  for (final member in members) {
    if (member == version) continue;
    final name = member.path.join('/');
    if (member.directory &&
        (name == 'userData' || name == 'userData/noteFolder')) {
      member.read(archive, false);
      continue;
    }
    if (member.directory ||
        member.path.length != 1 ||
        name.length <= 5 ||
        !name.toLowerCase().endsWith('.note') ||
        !names.add(name.toLowerCase())) {
      _unsupportedStarNote();
    }
    notes.add(member);
  }
  if (notes.isEmpty || notes.length > _starNoteMaxNotes) {
    throw const FormatException('StarNote 묶음은 노트 1~128개를 지원합니다.');
  }

  final ids = <String>{};
  final files = <StarNotePdfFile>[];
  for (final note in notes) {
    final bytes = note.read(archive, true)!;
    final (id, file) = _readStarNotePdf(bytes, budget.members(bytes), budget);
    if (!ids.add(id)) _unsupportedStarNote();
    files.add(file);
  }
  return List.unmodifiable(files);
}

(String, StarNotePdfFile) _readStarNotePdf(
  Uint8List archive,
  List<_ZipMember> members,
  _StarNoteZipBudget budget,
) {
  if (members.isEmpty) _unsupportedStarNote();
  final id = members.first.path.first;
  if (!_starNoteId.hasMatch(id)) _unsupportedStarNote();

  var hasNoteInfo = false;
  _ZipMember? pdf;
  for (final member in members) {
    final path = member.path;
    if (path.first != id || (!member.directory && path.length == 1)) {
      _unsupportedStarNote();
    }
    if (member.directory || path.length < 4) continue;
    if (path.length == 4 &&
        path[1] == 'note' &&
        path[2] == 'pb' &&
        path[3] == 'note_info' &&
        member.size > 0) {
      hasNoteInfo = true;
    }
    if (path[1] == 'resource' &&
        path[2] == 'content' &&
        path.last.toLowerCase().endsWith('.pdf')) {
      if (path.length != 4 || pdf != null) _unsupportedStarNote();
      pdf = member;
    }
  }
  if (!hasNoteInfo || pdf == null) _unsupportedStarNote();

  final fileName = pdf.path.last;
  final title = fileName.substring(0, fileName.length - 4).trim();
  if (title.isEmpty) _unsupportedStarNote();
  budget.addPdf(pdf.size);
  final bytes = pdf.read(archive, true)!;
  if (bytes.length < 8 ||
      ascii.decode(bytes.sublist(0, 5), allowInvalid: true) != '%PDF-') {
    throw const FormatException('StarNote의 내장 PDF가 손상되었습니다.');
  }
  for (final member in members) {
    if (member != pdf) member.read(archive, false);
  }
  return (id.toLowerCase(), StarNotePdfFile._(title, fileName, bytes));
}

final class _StarNoteZipBudget {
  var _entries = 0;
  var _expandedBytes = 0;
  var _pdfBytes = 0;

  List<_ZipMember> members(Uint8List archive) {
    final members = _zipMembers(archive);
    _entries += members.length;
    if (_entries > _maxEntries) _tooManyEntries();
    for (final member in members) {
      _expandedBytes += member.size;
      if (member.size > starNoteArchiveMaxBytes ||
          _expandedBytes > _starNoteMaxExpandedBytes) {
        throw const FormatException('StarNote 파일의 압축 해제 크기 한도를 넘었습니다.');
      }
    }
    return members;
  }

  void addPdf(int size) {
    if (size > _maxAttachmentBytes) {
      throw const FormatException('StarNote 내장 PDF 하나는 64 MiB까지 지원합니다.');
    }
    _pdfBytes += size;
    if (_pdfBytes > _maxAllAttachmentBytes) {
      throw const FormatException('StarNote 내장 PDF는 총 192 MiB까지 지원합니다.');
    }
  }
}

Never _unsupportedStarNote() =>
    throw const FormatException('지원하지 않는 StarNote 파일 구조입니다.');
