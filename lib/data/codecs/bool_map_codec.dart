import 'dart:convert';

import 'package:stow_codecs/stow_codecs.dart';

/// On/off values by name, kept as one JSON string. Whatever else is kept
/// under the key (an empty or broken string, a list, a number, a name with a
/// value that is not on or off) reads as no value for that name, so a
/// setting kept wrong opens as its default instead of failing to read.
class const BoolMapCodec() extends AbstractCodec<Map<String, bool>, Object?> {
  @override
  Object? encode(Map<String, bool> input) => jsonEncode(input);

  @override
  Map<String, bool> decode(Object? encoded) {
    Object? json = encoded;
    if (encoded is String) {
      try {
        json = jsonDecode(encoded);
      } on FormatException {
        return {};
      }
    }
    return {
      if (json is Map)
        for (final MapEntry(:key, :value) in json.entries)
          if (key is String && value is bool) key: value,
    };
  }
}
