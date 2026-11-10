import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/office_original_edit_result.dart';
import 'package:saber/data/office/windows_office_interactive.dart';

export 'office_original_edit_result.dart';
export 'windows_office_interactive.dart'
    show WindowsOfficeInteractiveRunner, WindowsOfficeInteractiveSession;

class WindowsOfficeException implements Exception {
  const new(this.code, this.message, {this.diagnostics});
  final String code;
  final String message;
  final Map<String, dynamic>? diagnostics;
  Map<String, dynamic>? get safeDiagnostics =>
      _officeWorkerDiagnostics(diagnostics);
  @override
  String toString() => 'WindowsOfficeException($code): $message';
}

Map<String, dynamic>? _officeWorkerDiagnostics(Object? value) {
  const rootFields = {
    'type',
    'frames',
    'framesTruncated',
    'causes',
    'causesTruncated',
  };
  const causeFields = {'type', 'frames', 'framesTruncated'};
  const frameFields = {'file', 'function', 'line'};
  bool fields(Object? item, Set<String> names) =>
      item is Map &&
      item.length == names.length &&
      item.keys.every(
        (key) => key is String && key.length <= 32 && names.contains(key),
      );
  bool label(Object? item) =>
      item is String &&
      item.isNotEmpty &&
      item.length <= 256 &&
      item.runes.take(129).length <= 128;
  Map<String, dynamic>? summary(Object? value, Set<String> names) {
    if (!fields(value, names)) return null;
    final item = value as Map;
    final frames = item['frames'];
    if (!label(item['type']) ||
        item['framesTruncated'] is! bool ||
        frames is! List ||
        frames.length > 16)
      return null;
    final accepted = <Map<String, dynamic>>[];
    for (final value in frames) {
      if (!fields(value, frameFields)) return null;
      final frame = value as Map;
      final line = frame['line'];
      if (!label(frame['file']) ||
          RegExp(r'[/\\:]').hasMatch(frame['file'] as String) ||
          !label(frame['function']) ||
          line is! int ||
          line <= 0)
        return null;
      accepted.add(
        Map<String, dynamic>.unmodifiable({
          'file': frame['file'] as String,
          'function': frame['function'] as String,
          'line': line,
        }),
      );
    }
    return Map<String, dynamic>.unmodifiable({
      'type': item['type'] as String,
      'frames': List<Map<String, dynamic>>.unmodifiable(accepted),
      'framesTruncated': item['framesTruncated'] as bool,
    });
  }

  if (!fields(value, rootFields)) return null;
  final root = value as Map;
  final causes = root['causes'];
  if (causes is! List ||
      causes.length > 2 ||
      root['causesTruncated'] is! bool) {
    return null;
  }
  final primary = summary(root, rootFields);
  if (primary == null) return null;
  final acceptedCauses = <Map<String, dynamic>>[];
  for (final cause in causes) {
    final accepted = summary(cause, causeFields);
    if (accepted == null) return null;
    acceptedCauses.add(accepted);
  }
  final result = Map<String, dynamic>.unmodifiable({
    ...primary,
    'causes': List<Map<String, dynamic>>.unmodifiable(acceptedCauses),
    'causesTruncated': root['causesTruncated'] as bool,
  });
  if (utf8.encode(jsonEncode(result)).length > 16 * 1024) return null;
  return result;
}

class WindowsOfficeTextRun {
  new _(Map<String, dynamic> json)
    : startUtf16 = json['startUtf16'] as int,
      endUtf16 = json['endUtf16'] as int,
      fontSize = (json['fontSize'] as num?)?.toDouble(),
      bold = json['bold'] as bool?,
      italic = json['italic'] as bool?,
      underline = json['underline'] as bool?,
      color = json['color'] as int?,
      fontFamily = json['fontFamily'] as String?;
  final int startUtf16;
  final int endUtf16;
  final double? fontSize;
  final bool? bold;
  final bool? italic;
  final bool? underline;
  final int? color;
  final String? fontFamily;
}

class WindowsOfficeProtectedRange {
  new _(Map<String, dynamic> json)
    : startUtf16 = json['startUtf16'] as int,
      endUtf16 = json['endUtf16'] as int,
      type = json['type'] as String;
  final int startUtf16;
  final int endUtf16;
  final String type;
}

class WindowsOfficeTextDetails {
  factory fromJson(Map<String, dynamic> json) =>
      WindowsOfficeTextDetails._(json);

  new _(Map<String, dynamic> json)
    : utf16Length = json['utf16Length'] as int,
      textSha256 = json['textSha256'] as String,
      canReplace = json['canReplace'] == true,
      canStyle = json['canStyle'] == true,
      truncated = json['truncated'] == true,
      runs = List.unmodifiable([
        for (final run in json['runs'] as List)
          WindowsOfficeTextRun._(Map<String, dynamic>.from(run as Map)),
      ]),
      protectedRanges = List.unmodifiable([
        for (final range in json['protectedRanges'] as List)
          WindowsOfficeProtectedRange._(
            Map<String, dynamic>.from(range as Map),
          ),
      ]);
  final int utf16Length;
  final String textSha256;
  final bool canReplace;
  final bool canStyle;
  final bool truncated;
  final List<WindowsOfficeTextRun> runs;
  final List<WindowsOfficeProtectedRange> protectedRanges;
}

class WindowsOfficeImageDetails {
  new _(Map<String, dynamic> json)
    : mimeType = json['mimeType'] as String?,
      pixelWidth = json['pixelWidth'] as int?,
      pixelHeight = json['pixelHeight'] as int?,
      canReplace = json['canReplace'] == true,
      rotationHundredths = json['rotationHundredths'] == null
          ? null
          : _imageRotationHundredths(json['rotationHundredths']),
      canRotate = _presentationFlag(json, 'canRotate'),
      thumbnailBase64 = json['thumbnailBase64'] as String?,
      thumbnailMimeType = json['thumbnailMimeType'] as String?,
      thumbnailSha256 = json['thumbnailSha256'] as String?,
      thumbnailTruncated = json['thumbnailTruncated'] == true {
    if (canRotate && rotationHundredths == null) {
      throw const FormatException('Missing current Office image rotation');
    }
  }
  final String? mimeType;
  final int? pixelWidth;
  final int? pixelHeight;
  final bool canReplace;
  final int? rotationHundredths;
  final bool canRotate;
  final String? thumbnailBase64;
  final String? thumbnailMimeType;
  final String? thumbnailSha256;
  final bool thumbnailTruncated;

  Uint8List? get thumbnailBytes {
    final encoded = thumbnailBase64;
    if (encoded == null) return null;
    if (encoded.length > 384 * 1024 || thumbnailMimeType != 'image/png') {
      throw const FormatException('Invalid Office image preview');
    }
    final bytes = base64Decode(encoded);
    if (sha256.convert(bytes).toString() != thumbnailSha256) {
      throw const FormatException('Office image preview checksum mismatch');
    }
    return bytes;
  }
}

int _imageRotationHundredths(Object? value) {
  if (value is! int || value < 0 || value >= 36000) {
    throw const FormatException('Invalid Office image rotation');
  }
  return value;
}

class WindowsOfficeBodyBlock {
  new _(Map<String, dynamic> json)
    : kind = json['kind'] as String,
      id = json['id'] as String;
  final String kind;
  final String id;
}

class WindowsOfficeParagraphStyle {
  new _(Map<String, dynamic> json)
    : name = json['name'] as String,
      displayName = json['displayName'] as String;
  final String name;
  final String displayName;
}

class WindowsOfficeParagraphFormat {
  new _(Map<String, dynamic> json)
    : styleName = json['styleName'] as String?,
      alignment = json['alignment'] as String?,
      listKind = json['listKind'] as String?,
      listLevel = json['listLevel'] as int?,
      pageBreakBefore = json['pageBreakBefore'] as bool?;
  final String? styleName;
  final String? alignment;
  final String? listKind;
  final int? listLevel;
  final bool? pageBreakBefore;
}

class WindowsOfficeParagraphStructure {
  new _(Map<String, dynamic> json)
    : canSplit = json['canSplit'] == true,
      canDelete = json['canDelete'] == true,
      canInsertBefore = json['canInsertBefore'] == true,
      canInsertAfter = json['canInsertAfter'] == true,
      canJoinNext = json['canJoinNext'] == true;
  final bool canSplit;
  final bool canDelete;
  final bool canInsertBefore;
  final bool canInsertAfter;
  final bool canJoinNext;
}

class WindowsOfficeParagraph {
  new _(Map<String, dynamic> json)
    : id = json['id'] as String,
      ownerId = json['ownerId'] as String?,
      text = json['text'] as String,
      tableInsertAnchor = json['tableInsertAnchor'] == true,
      fontSize = (json['fontSize'] as num?)?.toDouble(),
      bold = json['bold'] as bool?,
      color = json['color'] as int?,
      textDetails = json['textDetails'] == null
          ? null
          : WindowsOfficeTextDetails._(
              Map<String, dynamic>.from(json['textDetails'] as Map),
            ),
      paragraphFormat = json['paragraphFormat'] == null
          ? null
          : WindowsOfficeParagraphFormat._(
              Map<String, dynamic>.from(json['paragraphFormat'] as Map),
            ),
      structure = json['structure'] == null
          ? null
          : WindowsOfficeParagraphStructure._(
              Map<String, dynamic>.from(json['structure'] as Map),
            );
  final String id;
  final String? ownerId;
  final String text;
  final bool tableInsertAnchor;
  final double? fontSize;
  final bool? bold;
  final int? color;
  final WindowsOfficeTextDetails? textDetails;
  final WindowsOfficeParagraphFormat? paragraphFormat;
  final WindowsOfficeParagraphStructure? structure;
}

enum HwpTableStructureAction {
  insertRow,
  deleteRow,
  insertColumn,
  deleteColumn;

  bool get isRow => this == insertRow || this == deleteRow;
  bool get isDelete => this == deleteRow || this == deleteColumn;
}

final class WindowsOfficeHwpTableStructure {
  const new _({
    required this.rows,
    required this.columns,
    required this.canInsertRow,
    required this.canDeleteRow,
    required this.canInsertColumn,
    required this.canDeleteColumn,
  });

  factory _fromJson(Map<String, dynamic> json) {
    final rows = json['rows'];
    final columns = json['columns'];
    final canInsertRow = json['canInsertRow'];
    final canDeleteRow = json['canDeleteRow'];
    final canInsertColumn = json['canInsertColumn'];
    final canDeleteColumn = json['canDeleteColumn'];
    if (json.length != 6 ||
        rows is! int ||
        columns is! int ||
        rows < 1 ||
        rows > maxRows ||
        columns < 1 ||
        columns > maxColumns ||
        rows * columns > maxCells ||
        canInsertRow is! bool ||
        canDeleteRow is! bool ||
        canInsertColumn is! bool ||
        canDeleteColumn is! bool) {
      throw const FormatException('한글 표의 행·열 정보를 확인하지 못했습니다.');
    }
    return WindowsOfficeHwpTableStructure._(
      rows: rows,
      columns: columns,
      canInsertRow: canInsertRow,
      canDeleteRow: canDeleteRow,
      canInsertColumn: canInsertColumn,
      canDeleteColumn: canDeleteColumn,
    );
  }

  static const maxRows = 64;
  static const maxColumns = 32;
  static const maxCells = 512;
  final int rows;
  final int columns;
  final bool canInsertRow;
  final bool canDeleteRow;
  final bool canInsertColumn;
  final bool canDeleteColumn;

  bool allows(HwpTableStructureAction action) => switch (action) {
    HwpTableStructureAction.insertRow => canInsertRow,
    HwpTableStructureAction.deleteRow => canDeleteRow,
    HwpTableStructureAction.insertColumn => canInsertColumn,
    HwpTableStructureAction.deleteColumn => canDeleteColumn,
  };
}

