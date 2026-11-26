import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/settings_registry.dart';
import 'package:saber/pages/settings/settings_entries.dart';
import 'package:saber/pages/settings/settings_text.dart';

const _plain = TextDecoration.none;

/// One `.srow` of the settings page: a 19px icon, the name with its note lines
/// under it, and something on the right (a switch, a value chip, or nothing).
/// It fills the width and has a thin line under it.
class SettingsRowShell extends StatelessWidget {
  const new({
    super.key,
    required this.id,
    required this.icon,
    required this.label,
    this.widgetKey,
    this.description,
    this.reason,
    this.trailing,
    this.onTap,
    this.opacity = 1,
    this.toggled,
  });

  /// The setting key; the row is found as `settings-row-<id>`.
  final String id;
  final KitIconName icon;
  final String label;

  /// The old key tests look for; on the part that takes the tap.
  final Key? widgetKey;
  final String? description;

  /// Why the row was turned off, in red under the note.
  final String? reason;
  final Widget? trailing;
  final VoidCallback? onTap;
  final double opacity;

  /// For a switch row: whether it is on (read by screen readers).
  final bool? toggled;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: ValueKey('settings-row-$id'),
      child: Opacity(
        opacity: opacity,
        child: Semantics(
          container: true,
          button: toggled == null && onTap != null,
          toggled: toggled,
          enabled: onTap != null || trailing != null,
          label: label,
          hint: [?description, ?reason].join(' '),
          onTap: onTap,
          // A row with a chip on the right leaves the chip's own semantics.
          excludeSemantics: toggled != null || onTap != null,
          child: Material(
            color: KitTokens.settingsSurface,
            child: InkWell(
              key: widgetKey,
              onTap: onTap,
              // A Container, so the 1px line takes room like a CSS border.
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: KitTokens.settingsLine),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  vertical: KitTokens.settingsRowPadV,
                  horizontal: KitTokens.settingsRowPadH,
                ),
                child: Row(
                  children: [
                    KitIcon(
                      icon,
                      size: KitTokens.settingsIconSize,
                      strokeWidth: KitTokens.settingsIconStroke,
                      color: KitTokens.settingsMuted,
                    ),
                    const SizedBox(width: KitTokens.settingsRowGap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SettingsText(
                            label,
                            style: const TextStyle(
                              fontSize: KitTokens.settingsRowFontSize,
                              height: KitTokens.settingsLabelLineHeight,
                              color: KitTokens.menuInk,
                              decoration: _plain,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                          if (description != null)
                            SettingsText(
                              description!,
                              style: const TextStyle(
                                fontSize: KitTokens.settingsNoteFontSize,
                                height: KitTokens.settingsNoteLineHeight,
                                color: KitTokens.settingsMuted,
                                decoration: _plain,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          if (reason != null)
                            SettingsText(
                              reason!,
                              style: const TextStyle(
                                fontSize: KitTokens.settingsNoteFontSize,
                                height: KitTokens.settingsNoteLineHeight,
                                color: KitTokens.settingsDanger,
                                decoration: _plain,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: KitTokens.settingsRowGap),
                      trailing!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An on/off row. A row the table turned off shows at .45 with its reason, and
/// still turns on when pressed (the pair rule then follows).
class SettingsToggleRow extends StatelessWidget {
  const new({super.key, required this.entry, required this.registry});

  final ToggleSetting entry;
  final SettingsRegistry registry;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([registry, entry.notifier]),
      builder: (context, _) {
        final value = entry.notifier.value;
        final reason = registry.autoOffReason(entry.key);
        return SettingsRowShell(
          id: entry.key,
          widgetKey: entry.widgetKey,
          icon: settingsRowIcon(entry.key),
          label: entry.label,
          description: entry.description,
          reason: reason,
          opacity: reason == null ? 1 : KitTokens.settingsDimOpacity,
          toggled: value,
          trailing: KitSwitch(value: value),
          onTap: () => entry.notifier.value = !value,
        );
      },
    );
  }
}

/// A pick-one row: the current value in a chip on the right; the chip opens a
/// menu under it with the current value checked.
class SettingsChoiceRow extends StatefulWidget {
  const new({super.key, required this.entry});

  final ChoiceSetting<Object?> entry;

  @override
  State<SettingsChoiceRow> createState() => _SettingsChoiceRowState();
}

class _SettingsChoiceRowState extends State<SettingsChoiceRow> {
  final _anchor = GlobalKey();

  ChoiceSetting<Object?> get _entry => widget.entry;

  String _nameOf(Object? value) {
    for (final (v, name) in _entry.options) {
      if (v == value) return name;
    }
    return '';
  }

  KitMenu _menu() => KitMenu(
    groups: [
      KitMenuGroup(
        rows: [
          for (final (value, name) in _entry.options)
            KitMenuRow.action(
              icon: value == _entry.notifier.value
                  ? KitIconName.check
                  : KitIconName.radio,
              label: name,
              onTap: () {
                Navigator.of(context).pop();
                _entry.notifier.value = value;
              },
            ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(KitTokens.settingsChipRadius);
    return ListenableBuilder(
      listenable: _entry.notifier,
      builder: (context, _) => SettingsRowShell(
        id: _entry.key,
        widgetKey: _entry.widgetKey,
        icon: settingsRowIcon(_entry.key),
        label: _entry.label,
        description: _entry.description,
        trailing: KeyedSubtree(
          key: ValueKey('settings-chip-${_entry.key}'),
          child: Semantics(
            button: true,
            label: _entry.label,
            value: _nameOf(_entry.notifier.value),
            excludeSemantics: true,
            child: Material(
              key: _anchor,
              color: KitTokens.settingsSoft,
              borderRadius: radius,
              child: InkWell(
                borderRadius: radius,
                onTap: () => showKitMenu(
                  context: context,
                  anchor: _anchor,
                  builder: _menu,
                ),
                child: Padding(
                  padding: KitTokens.settingsChipPadding,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SettingsText(
                        _nameOf(_entry.notifier.value),
                        style: const TextStyle(
                          fontSize: KitTokens.settingsChipFontSize,
                          height: KitTokens.settingsChipLineHeight,
                          color: KitTokens.accent,
                          decoration: _plain,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(width: KitTokens.settingsChipGap),
                      const KitIcon(
                        KitIconName.chev,
                        size: KitTokens.settingsChipIconSize,
                        strokeWidth: KitTokens.settingsIconStroke,
                        color: KitTokens.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row that runs an action of the app registry; the whole row is the button
/// and the right side stays empty.
class SettingsActionRow extends StatelessWidget {
  const new({
    super.key,
    required this.entry,
    required this.actions,
    required this.onPressed,
  });

  final ActionSetting entry;
  final AppActionRegistry actions;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppAction? action = actions.lookup(entry.actionId);
    if (action == null) return const SizedBox.shrink();
    return SettingsRowShell(
      id: entry.key,
      widgetKey: entry.widgetKey,
      icon: action.icon,
      label: entry.label,
      description: entry.description,
      opacity: action.enabled ? 1 : KitTokens.disabledOpacity,
      onTap: action.enabled ? onPressed : null,
    );
  }
}
