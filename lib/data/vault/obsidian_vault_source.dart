import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart'
    show InputMemoryStream, ZipFileHeader, getCrc32;
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/notion_export_csv.dart' show notionCsvMaxBytes;
import 'package:yaml/yaml.dart';

part 'starnote_note_source.dart';

const obsidianVaultZipMaxBytes = 128 * 1024 * 1024;
const _maxEntries = 10000;
const _maxDepth = 64;
const _maxNoteBytes = 8 * 1024 * 1024;
const _maxMarkdownBytes = 128 * 1024 * 1024;
const _maxCanvasBytes = 8 * 1024 * 1024;
const _maxAttachmentBytes = 64 * 1024 * 1024;
const _maxAllAttachmentBytes = 192 * 1024 * 1024;
const _maxExpandedZipBytes = 512 * 1024 * 1024;
const _maxBookmarkBytes = 256 * 1024;
const _maxTemplateSettingsBytes = 16 * 1024;

typedef _SettingSource = ({Uint8List? bytes, bool unreadable});
const _noSetting = (bytes: null, unreadable: false);
const _unreadableSetting = (bytes: null, unreadable: true);

typedef ObsidianTemplateSourceSettings = ({
  List<String> folderPath,
  String? dateFormat,
  String? timeFormat,
});

final _unsafeSegment = RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f-\x9f]');
final _controlCharacters = RegExp(r'[\x00-\x1f\x7f-\x9f]');
final _invalidTemplateText = RegExp(
  r'[\x00-\x1f\x7f-\x9f\ud800-\udfff]',
  unicode: true,
);
final _windowsDeviceName = RegExp(
  r'^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³]|conin\$|conout\$)(?: *\.|$)',
  caseSensitive: false,
);
final _frontmatter = RegExp(
  r'^---[ \t]*\r?\n([\s\S]*?)^---[ \t]*(?:\r?\n|$)',
  multiLine: true,
);

typedef _SourceEntry = ({
  List<String> path,
  bool directory,
  int size,
  FutureOr<Uint8List?> Function(bool keep)? read,
});

final class ObsidianVaultSource {
  new(
    this.notes,
    this.folders,
    this.skippedFiles, {
    this.attachments = const [],
    this.bookmarkBytes,
    this.bookmarksUnreadable = false,
    this.templateSettings,
  });

  final List<ObsidianMarkdownFile> notes;
  final List<ObsidianAttachmentFile> attachments;
  final List<List<String>> folders;
  final int skippedFiles;
  final Uint8List? bookmarkBytes;
  final bool bookmarksUnreadable;
  final ObsidianTemplateSourceSettings? templateSettings;
}

final class ObsidianMarkdownFile {
  new(this.folders, this.title, this.markdown, this.aliases);

  final List<String> folders;
  final String title;
  final Uint8List markdown;
  final List<String> aliases;
}

final class ObsidianAttachmentFile {
  new(this.folders, this.fileName, this.bytes, this.documentKind);

  final List<String> folders;
  final String fileName;
  final Uint8List bytes;
  final String documentKind;
}

String? obsidianAttachmentKind(String fileName) {
  final extensionStart = fileName.lastIndexOf('.');
  if (extensionStart <= 0 ||
      fileName.startsWith('.') ||
      !isObsidianPathSegment(fileName)) {
    return null;
  }
  return switch (fileName.substring(extensionStart + 1).toLowerCase()) {
    'pdf' => 'pdf',
    'canvas' => 'canvas',
    'png' || 'jpg' || 'jpeg' || 'webp' => 'image',
    'doc' ||
    'docx' ||
    'odt' ||
    'ppt' ||
    'pptx' ||
    'odp' ||
    'hwp' ||
    'hwpx' => 'office',
    _ => null,
  };
}