class WindowsOfficeTable {
  new _(Map<String, dynamic> json)
    : id = json['id'] as String,
      ownerId = json['ownerId'] as String?,
      cells = Map.unmodifiable(Map<String, String>.from(json['cells'] as Map)),
      structure = json['structure'] == null
          ? null
          : WindowsOfficeHwpTableStructure._fromJson(
              WindowsOfficeEngine._object(json['structure']),
            ),
      cellTextDetails = Map.unmodifiable({
        for (final entry
            in (json['cellTextDetails'] as Map? ?? const {}).entries)
          entry.key as String: WindowsOfficeTextDetails._(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      });
  final String id;
  final String? ownerId;
  final Map<String, String> cells;
  final WindowsOfficeHwpTableStructure? structure;
  final Map<String, WindowsOfficeTextDetails> cellTextDetails;
}

class WindowsOfficeWordReference {
  new _(Map<String, dynamic> json)
    : pageStyleId = json['pageStyleId'] as String,
      variant = json['variant'] as String;
  final String pageStyleId;
  final String variant;
}

class WindowsOfficeWordOwner {
  new _(Map<String, dynamic> json)
    : id = json['id'] as String,
      kind = json['kind'] as String,
      references = List.unmodifiable([
        for (final item in json['references'] as List)
          WindowsOfficeWordReference._(Map<String, dynamic>.from(item as Map)),
      ]),
      blocks = List.unmodifiable([
        for (final item in json['blocks'] as List)
          WindowsOfficeBodyBlock._(Map<String, dynamic>.from(item as Map)),
      ]),
      paragraphs = List.unmodifiable([
        for (final item in json['paragraphs'] as List)
          WindowsOfficeParagraph._(Map<String, dynamic>.from(item as Map)),
      ]),
      tableIds = List.unmodifiable(List<String>.from(json['tableIds'] as List));
  final String id;
  final String kind;
  final List<WindowsOfficeWordReference> references;
  final List<WindowsOfficeBodyBlock> blocks;
  final List<WindowsOfficeParagraph> paragraphs;
  final List<String> tableIds;
}

class WindowsOfficePageStyle {
  new _(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      displayName = json['displayName'] as String,
      inUse = json['inUse'] as bool?,
      canEditGeometry = json['canEditGeometry'] as bool?,
      width = (json['width'] as num?)?.toDouble(),
      height = (json['height'] as num?)?.toDouble(),
      leftMargin = (json['leftMargin'] as num?)?.toDouble(),
      rightMargin = (json['rightMargin'] as num?)?.toDouble(),
      topMargin = (json['topMargin'] as num?)?.toDouble(),
      bottomMargin = (json['bottomMargin'] as num?)?.toDouble(),
      landscape = json['landscape'] as bool?,
      headerIsOn = json['headerIsOn'] as bool?,
      footerIsOn = json['footerIsOn'] as bool?,
      headerIsShared = json['headerIsShared'] as bool?,
      footerIsShared = json['footerIsShared'] as bool?,
      firstIsShared = json['firstIsShared'] as bool?,
      pageLayout = json['pageLayout'] as String?,
      layoutSha256 = json['layoutSha256'] as String?,
      regions = Map.unmodifiable({
        for (final entry in (json['regions'] as Map).entries)
          entry.key as String: Map<String, String?>.unmodifiable(
            Map<String, String?>.from(entry.value as Map),
          ),
      });
  final String id;
  final String name;
  final String displayName;
  final bool? inUse;
  final bool? canEditGeometry;
  final double? width;
  final double? height;
  final double? leftMargin;
  final double? rightMargin;
  final double? topMargin;
  final double? bottomMargin;
  final bool? landscape;
  final bool? headerIsOn;
  final bool? footerIsOn;
  final bool? headerIsShared;
  final bool? footerIsShared;
  final bool? firstIsShared;
  final String? pageLayout;
  final String? layoutSha256;
  final Map<String, Map<String, String?>> regions;
}

class WindowsOfficeShape {
  new _(Map<String, dynamic> json)
    : id = json['id'] as String,
      type = json['type'] as String,
      text = json['text'] as String,
      editableText = json['editableText'] == true,
      x = (json['x'] as num).toDouble(),
      y = (json['y'] as num).toDouble(),
      width = (json['width'] as num).toDouble(),
      height = (json['height'] as num).toDouble(),
      fontSize = (json['fontSize'] as num?)?.toDouble(),
      bold = json['bold'] as bool?,
      color = json['color'] as int?,
      shapeKind = json['shapeKind'] as String?,
      fillStyle = json['fillStyle'] as String?,
      fillColor = json['fillColor'] as int?,
      lineStyle = json['lineStyle'] as String?,
      lineColor = json['lineColor'] as int?,
      lineWidth = (json['lineWidth'] as num?)?.toDouble(),
      canEditFill = json['canEditFill'] == true,
      canEditLine = json['canEditLine'] == true,
      ownerKind = json['ownerKind'] as String?,
      ownerId = json['ownerId'] as String?,
      presentationObject = json['presentationObject'] as bool?,
      emptyPresentationObject = json['emptyPresentationObject'] as bool?,
      canEditGeometry = json['canEditGeometry'] != false,
      canDelete = json['canDelete'] != false,
      canEditTextStyle = json['canEditTextStyle'] != false,
      textDetails = json['textDetails'] == null
          ? null
          : WindowsOfficeTextDetails._(
              Map<String, dynamic>.from(json['textDetails'] as Map),
            ),
      image = json['image'] == null
          ? null
          : WindowsOfficeImageDetails._(
              Map<String, dynamic>.from(json['image'] as Map),
            );
  final String id;
  final String type;
  final String text;
  final bool editableText;
  final double x;
  final double y;
  final double width;
  final double height;
  final double? fontSize;
  final bool? bold;
  final int? color;
  final String? shapeKind;
  final String? fillStyle;
  final int? fillColor;
  final String? lineStyle;
  final int? lineColor;
  final double? lineWidth;
  final bool canEditFill;
  final bool canEditLine;
  final String? ownerKind;
  final String? ownerId;
  final bool? presentationObject;
  final bool? emptyPresentationObject;
  final bool canEditGeometry;
  final bool canDelete;
  final bool canEditTextStyle;
  final WindowsOfficeTextDetails? textDetails;
  final WindowsOfficeImageDetails? image;
}

class WindowsOfficeMaster {
  new _(Map<String, dynamic> json)
    : id = json['id'] as String,
      name = json['name'] as String,
      width = (json['width'] as num).toDouble(),
      height = (json['height'] as num).toDouble(),
      backgroundStyle = json['backgroundStyle'] as String?,
      backgroundColor = json['backgroundColor'] as int?,
      presentationTables = _presentationTables(json),
      presentationTableCount = json['presentationTableCount'] == null
          ? null
          : _presentationInt(
              json['presentationTableCount'],
              'owner.presentationTableCount',
              minimum: 0,
            ),
      presentationTablesTruncated = _presentationFlag(
        json,
        'presentationTablesTruncated',
      ),
      presentationTablesUnknownReason = _presentationNullableString(
        json['presentationTablesUnknownReason'],
        'owner.presentationTablesUnknownReason',
      ),
      canAddTable = _presentationFlag(json, 'canAddTable'),
      shapes = List.unmodifiable([
        for (final shape in json['shapes'] as List)
          WindowsOfficeShape._(Map<String, dynamic>.from(shape as Map)),
      ]) {
    if (json['sourceStructureAuthority'] != null) {
      throw const FormatException(
        'Master source structure authority is unsupported',
      );
    }
    _validatePresentationCatalog(
      id,
      presentationTables,
      presentationTableCount,
      presentationTablesTruncated,
      canAddTable,
    );
  }
  final String id;
  final String name;
  final double width;
  final double height;
  final String? backgroundStyle;
  final int? backgroundColor;
  final List<WindowsOfficeShape> shapes;
  final List<WindowsOfficePresentationTable>? presentationTables;
  final int? presentationTableCount;
  final bool presentationTablesTruncated;
  final String? presentationTablesUnknownReason;
  final bool canAddTable;
}

class WindowsOfficeLayoutOption {
  new _(Map<String, dynamic> json)
    : code = json['code'] as int,
      label = json['label'] as String;
  final int code;
  final String label;
}

class WindowsOfficePresentationTableCapabilities {
  new _(Map<String, dynamic> json)
    : canEditText = _presentationFlag(json, 'canEditText'),
      canEditTextStyle = _presentationFlag(json, 'canEditTextStyle'),
      canEditAppearance = _presentationFlag(json, 'canEditAppearance'),
      canInsertRows = _presentationFlag(json, 'canInsertRows'),
      canDeleteRows = _presentationFlag(json, 'canDeleteRows'),
      canInsertColumns = _presentationFlag(json, 'canInsertColumns'),
      canDeleteColumns = _presentationFlag(json, 'canDeleteColumns'),
      canMerge = _presentationFlag(json, 'canMerge'),
      canSplit = _presentationFlag(json, 'canSplit'),
      canDeleteTable = _presentationFlag(json, 'canDeleteTable') {
    _presentationFields(json, const {
      'canEditText',
      'canEditTextStyle',
      'canEditAppearance',
      'canInsertRows',
      'canDeleteRows',
      'canInsertColumns',
      'canDeleteColumns',
      'canMerge',
      'canSplit',
      'canDeleteTable',
    });
  }

  final bool canEditText;
  final bool canEditTextStyle;
  final bool canEditAppearance;
  final bool canInsertRows;
  final bool canDeleteRows;
  final bool canInsertColumns;
  final bool canDeleteColumns;
  final bool canMerge;
  final bool canSplit;
  final bool canDeleteTable;

  bool get _hasWriteCapability =>
      canEditText ||
      canEditTextStyle ||
      canEditAppearance ||
      canInsertRows ||
      canDeleteRows ||
      canInsertColumns ||
      canDeleteColumns ||
      canMerge ||
      canSplit ||
      canDeleteTable;
}

const _sourceTextPatchLimit = 131072;
const _sourceTextPatchReasons = {
  'field',
  'hyperlink',
  'comment',
  'processingInstruction',
  'lineBreak',
  'paragraphBoundary',
};

bool _sourceTextScalar(String text) {
  for (var index = 0; index < text.length; index++) {
    var value = text.codeUnitAt(index);
    if (value >= 0xd800 && value <= 0xdbff) {
      if (++index >= text.length) return false;
      final low = text.codeUnitAt(index);
      if (low < 0xdc00 || low > 0xdfff) return false;
      value = 0x10000 + ((value - 0xd800) << 10) + low - 0xdc00;
    } else if (value >= 0xdc00 && value <= 0xdfff) {
      return false;
    }
    if (!(value == 9 ||
        value == 10 ||
        value == 13 ||
        value >= 0x20 && value <= 0xd7ff ||
        value >= 0xe000 && value <= 0xfffd ||
        value >= 0x10000 && value <= 0x10ffff))
      return false;
  }
  return true;
}

bool _sourceTextBoundary(String text, int offset) =>
    offset >= 0 &&
    offset <= text.length &&
    !(offset > 0 &&
        offset < text.length &&
        text.codeUnitAt(offset - 1) >= 0xd800 &&
        text.codeUnitAt(offset - 1) <= 0xdbff &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff);

String _sourceTextHash(Object? value, String name) {
  final hash = _presentationString(value, name);
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
    throw FormatException('Invalid $name');
  }
  return hash;
}

String _sourceTextPart(Object? value) {
  final part = _presentationString(value, 'source text part');
  if (part.length > 1024 ||
      !_sourceTextScalar(part) ||
      RegExp(r'[\\:%?#]').hasMatch(part) ||
      part.runes.any((value) => value < 32) ||
      part
          .split('/')
          .any((value) => value.isEmpty || value == '.' || value == '..')) {
    throw const FormatException('Invalid source text package part');
  }
  return part;
}

String _sourceTextShapeId(Object? value) {
  final id = _presentationString(value, 'source text shape ID');
  if (id.length > 256 ||
      !RegExp(r'^[0-9]+$').hasMatch(id) ||
      BigInt.parse(id) > BigInt.from(0xffffffff)) {
    throw const FormatException('Invalid original source shape ID');
  }
  return id;
}

int _sourceStructureMm(Object? value, {bool positive = false}) {
  if (value is! num ||
      !value.isFinite ||
      value < -1000 ||
      value > 1000 ||
      positive && value <= 0) {
    throw const FormatException('Invalid source table millimetre dimension');
  }
  final match = RegExp(r'^(-?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$')
      .firstMatch(value.toString());
  if (match == null) throw const FormatException('Invalid decimal dimension');
  final fraction = match.group(3) ?? '';
  final coefficient = BigInt.parse(
    match.group(1)! + match.group(2)! + fraction,
  );
  if (coefficient == BigInt.zero) return 0;
  final shift = 2 + int.parse(match.group(4) ?? '0') - fraction.length;
  final BigInt result;
  if (shift >= 0) {
    result = coefficient * BigInt.from(10).pow(shift);
  } else {
    final divisor = BigInt.from(10).pow(-shift);
    if (coefficient.remainder(divisor) != BigInt.zero) {
      throw const FormatException(
        'Source table dimensions require exact hundredths',
      );
    }
    result = coefficient ~/ divisor;
  }
  return result.toInt();
}

List<num> _sourceStructureSizes(List<num> values) {
  if (values.isEmpty || values.length > 100) {
    throw const FormatException(
      'A bounded nonempty table size list is required',
    );
  }
  var total = 0;
  for (final value in values) {
    total += _sourceStructureMm(value, positive: true);
  }
  if (total > 100000)
    throw const FormatException('Table extent exceeds 1000mm');
  return List<num>.unmodifiable(values);
}

String _sourceStructureAlias(Object? value) {
  final alias = _presentationString(value, 'source table alias');
  if (!RegExp(r'^new-table-[A-Za-z0-9_-]{1,64}$').hasMatch(alias)) {
    throw const FormatException('Invalid source table alias');
  }
  return alias;
}

String _sourceStructureId(Object? value) {
  final id = _presentationString(value, 'source table identity');
  if (id.length > 256 ||
      !_sourceTextScalar(id) ||
      id.runes.any((value) => value < 32)) {
    throw const FormatException('Invalid source table identity');
  }
  return id;
}

Object? _sourceStructureJsonValue(Object? value) {
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('Source structure JSON keys must be strings');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sourceStructureJsonValue(value[key])};
  }
  if (value is List)
    return [for (final child in value) _sourceStructureJsonValue(child)];
  if (value == null ||
      value is String ||
      value is bool ||
      value is int ||
      value is double && value.isFinite)
    return value;
  throw const FormatException('Invalid source structure JSON value');
}

String _sourceStructureCanonical(Object? value) =>
    jsonEncode(_sourceStructureJsonValue(value));

class WindowsOfficeSourceStructureAuthority {
  factory fromJson(Map<String, dynamic> json) =>
      WindowsOfficeSourceStructureAuthority._(json);

  new _(Map<String, dynamic> json)
    : kind = _presentationString(json['kind'], 'source structure kind'),
      version = _presentationInt(json['version'], 'source structure version'),
      sourceSha256 = _sourceTextHash(
        json['sourceSha256'],
        'source structure SHA',
      ),
      sourcePart = _sourceTextPart(json['sourcePart']),
      partSha256 = _sourceTextHash(json['partSha256'], 'source part SHA'),
      shapeIdInventorySha256 = _sourceTextHash(
        json['shapeIdInventorySha256'],
        'source shape inventory SHA',
      ),
      shapeIdCount = _presentationInt(
        json['shapeIdCount'],
        'source shape count',
        minimum: 0,
      ),
      canAddTable = _presentationBool(
        json['canAddTable'],
        'source canAddTable',
      ) {
    _presentationFields(json, const {
      'kind',
      'version',
      'sourceSha256',
      'sourcePart',
      'partSha256',
      'shapeIdInventorySha256',
      'shapeIdCount',
      'canAddTable',
    });
    if (kind != 'sourceStructure' || version != 1 || shapeIdCount > 131072) {
      throw const FormatException('Unsupported source structure authority');
    }
  }

  final String kind;
  final int version;
  final String sourceSha256;
  final String sourcePart;
  final String partSha256;
  final String shapeIdInventorySha256;
  final int shapeIdCount;
  final bool canAddTable;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'version': version,
    'sourceSha256': sourceSha256,
    'sourcePart': sourcePart,
    'partSha256': partSha256,
    'shapeIdInventorySha256': shapeIdInventorySha256,
    'shapeIdCount': shapeIdCount,
    'canAddTable': canAddTable,
  };
}

class WindowsOfficeSourceTextPatchAuthority {
  factory fromJson(Map<String, dynamic> json) =>
      WindowsOfficeSourceTextPatchAuthority._(json);

