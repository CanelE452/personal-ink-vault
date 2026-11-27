import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Layer rules for the new UI folders.
/// - `lib/components/kit/**` imports only other kit files from `lib/`
///   (exception: `package:sbn/tool_id.dart`).
/// - `lib/components/ink_ui/**` never imports `package:saber/pages/`.
/// - Neither folder uses `Icons.` or `Symbols.` (icons come from KitIcon).
/// - Elsewhere in lib/ the uses may not grow past the allow list below.
///
/// Files that already break a rule go in the allow lists below (matched by
/// path suffix). The two import lists are empty now.
const _kitImportAllow = <String>[];
const _inkUiPagesAllow = <String>[];

/// Old code outside kit/ink_ui that still uses Icons./Symbols. (file -> number
/// of uses on non-comment lines). A file not listed, or listed with a lower
/// count than it has now, fails. Task 19 set each number to the uses left
/// after the 229 toolbar was deleted; lower a number when a file drops uses.
/// Generated *.g.dart files are not scanned.
const _iconAllow = <String, int>{
  'lib/components/canvas/canvas_gesture_detector.dart': 2,
  'lib/components/canvas/canvas_image_dialog.dart': 5,
  'lib/components/canvas/page_link_layer.dart': 5,
  'lib/components/canvas/save_indicator.dart': 3,
  'lib/components/drive/drive_panel.dart': 2,
  'lib/components/editor/read_only_banner.dart': 2,
  'lib/components/files/file_tree.dart': 3,
  'lib/components/home/delete_folder_button.dart': 1,
  'lib/components/home/delete_note_button.dart': 1,
  'lib/components/home/export_note_button.dart': 2,
  'lib/components/home/grid_folders.dart': 4,
  'lib/components/home/home_layout_button.dart': 3,
  'lib/components/home/move_note_button.dart': 1,
  'lib/components/home/new_folder_dialog.dart': 1,
  'lib/components/home/new_note_button.dart': 3,
  'lib/components/home/path_components.dart': 1,
  'lib/components/home/rename_folder_button.dart': 2,
  'lib/components/home/rename_note_button.dart': 2,
  'lib/components/home/sort_button.dart': 3,
  'lib/components/home/sync_indicator.dart': 3,
  'lib/components/home/syncing_button.dart': 1,
  'lib/components/navbar/left_navbar.dart': 1,
  'lib/components/nextcloud/done_login_step.dart': 1,
  'lib/components/settings/nextcloud_profile.dart': 2,
  'lib/components/settings/settings_color.dart': 1,
  'lib/components/settings/settings_directory_selector.dart': 2,
  'lib/components/settings/settings_dropdown.dart': 1,
  'lib/components/settings/settings_selection.dart': 1,
  'lib/components/settings/settings_sentry.dart': 1,
  'lib/components/settings/settings_switch.dart': 1,
  'lib/components/theming/adaptive_text_field.dart': 2,
  'lib/components/toolbar/customize_dialog_frame.dart': 3,
  'lib/components/toolbar/editor_bottom_sheet.dart': 2,
  'lib/components/toolbar/shortcut_bar_editor.dart': 3,
  'lib/components/toolbar/shortcut_layout.dart': 20,
  'lib/data/routes.dart': 4,
  'lib/pages/editor/editor.dart': 1,
  'lib/pages/editor/link_dialog.dart': 1,
  'lib/pages/home/settings.dart': 40,
  'lib/pages/logs.dart': 3,
  'lib/pages/office/office_original_preview.dart': 5,
  'lib/pages/office/office_workspace.dart': 46,
  'lib/pages/office/pptx_photo_dialog.dart': 1,
  'lib/pages/office/pptx_shape_text_dialog.dart': 2,
  'lib/pages/office/pptx_slide_clone_dialog.dart': 1,
  'lib/pages/office/pptx_slide_reorder_dialog.dart': 1,
  'lib/pages/office/windows_office_editor.dart': 42,
  'lib/pages/office/windows_presentation_editor.dart': 6,
  'lib/pages/office/windows_word_editor.dart': 25,
  'lib/pages/planner/calendar_page.dart': 18,
  'lib/pages/planner/event_sheet.dart': 2,
  'lib/pages/planner/reminder_page.dart': 14,
  'lib/pages/user/login.dart': 1,
  'lib/pages/workspace/block_page_editor.dart': 52,
  'lib/pages/workspace/block_page_history_sheet.dart': 3,
  'lib/pages/workspace/block_table_editor.dart': 3,
  'lib/pages/workspace/card_canvas.dart': 19,
  'lib/pages/workspace/daily_note_template_settings_dialog.dart': 1,
  'lib/pages/workspace/database_automations_panel.dart': 12,
  'lib/pages/workspace/database_dashboard.dart': 4,
  'lib/pages/workspace/database_editor.dart': 20,
  'lib/pages/workspace/database_forms_editor.dart': 7,
  'lib/pages/workspace/database_history_sheet.dart': 1,
  'lib/pages/workspace/database_view_filter_editor.dart': 2,
  'lib/pages/workspace/database_view_sort_editor.dart': 4,
  'lib/pages/workspace/knowledge_panel.dart': 3,
  'lib/pages/workspace/library_add.dart': 28,
  'lib/pages/workspace/library_cards.dart': 12,
  'lib/pages/workspace/library_home.dart': 21,
  'lib/pages/workspace/library_menus.dart': 32,
  'lib/pages/workspace/linked_database_block.dart': 2,
  'lib/pages/workspace/markdown_callout.dart': 6,
  'lib/pages/workspace/markdown_editor.dart': 7,
  'lib/pages/workspace/mcp_panel.dart': 1,
  'lib/pages/workspace/page_discussion_sheet.dart': 1,
  'lib/pages/workspace/study_workspace.dart': 33,
  'lib/pages/workspace/workspace_bookmark_sheet.dart': 12,
  'lib/pages/workspace/workspace_quick_switcher.dart': 3,
};