Future<ObsidianVaultSource> readObsidianVaultFolder(
  Directory root, {
  required List<String> Function(List<String>) normalizeSegments,
}) async {
  final rootPath = p.normalize(p.absolute(root.path));
  await _checkDiskPath(rootPath, FileSystemEntityType.directory);
  final entries = <_SourceEntry>[];
  var entryCount = 0;
  String? settingsDirectory;

  Future<void> walk(String folder, List<String> parent) async {
    await for (final item in Directory(folder).list(followLinks: false)) {
      if (++entryCount > _maxEntries) _tooManyEntries();
      final name = p.basename(item.path);
      if (parent.isEmpty && name == '.obsidian') {
        settingsDirectory = p.join(folder, name);
      }
      if (name.startsWith('.')) continue;
      final path = [...parent, name];
      final fullPath = p.join(folder, name);
      final directory = item is Directory;
      _validatePath(path, directory);
      await _checkDiskPath(
        fullPath,
        directory ? FileSystemEntityType.directory : FileSystemEntityType.file,
      );
      final importable =
          !directory &&
          (_isMarkdown(name) || obsidianAttachmentKind(name) != null);
      final file = File(fullPath);
      final size = importable ? await file.length() : 0;
      entries.add((
        path: path,
        directory: directory,
        size: size,
        read: importable ? (_) => _readDiskFile(file, size) : null,
      ));
      if (directory) await walk(fullPath, path);
    }
  }

  await walk(rootPath, []);
  final settings = settingsDirectory;
  final bookmarks = settings == null
      ? _noSetting
      : await _readDiskSetting(settings, 'bookmarks.json', _maxBookmarkBytes);
  final templates = settings == null
      ? _noSetting
      : await _readDiskSetting(
          settings,
          'templates.json',
          _maxTemplateSettingsBytes,
        );
  return _buildSource(
    entries,
    normalizeSegments,
    bookmarks: bookmarks,
    templateSettings: _decodeTemplateSettings(templates.bytes),
  );
}

Future<_SettingSource> _readDiskSetting(
  String settings,
  String name,
  int maxBytes,
) async {
  try {
    await _checkDiskPath(settings, FileSystemEntityType.directory);
    var entries = 0;
    await for (final item in Directory(settings).list(followLinks: false)) {
      if (++entries > _maxEntries) return _unreadableSetting;
      if (p.basename(item.path) != name) continue;
      final path = p.join(settings, name);
      await _checkDiskPath(path, FileSystemEntityType.file);
      final file = File(path);
      final length = await file.length();
      if (length > maxBytes) return _unreadableSetting;
      final bytes = await _readDiskFile(file, length);
      return (bytes: bytes.asUnmodifiableView(), unreadable: false);
    }
    return _noSetting;
  } on FileSystemException {
    return _unreadableSetting;
  } on FormatException {
    return _unreadableSetting;
  }
}

