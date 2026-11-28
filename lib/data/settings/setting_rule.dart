/// A rule over rows of the settings table. The rows are named by their key
/// (`stows.x.key` for a value row); the table reads the values itself.
sealed class SettingRule {
  const new({required this.reason});

  /// The one line shown where the rule holds something back.
  final String reason;
}

/// The row [key] is usable only while the on/off row [needs] is on. [needs]
/// is any on/off row of the table, not only one that is a stow.
final class Requires extends SettingRule {
  const new({required this.key, required this.needs, required super.reason});

  final String key;
  final String needs;
}

/// The last one on of these cannot be turned off. [KeepOneOn.toggles] names
/// on/off rows; [KeepOneOn.lists] names rows that each keep a list of names,
/// and counts the names of all of them together.
final class KeepOneOn extends SettingRule {
  const new toggles({required this.keys, required super.reason})
    : isList = false;

  const new lists({required this.keys, required super.reason}) : isList = true;

  final List<String> keys;
  final bool isList;
}
