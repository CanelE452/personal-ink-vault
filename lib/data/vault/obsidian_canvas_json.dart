import 'dart:convert';
import 'dart:typed_data';

import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';

const _sides = {'top', 'right', 'bottom', 'left'};
const _ends = {'none', 'arrow'};
const _backgroundStyles = {'cover', 'ratio', 'repeat'};
final _colors = RegExp(r'^(?:[1-6]|#[0-9a-fA-F]{6})$');
final _appLinks = RegExp(r'(?:inkvault://|inkwiki:)', caseSensitive: false);

Uint8List encodeObsidianCanvas(
  CardCanvasDocument document, {
  required String? Function(String noteId) filePathFor,
  required String? Function(String rawVaultPath) imagePathFor,
  required void Function(String nodeId, String message) onWarning,
}) {
  if (document.nodes.length > 2000 || document.edges.length > 5000) {
    throw const FormatException('Canvas 배열이 내보내기 한도를 초과했습니다.');
  }
  final nodes = [
    for (final node in document.nodes)
      _encodeNode(node, filePathFor, imagePathFor, onWarning),
  ];
  final nodeIds = document.nodes.map((node) => node.id).toSet();
  final edges = <Map<String, Object?>>[];
  for (final edge in document.edges) {
    if (!nodeIds.contains(edge.fromNode) || !nodeIds.contains(edge.toNode)) {
      onWarning(edge.fromNode, '끝점이 없는 연결선 ${edge.id}을 제외했습니다.');
      continue;
    }
    final raw = edge.toJson();
    final color = _color(raw['color']);
    edges.add({
      'id': edge.id,
      'fromNode': edge.fromNode,
      if (_sides.contains(raw['fromSide'])) 'fromSide': raw['fromSide'],
      if (_ends.contains(raw['fromEnd'])) 'fromEnd': raw['fromEnd'],
      'toNode': edge.toNode,
      if (_sides.contains(raw['toSide'])) 'toSide': raw['toSide'],
      if (_ends.contains(raw['toEnd'])) 'toEnd': raw['toEnd'],
      'color': ?color,
      if (raw['label'] is String) 'label': raw['label'],
    });
  }
  final text = const JsonEncoder.withIndent('  ')
      .convert({'nodes': nodes, 'edges': edges});
  final bytes = utf8.encode('$text\n');
  if (bytes.length > 8 * 1024 * 1024) {
    throw const FormatException('Canvas 파일이 8 MiB를 초과했습니다.');
  }
  return bytes;
}

Map<String, Object?> _encodeNode(
  CardCanvasNode node,
  String? Function(String) filePathFor,
  String? Function(String) imagePathFor,
  void Function(String, String) onWarning,
) {
  final color = _color(node.color);
  final result = <String, Object?>{
    'id': node.id,
    'type': node.type,
    'x': _coordinate(node.x),
    'y': _coordinate(node.y),
    'width': _coordinate(node.width).clamp(1, 1000000000),
    'height': _coordinate(node.height).clamp(1, 1000000000),
    'color': ?color,
  };
  Map<String, Object?> placeholder(String message) {
    onWarning(node.id, message);
    return {...result, 'type': 'text', 'text': message};
  }

  switch (node.type) {
    case 'text':
      final text = node.text!;
      if (_appLinks.hasMatch(text)) {
        onWarning(node.id, '앱 내부 링크가 텍스트에 남아 있습니다.');
      }
      return {...result, 'text': text};
    case 'file':
      final id = node.linkedNoteId;
      final path = id == null ? null : filePathFor(id);
      if (path == null || !_vaultPath(path)) {
        return placeholder('연결된 파일을 내보내기에 포함하지 못했습니다.');
      }
      final subpath = node.subpath;
      final lowerPath = path.toLowerCase();
      final keepsSubpath =
          subpath != null &&
          (lowerPath.endsWith('.md') || lowerPath.endsWith('.pdf'));
      if (!keepsSubpath && node.toJson().containsKey('subpath')) {
        onWarning(node.id, '파일 카드의 하위 링크를 내보낼 수 없습니다.');
      }
      return {...result, 'file': path, if (keepsSubpath) 'subpath': subpath};
    case 'link':
      final url = node.safeUrl;
      return url == null
          ? placeholder('웹 링크를 내보낼 수 없습니다.')
          : {...result, 'url': url};
    case 'group':
      final raw = node.toJson();
      final label = raw['label'];
      final background = raw['background'];
      final style = raw['backgroundStyle'];
      final path = background is String && _vaultPath(background)
          ? imagePathFor(background)
          : null;
      final keepsBackground =
          path != null &&
          _vaultPath(path) &&
          obsidianAttachmentKind(path.split('/').last) == 'image';
      if (!keepsBackground && raw.containsKey('background')) {
        onWarning(node.id, '그룹 배경 이미지를 내보내기에 포함하지 못했습니다.');
      }
      return {
        ...result,
        if (label is String) 'label': label,
        if (keepsBackground) 'background': path,
        if (keepsBackground && _backgroundStyles.contains(style))
          'backgroundStyle': style,
      };
    default:
      return placeholder('이 카드 형식은 Canvas로 내보낼 수 없습니다.');
  }
}

int _coordinate(double value) {
  if (!value.isFinite || value.abs() > 1e9) {
    throw const FormatException('Canvas 좌표가 내보내기 한도를 초과했습니다.');
  }
  return value.round();
}

String? _color(Object? value) =>
    value is String && _colors.hasMatch(value) ? value : null;

bool _vaultPath(String path) {
  if (path.length > 4096) return false;
  final segments = path.split('/');
  return segments.length <= 65 &&
      segments.every(
        (segment) => !segment.startsWith('.') && isObsidianPathSegment(segment),
      );
}