Future<ObsidianVaultSource> readObsidianVaultZip(
  Uint8List zipBytes, {
  required List<String> Function(List<String>) normalizeSegments,
  bool notionExport = false,
}) async {
  final members = _zipMembers(zipBytes);
  final visibleRoots = members
      .map((member) => member.path.first)
      .where((root) => !root.startsWith('.') && root != '__MACOSX')
      .toSet();
  final top = visibleRoots.singleOrNull;
  final hasRootSettings = members.any(_isSettingsMarker);
  // A single ordinary folder could be a real vault subfolder. Only remove a
  // wrapper when it contains its own Obsidian settings marker.
  final wrapper =
      !notionExport &&
          !hasRootSettings &&
          top != null &&
          members.any(
            (member) =>
                member.path.first == top && _isSettingsMarker(member, skip: 1),
          )
      ? top
      : null;

  var expandedBytes = 0;
  var memberCount = 0;
  final entries = <_SourceEntry>[];
  final partDirectories = <String>{};
  void checkSize(_ZipMember member) {
    if (++memberCount > _maxEntries) _tooManyEntries();
    expandedBytes += member.size;
    if (member.size > obsidianVaultZipMaxBytes ||
        expandedBytes > _maxExpandedZipBytes) {
      throw const FormatException('ZIP의 압축 해제 크기 한도를 넘었습니다.');
    }
  }

  void collect(
    List<_ZipMember> archive,
    Uint8List bytes, {
    bool nested = false,
  }) {
    final archiveWrapper = notionExport ? _notionWrapper(archive) : wrapper;
    for (final member in archive) {
      if (member.path.first == '__MACOSX') continue;
      final path = member.path.first == archiveWrapper
          ? member.path.sublist(1)
          : member.path;
      if (path.isEmpty || path.any((part) => part.startsWith('.'))) continue;
      _validatePath(path, member.directory);
      checkSize(member);
      if (nested) {
        if (!member.directory && _notionExportPart.hasMatch(path.last)) {
          throw const FormatException('Notion 분할 ZIP은 한 단계까지 가져올 수 있습니다.');
        }
        if (member.directory && !partDirectories.add(path.join('/'))) continue;
      }
      entries.add((
        path: path,
        directory: member.directory,
        size: member.size,
        read: member.directory ? null : (keep) => member.read(bytes, keep),
      ));
    }
  }

  final visibleFiles = members.where(
    (member) =>
        !member.directory &&
        member.path.first != '__MACOSX' &&
        !member.path.any((part) => part.startsWith('.')),
  );
  final notionWrapper = notionExport ? _notionWrapper(members) : null;
  final partDepth = notionWrapper == null ? 1 : 2;
  final parts = notionExport
      ? visibleFiles
            .where(
              (member) =>
                  member.path.length == partDepth &&
                  _notionExportPart.hasMatch(member.path.last),
            )
            .toList()
      : const <_ZipMember>[];
  if (parts.isEmpty) {
    collect(members, zipBytes);
  } else {
    if (parts.length != visibleFiles.length) {
      throw const FormatException('Notion ZIP 묶음에 분할 ZIP과 다른 파일이 섞여 있습니다.');
    }
    for (final part in parts) {
      checkSize(part);
      final bytes = part.read(zipBytes, true)!;
      collect(_zipMembers(bytes), bytes, nested: true);
    }
  }
  final bookmarks = notionExport
      ? _noSetting
      : _readZipSetting(
          members, zipBytes, wrapper, 'bookmarks.json', _maxBookmarkBytes,
        );
  final templates = notionExport
      ? _noSetting
      : _readZipSetting(
          members, zipBytes, wrapper, 'templates.json', _maxTemplateSettingsBytes,
        );
  return _buildSource(
    entries,
    normalizeSegments,
    notionExport: notionExport,
    bookmarks: bookmarks,
    templateSettings: _decodeTemplateSettings(templates.bytes),
  );
}

_SettingSource _readZipSetting(
  List<_ZipMember> members,
  Uint8List bytes,
  String? wrapper,
  String name,
  int maxBytes,
) {
  final skip = wrapper == null ? 0 : 1;
  final matches = members.where((member) {
    final path = member.path;
    return path.length == skip + 2 &&
        (wrapper == null || path.first == wrapper) &&
        path[skip] == '.obsidian' &&
        path.last == name;
  }).toList();
  if (matches.isEmpty) return _noSetting;
  if (matches.length != 1) return _unreadableSetting;
  final member = matches.single;
  if (member.directory ||
      member.size > maxBytes ||
      member.dataEnd - member.dataOffset > maxBytes + 4096) {
    return _unreadableSetting;
  }
  try {
    return (
      bytes: member.read(bytes, true)!.asUnmodifiableView(),
      unreadable: false,
    );
  } on FormatException {
    return _unreadableSetting;
  }
}

ObsidianTemplateSourceSettings? _decodeTemplateSettings(Uint8List? bytes) {
  if (bytes == null) return null;
  try {
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> || data['folder'] is! String) return null;
    final folderPath = (data['folder'] as String).split('/');
    if (folderPath.length > _maxDepth ||
        folderPath.any(
          (part) => part.startsWith('.') ||
              !isObsidianPathSegment(part) ||
              _invalidTemplateText.hasMatch(part),
        )) {
      return null;
    }
    String? format(String key) {
      final value = data[key];
      if (value == null || value == '') return null;
      if (value is! String ||
          value.length > 128 ||
          value.trim().isEmpty ||
          _invalidTemplateText.hasMatch(value)) {
        throw const FormatException('Invalid Obsidian template format');
      }
      return value;
    }

    return (
      folderPath: List.unmodifiable(folderPath),
      dateFormat: format('dateFormat'),
      timeFormat: format('timeFormat'),
    );
  } on FormatException {
    return null;
  }
}