  new _(Map<String, dynamic> json)
    : kind = _presentationString(json['kind'], 'source authority kind'),
      version = _presentationInt(json['version'], 'source authority version'),
      sourceSha256 = _sourceTextHash(
        json['sourceSha256'],
        'source authority SHA',
      ),
      sourcePart = _sourceTextPart(json['sourcePart']),
      shapeId = _sourceTextShapeId(json['shapeId']),
      frameSha256 = _sourceTextHash(json['frameSha256'], 'source frame SHA') {
    _presentationFields(json, const {
      'kind',
      'version',
      'sourceSha256',
      'sourcePart',
      'shapeId',
      'frameSha256',
    });
    if (kind != 'sourceTextPatch' || version != 1) {
      throw const FormatException('Unsupported source text authority');
    }
  }

  final String kind;
  final int version;
  final String sourceSha256;
  final String sourcePart;
  final String shapeId;
  final String frameSha256;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'version': version,
    'sourceSha256': sourceSha256,
    'sourcePart': sourcePart,
    'shapeId': shapeId,
    'frameSha256': frameSha256,
  };
}

class WindowsOfficeSourceTextPatchSegment {
  factory fromJson(Map<String, dynamic> json) =>
      WindowsOfficeSourceTextPatchSegment._(json);

  new _(Map<String, dynamic> json)
    : startUtf16 = _presentationInt(
        json['startUtf16'],
        'source segment start',
        minimum: 0,
      ),
      endUtf16 = _presentationInt(
        json['endUtf16'],
        'source segment end',
        minimum: 0,
      ),
      editable = _presentationBool(
        json['editable'],
        'source segment editable',
      ) {
    _presentationFields(json, const {'startUtf16', 'endUtf16', 'editable'});
    if (endUtf16 < startUtf16 || endUtf16 > _sourceTextPatchLimit) {
      throw const FormatException('Invalid source segment range');
    }
  }

  final int startUtf16;
  final int endUtf16;
  final bool editable;
  Map<String, Object?> toJson() => {
    'startUtf16': startUtf16,
    'endUtf16': endUtf16,
    'editable': editable,
  };
}

class WindowsOfficeSourceTextPatchProtectedRange {
  factory fromJson(Map<String, dynamic> json) =>
      WindowsOfficeSourceTextPatchProtectedRange._(json);

  new _(Map<String, dynamic> json)
    : startUtf16 = _presentationInt(
        json['startUtf16'],
        'source protected start',
        minimum: 0,
      ),
      endUtf16 = _presentationInt(
        json['endUtf16'],
        'source protected end',
        minimum: 0,
      ),
      reason = _presentationString(json['reason'], 'source protected reason') {
    _presentationFields(json, const {'startUtf16', 'endUtf16', 'reason'});
    if (endUtf16 < startUtf16 ||
        endUtf16 > _sourceTextPatchLimit ||
        !_sourceTextPatchReasons.contains(reason)) {
      throw const FormatException('Invalid source protected range');
    }
  }

  final int startUtf16;
  final int endUtf16;
  final String reason;
  Map<String, Object?> toJson() => {
    'startUtf16': startUtf16,
    'endUtf16': endUtf16,
    'reason': reason,
  };
}

class WindowsOfficeSourceTextPatch {
  factory fromJson(Map<String, dynamic> json) =>
      WindowsOfficeSourceTextPatch._(json);

  new _(Map<String, dynamic> json)
    : canReplace = _presentationBool(json['canReplace'], 'source canReplace'),
      truncated = _presentationBool(json['truncated'], 'source truncated'),
      text = _presentationString(json['text'], 'source text', allowEmpty: true),
      utf16Length = _presentationInt(
        json['utf16Length'],
        'source UTF16 length',
        minimum: 0,
      ),
      textSha256 = _sourceTextHash(json['textSha256'], 'source text SHA'),
      segments = List<WindowsOfficeSourceTextPatchSegment>.unmodifiable([
        for (final value in _presentationList(
          json['segments'],
          'source segments',
        ))
          WindowsOfficeSourceTextPatchSegment.fromJson(
            _presentationMap(value, 'source segment'),
          ),
      ]),
      protectedRanges =
          List<WindowsOfficeSourceTextPatchProtectedRange>.unmodifiable([
            for (final value in _presentationList(
              json['protectedRanges'],
              'source protected ranges',
            ))
              WindowsOfficeSourceTextPatchProtectedRange.fromJson(
                _presentationMap(value, 'source protected range'),
              ),
          ]) {
    _presentationFields(json, const {
      'canReplace',
      'truncated',
      'text',
      'utf16Length',
      'textSha256',
      'segments',
      'protectedRanges',
    });
    if (utf16Length > _sourceTextPatchLimit ||
        utf16Length != text.length ||
        !_sourceTextScalar(text) ||
        sha256.convert(utf8.encode(text)).toString() != textSha256 ||
        segments.length > 4096 ||
        protectedRanges.length > 4096 ||
        canReplace && truncated) {
      throw const FormatException('Invalid or incomplete source text proof');
    }
    var cursor = 0;
    for (final segment in segments) {
      if (segment.startUtf16 < cursor ||
          !truncated && segment.startUtf16 != cursor ||
          !_sourceTextBoundary(text, segment.startUtf16) ||
          !_sourceTextBoundary(text, segment.endUtf16)) {
        throw const FormatException('Invalid source text segment coverage');
      }
      cursor = segment.endUtf16;
    }
    if (!truncated && cursor != utf16Length ||
        canReplace && !segments.any((segment) => segment.editable)) {
      throw const FormatException(
        'Missing complete editable source text coverage',
      );
    }
    for (final range in protectedRanges) {
      if (!_sourceTextBoundary(text, range.startUtf16) ||
          !_sourceTextBoundary(text, range.endUtf16)) {
        throw const FormatException('Invalid source protected scalar boundary');
      }
    }
  }

  final bool canReplace;
  final bool truncated;
  final String text;
  final int utf16Length;
  final String textSha256;
  final List<WindowsOfficeSourceTextPatchSegment> segments;
  final List<WindowsOfficeSourceTextPatchProtectedRange> protectedRanges;

  bool allowsRange(int startUtf16, int endUtf16) {
    if (!canReplace ||
        truncated ||
        endUtf16 < startUtf16 ||
        !_sourceTextBoundary(text, startUtf16) ||
        !_sourceTextBoundary(text, endUtf16))
      return false;
    bool touches(int start, int end) => startUtf16 == endUtf16
        ? start <= startUtf16 && startUtf16 <= end
        : start == end
        ? startUtf16 < start && start < endUtf16
        : startUtf16 < end && start < endUtf16;
    if (segments.any(
          (segment) =>
              !segment.editable &&
              touches(segment.startUtf16, segment.endUtf16),
        ) ||
        protectedRanges.any(
          (range) =>
              range.reason != 'comment' &&
              range.reason != 'processingInstruction' &&
              touches(range.startUtf16, range.endUtf16),
        ))
      return false;
    return segments.any(
      (segment) =>
          segment.editable &&
          (startUtf16 == endUtf16
              ? segment.startUtf16 <= startUtf16 &&
                    startUtf16 <= segment.endUtf16
              : startUtf16 < segment.endUtf16 && segment.startUtf16 < endUtf16),
    );
  }

  Map<String, Object?> toJson() => {
    'canReplace': canReplace,
    'truncated': truncated,
    'text': text,
    'utf16Length': utf16Length,
    'textSha256': textSha256,
    'segments': [for (final segment in segments) segment.toJson()],
    'protectedRanges': [for (final range in protectedRanges) range.toJson()],
  };
}

class WindowsOfficePresentationCell {
  new _(Map<String, dynamic> json)
    : id = _presentationString(json['id'], 'cell.id'),
      row = _presentationInt(json['row'], 'cell.row', minimum: 0),
      column = _presentationInt(json['column'], 'cell.column', minimum: 0),
      rowSpan = _presentationInt(json['rowSpan'], 'cell.rowSpan', minimum: 1),
      columnSpan = _presentationInt(
        json['columnSpan'],
        'cell.columnSpan',
        minimum: 1,
      ),
      covered = _presentationBool(json['covered'], 'cell.covered'),
      anchorCellId = _presentationNullableString(
        json['anchorCellId'],
        'cell.anchorCellId',
      ),
      text = _presentationNullableString(
        json['text'],
        'cell.text',
        allowEmpty: true,
      ),
      textDetails = _presentationTextDetails(json['textDetails']),
      sourceTextPatch = json['sourceTextPatch'] == null
          ? null
          : WindowsOfficeSourceTextPatch.fromJson(
              _presentationMap(json['sourceTextPatch'], 'cell.sourceTextPatch'),
            ),
      rawStyle = _presentationRawMap(json['rawStyle'], 'cell.rawStyle') {
    _presentationFields(json, const {
      'id',
      'row',
      'column',
      'rowSpan',
      'columnSpan',
      'covered',
      'anchorCellId',
      'text',
      'textDetails',
      'rawStyle',
      'sourceTextPatch',
    });
    if (covered && sourceTextPatch?.canReplace == true) {
      throw const FormatException(
        'Covered cells cannot receive source text permission',
      );
    }
  }

  final String id;
  final int row;
  final int column;
  final int rowSpan;
  final int columnSpan;
  final bool covered;
  final String? anchorCellId;
  final String? text;
  final WindowsOfficeTextDetails? textDetails;
  final WindowsOfficeSourceTextPatch? sourceTextPatch;
  final Map<String, dynamic> rawStyle;
}

class WindowsOfficePresentationTable {
  new _(Map<String, dynamic> json)
    : id = _presentationString(json['id'], 'table.id'),
      ownerId = _presentationString(json['ownerId'], 'table.ownerId'),
      tableSha256 = _presentationTableHash(json['tableSha256']),
      rowCount = _presentationInt(
        json['rowCount'],
        'table.rowCount',
        minimum: 1,
      ),
      columnCount = _presentationInt(
        json['columnCount'],
        'table.columnCount',
        minimum: 1,
      ),
      totalCellCount = _presentationTotalCellCount(json),
      truncated = _presentationFlag(json, 'truncated'),
      rowHeightsHmm = _presentationNativeDimensions(
        json['rowHeightsHmm'],
        'table.rowHeightsHmm',
      ),
      columnWidthsHmm = _presentationNativeDimensions(
        json['columnWidthsHmm'],
        'table.columnWidthsHmm',
      ),
      cells = List<WindowsOfficePresentationCell>.unmodifiable([
        for (final item in _presentationList(json['cells'], 'table.cells'))
          WindowsOfficePresentationCell._(_presentationMap(item, 'table.cell')),
      ]),
      rawStyle = _presentationRawMap(json['rawStyle'], 'table.rawStyle'),
      capabilities = WindowsOfficePresentationTableCapabilities._(
        json.containsKey('capabilities')
            ? _presentationMap(json['capabilities'], 'table.capabilities')
            : const <String, dynamic>{},
      ),
      nativeBoundsHmm = _presentationNativeBounds(json['nativeBoundsHmm']),
      sourceTextPatchAuthority = json['sourceTextPatchAuthority'] == null
          ? null
          : WindowsOfficeSourceTextPatchAuthority.fromJson(
              _presentationMap(
                json['sourceTextPatchAuthority'],
                'table.sourceTextPatchAuthority',
              ),
            ),
      authoredGeometry = _presentationAuthoredGeometry(json) {
    _presentationFields(json, const {
      'id',
      'ownerId',
      'tableSha256',
      'rowCount',
      'columnCount',
      'totalCellCount',
      'truncated',
      'rowHeightsHmm',
      'columnWidthsHmm',
      'cells',
      'rawStyle',
      'capabilities',
      'nativeBoundsHmm',
      'authoredGeometry',
      'sourceTextPatchAuthority',
    });
    final observedRows = truncated && rowCount > 100 ? 100 : rowCount;
    final observedColumns = truncated && columnCount > 100 ? 100 : columnCount;
    if (totalCellCount != rowCount * columnCount ||
        rowHeightsHmm.length != observedRows ||
        columnWidthsHmm.length != observedColumns) {
      throw const FormatException('Invalid presentation table dimensions');
    }
    if (capabilities._hasWriteCapability &&
        (truncated ||
            tableSha256 == null ||
            totalCellCount > 100 ||
            rowHeightsHmm.contains(null) ||
            columnWidthsHmm.contains(null) ||
            !_presentationAuthoredGridMatches(authoredGeometry))) {
      throw const FormatException(
        'Incomplete presentation table cannot be edited',
      );
    }
    final sourceWrite = cells.any(
      (cell) => cell.sourceTextPatch?.canReplace == true,
    );
    if (sourceWrite &&
        (sourceTextPatchAuthority == null ||
            totalCellCount > 100 ||
            cells.length != totalCellCount)) {
      throw const FormatException('Incomplete source table permission');
    }
    if (sourceTextPatchAuthority case final authority?) {
      if (authoredGeometry == null ||
          authority.sourcePart != authoredGeometry!['sourcePart'] ||
          authority.shapeId != authoredGeometry!['shapeId']) {
        throw const FormatException(
          'Source authority differs from authored geometry',
        );
      }
    }
    _validatePresentationTopology(this, requireComplete: sourceWrite);
  }

  final String id;
  final String ownerId;
  final String? tableSha256;
  final int rowCount;
  final int columnCount;
  final int totalCellCount;
  final bool truncated;
  final List<int?> rowHeightsHmm;
  final List<int?> columnWidthsHmm;
  final List<WindowsOfficePresentationCell> cells;
  final Map<String, dynamic> rawStyle;
  final WindowsOfficePresentationTableCapabilities capabilities;
  final Map<String, int>? nativeBoundsHmm;
  final Map<String, dynamic>? authoredGeometry;
  final WindowsOfficeSourceTextPatchAuthority? sourceTextPatchAuthority;
}

Map<String, dynamic> _presentationMap(Object? value, String name) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('Invalid $name');
  }
  return Map<String, dynamic>.from(value);
}

List<dynamic> _presentationList(Object? value, String name) {
  if (value is! List) throw FormatException('Invalid $name');
  return value;
}

void _presentationFields(Map<String, dynamic> json, Set<String> fields) {
  if (json.keys.any((key) => !fields.contains(key))) {
    throw const FormatException('Unknown presentation table field');
  }
}

String _presentationString(
  Object? value,
  String name, {
  bool allowEmpty = false,
}) {
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw FormatException('Invalid $name');
  }
  return value;
}

String? _presentationNullableString(
  Object? value,
  String name, {
  bool allowEmpty = false,
}) => value == null
    ? null
    : _presentationString(value, name, allowEmpty: allowEmpty);

