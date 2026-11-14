import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';

const _noteId = '01345678-abcd-4012-89ab-000000000001';
const _otherNoteId = '01345678-abcd-4012-89ab-000000000002';
final _pdf = utf8.encode('%PDF-1.7\noriginal bytes\n%%EOF\n');

void main() {
  test('reads the source PDF and preserves its UTF-8 name and bytes', () {
    final archive = _zip(_note(_noteId, '수업 자료.PDF'));
    final before = Uint8List.fromList(archive);

    final file = readStarNotePdfSource(archive).single;

    expect(file.title, '수업 자료');
    expect(file.fileName, '수업 자료.PDF');
    expect(file.bytes, _pdf);
    expect(archive, before);
  });

  test('reads the version 2 collection in archive order', () {
    final archive = _collection({
      'renamed.note': _zip(_note(_noteId, '자료.pdf')),
      'B.note': _zip(_note(_otherNoteId, '다른 문서.pdf')),
    });

    final files = readStarNotePdfSource(archive);

    expect(files.map((file) => file.title), ['자료', '다른 문서']);
    expect(files.map((file) => file.bytes), everyElement(equals(_pdf)));
  });

  test('rejects unverified version, ambiguous metadata and layouts', () {
    final note = _zip(_note(_noteId, 'source.pdf'));
    for (final archive in [
      _collection({'source.note': note}, info: '{"version":3}'),
      _collection({'source.note': note}, info: '{"version":3,"version":2}'),
      _collection({'source.note': note}, info: '{"version":2.0}'),
      _collection({}),
      _collection({'folder/source.note': note}),
      _collection({
        'source.note': note,
        'userData/noteFolder/map': [1],
      }),
      _collection({
        'source.note': _collection({'nested.note': note}),
      }),
      _collection({'source.note': note, 'SOURCE.note': note}),
      _collection({'source.note': note, 'duplicate.note': note}),
    ]) {
      expect(() => readStarNotePdfSource(archive), throwsFormatException);
    }
  });

  test('requires one PDF and a StarNote marker at the same UUID root', () {
    final withoutMarker = _note(_noteId, 'source.pdf')
      ..remove('$_noteId/note/pb/note_info');
    final withTwoPdfs = _note(_noteId, 'source.pdf')
      ..['$_noteId/resource/content/second.pdf'] = _pdf;
    final nestedPdf = _note(_noteId, 'nested/source.pdf');
    final differentRoot = _note(_noteId, 'source.pdf')
      ..['$_otherNoteId/note/pb/note_info'] = [1];
    final invalidPdf = _note(_noteId, 'source.pdf')
      ..['$_noteId/resource/content/source.pdf'] = [1, 2, 3];
    final pathTraversal = _note(_noteId, 'source.pdf')
      ..['$_noteId/../elsewhere'] = [1];
    for (final files in [
      withoutMarker,
      withTwoPdfs,
      nestedPdf,
      differentRoot,
      invalidPdf,
      pathTraversal,
    ]) {
      expect(() => readStarNotePdfSource(_zip(files)), throwsFormatException);
    }
  });

  test('rejects corrupt bytes in a later note before returning the batch', () {
    final files = _note(_otherNoteId, 'second.pdf');
    final corrupt = _zip(files, store: true);
    final data = ByteData.sublistView(corrupt);
    final dataOffset =
        30 +
        data.getUint16(26, Endian.little) +
        data.getUint16(28, Endian.little);
    corrupt[dataOffset] ^= 1;

    final archive = _collection({
      'first.note': _zip(_note(_noteId, 'first.pdf')),
      'second.note': corrupt,
    });

    expect(() => readStarNotePdfSource(archive), throwsFormatException);
  });

  test('checks the declared PDF limit before inflating the file', () {
    final archive = _zip({
      ..._note(_noteId, 'source.pdf'),
      '$_noteId/resource/content/source.pdf': List<int>.filled(512, 65),
    });
    _setDeclaredMemberSize(archive, 0, 64 * 1024 * 1024 + 1);

    expect(
      () => readStarNotePdfSource(archive),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('64 MiB'),
        ),
      ),
    );
  });

  test('shares its expanded byte limit across nested ZIPs', () {
    final first = _zip({
      ..._note(_noteId, 'first.pdf'),
      '$_noteId/extra/pb/extra': List<int>.filled(4096, 65),
    });
    final second = _zip({
      ..._note(_otherNoteId, 'second.pdf'),
      '$_otherNoteId/extra/pb/a': List<int>.filled(512, 65),
      '$_otherNoteId/extra/pb/b': List<int>.filled(512, 66),
    });
    _setDeclaredMemberSize(second, 2, 128 * 1024 * 1024);
    _setDeclaredMemberSize(second, 3, 128 * 1024 * 1024 - 2048);

    expect(
      () => readStarNotePdfSource(
        _collection({'first.note': first, 'second.note': second}),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('압축 해제 크기 한도'),
        ),
      ),
    );
  });
}

Map<String, List<int>> _note(String id, String fileName) => {
  '$id/resource/content/$fileName': _pdf,
  '$id/note/pb/note_info': [8, 1],
};

Uint8List _collection(
  Map<String, List<int>> notes, {
  String info = '{"version":2}',
}) => _zip({
  ...notes,
  'userData/noteFolder/': [],
  'userData/': [],
  'extraInfo': utf8.encode(info),
});

Uint8List _zip(Map<String, List<int>> members, {bool store = false}) {
  final archive = Archive();
  for (final member in members.entries) {
    final file = member.key.endsWith('/')
        ? ArchiveFile.directory(member.key)
        : ArchiveFile.bytes(member.key, member.value);
    if (store) file.compression = CompressionType.none;
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void _setDeclaredMemberSize(Uint8List archive, int index, int size) {
  final data = ByteData.sublistView(archive);
  var central = data.getUint32(archive.length - 6, Endian.little);
  for (var i = 0; i < index; i++) {
    central +=
        46 +
        data.getUint16(central + 28, Endian.little) +
        data.getUint16(central + 30, Endian.little) +
        data.getUint16(central + 32, Endian.little);
  }
  final local = data.getUint32(central + 42, Endian.little);
  expect(data.getUint16(local + 8, Endian.little), 8);
  data.setUint32(local + 22, size, Endian.little);
  data.setUint32(central + 24, size, Endian.little);
}