bool _isMarkdown(String name) => name.toLowerCase().endsWith('.md');

final _notionExportPart = RegExp(
  r'^(?:Export-)?[\da-f-]+-Part-\d+\.zip$',
  caseSensitive: false,
);

final _notionExportDirectory = RegExp(
  r'^Export-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

String? _notionWrapper(List<_ZipMember> members) {
  final roots = {
    for (final member in members)
      if (!member.path.first.startsWith('.') && member.path.first != '__MACOSX')
        member.path.first,
  };
  final candidate = roots.singleOrNull;
  return candidate != null && _notionExportDirectory.hasMatch(candidate)
      ? candidate
      : null;
}

String? _zipAttachmentKind(String name, bool notionExport) =>
    notionExport && name.toLowerCase().endsWith('.csv')
    ? 'notion-csv'
    : obsidianAttachmentKind(name);

Never _tooManyEntries() =>
    throw const FormatException('보관함 항목은 최대 10,000개까지 가져올 수 있습니다.');

void _validateSegment(String segment) {
  if (!isObsidianPathSegment(segment)) {
    throw const FormatException('Windows에서 보존할 수 없는 보관함 경로가 있습니다.');
  }
}

bool isObsidianPathSegment(String segment) =>
    segment.isNotEmpty &&
    segment == segment.trim() &&
    !segment.endsWith('.') &&
    segment.length <= 255 &&
    !_unsafeSegment.hasMatch(segment) &&
    !_windowsDeviceName.hasMatch(segment);

void _validatePath(List<String> path, bool directory) {
  if (path.length - (directory ? 0 : 1) > _maxDepth) {
    throw const FormatException('보관함 폴더 깊이는 최대 64단계입니다.');
  }
  for (final segment in path) {
    _validateSegment(segment);
  }
}

Future<void> _checkDiskPath(String path, FileSystemEntityType expected) async {
  final entity = expected == FileSystemEntityType.directory
      ? Directory(path)
      : File(path);
  if (FileSystemEntity.typeSync(path, followLinks: false) != expected ||
      !p.equals(path, await entity.resolveSymbolicLinks())) {
    throw const FormatException('링크 또는 이동된 항목이 포함된 보관함은 가져올 수 없습니다.');
  }
}

Future<Uint8List> _readDiskFile(File file, int size) async {
  await _checkDiskPath(file.path, FileSystemEntityType.file);
  final handle = await file.open();
  try {
    await _checkDiskPath(file.path, FileSystemEntityType.file);
    if (await handle.length() != size) {
      throw const FormatException('가져오는 동안 파일 크기가 변경됐습니다.');
    }
    final bytes = await handle.read(size + 1);
    if (bytes.length != size) {
      throw const FormatException('가져오는 동안 파일 크기가 변경됐습니다.');
    }
    return bytes;
  } finally {
    await handle.close();
  }
}

Future<ObsidianVaultSource> _buildSource(
  List<_SourceEntry> entries,
  List<String> Function(List<String>) normalizeSegments, {
  bool notionExport = false,
  _SettingSource bookmarks = _noSetting,
  ObsidianTemplateSourceSettings? templateSettings,
}) async {
  final segments = <String>{for (final entry in entries) ...entry.path}
      .toList();
  final keys = <String, String>{};
  for (var start = 0; start < segments.length; start += _maxEntries) {
    final batch = segments.skip(start).take(_maxEntries).toList();
    final result = normalizeSegments(batch);
    if (result.length != batch.length)
      throw StateError('Invalid workspace path normalization result');
    for (var i = 0; i < batch.length; i++) {
      if (result[i].isEmpty || result[i].contains('/')) {
        throw StateError('Invalid workspace path key');
      }
      keys[batch[i]] = result[i];
    }
  }

  final folders = <String, List<String>>{};
  final files = <String>{};
  final explicitFolders = <String>{};
  var markdownBytes = 0;
  var attachmentBytes = 0;
  var importableCount = 0;
  var hasNotionContent = false;
  for (final entry in entries) {
    final key = StringBuffer();
    final parentCount = entry.path.length - (entry.directory ? 0 : 1);
    for (var i = 0; i < parentCount; i++) {
      key.write('${keys[entry.path[i]]!}/');
      final folderKey = key.toString();
      final prefix = entry.path.sublist(0, i + 1);
      final stored = folders.putIfAbsent(folderKey, () => prefix);
      if (folders.length + files.length > _maxEntries) _tooManyEntries();
      if (stored.join('/') != prefix.join('/') || files.contains(folderKey))
        _pathConflict();
    }
    if (entry.directory) {
      if (!explicitFolders.add(key.toString())) _pathConflict();
    } else {
      key.write('${keys[entry.path.last]!}/');
      final fileKey = key.toString();
      if (folders.containsKey(fileKey) || !files.add(fileKey)) _pathConflict();
      if (folders.length + files.length > _maxEntries) _tooManyEntries();
      final name = entry.path.last;
      if (_isMarkdown(name)) {
        hasNotionContent = true;
        _validateSegment(name.substring(0, name.length - 3));
        markdownBytes += entry.size;
        if (entry.size > _maxNoteBytes || markdownBytes > _maxMarkdownBytes) {
          throw const FormatException(
            'Markdown은 파일당 8 MiB, 전체 128 MiB까지 가져올 수 있습니다.',
          );
        }
      } else if (_zipAttachmentKind(name, notionExport) case final kind?) {
        if (entry.size == 0) {
          throw FormatException('빈 첨부 파일은 가져올 수 없습니다 ($name).');
        }
        if (kind == 'canvas' && entry.size > _maxCanvasBytes) {
          throw const FormatException('Canvas는 파일당 8 MiB까지 가져올 수 있습니다.');
        }
        if (kind == 'notion-csv') {
          hasNotionContent = true;
          if (entry.size > notionCsvMaxBytes) {
            throw const FormatException('CSV는 파일당 8 MiB까지 가져올 수 있습니다.');
          }
        }
        attachmentBytes += entry.size;
        if (entry.size > _maxAttachmentBytes ||
            attachmentBytes > _maxAllAttachmentBytes) {
          throw const FormatException(
            '첨부 파일은 파일당 64 MiB, 전체 192 MiB까지 가져올 수 있습니다.',
          );
        }
      } else {
        continue;
      }
      importableCount++;
    }
  }
  if (notionExport && !hasNotionContent) {
    throw const FormatException('Notion에서 Markdown 및 CSV 형식으로 내보낸 ZIP을 선택하세요.');
  }
  if (importableCount == 0) {
    throw const FormatException('가져올 Markdown 또는 지원되는 첨부 파일이 없습니다.');
  }

  final notes = <ObsidianMarkdownFile>[];
  final attachments = <ObsidianAttachmentFile>[];
  var skipped = 0;
  for (final entry in entries.where((entry) => !entry.directory)) {
    final name = entry.path.last;
    final kind = _zipAttachmentKind(name, notionExport);
    if (kind == null && !_isMarkdown(name)) {
      await entry.read?.call(false);
      skipped++;
      continue;
    }
    final bytes = (await entry.read!.call(true))!.asUnmodifiableView();
    final folders = List<String>.unmodifiable(
      entry.path.take(entry.path.length - 1),
    );
    if (kind != null) {
      attachments.add(ObsidianAttachmentFile(folders, name, bytes, kind));
      continue;
    }
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw FormatException('UTF-8 Markdown 파일이 아닙니다 ($name).');
    }
    notes.add(
      ObsidianMarkdownFile(
        folders,
        name.substring(0, name.length - 3),
        bytes,
        _aliases(text),
      ),
    );
  }
  final orderedFolders = folders.values.toList()
    ..sort((a, b) => a.join('/').compareTo(b.join('/')));
  return ObsidianVaultSource(
    List.unmodifiable(notes),
    List.unmodifiable(orderedFolders.map(List<String>.unmodifiable)),
    skipped,
    attachments: List.unmodifiable(attachments),
    bookmarkBytes: bookmarks.bytes,
    bookmarksUnreadable: bookmarks.unreadable,
    templateSettings: templateSettings,
  );
}

