import 'dart:convert';
import 'dart:ui';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/note_link.dart';

class CardCanvasDocument {
  const new empty() : _extra = const {}, nodes = const [], edges = const [];
  new _(this._extra, List<CardCanvasNode> nodes, List<CardCanvasEdge> edges)
    : nodes = List.unmodifiable(nodes),
      edges = List.unmodifiable(edges) {
    if (nodes.map((node) => node.id).toSet().length != nodes.length ||
        edges.map((edge) => edge.id).toSet().length != edges.length) {
      throw const FormatException('Duplicate canvas identity');
    }
  }
  factory fromJson(Map<String, dynamic> json) {
    final raw = _object(jsonDecode(jsonEncode(json)));
    final nodes = raw.remove('nodes') ?? [];
    final edges = raw.remove('edges') ?? [];
    if (nodes is! List || edges is! List)
      throw const FormatException('Invalid canvas arrays');
    return CardCanvasDocument._(
      raw,
      [for (final node in nodes) CardCanvasNode.fromJson(_object(node))],
      [for (final edge in edges) CardCanvasEdge.fromJson(_object(edge))],
    );
  }
  final Map<String, dynamic> _extra;
  final List<CardCanvasNode> nodes;
  final List<CardCanvasEdge> edges;
  Map<String, dynamic> toJson() => {
    ..._copy(_extra),
    'nodes': [for (final node in nodes) node.toJson()],
    'edges': [for (final edge in edges) edge.toJson()],
  };
  CardCanvasDocument copyWith({
    List<CardCanvasNode>? nodes,
    List<CardCanvasEdge>? edges,
  }) => CardCanvasDocument._(_extra, nodes ?? this.nodes, edges ?? this.edges);
}

class CardCanvasNode {
  factory text({
    required String id,
    String text = '',
    double x = 0,
    double y = 0,
    double width = 280,
    double height = 180,
  }) => CardCanvasNode.fromJson({
    'id': id,
    'type': 'text',
    'text': text,
    'x': x.round(),
    'y': y.round(),
    'width': width.round(),
    'height': height.round(),
  });
  factory note({
    required String id,
    required String noteId,
    required String title,
    double x = 0,
    double y = 0,
  }) => CardCanvasNode.fromJson({
    'id': id,
    'type': 'file',
    'file': noteId,
    'inkVaultTitle': title,
    'x': x.round(),
    'y': y.round(),
    'width': 280,
    'height': 180,
  });
  factory group({
    required String id,
    required String label,
    required Rect bounds,
  }) => CardCanvasNode.fromJson({
    'id': id,
    'type': 'group',
    'label': label,
    'x': bounds.left.round(),
    'y': bounds.top.round(),
    'width': bounds.width.round(),
    'height': bounds.height.round(),
  });
  new _(this._raw);
  factory fromJson(Map<String, dynamic> json) {
    _identifier(json['id']);
    if (json['type'] is! String ||
        _number(json['width']) <= 0 ||
        _number(json['height']) <= 0 ||
        (json['color'] != null && json['color'] is! String)) {
      throw const FormatException('Invalid canvas node');
    }
    _number(json['x']);
    _number(json['y']);
    final requiredText = switch (json['type']) {
      'text' => 'text',
      'file' => 'file',
      'link' => 'url',
      _ => null,
    };
    if (requiredText != null && json[requiredText] is! String)
      throw const FormatException('Invalid canvas content');
    return CardCanvasNode._(_copy(json));
  }
  final Map<String, dynamic> _raw;
  String get id => _raw['id'] as String;
  String get type => _raw['type'] as String;
  String? get text => switch (_raw['text']) {
    final String value => value,
    _ => null,
  };
  String? get file => switch (_raw['file']) {
    final String value => value,
    _ => null,
  };
  String? get linkedNoteId {
    if (type != 'file') return null;
    final value = _raw.containsKey('inkVaultNoteId')
        ? _raw['inkVaultNoteId']
        : _raw['file'];
    if (value is! String) return null;
    try {
      validateId(value);
      return value;
    } on FormatException {
      return null;
    }
  }