int _presentationInt(Object? value, String name, {int? minimum}) {
  if (value is! int || (minimum != null && value < minimum)) {
    throw FormatException('Invalid $name');
  }
  return value;
}

bool _presentationBool(Object? value, String name) {
  if (value is! bool) throw FormatException('Invalid $name');
  return value;
}

bool _presentationFlag(Map<String, dynamic> json, String key) =>
    json.containsKey(key) ? _presentationBool(json[key], key) : false;

List<int> _presentationIntList(Object? value, String name, {int? minimum}) =>
    List<int>.unmodifiable([
      for (final item in _presentationList(value, name))
        _presentationInt(item, name, minimum: minimum),
    ]);

List<int?> _presentationNativeDimensions(Object? value, String name) =>
    List<int?>.unmodifiable([
      for (final item in _presentationList(value, name))
        if (item == null) null else _presentationInt(item, name, minimum: 0),
    ]);

String? _presentationTableHash(Object? value) {
  if (value == null) return null;
  final hash = _presentationString(value, 'table.tableSha256');
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
    throw const FormatException('Invalid presentation table fingerprint');
  }
  return hash;
}

int _presentationTotalCellCount(Map<String, dynamic> json) {
  final expected =
      _presentationInt(json['rowCount'], 'table.rowCount', minimum: 1) *
      _presentationInt(json['columnCount'], 'table.columnCount', minimum: 1);
  if (expected < 1)
    throw const FormatException('Invalid presentation table size');
  return json.containsKey('totalCellCount')
      ? _presentationInt(
          json['totalCellCount'],
          'table.totalCellCount',
          minimum: 1,
        )
      : expected;
}

WindowsOfficeTextDetails? _presentationTextDetails(Object? value) {
  if (value == null) return null;
  try {
    return WindowsOfficeTextDetails._(
      _presentationMap(value, 'cell.textDetails'),
    );
  } on TypeError {
    throw const FormatException('Invalid presentation cell text details');
  }
}

Object? _presentationRawValue(Object? value) {
  if (value == null || value is String || value is bool || value is int)
    return value;
  if (value is double && value.isFinite) return value;
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_presentationRawValue));
  }
  if (value is Map) {
    final json = _presentationMap(value, 'presentation raw property');
    return Map<String, dynamic>.unmodifiable({
      for (final entry in json.entries)
        entry.key: _presentationRawValue(entry.value),
    });
  }
  throw const FormatException('Invalid presentation raw property value');
}

Map<String, dynamic> _presentationRawMap(Object? value, String name) =>
    Map<String, dynamic>.unmodifiable({
      for (final entry in _presentationMap(value, name).entries)
        entry.key: _presentationRawValue(entry.value),
    });

Map<String, int>? _presentationNativeBounds(Object? value) {
  if (value == null) return null;
  final json = _presentationMap(value, 'table.nativeBoundsHmm');
  _presentationFields(json, const {'x', 'y', 'width', 'height'});
  return Map<String, int>.unmodifiable({
    for (final key in const ['x', 'y', 'width', 'height'])
      key: _presentationInt(json[key], 'table.nativeBoundsHmm.$key'),
  });
}