Never _pathConflict() =>
    throw const FormatException('이름이 중복되거나 충돌하는 보관함 경로가 있습니다.');

List<String> _aliases(String markdown) {
  if (!markdown.startsWith('---')) return const [];
  final header = markdown.length <= 65536
      ? markdown
      : markdown.substring(0, 65536);
  final match = _frontmatter.firstMatch(header);
  if (match == null || match.start != 0) return const [];
  try {
    final yaml = loadYaml(match.group(1)!);
    if (yaml is! YamlMap) return const [];
    final aliases = yaml['aliases'];
    final values = aliases is String
        ? [aliases]
        : aliases is YamlList
        ? aliases
        : const [];
    return List.unmodifiable({
      for (final alias in values.whereType<String>().take(1024))
        if (alias.trim().isNotEmpty &&
            alias.length <= 255 &&
            !_controlCharacters.hasMatch(alias))
          alias.trim(),
    });
  } on YamlException {
    return const [];
  } on StackOverflowError {
    return const [];
  }
}

bool _isSettingsMarker(_ZipMember member, {int skip = 0}) =>
    member.path.length > skip &&
    member.path[skip] == '.obsidian' &&
    (member.directory || member.path.length > skip + 1);

final class _ZipMember {
  new(
    this.path,
    this.directory,
    this.size,
    this.compression,
    this.crc,
    this.localOffset,
    this.dataOffset,
    this.dataEnd,
    this.end,
  );

