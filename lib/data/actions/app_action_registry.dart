import 'package:flutter/widgets.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';

/// The actions one scope offers. There are two scopes: the app registry (library,
/// settings, ... filled by the workspace) and one document registry per editor
/// host (the open document's actions). A document registry has the app registry
/// as [parent]; [lookup] asks itself first, then the parent.
///
/// Owners publish their whole current list with [publish]. The list changes at
/// once, but listeners hear about it once after the frame, and only when what
/// is seen changed (ids, or any field but `run`).
class AppActionRegistry extends ChangeNotifier {
  new({this.parent}) {
    parent?.addListener(_onParentChanged);
  }

  final AppActionRegistry? parent;

  final Map<String, AppAction> _actions = {};
  final Map<String, Object> _owners = {};
  var _noticeScheduled = false;
  var _disposed = false;

  /// The ids each owner published last, kept in debug builds only. The table
  /// keeps one owner per id (the later one), so a test reads this to check
  /// that two owners never publish the same id.
  @visibleForTesting
  final Map<Object, Set<String>> debugPublishedIds = {};

  void _onParentChanged() {
    if (!_disposed) notifyListeners();
  }

  /// Replaces everything [owner] publishes with [actions]. Ids of [owner] that
  /// are not in the new list are removed. An id another owner holds is taken
  /// over (the later publisher wins).
  void publish(Object owner, Iterable<AppAction> actions) {
    final list = actions.toList();
    assert(() {
      for (final action in list) {
        if (!AppActionIds.all.contains(action.id)) {
          throw AssertionError('Unknown action id: ${action.id}');
        }
      }
      return true;
    }());
    final newIds = {for (final action in list) action.id};
    assert(() {
      debugPublishedIds[owner] = newIds;
      return true;
    }());
    var changed = false;
    for (final id in [
      for (final e in _owners.entries)
        if (identical(e.value, owner) && !newIds.contains(e.key)) e.key,
    ]) {
      _actions.remove(id);
      _owners.remove(id);
      changed = true;
    }
    for (final action in list) {
      final old = _actions[action.id];
      if (old == null || !old.looksSame(action)) changed = true;
      _actions[action.id] = action;
      _owners[action.id] = owner;
    }
    if (changed) _scheduleNotice();
  }

  /// Removes the ids [owner] holds now. Ids another owner took over stay.
  void withdraw(Object owner) {
    assert(() {
      debugPublishedIds.remove(owner);
      return true;
    }());
    final ids = [
      for (final e in _owners.entries)
        if (identical(e.value, owner)) e.key,
    ];
    if (ids.isEmpty) return;
    for (final id in ids) {
      _actions.remove(id);
      _owners.remove(id);
    }
    _scheduleNotice();
  }

  AppAction? lookup(String id) => _actions[id] ?? parent?.lookup(id);

  bool has(String id) => lookup(id) != null;

  /// The actions found for [ids], in the order given. Unknown ids are skipped.
  List<AppAction> resolve(Iterable<String> ids) => [
    for (final id in ids)
      ?lookup(id),
  ];

  /// Runs the action [id] with [context] if it exists and is enabled. Returns
  /// whether it ran. Keyboard and gesture handlers use this.
  bool run(String id, BuildContext context) {
    final action = lookup(id);
    if (action == null || !action.enabled) return false;
    action.run(context);
    return true;
  }

  void _scheduleNotice() {
    if (_noticeScheduled || _disposed) return;
    _noticeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _noticeScheduled = false;
      if (!_disposed) notifyListeners();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    parent?.removeListener(_onParentChanged);
    super.dispose();
  }
}

/// Gives the widgets below an [AppActionRegistry].
class AppActionScope extends InheritedNotifier<AppActionRegistry> {
  const new({
    super.key,
    required AppActionRegistry actions,
    required super.child,
  }) : super(notifier: actions);

  /// The registry, listening: the caller is built again when the table
  /// changes. Bars and menus use this.
  static AppActionRegistry of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppActionScope>();
    assert(scope != null, 'No AppActionScope above this context');
    return scope!.notifier!;
  }

  /// The registry without listening, or null when there is none. The canvas and
  /// the page-level widgets use only this.
  static AppActionRegistry? read(BuildContext context) => context
      .getInheritedWidgetOfExactType<AppActionScope>()
      ?.notifier;
}
