import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/pages/settings/settings_entries.dart';
import 'package:saber/pages/settings/settings_text.dart';

const _plain = TextDecoration.none;
const _searchText = TextStyle(
  fontSize: KitTokens.settingsSearchFontSize,
  height: KitTokens.settingsSearchLineHeight,
  color: KitTokens.menuInk,
  decoration: _plain,
);

/// The settings page's top bar: back arrow, the title, and the search box at
/// the right end.
class SettingsTopBar extends StatelessWidget {
  const new({
    super.key,
    required this.onBack,
    required this.controller,
    required this.focusNode,
    required this.searchFocused,
  });

  final VoidCallback onBack;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool searchFocused;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('settings-topbar'),
      height: KitTokens.settingsTopBarHeight,
      padding: const EdgeInsets.only(
        left: KitTokens.settingsTopBarPadH - KitTokens.settingsBackTapPad,
        right: KitTokens.settingsTopBarPadH,
      ),
      decoration: const BoxDecoration(
        color: KitTokens.settingsSurface,
        border: Border(bottom: BorderSide(color: KitTokens.settingsLine)),
      ),
      child: Row(
        children: [
          InkWell(
            key: const ValueKey('settings-back'),
            customBorder: const CircleBorder(),
            onTap: onBack,
            child: Padding(
              padding: const EdgeInsets.all(KitTokens.settingsBackTapPad),
              child: Semantics(
                button: true,
                label: KitIconName.back.label,
                excludeSemantics: true,
                child: const KitIcon(
                  KitIconName.back,
                  size: KitTokens.settingsBackIconSize,
                  strokeWidth: KitTokens.settingsIconStroke,
                  color: KitTokens.menuInk,
                ),
              ),
            ),
          ),
          // The press area reaches 12 past the arrow on both sides; the title
          // sits 10 after the arrow itself.
          Transform.translate(
            offset: const Offset(
              KitTokens.settingsTopBarGap - KitTokens.settingsBackTapPad,
              0,
            ),
            child: const Text(
              '설정',
              style: TextStyle(
                fontSize: KitTokens.settingsTitleSize,
                fontWeight: KitTokens.settingsTitleWeight,
                color: KitTokens.menuInk,
                decoration: _plain,
              ),
            ),
          ),
          const SizedBox(width: KitTokens.settingsTopBarGap),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: KitTokens.settingsSearchWidth,
                ),
                child: Container(
                  key: const ValueKey('settings-search-box'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: KitTokens.settingsSearchPadH,
                    vertical: KitTokens.settingsSearchPadV,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: searchFocused
                          ? KitTokens.accent
                          : KitTokens.settingsLine,
                    ),
                    borderRadius: BorderRadius.circular(
                      KitTokens.settingsSearchRadius,
                    ),
                  ),
                  child: Row(
                    children: [
                      const KitIcon(
                        KitIconName.search,
                        size: KitTokens.settingsSearchIconSize,
                        strokeWidth: KitTokens.settingsIconStroke,
                        color: KitTokens.settingsMuted,
                      ),
                      const SizedBox(width: KitTokens.settingsSearchGap),
                      Expanded(
                        child: TextField(
                          key: const ValueKey('settings-search'),
                          controller: controller,
                          focusNode: focusNode,
                          style: _searchText,
                          strutStyle: settingsStrut(context, _searchText),
                          // The hint as a widget: the decorator's own hint
                          // text would have no strut.
                          decoration: const InputDecoration.collapsed(
                            hintText: null,
                            hint: SettingsText(
                              '설정 검색',
                              style: TextStyle(
                                fontSize: KitTokens.settingsSearchFontSize,
                                height: KitTokens.settingsSearchLineHeight,
                                color: KitTokens.settingsMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The left list `.snav`: one item per group with rows. [current] is the group
/// whose header is in view (null means the first one).
class SettingsNav extends StatelessWidget {
  const new({
    super.key,
    required this.groups,
    required this.current,
    required this.onSelect,
  });

  final List<String> groups;
  final ValueListenable<String?> current;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('settings-nav'),
      width: KitTokens.settingsNavWidth,
      padding: const EdgeInsets.symmetric(
        vertical: KitTokens.settingsNavPadV,
        horizontal: KitTokens.settingsNavPadH,
      ),
      decoration: const BoxDecoration(
        color: KitTokens.settingsBg,
        border: Border(right: BorderSide(color: KitTokens.settingsLine)),
      ),
      child: ValueListenableBuilder<String?>(
        valueListenable: current,
        builder: (context, now, _) {
          final on = groups.contains(now) ? now : groups.firstOrNull;
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final group in groups)
                  _NavItem(
                    group: group,
                    selected: group == on,
                    onTap: () => onSelect(group),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const new({required this.group, required this.selected, required this.onTap});

  final String group;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? KitTokens.accent : KitTokens.menuInk;
    final radius = BorderRadius.circular(KitTokens.settingsNavItemRadius);
    return Semantics(
      button: true,
      selected: selected,
      label: group,
      excludeSemantics: true,
      child: Material(
        key: ValueKey('settings-nav-$group'),
        color: selected ? KitTokens.settingsSoft : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: KitTokens.settingsNavItemPadV,
              horizontal: KitTokens.settingsNavItemPadH,
            ),
            child: Row(
              children: [
                KitIcon(
                  settingsGroupIcon(group),
                  size: KitTokens.settingsIconSize,
                  strokeWidth: KitTokens.settingsIconStroke,
                  color: selected ? KitTokens.accent : KitTokens.settingsMuted,
                ),
                const SizedBox(width: KitTokens.settingsNavItemGap),
                Expanded(
                  child: Text(
                    group,
                    style: TextStyle(
                      fontSize: KitTokens.settingsNavFontSize,
                      color: color,
                      decoration: _plain,
                      fontWeight: selected
                          ? KitTokens.settingsNavOnWeight
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
