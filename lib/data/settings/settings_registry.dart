import 'package:flutter/foundation.dart';
import 'package:saber/data/settings/korean_particle.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:stow/stow.dart';

/// The settings table: every row of the settings page, and the rule that
/// turning one setting on turns its conflicting partners off (with a reason
/// the page shows under the row).
///
/// The rule watches the values themselves, so it runs no matter who writes a
/// stow. Values read from storage never turn partners off, and the table's
/// own writes are not undone, so there is no cascade.
class SettingsRegistry extends ChangeNotifier {
  new({required this._reasons}) {
    _reasons.addListener(notifyListeners);
  }

  /// Why a row was turned off (key -> one line).
  final ValueNotifier<Map<String, String>> _reasons;

  final _entries = <SettingEntry>[];
  final _watchers = <String, VoidCallback>{};
  final _lastValue = <String, bool>{};
  var _turningOff = false;

  List<SettingEntry> get entries => List.unmodifiable(_entries);

  List<String> get groups => [
    for (final g in _entries.map((e) => e.group).toSet()) g,
  ];

  List<SettingEntry> inGroup(String group) => [
    for (final e in _entries)
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
      for (final e in _entries)
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

  /// Adds a row, or replaces the row with the same key in place. Does not
  /// change any value.
  void register(SettingEntry entry) {
    final i = _entries.indexWhere((e) => e.key == entry.key);
    if (i < 0) {
      _entries.add(entry);
    } else {
      _detach(_entries[i]);
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

  void _detach(SettingEntry entry) {
    if (entry is! ToggleSetting) return;
    final watcher = _watchers.remove(entry.key);
    if (watcher != null) entry.notifier.removeListener(watcher);
    _lastValue.remove(entry.key);
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

  /// Takes every row out again, with the reasons rows were turned off (a
  /// test that filled the app's table).
  @visibleForTesting
  void clear() {
    for (final e in _entries) {
      _detach(e);
    }
    _entries.clear();
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
