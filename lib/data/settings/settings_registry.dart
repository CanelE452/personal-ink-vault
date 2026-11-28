import 'package:flutter/foundation.dart';
import 'package:saber/data/settings/korean_particle.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/setting_rule.dart';
import 'package:stow/stow.dart';

/// The settings table: every row of the settings page, and the rule that
/// turning one setting on turns its conflicting partners off (with a reason
/// the page shows under the row).
///
/// The rule watches the values themselves, so it runs no matter who writes a
/// stow. Values read from storage never turn partners off, and the table's
/// own writes are not undone, so there is no cascade.
///
/// Rules ([addRule]) say when a row cannot be used ([unusableReason]) and
/// which last one on cannot be turned off ([keepOneReason]), with the line
/// the screen shows. A row with `onPage` false is found by [byKey] but is not
/// among [entries], [groups], [inGroup] or [search], which are the page's.
class SettingsRegistry extends ChangeNotifier {
  new({required this._reasons}) {
    _reasons.addListener(notifyListeners);
  }

  /// Why a row was turned off (key -> one line).
  final ValueNotifier<Map<String, String>> _reasons;

  final _entries = <SettingEntry>[];
  final _rules = <SettingRule>[];
  final _watchers = <String, VoidCallback>{};
  final _lastValue = <String, bool>{};
  var _turningOff = false;

  Iterable<SettingEntry> get _onPage => _entries.where((e) => e.onPage);

  /// The rows the settings page lists.
  List<SettingEntry> get entries => List.unmodifiable(_onPage);

  List<String> get groups => [
    for (final g in _onPage.map((e) => e.group).toSet()) g,
  ];

  List<SettingEntry> inGroup(String group) => [
    for (final e in _onPage)
      if (e.group == group) e,
  ];

  SettingEntry? byKey(String key) {
    for (final e in _entries) {
      if (e.key == key) return e;
    }
    return null;
  }

  List<SettingEntry> search(String query) {
    final q = _normalize(query);
    if (q.isEmpty) return entries;
    return [
      for (final e in _onPage)
        if (_normalize(e.label).contains(q) ||
            _normalize(e.description ?? '').contains(q))
          e,
    ];
  }

  static String _normalize(String s) =>
      s.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  /// The stored reason for [key], only while that toggle is off.
  String? autoOffReason(String key) {
    final e = byKey(key);
    if (e is! ToggleSetting || e.notifier.value) return null;
    return _reasons.value[key];
  }

  /// Adds a rule. Rows are looked up by key when a rule is asked, so a rule
  /// may be added before its rows.
  void addRule(SettingRule rule) => _rules.add(rule);

  /// Why [key] cannot be used now (the row it needs is off), or null.
  /// [values] gives on/off values by key that count in place of the table's
  /// rows: a pen panel's own pen in hand, which may not be the table's.
  String? unusableReason(String key, {Map<String, bool> values = const {}}) {
    for (final rule in _rules) {
      if (rule is! Requires || rule.key != key) continue;
      final on =
          values[rule.needs] ??
          switch (byKey(rule.needs)) {
            ToggleSetting(:final notifier) => notifier.value,
            _ => true,
          };
      if (!on) return rule.reason;
    }
    return null;
  }

  /// The line of the [KeepOneOn] rule that names [key], whatever the values.
  String? keepOneText(String key) => _keepOneRule(key)?.reason;

  KeepOneOn? _keepOneRule(String key) {
    for (final rule in _rules) {
      if (rule is KeepOneOn && rule.keys.contains(key)) return rule;
    }
    return null;
  }

  /// Why [key] (for a list row, its [item]) cannot be turned off now: it is
  /// the last one on of its [KeepOneOn] rule. Null when it is off or another
  /// is on.
  ///
  /// A [KeepOneOn.lists] rule counts the names of all its lists together
  /// (each list read through its own [ListSetting.value]), so names must be
  /// distinct across them. [among] limits the count to what the screen shows
  /// (the keys of toggles, the names of list items).
  String? keepOneReason(String key, {String? item, Iterable<String>? among}) {
    final rule = _keepOneRule(key);
    if (rule == null) return null;
    final Set<String> onNow;
    final String self;
    if (rule.isList) {
      if (item == null) return null;
      self = item;
      onNow = {
        for (final k in rule.keys)
          if (byKey(k) case ListSetting(:final value)) ...value,
      };
    } else {
      self = key;
      onNow = {
        for (final k in rule.keys)
          if (byKey(k) case ToggleSetting(:final notifier) when notifier.value)
            k,
      };
    }
    if (among != null) onNow.retainAll(among.toSet());
    return onNow.length == 1 && onNow.contains(self) ? rule.reason : null;
  }

  /// Adds a row, or replaces the row with the same key in place. Does not
  /// change any value.
  void register(SettingEntry entry) {
    final i = _entries.indexWhere((e) => e.key == entry.key);
    if (i < 0) {
      _entries.add(entry);
    } else {
      _detach(_entries[i], by: entry);
      _entries[i] = entry;
    }
    if (entry is ToggleSetting) {
      _lastValue[entry.key] = entry.notifier.value;
      void watcher() => _onToggleChanged(entry);
      _watchers[entry.key] = watcher;
      entry.notifier.addListener(watcher);
    }
    notifyListeners();
  }

  /// Stops watching [entry], and lets its own notifier go unless [by], the
  /// row put in its place, keeps it.
  void _detach(SettingEntry entry, {SettingEntry? by}) {
    if (entry is! ToggleSetting) return;
    final watcher = _watchers.remove(entry.key);
    if (watcher != null) entry.notifier.removeListener(watcher);
    _lastValue.remove(entry.key);
    final kept = by is ToggleSetting && identical(by.notifier, entry.notifier);
    if (entry.ownsNotifier && !kept) entry.notifier.dispose();
  }

  void _onToggleChanged(ToggleSetting t) {
    final now = t.notifier.value;
    if (_lastValue[t.key] == now) return;
    _lastValue[t.key] = now;
    if (_turningOff) return;
    final Object n = t.notifier;
    if (n is Stow && n.isReading) return;
    _clearReason(t.key);
    if (now) _turnOffPartners(t);
  }

  void _turnOffPartners(ToggleSetting t) {
    final partners = [
      for (final e in _entries)
        if (e is ToggleSetting &&
            e.key != t.key &&
            e.notifier.value &&
            (t.conflictsWith.contains(e.key) ||
                e.conflictsWith.contains(t.key)))
          e,
    ];
    if (partners.isEmpty) return;
    _turningOff = true;
    try {
      for (final p in partners) {
        p.notifier.value = false;
        _reasons.value = Map.unmodifiable({
          ..._reasons.value,
          p.key: '${t.label}${subjectParticle(t.label)} 켜져 있어서 꺼졌습니다',
        });
      }
    } finally {
      _turningOff = false;
    }
  }

  void _clearReason(String key) {
    if (!_reasons.value.containsKey(key)) return;
    _reasons.value = Map.unmodifiable({..._reasons.value}..remove(key));
  }

  /// Takes the page's rows out again, with the reasons rows were turned off
  /// (a test that filled the app's table). The rows the page does not list
  /// and the rules stay: the ink panels read them.
  @visibleForTesting
  void clear() {
    for (final e in _entries.where((e) => e.onPage)) {
      _detach(e);
    }
    _entries.removeWhere((e) => e.onPage);
    _reasons.value = const {};
    notifyListeners();
  }

  @override
  void dispose() {
    for (final e in _entries) {
      _detach(e);
    }
    _reasons.removeListener(notifyListeners);
    super.dispose();
  }
}
