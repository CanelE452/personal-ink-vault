import 'package:flutter/foundation.dart';

/// One row of the settings table. Value rows hold the stow itself (any
/// `ValueNotifier`), so the table sees every write, whoever makes it.
sealed class SettingEntry {
  const new({
    required this.key,
    required this.label,
    this.description,
    required this.group,
    this.widgetKey,
  });

  /// For a value row, the stow key (use `stows.x.key`); for an action row,
  /// the action id.
  final String key;
  final String label;
  final String? description;
  final String group;
  final Key? widgetKey;
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
    required this.notifier,
    this.conflictsWith = const [],
  });

  final ValueNotifier<bool> notifier;
  final List<String> conflictsWith;
}

/// A pick-one row. [options] holds (value, name shown).
final class ChoiceSetting<T> extends SettingEntry {
  const new({
    required super.key,
    required super.label,
    super.description,
    required super.group,
    super.widgetKey,
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