  String? get subpath {
    final value = _raw['subpath'];
    if (type != 'file' ||
        value is! String ||
        value.length <= 1 ||
        value.length > 2049 ||
        !value.startsWith('#') ||
        value.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]'))) {
      return null;
    }
    return value;
  }

  String? get url => type == 'link' ? _raw['url'] as String : null;
  String? get safeUrl {
    final value = url;
    if (value == null ||
        value.contains(RegExp(r'[\x00-\x20\x7f-\x9f]')) ||
        !isSafeExternalLink(value)) {
      return null;
    }
    return value;
  }

  String? get color => _raw['color'] as String?;
  String? get label {
    final label = _raw['label'];
    final value = type == 'group' && label is String
        ? label
        : _raw['inkVaultTitle'] ?? label;
    return value is String ? value : null;
  }

  String? get backgroundPath {
    final value = _raw['background'];
    return type == 'group' && value is String && value.isNotEmpty
        ? value
        : null;
  }

  String get backgroundStyle => switch (_raw['backgroundStyle']) {
    'ratio' => 'ratio',
    'repeat' => 'repeat',
    _ => 'cover',
  };

  double get x => _number(_raw['x']);
  double get y => _number(_raw['y']);
  double get width => _number(_raw['width']);
  double get height => _number(_raw['height']);
  Rect get bounds => Rect.fromLTWH(x, y, width, height);
  CardCanvasNode withGroupLabel(String label) {
    if (type != 'group') throw StateError('Only group nodes have group labels');
    return CardCanvasNode.fromJson({..._raw, 'label': label});
  }

  CardCanvasNode copyWith({
    double? x,
    double? y,
    double? width,
    double? height,
    String? text,
    String? color,
  }) => CardCanvasNode.fromJson({
    ..._raw,
    if (x != null) 'x': x.round(),
    if (y != null) 'y': y.round(),
    if (width != null) 'width': width.round(),
    if (height != null) 'height': height.round(),
    'text': ?text,
    'color': ?color,
  });
  Map<String, dynamic> toJson() => _copy(_raw);
}

class CardCanvasEdge {
  new _(this._raw);
  factory fromJson(Map<String, dynamic> json) {
    _identifier(json['id']);
    _identifier(json['fromNode']);
    _identifier(json['toNode']);
    return CardCanvasEdge._(_copy(json));
  }
  factory connect({
    required String id,
    required String fromNode,
    required String toNode,
  }) => CardCanvasEdge.fromJson({
    'id': id,
    'fromNode': fromNode,
    'toNode': toNode,
    'fromSide': 'right',
    'toSide': 'left',
    'toEnd': 'arrow',
  });
  final Map<String, dynamic> _raw;
  String get id => _raw['id'] as String;
  String get fromNode => _raw['fromNode'] as String;
  String get toNode => _raw['toNode'] as String;
  String? get fromSide => _string('fromSide');
  String? get toSide => _string('toSide');
  String? get label => _string('label');

  String? _string(String key) => switch (_raw[key]) {
    final String value => value,
    _ => null,
  };

  CardCanvasEdge withLabel(String? label) {
    final next = Map.of(_raw);
    if (label == null) {
      next.remove('label');
    } else {
      next['label'] = label;
    }
    return CardCanvasEdge.fromJson(next);
  }

  Map<String, dynamic> toJson() => _copy(_raw);
}

class CardCanvasViewport {
  const new({this.offset = Offset.zero, this.scale = 1});
  final Offset offset;
  final double scale;
  Offset worldToScreen(Offset world) => world * scale + offset;
  Offset screenToWorld(Offset screen) => (screen - offset) / scale;
  CardCanvasViewport pan(Offset delta) =>
      CardCanvasViewport(offset: offset + delta, scale: scale);
  CardCanvasViewport zoomAt(Offset focal, double factor) => CardCanvasViewport(
    scale: (scale * factor).clamp(.1, 5.0).toDouble(),
    offset:
        focal -
        screenToWorld(focal) * (scale * factor).clamp(.1, 5.0).toDouble(),
  );
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map) throw const FormatException('Expected a canvas object');
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    _object(jsonDecode(jsonEncode(value)));
double _number(Object? value) {
  if (value is! num || !value.isFinite)
    throw const FormatException('Invalid canvas coordinate');
  return value.toDouble();
}

void _identifier(Object? value) {
  if (value is! String || value.isEmpty)
    throw const FormatException('Invalid canvas identity');
}
