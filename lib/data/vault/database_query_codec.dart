import 'dart:collection';

abstract final class DatabaseQueryCodec {
  static const maxDepth = 128;
  static const maxNodes = 200000;
  static const maxCodeUnits = 2000000;

  static Map<String, Object?> pack(Object? value) {
    final nodes = <Object?>[];
    final active = HashSet<Object>.identity();
    var units = 0;
    List<int> string(String value) {
      units += value.length;
      if (units > maxCodeUnits) _invalid();
      return List.of(value.codeUnits);
    }

    int visit(Object? value, int depth) {
      if (depth > maxDepth) _invalid();
      Object? node;
      if (value == null || value is bool) {
        node = value;
      } else if (value is num) {
        if (!value.isFinite) _invalid();
        node = value;
      } else if (value is String) {
        node = ['s', string(value)];
      } else if (value is List) {
        if (!active.add(value)) _invalid();
        try {
          node = [
            'a',
            [for (final child in value) visit(child, depth + 1)],
          ];
        } finally {
          active.remove(value);
        }
      } else if (value is Map) {
        if (!active.add(value)) _invalid();
        try {
          node = [
            'o',
            [
              for (final entry in value.entries)
                if (entry.key is String)
                  [string(entry.key as String), visit(entry.value, depth + 1)]
                else
                  _invalid(),
            ],
          ];
        } finally {
          active.remove(value);
        }
      } else {
        _invalid();
      }
      if (nodes.length >= maxNodes) _invalid();
      nodes.add(node);
      return nodes.length - 1;
    }

    final root = visit(value, 0);
    return {'root': root, 'nodes': nodes};
  }

  static Object? unpack(Object? payload) {
    if (payload is! Map ||
        payload.length != 2 ||
        payload['nodes'] is! List ||
        payload['root'] is! int)
      _invalid();
    final nodes = payload['nodes'] as List;
    if (nodes.isEmpty ||
        nodes.length > maxNodes ||
        payload['root'] != nodes.length - 1)
      _invalid();
    final values = <Object?>[];
    final depths = <int>[];
    final uses = List<int>.filled(nodes.length, 0);
    var units = 0;
    String string(Object? raw) {
      if (raw is! List) _invalid();
      units += raw.length;
      if (units > maxCodeUnits) _invalid();
      final codeUnits = <int>[];
      for (final unit in raw) {
        if (unit is! int || unit < 0 || unit > 0xffff) _invalid();
        codeUnits.add(unit);
      }
      return String.fromCharCodes(codeUnits);
    }

    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      var depth = 0;
      int reference(Object? raw) {
        if (raw is! int || raw < 0 || raw >= index) _invalid();
        if (++uses[raw] != 1) _invalid();
        final childDepth = depths[raw] + 1;
        if (childDepth > depth) depth = childDepth;
        if (depth > maxDepth) _invalid();
        return raw;
      }

      Object? value;
      if (node == null || node is bool) {
        value = node;
      } else if (node is num) {
        if (!node.isFinite) _invalid();
        value = node;
      } else if (node is List && node.length == 2) {
        switch (node[0]) {
          case 's':
            value = string(node[1]);
          case 'a':
            if (node[1] is! List) _invalid();
            value = List<Object?>.unmodifiable([
              for (final child in node[1] as List) values[reference(child)],
            ]);
          case 'o':
            if (node[1] is! List) _invalid();
            final object = <String, Object?>{};
            for (final raw in node[1] as List) {
              if (raw is! List || raw.length != 2) _invalid();
              final key = string(raw[0]);
              if (object.containsKey(key)) _invalid();
              object[key] = values[reference(raw[1])];
            }
            value = Map<String, Object?>.unmodifiable(object);
          default:
            _invalid();
        }
      } else {
        _invalid();
      }
      values.add(value);
      depths.add(depth);
    }
    for (var index = 0; index < nodes.length; index++) {
      if (uses[index] != (index == nodes.length - 1 ? 0 : 1)) _invalid();
    }
    return values.last;
  }

  static Never _invalid() =>
      throw const FormatException('Invalid UTF16 query wire tree');
}
