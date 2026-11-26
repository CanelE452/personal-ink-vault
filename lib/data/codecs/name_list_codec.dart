import 'package:stow_codecs/stow_codecs.dart';

/// A list of names kept as a string list. Whatever else was kept under the
/// key (a string, a number, a list holding other things) reads as names too,
/// each written out, so the reader sees names it does not know instead of
/// failing to read the setting.
class const NameListCodec() extends AbstractCodec<List<String>, Object?> {
  @override
  Object? encode(List<String> input) => input;

  @override
  List<String> decode(Object? encoded) => switch (encoded) {
    final List<Object?> list => [for (final name in list) '$name'],
    _ => ['$encoded'],
  };
}