/// keybinder binds keys for the whole app: two editors undo twice, and the
/// keys fire while the user types elsewhere. The editor's keys are focus
/// shortcuts now (the old toolbar's became them in Task 13B, the canvas's
/// zoom and arrow keys in Task 19, which took keybinder out of pubspec.yaml).
const _keybinderAllow = <String>[];

final _importLine = RegExp(
  r'^\s*(?:import|export)\s+(?:"([^"]+)"|'
  "'([^']+)')",
);
final _iconUse = RegExp(r'\b(?:Icons|Symbols)\.');
final _colorLiteral = RegExp(
  r'\bColor\s*(?:\(\s*0x|\.\s*from(?:ARGB|RGBO)\s*\()',
);

/// Number of colour literals in [source], ignoring comment lines. Looks at
/// the whole text, so a literal split over lines is found too.
int _colorLiterals(String source) {
  final code = [
    for (final line in source.split('\n'))
      if (!line.trimLeft().startsWith('//')) line,
  ].join('\n');
  return _colorLiteral.allMatches(code).length;
}

List<File> _dartFiles(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return const [];
  return d
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

int _iconUses(File f) {
  var n = 0;
  for (final line in f.readAsLinesSync()) {
    if (line.trimLeft().startsWith('//')) continue;
    n += _iconUse.allMatches(line).length;
  }
  return n;
}

String _rel(File f) => f.path.replaceAll(r'\', '/');

bool _allowed(File f, List<String> allow) => allow.any(_rel(f).endsWith);

List<String> _imports(File f) => [
  for (final line in f.readAsLinesSync())
    if (_importLine.firstMatch(line) case final m?) (m.group(1) ?? m.group(2))!,
];

/// Absolute posix-style path a relative [uri] points to, seen from [from].
String _resolveRelative(File from, String uri) =>
    Uri.file(from.absolute.path).resolve(uri).path;

void main() {
  final kitFiles = _dartFiles('lib/components/kit');
  final inkUiFiles = _dartFiles('lib/components/ink_ui');

  test('kit files import only kit (and sbn/tool_id.dart) from lib', () {
    final violations = <String>[];
    for (final f in kitFiles) {
      if (_allowed(f, _kitImportAllow)) continue;
      for (final uri in _imports(f)) {
        final bool ok;
        if (uri.startsWith('dart:')) {
          ok = true;
        } else if (uri.startsWith('package:saber/')) {
          ok = uri.startsWith('package:saber/components/kit/');
        } else if (uri.startsWith('package:sbn/')) {
          ok = uri == 'package:sbn/tool_id.dart';
        } else if (uri.startsWith('package:')) {
          ok = true; // flutter and third-party packages
        } else {
          ok = _resolveRelative(f, uri).contains('/lib/components/kit/');
        }
        if (!ok) violations.add('${_rel(f)} imports $uri');
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('ink_ui files do not import package:saber/pages/', () {
    final violations = <String>[];
    for (final f in inkUiFiles) {
      if (_allowed(f, _inkUiPagesAllow)) continue;
      for (final uri in _imports(f)) {
        final bad = uri.startsWith('package:')
            ? uri.startsWith('package:saber/pages/')
            : !uri.startsWith('dart:') &&
                  _resolveRelative(f, uri).contains('/lib/pages/');
        if (bad) violations.add('${_rel(f)} imports $uri');
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('kit and ink_ui do not use Icons. or Symbols.', () {
    final violations = <String>[];
    for (final f in [...kitFiles, ...inkUiFiles]) {
      final n = _iconUses(f);
      if (n > 0) violations.add('${_rel(f)}: $n use(s)');
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('kit and ink_ui have no Color(0x literals outside kit_tokens.dart', () {
    final violations = <String>[];
    for (final f in [...kitFiles, ...inkUiFiles]) {
      final p = _rel(f);
      if (p.endsWith('lib/components/kit/kit_tokens.dart')) continue;
      if (p.endsWith('.g.dart')) continue;
      final n = _colorLiterals(f.readAsStringSync());
      if (n > 0) violations.add('$p: $n literal(s)');
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  // The kit's screens (final fix wave 2, widened in wave 2 of the final fix):
  // a line as high as its font takes KitTokens.lineHeightOne and a 1 px line
  // a KitTokens width, as the other values come from the tokens.
  test('the kit and ink_ui screens give no height 1 as a number', () {
    final violations = <String>[];
    for (final dir in ['lib/components/kit', 'lib/components/ink_ui']) {
      for (final f in _dartFiles(dir)) {
        for (final (i, line) in f.readAsLinesSync().indexed) {
          if (line.trimLeft().startsWith('//')) continue;
          if (RegExp(r'\bheight:\s*1(?:\.0)?\s*[,)]').hasMatch(line)) {
            violations.add('${_rel(f)}:${i + 1}');
          }
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('colour literal check catches split lines and the from* forms', () {
    expect(_colorLiterals('const a = Color(\n    0xff112233,\n);'), 1);
    expect(_colorLiterals('final b = Color.fromARGB(255, 1, 2, 3);'), 1);
    expect(_colorLiterals('final c = Color.fromRGBO(1, 2, 3, 0.5);'), 1);
    expect(_colorLiterals('final d = Color\n  .fromRGBO(1, 2, 3, 1);'), 1);
    expect(
      _colorLiterals('// Color(0xff000000)\n/// Color.fromARGB(1,2,3,4)'),
      0,
    );
    expect(_colorLiterals('final e = Colors.black;'), 0);
    expect(_colorLiterals('final f = KitTokens.toolbarOnBar;'), 0);
  });

  test('data/settings imports only data/settings from lib', () {
    final files = _dartFiles('lib/data/settings');
    expect(files, isNotEmpty, reason: 'lib/data/settings has no files');
    final violations = <String>[];
    for (final f in files) {
      for (final uri in _imports(f)) {
        final bad = uri.startsWith('package:saber/')
            ? !uri.startsWith('package:saber/data/settings/')
            : !uri.startsWith('package:') &&
                  !uri.startsWith('dart:') &&
                  !_resolveRelative(f, uri).contains('/lib/data/settings/');
        if (bad) violations.add('${_rel(f)} imports $uri');
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test(
    'data/actions imports only data/actions and kit_icons.g.dart from lib',
    () {
      final files = _dartFiles('lib/data/actions');
      expect(files, isNotEmpty, reason: 'lib/data/actions has no files');
      final violations = <String>[];
      for (final f in files) {
        for (final uri in _imports(f)) {
          final bool bad;
          if (uri.startsWith('package:saber/')) {
            bad =
                !uri.startsWith('package:saber/data/actions/') &&
                uri != 'package:saber/components/kit/kit_icons.g.dart';
          } else if (uri.startsWith('package:') || uri.startsWith('dart:')) {
            bad = false;
          } else {
            final path = _resolveRelative(f, uri);
            bad =
                !path.contains('/lib/data/actions/') &&
                !path.endsWith('/lib/components/kit/kit_icons.g.dart');
          }
          if (bad) violations.add('${_rel(f)} imports $uri');
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    },
  );

  test('no keybinder import is left in lib', () {
    final violations = <String>[
      for (final f in _dartFiles('lib'))
        if (!_allowed(f, _keybinderAllow))
          for (final uri in _imports(f))
            if (uri.startsWith('package:keybinder/'))
              '${_rel(f)} imports $uri',
    ];
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('Icons. and Symbols. uses outside kit stay within the allow list', () {
    final violations = <String>[];
    for (final f in _dartFiles('lib')) {
      final p = _rel(f);
      if (p.endsWith('.g.dart')) continue;
      final n = _iconUses(f);
      if (n == 0) continue;
      final allowed = _iconAllow[p];
      if (allowed == null) {
        violations.add('$p: $n use(s), not in the allow list');
      } else if (n > allowed) {
        violations.add('$p: $n use(s), allow list says $allowed');
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