Map<String, dynamic>? _presentationAuthoredGeometry(
  Map<String, dynamic> table,
) {
  final value = table['authoredGeometry'];
  if (value == null) return null;
  final json = _presentationMap(value, 'table.authoredGeometry');
  _presentationFields(json, const {
    'sourcePart',
    'shapeId',
    'positionEmu',
    'extentEmu',
    'columnWidthsEmu',
    'rowHeightsEmu',
  });
  final part = _presentationString(
    json['sourcePart'],
    'authoredGeometry.sourcePart',
  );
  if (part.length > 1024 ||
      part.contains(r'\') ||
      part.contains(':') ||
      part.runes.any((rune) => rune < 32) ||
      part
          .split('/')
          .any(
            (segment) => segment.isEmpty || segment == '.' || segment == '..',
          )) {
    throw const FormatException('Invalid authored presentation package part');
  }
  final position = _presentationMap(
    json['positionEmu'],
    'authoredGeometry.positionEmu',
  );
  final extent = _presentationMap(
    json['extentEmu'],
    'authoredGeometry.extentEmu',
  );
  _presentationFields(position, const {'x', 'y'});
  _presentationFields(extent, const {'width', 'height'});
  final widths = _presentationIntList(
    json['columnWidthsEmu'],
    'authoredGeometry.columnWidthsEmu',
    minimum: 1,
  );
  final heights = _presentationIntList(
    json['rowHeightsEmu'],
    'authoredGeometry.rowHeightsEmu',
    minimum: 1,
  );
  if (widths.length != table['columnCount'] ||
      heights.length != table['rowCount']) {
    throw const FormatException(
      'Invalid authored presentation grid dimensions',
    );
  }
  return Map<String, dynamic>.unmodifiable({
    'sourcePart': part,
    'shapeId': _presentationString(json['shapeId'], 'authoredGeometry.shapeId'),
    'positionEmu': Map<String, int>.unmodifiable({
      'x': _presentationInt(position['x'], 'authoredGeometry.positionEmu.x'),
      'y': _presentationInt(position['y'], 'authoredGeometry.positionEmu.y'),
    }),
    'extentEmu': Map<String, int>.unmodifiable({
      'width': _presentationInt(
        extent['width'],
        'authoredGeometry.extentEmu.width',
        minimum: 1,
      ),
      'height': _presentationInt(
        extent['height'],
        'authoredGeometry.extentEmu.height',
        minimum: 1,
      ),
    }),
    'columnWidthsEmu': widths,
    'rowHeightsEmu': heights,
  });
}

bool _presentationAuthoredGridMatches(Map<String, dynamic>? geometry) {
  if (geometry == null) return false;
  final extent = geometry['extentEmu'] as Map<String, int>;
  final widths = geometry['columnWidthsEmu'] as List<int>;
  final heights = geometry['rowHeightsEmu'] as List<int>;
  BigInt sum(List<int> values) => values.fold<BigInt>(
    BigInt.zero,
    (total, value) => total + BigInt.from(value),
  );
  return sum(widths) == BigInt.from(extent['width']!) &&
      sum(heights) == BigInt.from(extent['height']!);
}

void _validatePresentationTopology(
  WindowsOfficePresentationTable table, {
  bool requireComplete = false,
}) {
  final ids = <String, WindowsOfficePresentationCell>{};
  final coordinates = <String>{};
  for (final cell in table.cells) {
    if (cell.row >= table.rowCount ||
        cell.rowSpan > table.rowCount - cell.row ||
        cell.column >= table.columnCount ||
        cell.columnSpan > table.columnCount - cell.column ||
        ids.containsKey(cell.id) ||
        !coordinates.add('${cell.row}:${cell.column}')) {
      throw const FormatException(
        'Invalid presentation cell bounds or identity',
      );
    }
    ids[cell.id] = cell;
  }
  if (table.truncated && !requireComplete) return;
  if (table.cells.length != table.totalCellCount) {
    throw const FormatException('Incomplete presentation table grid');
  }
  final anchors = <String, String>{};
  for (final cell in table.cells.where((cell) => !cell.covered)) {
    if (cell.anchorCellId != null) {
      throw const FormatException(
        'Presentation anchor cannot reference another anchor',
      );
    }
    for (var row = cell.row; row < cell.row + cell.rowSpan; row++) {
      for (
        var column = cell.column;
        column < cell.column + cell.columnSpan;
        column++
      ) {
        if (anchors.putIfAbsent('$row:$column', () => cell.id) != cell.id) {
          throw const FormatException('Overlapping presentation table anchors');
        }
      }
    }
  }
  for (final cell in table.cells) {
    final anchorId = anchors['${cell.row}:${cell.column}'];
    if (anchorId == null ||
        (cell.covered
            ? cell.anchorCellId != anchorId || ids[anchorId]?.covered != false
            : cell.id != anchorId)) {
      throw const FormatException(
        'Invalid presentation table anchor partition',
      );
    }
  }
}

List<WindowsOfficePresentationTable>? _presentationTables(
  Map<String, dynamic> json,
) {
  final value = json['presentationTables'];
  if (value == null) return null;
  return List<WindowsOfficePresentationTable>.unmodifiable([
    for (final item in _presentationList(value, 'slide.presentationTables'))
      WindowsOfficePresentationTable._(
        _presentationMap(item, 'slide.presentationTable'),
      ),
  ]);
}

void _validatePresentationCatalog(
  String ownerId,
  List<WindowsOfficePresentationTable>? tables,
  int? count,
  bool ownerTruncated,
  bool canAddTable,
) {
  if (tables == null) {
    if (canAddTable) {
      throw const FormatException(
        'Unknown presentation catalog cannot add a table',
      );
    }
    return;
  }
  if (count != null &&
      (count < tables.length || (!ownerTruncated && count != tables.length))) {
    throw const FormatException('Invalid presentation table catalog count');
  }
  final ids = <String>{};
  for (final table in tables) {
    if (table.ownerId != ownerId || !ids.add(table.id)) {
      throw const FormatException(
        'Invalid presentation table owner or identity',
      );
    }
  }
  if ((ownerTruncated || (count ?? tables.length) > 20) &&
      (canAddTable ||
          tables.any((table) => table.capabilities._hasWriteCapability))) {
    throw const FormatException(
      'Incomplete presentation catalog cannot be edited',
    );
  }
}

class WindowsOfficeSlide {
  new _(Map<String, dynamic> json)
    : id = json['id'] as String,
      width = (json['width'] as num).toDouble(),
      height = (json['height'] as num).toDouble(),
      backgroundStyle = json['backgroundStyle'] as String?,
      backgroundColor = json['backgroundColor'] as int?,
      masterId = json['masterId'] as String?,
      layoutCode = json['layoutCode'] as int?,
      designSha256 = json['designSha256'] as String?,
      visible = json['visible'] as bool?,
      showMasterObjects = json['showMasterObjects'] as bool?,
      presentationTables = _presentationTables(json),
      presentationTableCount = json['presentationTableCount'] == null
          ? null
          : _presentationInt(
              json['presentationTableCount'],
              'slide.presentationTableCount',
              minimum: 0,
            ),
      presentationTablesTruncated = _presentationFlag(
        json,
        'presentationTablesTruncated',
      ),
      presentationTablesUnknownReason = _presentationNullableString(
        json['presentationTablesUnknownReason'],
        'slide.presentationTablesUnknownReason',
      ),
      canAddTable = _presentationFlag(json, 'canAddTable'),
      canDuplicate = _presentationFlag(json, 'canDuplicate'),
      sourceStructureAuthority = json['sourceStructureAuthority'] == null
          ? null
          : WindowsOfficeSourceStructureAuthority._(
              _presentationMap(
                json['sourceStructureAuthority'],
                'slide source structure authority',
              ),
            ),
      shapes = List.unmodifiable([
        for (final shape in json['shapes'] as List)
          WindowsOfficeShape._(Map<String, dynamic>.from(shape as Map)),
      ]) {
    _validatePresentationCatalog(
      id,
      presentationTables,
      presentationTableCount,
      presentationTablesTruncated,
      canAddTable,
    );
  }
  final String id;
  final double width;
  final double height;
  final String? backgroundStyle;
  final int? backgroundColor;
  final String? masterId;
  final int? layoutCode;
  final String? designSha256;
  final bool? visible;
  final bool? showMasterObjects;
  final List<WindowsOfficeShape> shapes;
  final List<WindowsOfficePresentationTable>? presentationTables;
  final int? presentationTableCount;
  final bool presentationTablesTruncated;
  final String? presentationTablesUnknownReason;
  final bool canAddTable;
  final bool canDuplicate;
  final WindowsOfficeSourceStructureAuthority? sourceStructureAuthority;
}

class WindowsOfficeWordImageTarget {
  new _(Map<String, dynamic> json)
    : ownerId = json['ownerId'] as String,
      paragraphId = json['paragraphId'] as String,
      canAdd = json['canAdd'] == true,
      canMoveHere = json['canMoveHere'] == true;

  final String ownerId;
  final String paragraphId;
  final bool canAdd;
  final bool canMoveHere;
}

class WindowsOfficeWordImage {
  new _(Map<String, dynamic> json)
    : id = json['id'] as String,
      ownerId = json['ownerId'] as String?,
      paragraphId = json['paragraphId'] as String?,
      tableId = json['tableId'] as String?,
      cell = json['cell'] as String?,
      anchorType = json['anchorType'] as String?,
      offsetUtf16 = _frameOffset(json),
      canMove = json['canMove'] == true && _frameOffset(json) != null,
      canDelete = json['canDelete'] == true && _frameOffset(json) != null,
      width = (json['width'] as num?)?.toDouble(),
      height = (json['height'] as num?)?.toDouble(),
      nativeGraphicSha256 = json['nativeGraphicSha256'] as String?,
      image = json['image'] == null
          ? null
          : WindowsOfficeImageDetails._(
              Map<String, dynamic>.from(json['image'] as Map),
            );
  final String id;
  final String? ownerId;
  final String? paragraphId;
  final String? tableId;
  final String? cell;
  final String? anchorType;
  final int? offsetUtf16;
  final bool canMove;
  final bool canDelete;
  final double? width;
  final double? height;
  final String? nativeGraphicSha256;
  final WindowsOfficeImageDetails? image;

  static int? _frameOffset(Map<String, dynamic> json) {
    final offset = json['offsetUtf16'];
    return json['anchorType'] == 'AS_CHARACTER' && offset is int && offset >= 0
        ? offset
        : null;
  }
}

void _validateSourceStructureSnapshot(WindowsOfficeSnapshot snapshot) {
  final parts = <String>{};
  var canCreate = false;
  for (final slide in snapshot.slides) {
    final authority = slide.sourceStructureAuthority;
    if (authority == null) continue;
    if (snapshot.kind != 'presentation' ||
        authority.sourceSha256 != snapshot.sourceSha256 ||
        !parts.add(authority.sourcePart)) {
      throw const FormatException(
        'Source structure authority is stale or duplicated',
      );
    }
    canCreate = canCreate || authority.canAddTable;
  }
  if (!canCreate) return;
  var tableCount = 0;
  var cellCount = 0;
  for (final slide in snapshot.slides) {
    final tables = slide.presentationTables;
    if (tables == null ||
        slide.presentationTableCount != tables.length ||
        slide.presentationTablesTruncated ||
        slide.presentationTablesUnknownReason != null &&
            !{
              'raw_state_unavailable',
              'read_budget_exhausted',
            }.contains(slide.presentationTablesUnknownReason)) {
      throw const FormatException(
        'Source creation requires complete source owner inventories',
      );
    }
    tableCount += tables.length;
    for (final table in tables) {
      if (table.cells.length != table.totalCellCount ||
          table.totalCellCount > 100 - cellCount ||
          table.authoredGeometry == null ||
          slide.sourceStructureAuthority != null &&
              table.authoredGeometry!['sourcePart'] !=
                  slide.sourceStructureAuthority!.sourcePart ||
          slide.shapes
                  .where(
                    (shape) =>
                        shape.id == table.id &&
                        shape.type == 'com.sun.star.drawing.TableShape',
                  )
                  .length !=
              1) {
        throw const FormatException(
          'Source creation requires a complete source-bound table grid',
        );
      }
      _validatePresentationTopology(table, requireComplete: true);
      cellCount += table.totalCellCount;
    }
    if (slide.shapes
            .where((shape) => shape.type == 'com.sun.star.drawing.TableShape')
            .length !=
        tables.length) {
      throw const FormatException(
        'Source creation table and shape inventories differ',
      );
    }
  }
  if (tableCount >= 20 || cellCount >= 100) {
    throw const FormatException(
      'No complete source table creation budget remains',
    );
  }
}

void _validateSourcePresentationSnapshot(WindowsOfficeSnapshot snapshot) {
  _validateSourceStructureSnapshot(snapshot);
  final sourceKeys = <String>{};
  final tableIds = <String>{};
  for (final master in snapshot.masters ?? const <WindowsOfficeMaster>[]) {
    for (final table
        in master.presentationTables ??
            const <WindowsOfficePresentationTable>[]) {
      if (table.sourceTextPatchAuthority != null ||
          table.cells.any((cell) => cell.sourceTextPatch?.canReplace == true)) {
        throw const FormatException(
          'Master source text authority is unsupported',
        );
      }
    }
  }
  for (final slide in snapshot.slides) {
    final tables =
        slide.presentationTables ?? const <WindowsOfficePresentationTable>[];
    for (final table in tables) {
      final authority = table.sourceTextPatchAuthority;
      final sourceWrite = table.cells.any(
        (cell) => cell.sourceTextPatch?.canReplace == true,
      );
      if (authority != null) {
        if (snapshot.kind != 'presentation' ||
            authority.sourceSha256 != snapshot.sourceSha256 ||
            !sourceKeys.add(
              jsonEncode([authority.sourcePart, authority.shapeId]),
            ) ||
            !tableIds.add(table.id)) {
          throw const FormatException(
            'Source authority is stale or duplicated in this snapshot',
          );
        }
      }
      if (!sourceWrite) continue;
      if (authority == null ||
          slide.presentationTablesTruncated ||
          slide.presentationTableCount == null ||
          slide.presentationTableCount != tables.length ||
          tables.length > 20 ||
          slide.presentationTablesUnknownReason != null &&
              !{
                'raw_state_unavailable',
                'read_budget_exhausted',
              }.contains(slide.presentationTablesUnknownReason) ||
          slide.shapes
                  .where(
                    (shape) =>
                        shape.id == table.id &&
                        shape.type == 'com.sun.star.drawing.TableShape',
                  )
                  .length !=
              1) {
        throw const FormatException(
          'Source text permission requires a complete visible owner and table',
        );
      }
    }
  }
}

class WindowsOfficeSnapshot {
  factory fromJson(
    Map<String, dynamic> json, {
    Future<void> Function()? onDisposePreview,
  }) => WindowsOfficeSnapshot._(json, onDisposePreview: onDisposePreview);

  new _(Map<String, dynamic> json, {this._onDisposePreview})
    : kind = json['kind'] as String,
      sourceSha256 = json['sourceSha256'] as String,
      supportsHwpTableInsert = json['supportsHwpTableInsert'] == true,
      previewPdfPath = json['previewPdfPath'] as String?,
      previewPageCount = json['previewPageCount'] as int?,
      bodyOwnerId = json['bodyOwnerId'] as String?,
      wordImageTargets = json['wordImageTargets'] == null
          ? null
          : List.unmodifiable([
              for (final item in json['wordImageTargets'] as List)
                WindowsOfficeWordImageTarget._(
                  Map<String, dynamic>.from(item as Map),
                ),
            ]),
      wordImages = json['wordImages'] == null
          ? null
          : List.unmodifiable([
              for (final item in json['wordImages'] as List)
                WindowsOfficeWordImage._(
                  Map<String, dynamic>.from(item as Map),
                ),
            ]),
      wordOwners = json['wordOwners'] == null
          ? null
          : List.unmodifiable([
              for (final item in json['wordOwners'] as List)
                WindowsOfficeWordOwner._(
                  Map<String, dynamic>.from(item as Map),
                ),
            ]),
      pageStyles = json['pageStyles'] == null
          ? null
          : List.unmodifiable([
              for (final item in json['pageStyles'] as List)
                WindowsOfficePageStyle._(
                  Map<String, dynamic>.from(item as Map),
                ),
            ]),
      blocks = json['blocks'] == null
          ? null
          : List.unmodifiable([
              for (final item in json['blocks'] as List)
                WindowsOfficeBodyBlock._(
                  Map<String, dynamic>.from(item as Map),
                ),
            ]),
      paragraphStyles = List.unmodifiable([
        for (final item in json['paragraphStyles'] as List? ?? const [])
          WindowsOfficeParagraphStyle._(Map<String, dynamic>.from(item as Map)),
      ]),
      masters = json['masters'] == null
          ? null
          : List.unmodifiable([
              for (final item in json['masters'] as List)
                WindowsOfficeMaster._(Map<String, dynamic>.from(item as Map)),
            ]),
      layoutOptions = List.unmodifiable([
        for (final item in json['layoutOptions'] as List? ?? const [])
          WindowsOfficeLayoutOption._(Map<String, dynamic>.from(item as Map)),
      ]),
      paragraphs = List.unmodifiable([
        for (final item in json['paragraphs'] as List)
          WindowsOfficeParagraph._(Map<String, dynamic>.from(item as Map)),
      ]),
      tables = List.unmodifiable([
        for (final item in json['tables'] as List)
          WindowsOfficeTable._(Map<String, dynamic>.from(item as Map)),
      ]),
      slides = List.unmodifiable([
        for (final item in json['slides'] as List)
          WindowsOfficeSlide._(Map<String, dynamic>.from(item as Map)),
      ]) {
    _validateSourcePresentationSnapshot(this);
  }
  final String kind;
  final String sourceSha256;
  final bool supportsHwpTableInsert;
  final String? previewPdfPath;
  final int? previewPageCount;
  final String? bodyOwnerId;
  final List<WindowsOfficeWordImageTarget>? wordImageTargets;
  final List<WindowsOfficeWordImage>? wordImages;
  final List<WindowsOfficeWordOwner>? wordOwners;
  final List<WindowsOfficePageStyle>? pageStyles;
  final List<WindowsOfficeBodyBlock>? blocks;
  final List<WindowsOfficeParagraphStyle> paragraphStyles;
  final List<WindowsOfficeMaster>? masters;
  final List<WindowsOfficeLayoutOption> layoutOptions;
  final List<WindowsOfficeParagraph> paragraphs;
  final List<WindowsOfficeTable> tables;
  final List<WindowsOfficeSlide> slides;
  final Future<void> Function()? _onDisposePreview;
  Future<void>? _previewDisposal;

  Future<void> disposePreview() =>
      _previewDisposal ??= Future<void>.sync(_onDisposePreview ?? () {});
}

class WindowsOfficeOperation {
  new _(Map<String, Object?> json) : _json = Map.unmodifiable(json);
  final Map<String, Object?> _json;
  Map<String, Object?> toJson() {
    final result = Map<String, Object?>.of(_json);
    if (_json['op'] == 'presentationSourceTableAdd') {
      result['columnWidthsMm'] = List<num>.of(
        _json['columnWidthsMm'] as List<num>,
      );
      result['rowHeightsMm'] = List<num>.of(_json['rowHeightsMm'] as List<num>);
    }
    return result;
  }

  factory docxTableStructureEdit({
    required String expectedSourceSha256,
    required int tableIndex,
    required String action,
    required int index,
    int? anchorIndex,
  }) => WindowsOfficeOperation._({
    'op': 'docxTableStructureEdit',
    'expectedSourceSha256': expectedSourceSha256,
    'tableIndex': tableIndex,
    'action': action,
    'index': index,
    'anchorIndex': ?anchorIndex,
  });

  factory presentationTableStructureEdit({
    required String expectedSourceSha256,
    required int slideIndex,
    required int shapeId,
    required String action,
    required int index,
  }) => WindowsOfficeOperation._({
    'op': 'presentationTableStructureEdit',
    'expectedSourceSha256': expectedSourceSha256,
    'slideIndex': slideIndex,
    'shapeId': shapeId,
    'action': action,
    'index': index,
  });

  factory pptxSlideSectionMove({
    required String expectedSourceSha256,
    required int sourceIndex,
    required int targetIndex,
    required bool after,
  }) => WindowsOfficeOperation._({
    'op': 'pptxSlideSectionMove',
    'expectedSourceSha256': expectedSourceSha256,
    'sourceIndex': sourceIndex,
    'targetIndex': targetIndex,
    'after': after,
  });

  factory pageGeometry({
    required String id,
    required String expectedLayoutSha256,
    double? width,
    double? height,
    bool? landscape,
    double? leftMargin,
    double? rightMargin,
    double? topMargin,
    double? bottomMargin,
  }) => WindowsOfficeOperation._({
    'op': 'pageGeometry',
    'id': id,
    'expectedLayoutSha256': expectedLayoutSha256,
    'width': ?width,
    'height': ?height,
    'landscape': ?landscape,
    'leftMargin': ?leftMargin,
    'rightMargin': ?rightMargin,
    'topMargin': ?topMargin,
    'bottomMargin': ?bottomMargin,
  });

  factory paragraphSplit({
    required String id,
    required String newId,
    required int offsetUtf16,
    required String expectedTextSha256,
  }) => WindowsOfficeOperation._({
    'op': 'paragraphSplit',
    'id': id,
    'newId': newId,
    'offsetUtf16': offsetUtf16,
    'expectedTextSha256': expectedTextSha256,
  });
  factory paragraphInsert({
    required String id,
    required String referenceId,
    required String position,
    required String expectedTextSha256,
    required String text,
  }) => WindowsOfficeOperation._({
    'op': 'paragraphInsert',
    'id': id,
    'referenceId': referenceId,
    'position': position,
    'expectedTextSha256': expectedTextSha256,
    'text': text,
  });
  factory hwpTableInsert({
    required String id,
    required String referenceId,
    required String expectedTextSha256,
    required int rows,
    required int columns,
    List<List<String>>? cells,
  }) => WindowsOfficeOperation._({
    'op': 'tableInsert',
    'id': id,
    'referenceId': referenceId,
    'position': 'after',
    'expectedTextSha256': expectedTextSha256,
    'rows': rows,
    'columns': columns,
    if (cells != null)
      'cells': List<List<String>>.unmodifiable([
        for (final row in cells) List<String>.unmodifiable(row),
      ]),
  });
  factory hwpTableStructure({
    required String id,
    required String action,
    required int index,
  }) => WindowsOfficeOperation._({
    'op': 'tableStructure',
    'id': id,
    'action': action,
    'index': index,
  });
  factory paragraphJoin({
    required String id,
    required String nextId,
    required String expectedTextSha256,
    required String expectedNextTextSha256,
  }) => WindowsOfficeOperation._({
    'op': 'paragraphJoin',
    'id': id,
    'nextId': nextId,
    'expectedTextSha256': expectedTextSha256,
    'expectedNextTextSha256': expectedNextTextSha256,
  });
  factory paragraphDelete({
    required String id,
    required String expectedTextSha256,
  }) => WindowsOfficeOperation._({
    'op': 'paragraphDelete',
    'id': id,
    'expectedTextSha256': expectedTextSha256,
  });
  factory paragraphFormat({
    required String id,
    required String expectedTextSha256,
    String? styleName,
    String? alignment,
    String? listKind,
    int? listLevel,
    bool? pageBreakBefore,
  }) => WindowsOfficeOperation._({
    'op': 'paragraphFormat',
    'id': id,
    'expectedTextSha256': expectedTextSha256,
    'styleName': ?styleName,
    'alignment': ?alignment,
    'listKind': ?listKind,
    'listLevel': ?listLevel,
    'pageBreakBefore': ?pageBreakBefore,
  });

  factory presentationSourceTableAdd({
    int authorityVersion = 1,
    required String id,
    required String ownerId,
    required String expectedSourceSha256,
    required String sourcePart,
    required String expectedSourcePartSha256,
    required String expectedShapeIdInventorySha256,
    required num xMm,
    required num yMm,
    required List<num> columnWidthsMm,
    required List<num> rowHeightsMm,
  }) {
    if (authorityVersion != 1)
      throw const FormatException('Unsupported source table authority');
    _sourceStructureAlias(id);
    _sourceStructureId(ownerId);
    _sourceTextHash(expectedSourceSha256, 'expected source SHA');
    _sourceTextHash(expectedSourcePartSha256, 'expected source part SHA');
    _sourceTextHash(
      expectedShapeIdInventorySha256,
      'expected shape inventory SHA',
    );
    _sourceTextPart(sourcePart);
    _sourceStructureMm(xMm);
    _sourceStructureMm(yMm);
    final widths = _sourceStructureSizes(columnWidthsMm);
    final heights = _sourceStructureSizes(rowHeightsMm);
    if (widths.length * heights.length > 100) {
      throw const FormatException(
        'The source table grid exceeds one hundred cells',
      );
    }
    return WindowsOfficeOperation._({
      'op': 'presentationSourceTableAdd',
      'authorityVersion': authorityVersion,
      'id': id,
      'ownerId': ownerId,
      'expectedSourceSha256': expectedSourceSha256,
      'sourcePart': sourcePart,
      'expectedSourcePartSha256': expectedSourcePartSha256,
      'expectedShapeIdInventorySha256': expectedShapeIdInventorySha256,
      'xMm': xMm,
      'yMm': yMm,
      'columnWidthsMm': widths,
      'rowHeightsMm': heights,
    });
  }

  factory presentationCellTextPatch({
    int authorityVersion = 1,
    required String ownerId,
    required String tableId,
    required String cellId,
    required String expectedSourceSha256,
    required String sourcePart,
    required String shapeId,
    required String expectedSourceFrameSha256,
    required String expectedTextSha256,
    required int startUtf16,
    required int endUtf16,
    required String text,
  }) {
    if (authorityVersion != 1 ||
        startUtf16 < 0 ||
        endUtf16 < startUtf16 ||
        endUtf16 > _sourceTextPatchLimit ||
        text.length > _sourceTextPatchLimit ||
        !_sourceTextScalar(text) ||
        [ownerId, tableId, cellId].any(
          (value) =>
              value.isEmpty ||
              value.length > 256 ||
              value.runes.any((rune) => rune < 32),
        )) {
      throw const FormatException(
        'Invalid presentation source text patch request',
      );
    }
    _sourceTextHash(expectedSourceSha256, 'expected source SHA');
    _sourceTextHash(expectedSourceFrameSha256, 'expected source frame SHA');
    _sourceTextHash(expectedTextSha256, 'expected source text SHA');
    _sourceTextPart(sourcePart);
    _sourceTextShapeId(shapeId);
    return WindowsOfficeOperation._({
      'op': 'presentationCellTextPatch',
      'authorityVersion': authorityVersion,
      'ownerId': ownerId,
      'tableId': tableId,
      'cellId': cellId,
      'expectedSourceSha256': expectedSourceSha256,
      'sourcePart': sourcePart,
      'shapeId': shapeId,
      'expectedSourceFrameSha256': expectedSourceFrameSha256,
      'expectedTextSha256': expectedTextSha256,
      'startUtf16': startUtf16,
      'endUtf16': endUtf16,
      'text': text,
    });
  }

  factory textReplace({
    required String targetKind,
    required String id,
    String? cell,
    required int startUtf16,
    required int endUtf16,
    required String expectedTextSha256,
    required String text,
  }) => WindowsOfficeOperation._({
    'op': 'textReplace',
    'targetKind': targetKind,
    'id': id,
    'cell': ?cell,
    'startUtf16': startUtf16,
    'endUtf16': endUtf16,
    'expectedTextSha256': expectedTextSha256,
    'text': text,
  });
  factory textStyle({
    required String targetKind,
    required String id,
    String? cell,
    required int startUtf16,
    required int endUtf16,
    required String expectedTextSha256,
    double? fontSize,
    bool? bold,
    bool? italic,
    bool? underline,
    int? color,
    String? fontFamily,
  }) => WindowsOfficeOperation._({
    'op': 'textStyle',
    'targetKind': targetKind,
    'id': id,
    'cell': ?cell,
    'startUtf16': startUtf16,
    'endUtf16': endUtf16,
    'expectedTextSha256': expectedTextSha256,
    'fontSize': ?fontSize,
    'bold': ?bold,
    'italic': ?italic,
    'underline': ?underline,
    'color': ?color,
    'fontFamily': ?fontFamily,
  });
  factory imageAdd({
    required String id,
    required String slideId,
    required String assetId,
    required double x,
    required double y,
    required double width,
    required double height,
  }) => WindowsOfficeOperation._({
    'op': 'imageAdd',
    'id': id,
    'slideId': slideId,
    'assetId': assetId,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  });
  factory imageReplace({required String id, required String assetId}) =>
      WindowsOfficeOperation._({
        'op': 'imageReplace',
        'id': id,
        'assetId': assetId,
      });

  factory imageRotate({
    required String id,
    required int expectedRotationHundredths,
    required int rotationHundredths,
  }) {
    final expected = _imageRotationHundredths(expectedRotationHundredths);
    final rotation = _imageRotationHundredths(rotationHundredths);
    if (rotation == expected || (rotation - expected) % 9000 != 0) {
      throw const FormatException(
        'Office image rotation requires a nonzero multiple of 90 degrees',
      );
    }
    return WindowsOfficeOperation._({
      'op': 'imageRotate',
      'id': id,
      'expectedRotationHundredths': expected,
      'rotationHundredths': rotation,
    });
  }

  factory wordImageAdd({
    required String id,
    required String ownerId,
    required String paragraphId,
    required int offsetUtf16,
    required String expectedTextSha256,
    required String assetId,
    required double width,
    required double height,
  }) => WindowsOfficeOperation._({
    'op': 'wordImageAdd',
    'id': id,
    'ownerId': ownerId,
    'paragraphId': paragraphId,
    'offsetUtf16': offsetUtf16,
    'expectedTextSha256': expectedTextSha256,
    'assetId': assetId,
    'width': width,
    'height': height,
  });

  factory wordImageMove({
    required String id,
    required String ownerId,
    required String paragraphId,
    required int offsetUtf16,
    required String expectedTextSha256,
  }) => WindowsOfficeOperation._({
    'op': 'wordImageMove',
    'id': id,
    'ownerId': ownerId,
    'paragraphId': paragraphId,
    'offsetUtf16': offsetUtf16,
    'expectedTextSha256': expectedTextSha256,
  });

  factory wordImageDelete({required String id}) =>
      WindowsOfficeOperation._({'op': 'wordImageDelete', 'id': id});

  factory paragraphText(String id, String text) =>
      WindowsOfficeOperation._({'op': 'paragraphText', 'id': id, 'text': text});
  factory paragraphStyle(
    String id, {
    double? fontSize,
    bool? bold,
    int? color,
  }) => WindowsOfficeOperation._({
    'op': 'paragraphStyle',
    'id': id,
    'fontSize': ?fontSize,
    'bold': ?bold,
    'color': ?color,
  });
  factory tableCellText(String tableId, String cell, String text) =>
      WindowsOfficeOperation._({
        'op': 'tableCellText',
        'tableId': tableId,
        'cell': cell,
        'text': text,
      });
  factory shapeText(String id, String text) =>
      WindowsOfficeOperation._({'op': 'shapeText', 'id': id, 'text': text});
  factory shapeStyle(String id, {double? fontSize, bool? bold, int? color}) =>
      WindowsOfficeOperation._({
        'op': 'shapeStyle',
        'id': id,
        'fontSize': ?fontSize,
        'bold': ?bold,
        'color': ?color,
      });
  factory shapeGeometry(
    String id, {
    required double x,
    required double y,
    required double width,
    required double height,
  }) => WindowsOfficeOperation._({
    'op': 'shapeGeometry',
    'id': id,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  });
  factory shapeAdd({
    required String id,
    required String slideId,
    required String shapeKind,
    required double x,
    required double y,
    required double width,
    required double height,
    String text = '',
  }) => WindowsOfficeOperation._({
    'op': 'shapeAdd',
    'id': id,
    'slideId': slideId,
    'shapeKind': shapeKind,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'text': text,
  });
  factory shapeDelete(String id) =>
      WindowsOfficeOperation._({'op': 'shapeDelete', 'id': id});
  factory shapeAppearance(
    String id, {
    String? fillStyle,
    int? fillColor,
    String? lineStyle,
    int? lineColor,
    double? lineWidth,
  }) => WindowsOfficeOperation._({
    'op': 'shapeAppearance',
    'id': id,
    'fillStyle': ?fillStyle,
    'fillColor': ?fillColor,
    'lineStyle': ?lineStyle,
    'lineColor': ?lineColor,
    'lineWidth': ?lineWidth,
  });
  factory slideBackground(String id, {String? fillStyle, int? fillColor}) =>
      WindowsOfficeOperation._({
        'op': 'slideBackground',
        'id': id,
        'fillStyle': ?fillStyle,
        'fillColor': ?fillColor,
      });
  factory slideAdd({
    required String id,
    required int index,
    String text = '',
  }) => WindowsOfficeOperation._({
    'op': 'slideAdd',
    'id': id,
    'index': index,
    'text': text,
  });
  factory slideDesign({
    required String id,
    required String changeId,
    required String expectedDesignSha256,
    String? masterId,
    int? layoutCode,
  }) => WindowsOfficeOperation._({
    'op': 'slideDesign',
    'id': id,
    'changeId': changeId,
    'expectedDesignSha256': expectedDesignSha256,
    'masterId': ?masterId,
    'layoutCode': ?layoutCode,
  });
  factory slideDisplay({
    required String id,
    bool? visible,
    bool? showMasterObjects,
  }) => WindowsOfficeOperation._({
    'op': 'slideDisplay',
    'id': id,
    'visible': ?visible,
    'showMasterObjects': ?showMasterObjects,
  });
  factory slideDelete(String id) =>
      WindowsOfficeOperation._({'op': 'slideDelete', 'id': id});
  factory slideMove(String id, int index) =>
      WindowsOfficeOperation._({'op': 'slideMove', 'id': id, 'index': index});
  factory slideDuplicate(String id) {
    if (!RegExp(r'^slide-(0|[1-9][0-9]{0,5})$').hasMatch(id)) {
      throw const FormatException('Invalid saved slide ID');
    }
    return WindowsOfficeOperation._({'op': 'slideDuplicate', 'id': id});
  }
}

class WindowsOfficeStructureAddition {
  new _(Map<String, dynamic> json)
    : alias = _sourceStructureAlias(json['alias']),
      ownerId = _sourceStructureId(json['ownerId']),
      tableId = _sourceStructureId(json['tableId']),
      sourcePart = _sourceTextPart(json['sourcePart']),
      shapeId = _sourceTextShapeId(json['shapeId']),
      frameSha256 = _sourceTextHash(
        json['frameSha256'],
        'created source frame SHA',
      ) {
    _presentationFields(json, const {
      'alias',
      'ownerId',
      'tableId',
      'sourcePart',
      'shapeId',
      'frameSha256',
    });
    if (BigInt.parse(shapeId) == BigInt.zero) {
      throw const FormatException(
        'New source table identities must be positive',
      );
    }
  }

  final String alias;
  final String ownerId;
  final String tableId;
  final String sourcePart;
  final String shapeId;
  final String frameSha256;
}

class WindowsOfficeStructuralPreview {
  factory fromJson(Map<String, dynamic> json) =>
      WindowsOfficeStructuralPreview._(json);

  new _(Map<String, dynamic> json)
    : kind = _presentationString(json['kind'], 'structural preview kind'),
      version = _presentationInt(json['version'], 'structural preview version'),
      baseSourceSha256 = _sourceTextHash(
        json['baseSourceSha256'],
        'structural base SHA',
      ),
      candidateSourceSha256 = _sourceTextHash(
        json['candidateSourceSha256'],
        'structural candidate SHA',
      ),
      operationsSha256 = _sourceTextHash(
        json['operationsSha256'],
        'structural operations SHA',
      ),
      additions = List<WindowsOfficeStructureAddition>.unmodifiable([
        for (final value in _presentationList(
          json['additions'],
          'structural additions',
        ))
          WindowsOfficeStructureAddition._(
            _presentationMap(value, 'structural addition'),
          ),
      ]),
      snapshot = WindowsOfficeSnapshot.fromJson(
        _presentationMap(json['snapshot'], 'structural snapshot'),
      ) {
    _presentationFields(json, const {
      'kind',
      'version',
      'baseSourceSha256',
      'candidateSourceSha256',
      'operationsSha256',
      'additions',
      'snapshot',
    });
    if (kind != 'presentationSourceStructure' ||
        version != 1 ||
        baseSourceSha256 == candidateSourceSha256 ||
        snapshot.kind != 'presentation' ||
        snapshot.sourceSha256 != candidateSourceSha256 ||
        additions.isEmpty ||
        additions.length > 20) {
      throw const FormatException('Invalid structural preview provenance');
    }
    final aliases = <String>{};
    final targets = <String>{};
    final sourceKeys = <String>{};
    for (final addition in additions) {
      if (!aliases.add(addition.alias) ||
          !targets.add(addition.tableId) ||
          !sourceKeys.add(
            jsonEncode([addition.sourcePart, addition.shapeId]),
          )) {
        throw const FormatException('Duplicate structural addition identity');
      }
      final owners = snapshot.slides
          .where((slide) => slide.id == addition.ownerId)
          .toList();
      if (owners.length != 1)
        throw const FormatException('Unknown structural addition owner');
      final tables = owners.single.presentationTables
          ?.where((table) => table.id == addition.tableId)
          .toList();
      if (tables == null || tables.length != 1)
        throw const FormatException('Unknown structural addition table');
      final table = tables.single;
      final authority = table.sourceTextPatchAuthority;
      if (authority == null ||
          authority.sourceSha256 != candidateSourceSha256 ||
          authority.sourcePart != addition.sourcePart ||
          authority.shapeId != addition.shapeId ||
          authority.frameSha256 != addition.frameSha256 ||
          table.cells.length != table.totalCellCount ||
          table.totalCellCount > 100 ||
          table.capabilities._hasWriteCapability ||
          table.cells.any(
            (cell) =>
                cell.covered ||
                cell.rowSpan != 1 ||
                cell.columnSpan != 1 ||
                cell.anchorCellId != null ||
                cell.sourceTextPatch == null ||
                cell.sourceTextPatch!.truncated ||
                !cell.sourceTextPatch!.canReplace ||
                cell.sourceTextPatch!.text != '' ||
                cell.sourceTextPatch!.utf16Length != 0,
          )) {
        throw const FormatException(
          'Created table lacks complete source-bound empty-cell proof',
        );
      }
    }
  }

  final String kind;
  final int version;
  final String baseSourceSha256;
  final String candidateSourceSha256;
  final String operationsSha256;
  final List<WindowsOfficeStructureAddition> additions;
  final WindowsOfficeSnapshot snapshot;
}

void _validateStructureReceiptOperations(
  WindowsOfficeStructuralPreview preview,
  List<Map<String, Object?>> operations,
) {
  if (preview.additions.length != operations.length) {
    throw const FormatException(
      'The created table receipt does not cover its operations',
    );
  }
  final aliases = {
    for (final operation in operations) operation['id'] as String: operation,
  };
  for (final addition in preview.additions) {
    final operation = aliases[addition.alias];
    if (operation == null ||
        addition.ownerId != operation['ownerId'] ||
        addition.sourcePart != operation['sourcePart']) {
      throw const FormatException(
        'The created table receipt belongs to another request',
      );
    }
    final widths = [
      for (final value in operation['columnWidthsMm'] as List)
        _sourceStructureMm(value, positive: true) * 360,
    ];
    final heights = [
      for (final value in operation['rowHeightsMm'] as List)
        _sourceStructureMm(value, positive: true) * 360,
    ];
    final expected = {
      'sourcePart': addition.sourcePart,
      'shapeId': addition.shapeId,
      'positionEmu': {
        'x': _sourceStructureMm(operation['xMm']) * 360,
        'y': _sourceStructureMm(operation['yMm']) * 360,
      },
      'extentEmu': {
        'width': widths.fold<int>(0, (total, value) => total + value),
        'height': heights.fold<int>(0, (total, value) => total + value),
      },
      'columnWidthsEmu': widths,
      'rowHeightsEmu': heights,
    };
    final owner = preview.snapshot.slides.singleWhere(
      (owner) => owner.id == addition.ownerId,
    );
    final table = owner.presentationTables!.singleWhere(
      (table) => table.id == addition.tableId,
    );
    if (table.columnCount != widths.length ||
        table.rowCount != heights.length ||
        _sourceStructureCanonical(table.authoredGeometry) !=
            _sourceStructureCanonical(expected)) {
      throw const FormatException(
        'The created source table geometry differs from its operation',
      );
    }
  }
}

class WindowsOfficeEditResult {
  factory fromJson(Map<String, dynamic> json) {
    final structural = json['structuralPreview'] == null
        ? null
        : WindowsOfficeStructuralPreview.fromJson(
            _presentationMap(json['structuralPreview'], 'structural preview'),
          );
    if (structural != null &&
        (json['draftSnapshot'] != null ||
            structural.candidateSourceSha256 != json['sourceSha256'] ||
            _sourceStructureCanonical(json['snapshot']) !=
                _sourceStructureCanonical(
                  (json['structuralPreview'] as Map)['snapshot'],
                ))) {
      throw const FormatException(
        'Structural preview differs from the saved candidate',
      );
    }
    return WindowsOfficeEditResult._(
      sessionId: json['sessionId'] as String,
      sourcePath: json['sourcePath'] as String,
      pdfPath: json['pdfPath'] as String,
      sourceSha256: json['sourceSha256'] as String,
      pdfSha256: json['pdfSha256'] as String,
      pdfPageCount: json['pdfPageCount'] as int,
      engineVersion: json['engineVersion'] as String,
      snapshot: WindowsOfficeSnapshot.fromJson(
        Map<String, dynamic>.from(json['snapshot'] as Map),
      ),
      draftSnapshot: json['draftSnapshot'] == null
          ? null
          : WindowsOfficeSnapshot.fromJson(
              Map<String, dynamic>.from(json['draftSnapshot'] as Map),
            ),
      structuralPreview: structural,
    );
  }

  const new _({
    required this.sessionId,
    required this.sourcePath,
    required this.pdfPath,
    required this.sourceSha256,
    required this.pdfSha256,
    required this.pdfPageCount,
    required this.engineVersion,
    required this.snapshot,
    this.draftSnapshot,
    this.structuralPreview,
  });
  final String sessionId;
  final String sourcePath;
  final String pdfPath;
  final String sourceSha256;
  final String pdfSha256;
  final int pdfPageCount;
  final String engineVersion;
  final WindowsOfficeSnapshot snapshot;
  final WindowsOfficeSnapshot? draftSnapshot;
  final WindowsOfficeStructuralPreview? structuralPreview;
}

typedef WindowsOfficeConversionResult = OfficeConversionResult;

class WindowsOfficeDraftPreview {
  const new({
    required this.snapshot,
    required this.pdfPath,
    required this.signature,
    required this.baseSourceSha256,
    this.structuralPreview,
  });
  final WindowsOfficeSnapshot snapshot;
  final String pdfPath;
  final String signature;
  final String baseSourceSha256;
  final WindowsOfficeStructuralPreview? structuralPreview;
}

typedef WindowsOfficeRunner = Future<Map<String, dynamic>> Function(
  Map<String, Object?> request,
);

class WindowsOfficePreview {
  new _(this.result, this._directory);
  final WindowsOfficeEditResult result;
  final Directory _directory;
  Future<void>? _disposal;
  var _retained = false;

  void retainForRecovery() {
    if (_disposal != null)
      throw StateError('Preview has already been released');
    _retained = true;
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    if (_retained) return;
    try {
      if (_directory.existsSync()) await _directory.delete(recursive: true);
    } on FileSystemException {
      // A locked private output must not replace the original operation result.
    }
  }
}

class WindowsOfficeEngine {
  new({
    String? runtimePath,
    String? helperDirectory,
    this._runner,
    this._interactiveRunner,
  }) : _runtimePath = runtimePath ?? _defaultRuntime(),
       _helperDirectory = helperDirectory ?? _defaultHelpers();

  final String _runtimePath;
  final String _helperDirectory;
  final WindowsOfficeRunner? _runner;
  final WindowsOfficeInteractiveRunner? _interactiveRunner;
  static const editableFormats = ['doc', 'docx', 'ppt', 'pptx', 'odt', 'odp'];

  WindowsOfficeInteractiveEngine get _interactive =>
      WindowsOfficeInteractiveEngine(
        runtimePath: _runtimePath,
        helperDirectory: _helperDirectory,
        runner: _interactiveRunner,
      );

  Future<bool> get interactiveAvailable =>
      _runner != null && _interactiveRunner == null
      ? Future.value(false)
      : _interactive.available;

  Future<WindowsOfficeInteractiveSession> startInteractive({
    required String workingPath,
    required String sessionId,
    required String inputSourceSha256,
  }) => _interactive.start(
    workingPath: workingPath,
    sessionId: sessionId,
    inputSourceSha256: inputSourceSha256,
  );

  static String _defaultRuntime() {
    final packaged = p.join(
      File(Platform.resolvedExecutable).parent.path,
      'office_engine',
      'runtime',
    );
    return Directory(packaged).existsSync()
        ? packaged
        : p.absolute('build', 'windows-office-engine', 'runtime');
  }

  static String _defaultHelpers() {
    final packaged = p.join(
      File(Platform.resolvedExecutable).parent.path,
      'office_engine',
    );
    return File(p.join(packaged, 'run-office.ps1')).existsSync()
        ? packaged
        : p.absolute('windows', 'office_engine');
  }

  Future<bool> get available async =>
      _runner != null ||
      Platform.isWindows &&
          File(p.join(_runtimePath, 'program', 'python.exe')).existsSync() &&
          File(p.join(_helperDirectory, 'run-office.ps1')).existsSync();

  Future<WindowsOfficeSnapshot> inspect(
    String sourcePath, {
    bool preview = false,
  }) async {
    Directory? owned;
    var transferred = false;
    try {
      final response = await _invoke({
        'mode': 'inspect',
        'sourcePath': sourcePath,
        if (preview) 'preview': true,
      }, onOwnedDirectory: preview ? (directory) => owned = directory : null);
      final directory = owned;
      final snapshot = WindowsOfficeSnapshot._(
        _object(response['snapshot']),
        onDisposePreview: directory == null
            ? null
            : () => _releaseInspectionDirectory(directory),
      );
      if (preview &&
          (snapshot.previewPdfPath == null ||
              snapshot.previewPageCount == null ||
              snapshot.previewPageCount! < 1)) {
        throw const WindowsOfficeException(
          'invalid_office_preview',
          '원본 문서의 미리보기를 만들지 못했습니다.',
        );
      }
      transferred = true;
      return snapshot;
    } finally {
      if (!transferred && owned != null) {
        await _releaseInspectionDirectory(owned!);
      }
    }
  }

  static Future<void> _releaseInspectionDirectory(Directory directory) async {
    try {
      if (FileSystemEntity.typeSync(directory.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Keep an owned output if an OS reader still holds it.
    }
  }

  Future<WindowsOfficeConversionResult> convertLegacy(
    String sourcePath, {
    required String sessionId,
    required String expectedSourceSha256,
  }) async {
    final targetExtension = switch (p.extension(sourcePath).toLowerCase()) {
      '.doc' => 'docx',
      '.ppt' => 'pptx',
      _ => null,
    };
    if (targetExtension == null ||
        !p.isAbsolute(sourcePath) ||
        sessionId.trim().isEmpty ||
        sessionId.length > 128) {
      throw const FormatException('Expected a DOC or PPT conversion session');
    }
    _sourceTextHash(expectedSourceSha256, 'expected source SHA');
    final source = File(p.normalize(sourcePath));
    final captured = await _legacySourceState(source);
    if (captured == null) {
      throw const WindowsOfficeException(
        'invalid_office_source',
        '구형 Office 원본 파일을 확인하지 못했습니다.',
      );
    }
    const sourceChanged = WindowsOfficeException(
      'source_changed',
      '원본 판본이 바뀌었습니다. 문서를 다시 열어 주세요.',
    );
    if (captured.digest != expectedSourceSha256) throw sourceChanged;

    Directory? owned;
    String? ownedRoot;
    try {
      final response = await _invoke(
        {
          'mode': 'convertLegacy',
          'sourcePath': source.path,
          'sessionId': sessionId,
          'expectedSourceSha256': expectedSourceSha256,
        },
        onOwnedDirectory: (directory) {
          owned = directory;
          ownedRoot = directory.resolveSymbolicLinksSync();
        },
      );
      const fields = {
        'sessionId',
        'inputSourceSha256',
        'targetExtension',
        'sourcePath',
        'sourceSha256',
        'pdfPath',
        'pdfSha256',
        'pdfPageCount',
        'engineVersion',
      };
      final pages = response['pdfPageCount'];
      final engineVersion = response['engineVersion'];
      if (response.length != fields.length ||
          !response.keys.every(fields.contains) ||
          response['sessionId'] != sessionId ||
          response['inputSourceSha256'] != expectedSourceSha256 ||
          response['targetExtension'] != targetExtension ||
          pages is! int ||
          pages < 1 ||
          engineVersion is! String ||
          engineVersion.trim().isEmpty ||
          engineVersion.length > 128 ||
          response['sourceSha256'] == expectedSourceSha256) {
        throw _invalidConversion;
      }
      final converted = await _legacyConversionFile(
        response['sourcePath'],
        '.$targetExtension',
        ownedRoot,
      );
      final pdf = await _legacyConversionFile(
        response['pdfPath'],
        '.pdf',
        ownedRoot,
      );
      if (await FileSystemEntity.identical(converted.path, source.path) ||
          await FileSystemEntity.identical(pdf.path, source.path) ||
          await FileSystemEntity.identical(converted.path, pdf.path)) {
        throw _invalidConversion;
      }
      final originalBytes = await _legacyConversionBytes(
        converted,
        response['sourceSha256'],
      );
      final pdfBytes = await _legacyConversionBytes(pdf, response['pdfSha256']);
      if (!_hasBytePrefix(originalBytes, const [0x50, 0x4b, 0x03, 0x04]) ||
          !_hasBytePrefix(pdfBytes, const [0x25, 0x50, 0x44, 0x46, 0x2d]) ||
          !latin1
              .decode(
                Uint8List.sublistView(
                  pdfBytes,
                  pdfBytes.length > 2048 ? pdfBytes.length - 2048 : 0,
                ),
              )
              .contains('%%EOF')) {
        throw _invalidConversion;
      }
      return WindowsOfficeConversionResult(
        originalBytes: originalBytes.asUnmodifiableView(),
        pdfBytes: pdfBytes.asUnmodifiableView(),
        engineVersion: engineVersion,
        pageCount: pages,
        targetExtension: targetExtension,
      );
    } on FileSystemException {
      throw _invalidConversion;
    } finally {
      try {
        if (await _legacySourceState(source) != captured) throw sourceChanged;
      } finally {
        if (owned != null) await _releaseInspectionDirectory(owned!);
      }
    }
  }

  static const _legacyConversionLimit = 128 * 1024 * 1024;
  static const _invalidConversion = WindowsOfficeException(
    'invalid_office_result',
    '편집용 복사본과 PDF를 확인하지 못했습니다.',
  );

  static bool _hasBytePrefix(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (bytes[index] != prefix[index]) return false;
    }
    return true;
  }

  static Future<({String path, int length, DateTime modified, String digest})?>
  _legacySourceState(File file) async {
    try {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file)
        return null;
      final path = await file.resolveSymbolicLinks();
      final before = file.statSync();
      const cfb = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1];
      if (before.size < cfb.length || before.size > _legacyConversionLimit)
        return null;
      final header = await file
          .openRead(0, cfb.length)
          .expand((chunk) => chunk)
          .toList();
      if (!_hasBytePrefix(header, cfb)) return null;
      final digest =
          (await sha256.bind(file.openRead(0, before.size + 1)).first)
              .toString();
      final after = file.statSync();
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !p.equals(await file.resolveSymbolicLinks(), path) ||
          before.size != after.size ||
          before.modified != after.modified)
        return null;
      return (
        path: path,
        length: before.size,
        modified: before.modified,
        digest: digest,
      );
    } on FileSystemException {
      return null;
    }
  }

  static Future<File> _legacyConversionFile(
    Object? path,
    String extension,
    String? ownedRoot,
  ) async {
    if (path is! String ||
        !p.isAbsolute(path) ||
        p.extension(path).toLowerCase() != extension) {
      throw _invalidConversion;
    }
    final file = File(p.normalize(path));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file)
      throw _invalidConversion;
    final resolved = await file.resolveSymbolicLinks();
    if (ownedRoot != null && !p.isWithin(ownedRoot, resolved))
      throw _invalidConversion;
    return File(resolved);
  }

  static Future<Uint8List> _legacyConversionBytes(
    File file,
    Object? expectedHash,
  ) async {
    final before = file.statSync();
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        before.size < 1 ||
        before.size > _legacyConversionLimit)
      throw _invalidConversion;
    final reader = await file.open();
    try {
      final bytes = await reader.read(before.size + 1);
      final after = file.statSync();
      if (bytes.length != before.size ||
          before.size != after.size ||
          before.modified != after.modified ||
          FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          sha256.convert(bytes).toString() != expectedHash)
        throw _invalidConversion;
      return bytes;
    } finally {
      await reader.close();
    }
  }

  Future<WindowsOfficeEditResult> apply(
    String sourcePath, {
    required List<WindowsOfficeOperation> operations,
    required String sessionId,
    String? expectedSourceSha256,
    Map<String, WindowsOfficeImageAsset> imageAssets = const {},
    bool includeDraftSnapshot = false,
  }) => _apply(
    sourcePath,
    operations: operations,
    sessionId: sessionId,
    expectedSourceSha256: expectedSourceSha256,
    imageAssets: imageAssets,
    includeDraftSnapshot: includeDraftSnapshot,
  );

  Future<WindowsOfficePreview> preview(
    String sourcePath, {
    required List<WindowsOfficeOperation> operations,
    required String sessionId,
    String? expectedSourceSha256,
    Map<String, WindowsOfficeImageAsset> imageAssets = const {},
  }) async {
    Directory? working;
    Directory? owned;
    try {
      final result = await _apply(
        sourcePath,
        operations: operations,
        sessionId: sessionId,
        expectedSourceSha256: expectedSourceSha256,
        imageAssets: imageAssets,
        includeDraftSnapshot: true,
        onOwnedDirectory: (directory) => working = directory,
      );
      owned = await Directory.systemTemp.createTemp(
        'personal-ink-vault-preview-',
      );
      final source = await File(result.sourcePath)
          .copy(p.join(owned.path, 'edited${p.extension(result.sourcePath)}'));
      final pdf = await File(result.pdfPath)
          .copy(p.join(owned.path, 'preview.pdf'));
      if ((await sha256.bind(source.openRead()).first).toString() !=
              result.sourceSha256 ||
          (await sha256.bind(pdf.openRead()).first).toString() !=
              result.pdfSha256) {
        throw const WindowsOfficeException(
          'office_payload_mismatch',
          '미리보기 복사본의 무결성을 확인하지 못했습니다.',
        );
      }
      final retained = WindowsOfficeEditResult._(
        sessionId: result.sessionId,
        sourcePath: source.path,
        pdfPath: pdf.path,
        sourceSha256: result.sourceSha256,
        pdfSha256: result.pdfSha256,
        pdfPageCount: result.pdfPageCount,
        engineVersion: result.engineVersion,
        snapshot: result.snapshot,
        draftSnapshot: result.draftSnapshot,
        structuralPreview: result.structuralPreview,
      );
      final lease = WindowsOfficePreview._(retained, owned);
      owned = null;
      return lease;
    } finally {
      for (final directory in [owned, working]) {
        if (directory == null) continue;
        try {
          if (directory.existsSync()) await directory.delete(recursive: true);
        } on FileSystemException {
          // Only directories created by this host invocation are eligible.
        }
      }
    }
  }

  Future<WindowsOfficeEditResult> _apply(
    String sourcePath, {
    required List<WindowsOfficeOperation> operations,
    required String sessionId,
    String? expectedSourceSha256,
    Map<String, WindowsOfficeImageAsset> imageAssets = const {},
    bool includeDraftSnapshot = false,
    void Function(Directory)? onOwnedDirectory,
  }) async {
    if (sessionId.trim().isEmpty) {
      throw ArgumentError('Expected an edit session');
    }
    final capturedOperations = [
      for (final operation in operations) operation.toJson(),
    ];
    if (capturedOperations.any(
          (operation) => operation['op'] == 'slideDuplicate',
        ) &&
        (capturedOperations.length != 1 ||
            p.extension(sourcePath).toLowerCase() != '.pptx' ||
            expectedSourceSha256 == null ||
            imageAssets.isNotEmpty ||
            includeDraftSnapshot)) {
      throw const FormatException(
        'Slide duplication requires one saved PPTX slide and its exact source hash',
      );
    }
    final structureCount = capturedOperations
        .where((operation) => operation['op'] == 'presentationSourceTableAdd')
        .length;
    final isSourceStructure = structureCount != 0;
    if (isSourceStructure &&
        (structureCount != capturedOperations.length ||
            structureCount > 100 ||
            imageAssets.isNotEmpty)) {
      throw const FormatException(
        'Source table creation requires a source-only batch of at most one hundred',
      );
    }
    final aliases = <String>{};
    if (isSourceStructure &&
        capturedOperations.any(
          (operation) => !aliases.add(operation['id'] as String),
        )) {
      throw const FormatException(
        'Source table aliases must be unique in a batch',
      );
    }
    final operationMaps = isSourceStructure
        ? List<Map<String, Object?>>.unmodifiable([
            for (final operation in capturedOperations)
              Map<String, Object?>.unmodifiable({
                ...operation,
                'columnWidthsMm': List<num>.unmodifiable(
                  operation['columnWidthsMm'] as List<num>,
                ),
                'rowHeightsMm': List<num>.unmodifiable(
                  operation['rowHeightsMm'] as List<num>,
                ),
              }),
          ])
        : capturedOperations;
    final operationHash = isSourceStructure
        ? sha256
              .convert(utf8.encode(_sourceStructureCanonical(operationMaps)))
              .toString()
        : null;
    final draftSourceHash = includeDraftSnapshot || isSourceStructure
        ? (await sha256.bind(File(sourcePath).openRead()).first).toString()
        : null;
    if ((includeDraftSnapshot || isSourceStructure) &&
        expectedSourceSha256 != null &&
        expectedSourceSha256 != draftSourceHash) {
      throw const WindowsOfficeException(
        'source_changed',
        '원본 판본이 바뀌었습니다. 문서를 다시 열어 주세요.',
      );
    }
    if (isSourceStructure &&
        operationMaps.any(
          (operation) => operation['expectedSourceSha256'] != draftSourceHash,
        )) {
      throw const WindowsOfficeException(
        'source_changed',
        '원본 판본이 바뀌었습니다. 문서를 다시 열어 주세요.',
      );
    }
    final response = await _invoke(
      {
        'mode': 'apply',
        'sourcePath': sourcePath,
        'sessionId': sessionId,
        'operations': operationMaps,
        'expectedSourceSha256': ?(expectedSourceSha256 ?? draftSourceHash),
        if (includeDraftSnapshot) 'includeDraftSnapshot': true,
      },
      imageAssets: Map.unmodifiable(imageAssets),
      onOwnedDirectory: onOwnedDirectory,
    );
    final edited = response['sourcePath'];
    final pdf = response['pdfPath'];
    final originalHash = response['sourceSha256'];
    final pdfHash = response['pdfSha256'];
    final pages = response['pdfPageCount'];
    if (response['status'] != 'saved' ||
        response['sessionId'] != sessionId ||
        edited is! String ||
        edited == sourcePath ||
        pdf is! String ||
        pdf == edited ||
        originalHash is! String ||
        pdfHash is! String ||
        pages is! int ||
        pages < 1 ||
        response['engineVersion'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(originalHash) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(pdfHash)) {
      throw const WindowsOfficeException(
        'invalid_office_result',
        '수정된 문서 저장 결과를 확인하지 못했습니다.',
      );
    }
    if (!p.isAbsolute(edited) ||
        !p.isAbsolute(pdf) ||
        FileSystemEntity.typeSync(edited, followLinks: false) !=
            FileSystemEntityType.file ||
        FileSystemEntity.typeSync(pdf, followLinks: false) !=
            FileSystemEntityType.file ||
        await File(edited).length() > 128 * 1024 * 1024 ||
        await File(pdf).length() > 128 * 1024 * 1024) {
      throw const WindowsOfficeException(
        'invalid_office_result',
        '문서 편집 결과 파일을 확인하지 못했습니다.',
      );
    }
    if ((await sha256.bind(File(edited).openRead()).first).toString() !=
            originalHash ||
        (await sha256.bind(File(pdf).openRead()).first).toString() != pdfHash) {
      throw const WindowsOfficeException(
        'office_payload_mismatch',
        '저장된 문서가 편집 결과와 일치하지 않습니다.',
      );
    }
    final snapshot = WindowsOfficeSnapshot._(_object(response['snapshot']));
    if (snapshot.sourceSha256 != originalHash) {
      throw const WindowsOfficeException(
        'invalid_office_result',
        '재열기한 문서의 판본을 확인하지 못했습니다.',
      );
    }
    WindowsOfficeStructuralPreview? structuralPreview;
    if ((!isSourceStructure || !includeDraftSnapshot) &&
            response['structuralPreview'] != null ||
        isSourceStructure && response['draftSnapshot'] != null) {
      throw const WindowsOfficeException(
        'invalid_office_result',
        '표 편집 결과의 미리보기 종류를 확인하지 못했습니다.',
      );
    }
    if (isSourceStructure && includeDraftSnapshot) {
      try {
        final wire = _presentationMap(
          response['structuralPreview'],
          'structural preview',
        );
        structuralPreview = WindowsOfficeStructuralPreview.fromJson(wire);
        if (structuralPreview.baseSourceSha256 != draftSourceHash ||
            structuralPreview.candidateSourceSha256 != originalHash ||
            structuralPreview.operationsSha256 != operationHash ||
            _sourceStructureCanonical(wire['snapshot']) !=
                _sourceStructureCanonical(response['snapshot'])) {
          throw const FormatException(
            'Structural preview lost its base, candidate or operation provenance',
          );
        }
        _validateStructureReceiptOperations(structuralPreview, operationMaps);
      } on FormatException {
        throw const WindowsOfficeException(
          'invalid_office_result',
          '새 표의 미리보기 결과를 확인하지 못했습니다.',
        );
      } on TypeError {
        throw const WindowsOfficeException(
          'invalid_office_result',
          '새 표의 미리보기 결과를 확인하지 못했습니다.',
        );
      }
    }
    if (includeDraftSnapshot &&
        !isSourceStructure &&
        response['draftSnapshot'] is! Map) {
      throw const WindowsOfficeException(
        'invalid_office_result',
        '편집 중인 슬라이드 결과를 확인하지 못했습니다.',
      );
    }
    final draftSnapshot = response['draftSnapshot'] == null
        ? null
        : WindowsOfficeSnapshot._(_object(response['draftSnapshot']));
    if (includeDraftSnapshot &&
        !isSourceStructure &&
        draftSnapshot!.sourceSha256 != draftSourceHash) {
      throw const WindowsOfficeException(
        'invalid_office_result',
        '편집 중인 슬라이드의 원본 판본이 다릅니다.',
      );
    }
    return WindowsOfficeEditResult._(
      sessionId: sessionId,
      sourcePath: edited,
      pdfPath: pdf,
      sourceSha256: originalHash,
      pdfSha256: pdfHash,
      pdfPageCount: pages,
      engineVersion: response['engineVersion'] as String,
      snapshot: snapshot,
      draftSnapshot: draftSnapshot,
      structuralPreview: structuralPreview,
    );
  }

  Future<Map<String, dynamic>> _invoke(
    Map<String, Object?> request, {
    Map<String, WindowsOfficeImageAsset> imageAssets = const {},
    void Function(Directory)? onOwnedDirectory,
  }) async {
    final referenced = <String>{};
    for (final operation in request['operations'] as List? ?? const []) {
      if (operation is Map &&
          [
            'imageAdd',
            'imageReplace',
            'wordImageAdd',
          ].contains(operation['op'])) {
        final id = operation['assetId'];
        if (id is! String ||
            !RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
            ).hasMatch(id)) {
          throw const FormatException('Invalid Office image asset identity');
        }
        referenced.add(id);
      }
    }
    if (referenced.length != imageAssets.length ||
        !referenced.every(imageAssets.containsKey) ||
        imageAssets.values.fold<int>(
              0,
              (total, asset) => total + asset.byteLength,
            ) >
            WindowsOfficeImageAsset.maxBatchBytes) {
      throw const FormatException(
        'Office photos must match their operations and total at most 80 MiB',
      );
    }
    if (imageAssets.isNotEmpty) {
      request = {
        ...request,
        'imageAssets': [
          for (final entry in imageAssets.entries)
            {
              'id': entry.key,
              'fileName':
                  'assets/${entry.key}.${entry.value.mimeType == 'image/png' ? 'png' : 'jpg'}',
              'mimeType': entry.value.mimeType,
              'byteLength': entry.value.byteLength,
              'sha256': entry.value.sha256,
              'width': entry.value.width,
              'height': entry.value.height,
            },
        ],
      };
    }
    if (!await available) {
      throw const WindowsOfficeException(
        'office_unavailable',
        '문서 편집 도구를 준비하지 못했습니다. 앱을 다시 설치하세요.',
      );
    }
    if (_runner != null && imageAssets.isEmpty) return _runner(request);
    final directory = await Directory.systemTemp.createTemp('piv-o-');
    onOwnedDirectory?.call(directory);
    var retainPreview = false;
    Directory? assetDirectory;
    try {
      if (imageAssets.isNotEmpty) {
        assetDirectory = await Directory(p.join(directory.path, 'assets'))
            .create();
        for (final entry in imageAssets.entries) {
          final extension = entry.value.mimeType == 'image/png' ? 'png' : 'jpg';
          await File(p.join(assetDirectory.path, '${entry.key}.$extension'))
              .writeAsBytes(entry.value.bytes, flush: true);
        }
      }
      if (_runner != null) return await _runner(request);
      final input = File(p.join(directory.path, 'request.json'));
      final output = File(p.join(directory.path, 'response.json'));
      await input.writeAsString(jsonEncode(request), flush: true);
      final process = await Process.run('powershell.exe', [
        '-NoProfile',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.join(_helperDirectory, 'run-office.ps1'),
        '-RuntimePath',
        _runtimePath,
        '-RequestPath',
        input.path,
        '-ResponsePath',
        output.path,
      ], runInShell: false);
      if (process.exitCode != 0 || !output.existsSync()) {
        throw const WindowsOfficeException(
          'office_worker_failed',
          '문서 편집을 완료하지 못했습니다. 원본은 보관됩니다.',
        );
      }
      final response = _object(jsonDecode(await output.readAsString()));
      if (response['ok'] != true) {
        final error = _object(response['error']);
        throw WindowsOfficeException(
          error['code'] as String,
          error['message'] as String,
          diagnostics: _officeWorkerDiagnostics(error['diagnostics']),
        );
      }
      final result = _object(response['result']);
      if (request['mode'] == 'inspect' && request['preview'] == true) {
        final preview = _object(result['snapshot'])['previewPdfPath'];
        retainPreview = preview is String && File(preview).existsSync();
      }
      return result;
    } finally {
      if (assetDirectory != null) {
        try {
          if (assetDirectory.existsSync())
            await assetDirectory.delete(recursive: true);
        } catch (_) {
          // Best-effort private input cleanup must not change a saved result.
        }
      }
      if (_runner != null || request['mode'] == 'inspect' && !retainPreview) {
        try {
          await directory.delete(recursive: true);
        } catch (_) {
          // Preserve the worker result or the original operation error.
        }
      }
    }
  }

  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map) throw const FormatException('Invalid Office response');
    return Map<String, dynamic>.from(value);
  }
}
