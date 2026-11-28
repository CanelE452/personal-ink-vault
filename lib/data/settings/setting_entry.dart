import 'package:flutter/foundation.dart';

/// One row of the settings table. Value rows hold the stow itself (any
/// `ValueNotifier`), so the table sees every write, whoever makes it.
///
/// A row with [onPage] false is in the table for its rules and for readers
/// of its value, but the settings page does not list it.
///
/// Not made yet, no row uses it: a pair of value rows. Its shape would be a
/// key, a condition on that row's value, and the value to put back when the
/// condition stops holding.
sealed class SettingEntry {
  const new({
    required this.key,
    required this.label,
    this.description,
    required this.group,
    this.widgetKey,
    this.onPage = true,
  });

  /// For a value row, the stow key (use `stows.x.key`); for an action row,
  /// the action id.
  final String key;
  final String label;
  final String? description;
  final String group;
  final Key? widgetKey;
  final bool onPage;
}

/// An on/off row. Turning it on turns off every row in [conflictsWith] and
/// every row that lists this one.
final class ToggleSetting extends SettingEntry {
  const new({
    required super.key,
    required super.label,
    super.description,
    required super.group,
    super.widgetKey,
    super.onPage,
    required this.notifier,
    this.conflictsWith = const [],
    this.ownsNotifier = false,
  });

  final ValueNotifier<bool> notifier;
  final List<String> conflictsWith;

  /// The row made [notifier] for itself (not a stow): the table disposes it
  /// when the row goes (replaced by a row with another notifier, taken off
  /// by `clear`, or the table disposed).
  final bool ownsNotifier;
}

/// A pick-one row. [options] holds (value, name shown).
final class ChoiceSetting<T> extends SettingEntry {
  const new({
    required super.key,
    required super.label,
    super.description,
    required super.group,
    super.widgetKey,
    super.onPage,
    required this.notifier,
    required this.options,
  });

  final ValueNotifier<T> notifier;
  final List<(T, String)> options;
}

/// A row that runs an action. The settings page runs it through the app's
/// action registry.
final class ActionSetting extends SettingEntry {
  const new({
    required this.actionId,
    required super.label,
    super.description,
    required super.group,
    super.widgetKey,
  }) : super(key: actionId);

  final String actionId;
}

/// A row that keeps a list of names (the eraser's targets). Never listed on
/// the settings page.
///
/// [read] gives the names that count as on now, when that is not just the
/// stored list (the eraser's list is empty until first set, and an older
/// switch decides until then). Without it the stored list counts.
final class ListSetting extends SettingEntry {
  const new({
    required super.key,
    required super.label,
    super.description,
    required super.group,
    required this.notifier,
    this.read,
  }) : super(onPage: false);

  final ValueNotifier<List<String>> notifier;
  final ValueGetter<List<String>>? read;

  /// The names on now.
  List<String> get value => read?.call() ?? notifier.value;
}
