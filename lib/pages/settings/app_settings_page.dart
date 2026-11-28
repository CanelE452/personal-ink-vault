import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/settings/app_settings.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/settings_registry.dart';
import 'package:saber/pages/settings/settings_chrome.dart';
import 'package:saber/pages/settings/settings_rows.dart';
import 'package:saber/pages/settings/settings_text.dart';

/// The full screen settings page (the approved preview's 9구역): a top bar
/// with the search box, a list of groups on the left, and on the right every
/// group's header and rows in one scrolling column. Value rows write the stow
/// they hold (the table turns conflicting partners off by itself). Action rows
/// run an action of the app registry [actions]; a row whose action is not
/// there is left out. Narrower than 720 the left list is hidden.
class AppSettingsPage extends StatefulWidget {
  const new({
    super.key,
    required this.actions,
    this.registry,
    this.initialQuery,
  });

  final AppActionRegistry actions;

  /// The table to show; the app's [settingsRegistry] when null.
  final SettingsRegistry? registry;

  final String? initialQuery;

  @override
  State<AppSettingsPage> createState() => _AppSettingsPageState();
}

/// Slides in from the right edge with the slow step; no slide when the system
/// asks for no animations.
Route<void> appSettingsRoute({
  required AppActionRegistry actions,
  SettingsRegistry? registry,
  String? initialQuery,
}) => _AppSettingsRoute(
  actions: actions,
  registry: registry,
  initialQuery: initialQuery,
);

class _AppSettingsRoute extends PageRoute<void> {
  new({required this.actions, this.registry, this.initialQuery});

  final AppActionRegistry actions;
  final SettingsRegistry? registry;
  final String? initialQuery;

  Duration _step({required bool closing}) {
    final context = navigator?.context;
    if (context == null) {
      return closing
          ? KitMotion.close(KitMotionStep.slow)
          : KitMotion.open(KitMotionStep.slow);
    }
    return KitMotion.of(context, KitMotionStep.slow, closing: closing);
  }

  @override
  Duration get transitionDuration => _step(closing: false);

  @override
  Duration get reverseTransitionDuration => _step(closing: true);

  @override
  bool get maintainState => true;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => AppSettingsPage(
    actions: actions,
    registry: registry,
    initialQuery: initialQuery,
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => SlideTransition(
    position: Tween(begin: const Offset(1, 0), end: Offset.zero).animate(
      CurvedAnimation(
        parent: animation,
        curve: KitMotion.openCurve,
        reverseCurve: KitMotion.closeCurve,
      ),
    ),
    child: child,
  );
}

class _AppSettingsPageState extends State<AppSettingsPage> {
  late final _query = TextEditingController(text: widget.initialQuery);
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _view = GlobalKey();
  final _heads = <String, GlobalKey>{};

  /// The group whose header is in view (the list highlights it).
  final _current = ValueNotifier<String?>(null);
  var _shown = <String>[];
  var _jumping = false;
  var _jumpId = 0;

  SettingsRegistry get _registry => widget.registry ?? settingsRegistry;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    _scroll.addListener(_followScroll);
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _scroll.removeListener(_followScroll);
    _focus.dispose();
    _scroll.dispose();
    _query.dispose();
    _current.dispose();
    super.dispose();
  }

  void _focusChanged() => setState(() {});

  bool _visible(SettingEntry e) =>
      e is! ActionSetting || widget.actions.has(e.actionId);

  /// The groups that have rows for the current query, in the table's order.
  List<(String, List<SettingEntry>)> _groups() {
    final found = _registry.search(_query.text);
    return [
      for (final group in _registry.groups)
        if ([
              for (final e in found)
                if (e.group == group && _visible(e)) e,
            ]
            case final rows when rows.isNotEmpty)
          (group, rows),
    ];
  }

  /// Follows the scroll: the last header that has reached the top is the
  /// current group; at the very bottom it is the last group.
  void _followScroll() {
    if (_jumping || _shown.isEmpty) return;
    final view = _view.currentContext?.findRenderObject();
    if (view is! RenderBox || !view.attached) return;
    String? best;
    for (final group in _shown) {
      final box = _heads[group]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      if (box.localToGlobal(Offset.zero, ancestor: view).dy <= 12) {
        best = group;
      }
    }
    if (_scroll.hasClients &&
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 1) {
      best = _shown.last;
    }
    best ??= _shown.first;
    if (best != _current.value) _current.value = best;
  }