  final List<String> path;
  final bool directory;
  final int size, compression, crc, localOffset, dataOffset, dataEnd, end;

  Uint8List? read(Uint8List zip, bool keep) {
    final compressed = Uint8List.sublistView(zip, dataOffset, dataEnd);
    final sink = _ZipContentSink(size, keep);
    if (compression == 0) {
      sink.add(compressed);
    } else {
      final decoder = ZLibDecoder(raw: true).startChunkedConversion(sink);
      decoder.add(compressed);
      decoder.close();
    }
    if (sink.length != size || sink.crc != crc) _badZip();
    return sink.bytes?.takeBytes();
  }
}

final class _ZipContentSink implements Sink<List<int>> {
  new(this.expectedLength, bool keep) : bytes = keep ? BytesBuilder() : null;

  final int expectedLength;
  final BytesBuilder? bytes;
  var length = 0;
  var crc = 0;

  @override
  void add(List<int> chunk) {
    length += chunk.length;
    if (length > expectedLength) _badZip();
    crc = getCrc32(chunk, crc);
    bytes?.add(chunk);
  }

  @override
  void close() {}
}

Never _badZip() => throw const FormatException('손상되었거나 지원하지 않는 ZIP 보관함입니다.');

List<_ZipMember> _zipMembers(Uint8List zip) {
  if (zip.length > obsidianVaultZipMaxBytes) {
    throw const FormatException('Obsidian ZIP은 128 MiB까지 가져올 수 있습니다.');
  }
  final data = ByteData.sublistView(zip);
  int u16(int offset) => data.getUint16(offset, Endian.little);
  int u32(int offset) => data.getUint32(offset, Endian.little);

  // Read the end record first to bound the number and size of headers before
  // reading any entries. This reader accepts single-disk ZIP32 archives.
  var endRecord = zip.length - 22;
  final commentLimit = endRecord - 65535;
  while (endRecord >= 0 &&
      endRecord >= commentLimit &&
      (u32(endRecord) != 0x06054b50 ||
          endRecord + 22 + u16(endRecord + 20) != zip.length)) {
    endRecord--;
  }
  if (endRecord < 0 || endRecord < commentLimit) _badZip();
  final entryCount = u16(endRecord + 10);
  final centralStart = u32(endRecord + 16);
  if (entryCount > _maxEntries) _tooManyEntries();
  if (u16(endRecord + 4) != 0 ||
      u16(endRecord + 6) != 0 ||
      u16(endRecord + 8) != entryCount ||
      centralStart + u32(endRecord + 12) != endRecord) {
    _badZip();
  }

  var offset = centralStart;
  final members = <_ZipMember>[];
  final names = <String>{};
  for (var i = 0; i < entryCount; i++) {
    if (offset + 46 > endRecord || u32(offset) != ZipFileHeader.signature)
      _badZip();
    final nameLength = u16(offset + 28);
    final next = offset + 46 + nameLength + u16(offset + 30) + u16(offset + 32);
    if (next > endRecord ||
        nameLength == 0 ||
        u32(offset + 20) == 0xffffffff ||
        u32(offset + 24) == 0xffffffff ||
        u32(offset + 42) == 0xffffffff) {
      _badZip();
    }
    final centralName = Uint8List.sublistView(
      zip,
      offset + 46,
      offset + 46 + nameLength,
    );
    final name = utf8.decode(centralName);
    if (utf8.encode(name).length != nameLength) _badZip();
    if (!names.add(name)) _pathConflict();
    final header = ZipFileHeader()
      ..read(
        InputMemoryStream(zip, offset: offset + 4, length: next - offset - 4),
      );
    offset = next;
    final directory = name.endsWith('/');
    final path = (directory ? name.substring(0, name.length - 1) : name).split(
      '/',
    );
    if (path.length - (directory ? 0 : 1) > _maxDepth + 1) {
      throw const FormatException('보관함 폴더 깊이는 최대 64단계입니다.');
    }
    for (final part in path) {
      _validateSegment(part);
    }
    final flags = header.generalPurposeBitFlag;
    final compression = header.compressionMethod;
    final mode = (header.externalFileAttributes >> 16) & 0xf000;
    final windowsAttributes = header.externalFileAttributes & 0xffff;
    if (flags & ~0x080e != 0 ||
        (compression != 0 && compression != 8) ||
        header.diskNumberStart != 0 ||
        windowsAttributes & 0x400 != 0 ||
        (mode != 0 && mode != (directory ? 0x4000 : 0x8000)) ||
        (!directory && windowsAttributes & 0x10 != 0) ||
        (directory && (header.uncompressedSize != 0 || header.crc32 != 0)) ||
        (compression == 0 &&
            header.compressedSize != header.uncompressedSize)) {
      _badZip();
    }

    final local = header.localHeaderOffset;
    if (local + 30 > centralStart ||
        u32(local) != 0x04034b50 ||
        u16(local + 6) != flags ||
        u16(local + 8) != compression ||
        u16(local + 26) != nameLength) {
      _badZip();
    }
    final dataOffset = local + 30 + nameLength + u16(local + 28);
    final dataEnd = dataOffset + header.compressedSize;
    if (dataEnd > centralStart) _badZip();
    for (var j = 0; j < nameLength; j++) {
      if (zip[local + 30 + j] != centralName[j]) _badZip();
    }
    var end = dataEnd;
    if (flags & 8 != 0) {
      // A streaming writer can put the CRC and sizes after the compressed data.
      if (end + 12 > centralStart) _badZip();
      if (u32(end) == 0x08074b50) end += 4;
      if (end + 12 > centralStart ||
          u32(end) != header.crc32 ||
          u32(end + 4) != header.compressedSize ||
          u32(end + 8) != header.uncompressedSize) {
        _badZip();
      }
      end += 12;
    } else if (u32(local + 14) != header.crc32 ||
        u32(local + 18) != header.compressedSize ||
        u32(local + 22) != header.uncompressedSize) {
      _badZip();
    }
    members.add(
      _ZipMember(
        path,
        directory,
        header.uncompressedSize,
        compression,
        header.crc32,
        local,
        dataOffset,
        dataEnd,
        end,
      ),
    );
  }
  if (offset != endRecord) _badZip();
  members.sort((a, b) => a.localOffset.compareTo(b.localOffset));
  for (var i = 1; i < members.length; i++) {
    if (members[i - 1].end > members[i].localOffset) _badZip();
  }
  return members;
}