  Future<void> _goTo(String group) async {
    final target = _heads[group]?.currentContext;
    if (target == null) return;
    _current.value = group;
    _jumping = true;
    final id = ++_jumpId;
    try {
      await Scrollable.ensureVisible(
        target,
        duration: KitMotion.of(context, KitMotionStep.normal),
        curve: KitMotion.openCurve,
      );
    } finally {
      // A later tap owns the flag; only the last one releases it.
      if (id == _jumpId) _jumping = false;
    }
  }

  /// Closes the page, then runs the action on the next frame, so what the
  /// action opens (a dialog, a file picker) is not hidden behind this page.
  void _runAction(BuildContext context, ActionSetting entry) {
    final nav = Navigator.of(context);
    final actions = widget.actions;
    nav.pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final overlay = nav.overlay;
      if (!nav.mounted || overlay == null) return;
      // A context below the Navigator, so `Navigator.of` and `showDialog`
      // work on it (the Navigator's own context is skipped by those lookups).
      actions.run(entry.actionId, overlay.context);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Widget _row(SettingEntry entry) => switch (entry) {
    ToggleSetting() => SettingsToggleRow(entry: entry, registry: _registry),
    ChoiceSetting<Object?>() => SettingsChoiceRow(entry: entry),
    ListSetting() => const SizedBox.shrink(),
    ActionSetting() => Builder(
      builder: (context) => SettingsActionRow(
        entry: entry,
        actions: widget.actions,
        onPressed: () => _runAction(context, entry),
      ),
    ),
  };

  Widget _head(String group) => KeyedSubtree(
    key: ValueKey('settings-head-$group'),
    child: Container(
      key: _heads.putIfAbsent(group, GlobalKey.new),
      padding: KitTokens.settingsHeadPadding,
      // A text line is rounded to whole px, so the preview's 15.5 line would
      // be 15; the box keeps 15.5 (a 33.5 header), gives the half px back
      // above and below the text, and still grows with larger text.
      child: Container(
        constraints: const BoxConstraints(
          minHeight:
              KitTokens.settingsHeadFontSize * KitTokens.settingsHeadLineHeight,
        ),
        alignment: AlignmentDirectional.centerStart,
        child: SettingsText(
          group,
          style: const TextStyle(
            fontSize: KitTokens.settingsHeadFontSize,
            height: KitTokens.settingsHeadLineHeight,
            fontWeight: KitTokens.settingsHeadWeight,
            color: KitTokens.settingsMuted,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    ),
  );

  Widget _content(List<(String, List<SettingEntry>)> groups) {
    if (groups.isEmpty) {
      return Center(
        child: Text(
          "'${_query.text}'에 맞는 설정이 없습니다",
          style: const TextStyle(
            fontSize: KitTokens.settingsRowFontSize,
            color: KitTokens.settingsMuted,
            decoration: TextDecoration.none,
          ),
        ),
      );
    }
    return KeyedSubtree(
      key: const ValueKey('settings-scroll'),
      child: SingleChildScrollView(
        key: _view,
        controller: _scroll,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (group, rows) in groups) ...[
              _head(group),
              for (final entry in rows) _row(entry),
            ],
            const SizedBox(height: KitTokens.settingsListBottomPad),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KitTokens.settingsBg,
      body: SafeArea(
        child: Column(
          children: [
            SettingsTopBar(
              onBack: () => Navigator.of(context).maybePop(),
              controller: _query,
              focusNode: _focus,
              searchFocused: _focus.hasFocus,
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: Listenable.merge([
                  _registry,
                  widget.actions,
                  _query,
                ]),
                builder: (context, _) {
                  final groups = _groups();
                  _shown = [for (final (g, _) in groups) g];
                  final content = _content(groups);
                  return LayoutBuilder(
                    builder: (context, box) =>
                        box.maxWidth >= KitTokens.settingsWideBreakpoint
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SettingsNav(
                                groups: _shown,
                                current: _current,
                                onSelect: _goTo,
                              ),
                              Expanded(child: content),
                            ],
                          )
                        : content,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
