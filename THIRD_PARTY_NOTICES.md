# Third-party notices

Personal Ink Vault is an independent Android/Windows validation build based on
[Saber](https://github.com/saber-notes/saber), commit
55eec16ad6f858bc68b7c229e497c5ed44d7c5fd.
Saber Copyright (C) 2022 Adil Hanney and contributors. Original copyright,
translation credits and GPL notices are retained. This fork's source is provided
under GNU GPL v3; see [LICENSE.md](LICENSE.md). The local sbn package includes
an actual copy of that license (the upstream Git symlink is materialized for Windows).

## Branding and validation restriction

This is not an official Saber release. Application IDs, executable name and default
storage are independent. Existing upstream launcher/about icons are retained only
for local validation. Do not distribute this build under Saber's name or icon;
replace these assets and review all remaining branding before distributing a binary.

## Bundled non-code assets

- Atkinson Hyperlegible Next: SIL Open Font License 1.1, copyright and full text in
  `assets/google_fonts/Atkinson_Hyperlegible_Next/OFL.txt`.
- Dekko: SIL Open Font License 1.1, `assets/google_fonts/Dekko/OFL.txt`.
- Fira Mono: SIL Open Font License 1.1, `assets/google_fonts/Fira_Mono/OFL.txt`.
- Neucha: SIL Open Font License 1.1, `assets/google_fonts/Neucha/OFL.txt`.
- `assets/images/undraw_*.svg`: inherited unDraw illustrations by Katerina Limpitsouni.
  [unDraw license](https://undraw.co/license), reviewed 2026-10-22: use as application
  illustrations is permitted, while asset-pack/service replication and AI/ML use
  are restricted. Do not treat these assets as GPL-covered code or training data.
  The exact historical license accompanying each upstream asset is not supplied;
  this provenance gap remains a distribution review item.
- `assets/images/nextcloud-logo.svg`: inherited service logo; Nextcloud's trademarks
  remain with their owner. The Nextcloud login UI is disabled in this validation build.
- Other scribble and icon SVG/PNG assets are inherited from the pinned Saber source.
  Their individual authorship is not independently established here; root GPL must
  not be interpreted as a trademark license.

## Dependencies and native components

The resolved package inventory below was produced from .dart_tool/package_config.json
after `flutter pub get` on 2026-10-22. Exact hosted package hashes and Git revisions
are in pubspec.lock. License labels below are text-based identification of the
locally downloaded LICENSE files, not a legal compatibility determination. Flutter
collects package notices into its runtime license registry; final binary notice
contents must be checked on a successful build before distribution.

Native dependencies include Flutter/Dart (BSD-style), PDFium via pdfrx/pdfium_flutter
and printing, platform file/secure-storage plugins and their
native transitive libraries. The `native` marker means platform/rust/build-hook
sources are present in the package, not that every native subdependency was audited.
A complete native-library/Gradle/PDFium notice and asset provenance audit remains open.
No assertion of complete distribution compliance is made by this inventory.

Onyx SDK dependencies and its insecure Maven repository, Sentry runtime/build
upload dependencies, and permission_handler were removed following the pinned
upstream FOSS/Windows patches. Their unused upstream source folders may remain as
provenance and are not application dependencies.

## Resolved Dart/Flutter package inventory

Package | Version | License text identification | Native sources
--- | --- | --- | ---
[abstract_sync](https://pub.dev/packages/abstract_sync/versions/1.3.2/license) | 1.3.2 | MIT |
[android_file_picker](https://pub.dev/packages/android_file_picker/versions/2.1.1/license) | 2.1.1 | MIT | android
[animated_vector](https://pub.dev/packages/animated_vector/versions/0.2.3/license) | 0.2.3 | MIT |
[animated_vector_annotations](https://pub.dev/packages/animated_vector_annotations/versions/0.2.2/license) | 0.2.2 | MIT |
[animations](https://pub.dev/packages/animations/versions/2.2.0/license) | 2.2.0 | BSD-style (see full text) |
[archive](https://pub.dev/packages/archive/versions/4.0.9/license) | 4.0.9 | MIT |
[args](https://pub.dev/packages/args/versions/2.7.0/license) | 2.7.0 | BSD-style (see full text) |
[asn1lib](https://pub.dev/packages/asn1lib/versions/1.6.5/license) | 1.6.5 | BSD-style (see full text) |
[assorted_layout_widgets](https://pub.dev/packages/assorted_layout_widgets/versions/11.0.0/license) | 11.0.0 | BSD-style (see full text) |
[async](https://pub.dev/packages/async/versions/2.13.1/license) | 2.13.1 | BSD-style (see full text) |
[background_downloader](https://pub.dev/packages/background_downloader/versions/9.6.4/license) | 9.6.4 | MIT | android
[barcode](https://pub.dev/packages/barcode/versions/2.2.9/license) | 2.2.9 | Apache-2.0 |
[bidi](https://pub.dev/packages/bidi/versions/2.0.13/license) | 2.0.13 | MIT |
[boolean_selector](https://pub.dev/packages/boolean_selector/versions/2.1.2/license) | 2.1.2 | BSD-style (see full text) |
[bson](https://pub.dev/packages/bson/versions/5.0.8/license) | 5.0.8 | MIT |
[built_collection](https://pub.dev/packages/built_collection/versions/5.1.2/license) | 5.1.2 | BSD-style (see full text) |
[built_value](https://pub.dev/packages/built_value/versions/8.13.0/license) | 8.13.0 | BSD-style (see full text) |
[characters](https://pub.dev/packages/characters/versions/1.4.1/license) | 1.4.1 | BSD-style (see full text) |
[charcode](https://pub.dev/packages/charcode/versions/1.4.0/license) | 1.4.0 | BSD-style (see full text) |
[clock](https://pub.dev/packages/clock/versions/1.1.3/license) | 1.1.3 | Apache-2.0 |
[code_assets](https://pub.dev/packages/code_assets/versions/1.2.1/license) | 1.2.1 | BSD-style (see full text) |
[collapsible](https://pub.dev/packages/collapsible/versions/1.0.0/license) | 1.0.0 | BSD-style (see full text) |
[collection](https://pub.dev/packages/collection/versions/1.19.1/license) | 1.19.1 | BSD-style (see full text) |
[connectivity_plus](https://pub.dev/packages/connectivity_plus/versions/7.3.1/license) | 7.3.1 | BSD-style (see full text) | android, windows
[connectivity_plus_platform_interface](https://pub.dev/packages/connectivity_plus_platform_interface/versions/2.1.0/license) | 2.1.0 | BSD-style (see full text) |
[convert](https://pub.dev/packages/convert/versions/3.1.2/license) | 3.1.2 | BSD-style (see full text) |
[cross_file](https://pub.dev/packages/cross_file/versions/0.3.5+5/license) | 0.3.5+5 | BSD-style (see full text) |
[crypto](https://pub.dev/packages/crypto/versions/3.0.7/license) | 3.0.7 | BSD-style (see full text) |
[crypton](https://pub.dev/packages/crypton/versions/2.2.1/license) | 2.2.1 | MIT |
[csslib](https://pub.dev/packages/csslib/versions/1.0.2/license) | 1.0.2 | BSD-style (see full text) |
[cupertino_icons](https://pub.dev/packages/cupertino_icons/versions/1.0.9/license) | 1.0.9 | MIT |
[dart_quill_delta](https://pub.dev/packages/dart_quill_delta/versions/10.8.3/license) | 10.8.3 | MIT |
[dbus](https://pub.dev/packages/dbus/versions/0.7.15/license) | 0.7.15 | GPL-3.0 (see full text) |
[decimal](https://pub.dev/packages/decimal/versions/3.2.6/license) | 3.2.6 | Apache-2.0 |
[defer_pointer](https://pub.dev/packages/defer_pointer/versions/0.0.2/license) | 0.0.2 | MIT |
[desktop_webview_window](https://pub.dev/packages/desktop_webview_window/versions/0.3.2/license) | 0.3.2 | Apache-2.0 | windows
[device_info_plus](https://pub.dev/packages/device_info_plus/versions/13.3.0/license) | 13.3.0 | BSD-style (see full text) | android
[device_info_plus_platform_interface](https://pub.dev/packages/device_info_plus_platform_interface/versions/8.1.0/license) | 8.1.0 | BSD-style (see full text) |
[diff_match_patch](https://pub.dev/packages/diff_match_patch/versions/0.4.1/license) | 0.4.1 | Apache-2.0 |
[dynamic_color](https://pub.dev/packages/dynamic_color/versions/1.9.0/license) | 1.9.0 | Apache-2.0 | android, windows
[dynamic_yaru](https://pub.dev/packages/dynamic_yaru/versions/0.2.0/license) | 0.2.0 | MIT |
[dynamite_runtime](https://pub.dev/packages/dynamite_runtime/versions/0.6.0/license) | 0.6.0 | BSD-style (see full text) |
[encrypt](https://pub.dev/packages/encrypt/versions/5.0.3/license) | 5.0.3 | BSD-style (see full text) |
[equatable](https://pub.dev/packages/equatable/versions/2.1.0/license) | 2.1.0 | MIT |
[fake_async](https://pub.dev/packages/fake_async/versions/1.3.3/license) | 1.3.3 | Apache-2.0 |
[ffi](https://pub.dev/packages/ffi/versions/2.2.0/license) | 2.2.0 | BSD-style (see full text) |
[ffi_leak_tracker](https://pub.dev/packages/ffi_leak_tracker/versions/0.1.2/license) | 0.1.2 | BSD-style (see full text) |
[file](https://pub.dev/packages/file/versions/7.0.1/license) | 7.0.1 | BSD-style (see full text) |
[file_picker](https://pub.dev/packages/file_picker/versions/13.1.0/license) | 13.1.0 | MIT |
[file_picker_darwin](https://pub.dev/packages/file_picker_darwin/versions/2.3.2/license) | 2.3.2 | MIT |
[file_picker_linux](https://pub.dev/packages/file_picker_linux/versions/2.0.0/license) | 2.0.0 | MIT |
[file_picker_platform_interface](https://pub.dev/packages/file_picker_platform_interface/versions/4.2.0/license) | 4.2.0 | MIT |
[file_picker_web](https://pub.dev/packages/file_picker_web/versions/4.2.0/license) | 4.2.0 | MIT |
[file_selector_linux](https://pub.dev/packages/file_selector_linux/versions/0.9.4+1/license) | 0.9.4+1 | BSD-style (see full text) |
[file_selector_platform_interface](https://pub.dev/packages/file_selector_platform_interface/versions/2.7.0/license) | 2.7.0 | BSD-style (see full text) |
[file_selector_windows](https://pub.dev/packages/file_selector_windows/versions/0.9.3+6/license) | 0.9.3+6 | BSD-style (see full text) | windows
[fixnum](https://pub.dev/packages/fixnum/versions/1.1.1/license) | 1.1.1 | BSD-style (see full text) |
[flex_color_picker](https://pub.dev/packages/flex_color_picker/versions/3.8.0/license) | 3.8.0 | BSD-style (see full text) |
[flex_seed_scheme](https://pub.dev/packages/flex_seed_scheme/versions/4.0.1/license) | 4.0.1 | BSD-style (see full text) |
[flutter](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/LICENSE) | SDK | BSD-style (see full text) |
[flutter_colorpicker](https://pub.dev/packages/flutter_colorpicker/versions/1.1.0/license) | 1.1.0 | MIT |
[flutter_driver](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/LICENSE) | SDK | UNREVIEWED / missing |
[flutter_hooks](https://pub.dev/packages/flutter_hooks/versions/0.21.3+1/license) | 0.21.3+1 | MIT |
[flutter_keyboard_visibility_linux](https://pub.dev/packages/flutter_keyboard_visibility_linux/versions/1.0.0/license) | 1.0.0 | MIT |
[flutter_keyboard_visibility_macos](https://pub.dev/packages/flutter_keyboard_visibility_macos/versions/1.0.0/license) | 1.0.0 | MIT |
[flutter_keyboard_visibility_platform_interface](https://pub.dev/packages/flutter_keyboard_visibility_platform_interface/versions/2.0.0/license) | 2.0.0 | MIT |
[flutter_keyboard_visibility_temp_fork](https://pub.dev/packages/flutter_keyboard_visibility_temp_fork/versions/0.1.5/license) | 0.1.5 | MIT | android
[flutter_keyboard_visibility_windows](https://pub.dev/packages/flutter_keyboard_visibility_windows/versions/1.0.0/license) | 1.0.0 | MIT |
[flutter_lints](https://pub.dev/packages/flutter_lints/versions/6.0.0/license) | 6.0.0 | BSD-style (see full text) |
[flutter_localizations](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/LICENSE) | SDK | UNREVIEWED / missing |
[flutter_markdown_plus](https://pub.dev/packages/flutter_markdown_plus/versions/1.0.12/license) | 1.0.12 | BSD-style (see full text) |
[flutter_math_fork](https://pub.dev/packages/flutter_math_fork/versions/0.7.4/license) | 0.7.4 | Apache-2.0 |
[flutter_quill](https://pub.dev/packages/flutter_quill/versions/11.6.0/license) | 11.6.0 | MIT |
[flutter_quill_delta_from_html](https://pub.dev/packages/flutter_quill_delta_from_html/versions/1.5.3/license) | 1.5.3 | MIT |
[flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage/versions/11.2.0/license) | 11.2.0 | BSD-style (see full text) | android
[flutter_secure_storage_darwin](https://pub.dev/packages/flutter_secure_storage_darwin/versions/0.4.3/license) | 0.4.3 | BSD-style (see full text) |
[flutter_secure_storage_linux](https://pub.dev/packages/flutter_secure_storage_linux/versions/3.0.3/license) | 3.0.3 | BSD-style (see full text) |
[flutter_secure_storage_platform_interface](https://pub.dev/packages/flutter_secure_storage_platform_interface/versions/2.1.1/license) | 2.1.1 | BSD-style (see full text) |
[flutter_secure_storage_web](https://pub.dev/packages/flutter_secure_storage_web/versions/2.1.1/license) | 2.1.1 | BSD-style (see full text) |
[flutter_secure_storage_windows](https://pub.dev/packages/flutter_secure_storage_windows/versions/4.2.2/license) | 4.2.2 | BSD-style (see full text) | windows
[flutter_sharing_intent](https://pub.dev/packages/flutter_sharing_intent/versions/2.0.4/license) | 2.0.4 | Apache-2.0 | android
[flutter_speed_dial](https://pub.dev/packages/flutter_speed_dial/versions/7.0.0/license) | 7.0.0 | MIT |
[flutter_staggered_grid_view](https://pub.dev/packages/flutter_staggered_grid_view/versions/0.7.0/license) | 0.7.0 | MIT |
[flutter_svg](https://pub.dev/packages/flutter_svg/versions/2.3.0/license) | 2.3.0 | MIT |
[flutter_test](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/LICENSE) | SDK | UNREVIEWED / missing |
[flutter_web_auth_2](https://pub.dev/packages/flutter_web_auth_2/versions/5.1.0/license) | 5.1.0 | MIT | android
[flutter_web_auth_2_platform_interface](https://pub.dev/packages/flutter_web_auth_2_platform_interface/versions/5.0.0/license) | 5.0.0 | MIT |
[flutter_web_plugins](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/LICENSE) | SDK | UNREVIEWED / missing |
[font_awesome_flutter](https://pub.dev/packages/font_awesome_flutter/versions/11.0.0/license) | 11.0.0 | MIT |
[fuchsia_remote_debug_protocol](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/LICENSE) | SDK | UNREVIEWED / missing |
[go_router](https://pub.dev/packages/go_router/versions/17.5.0/license) | 17.5.0 | BSD-style (see full text) |
[golden_screenshot](https://pub.dev/packages/golden_screenshot/versions/11.1.1/license) | 11.1.1 | MIT |
[google_identity_services_web](https://pub.dev/packages/google_identity_services_web/versions/0.3.3+1/license) | 0.3.3+1 | BSD-style (see full text) |
[google_sign_in](https://pub.dev/packages/google_sign_in/versions/7.2.0/license) | 7.2.0 | BSD-style (see full text) |
[google_sign_in_android](https://pub.dev/packages/google_sign_in_android/versions/7.2.18/license) | 7.2.18 | BSD-style (see full text) | android
[google_sign_in_ios](https://pub.dev/packages/google_sign_in_ios/versions/6.3.8/license) | 6.3.8 | BSD-style (see full text) |
[google_sign_in_platform_interface](https://pub.dev/packages/google_sign_in_platform_interface/versions/3.1.0/license) | 3.1.0 | BSD-style (see full text) |
[google_sign_in_web](https://pub.dev/packages/google_sign_in_web/versions/1.1.3/license) | 1.1.3 | BSD-style (see full text) |
[gsettings](https://pub.dev/packages/gsettings/versions/0.2.8/license) | 0.2.8 | GPL-3.0 (see full text) |
[gtk](https://pub.dev/packages/gtk/versions/2.2.0/license) | 2.2.0 | GPL-3.0 (see full text) |
[hooks](https://pub.dev/packages/hooks/versions/2.2.0/license) | 2.2.0 | BSD-style (see full text) |
[html](https://pub.dev/packages/html/versions/0.15.7/license) | 0.15.7 | MIT |
[http](https://pub.dev/packages/http/versions/1.6.0/license) | 1.6.0 | BSD-style (see full text) |
[http_parser](https://pub.dev/packages/http_parser/versions/4.1.2/license) | 4.1.2 | BSD-style (see full text) |
[icons_launcher](https://pub.dev/packages/icons_launcher/versions/3.1.0/license) | 3.1.0 | MIT |
[image](https://pub.dev/packages/image/versions/4.10.2/license) | 4.10.2 | MIT |
[ini](https://pub.dev/packages/ini/versions/2.1.0/license) | 2.1.0 | UNREVIEWED / custom |
[ink_vault_core](packages/ink_vault_core/LICENSE) | 0.1.0 | GPL-3.0 (see full text) |
[integration_test](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/LICENSE) | SDK | UNREVIEWED / missing | android
[intl](https://pub.dev/packages/intl/versions/0.20.3/license) | 0.20.3 | BSD-style (see full text) |
[is_ios_simulator](https://pub.dev/packages/is_ios_simulator/versions/1.0.1/license) | 1.0.1 | MIT |
[js](https://pub.dev/packages/js/versions/0.7.2/license) | 0.7.2 | BSD-style (see full text) |
[json_annotation](https://pub.dev/packages/json_annotation/versions/4.12.0/license) | 4.12.0 | BSD-style (see full text) |
[keybinder](https://pub.dev/packages/keybinder/versions/1.0.1/license) | 1.0.1 | BSD-style (see full text) |
[leak_tracker](https://pub.dev/packages/leak_tracker/versions/11.0.2/license) | 11.0.2 | BSD-style (see full text) |
[leak_tracker_flutter_testing](https://pub.dev/packages/leak_tracker_flutter_testing/versions/3.0.10/license) | 3.0.10 | BSD-style (see full text) |
[leak_tracker_testing](https://pub.dev/packages/leak_tracker_testing/versions/3.0.2/license) | 3.0.2 | BSD-style (see full text) |
[lints](https://pub.dev/packages/lints/versions/6.1.0/license) | 6.1.0 | BSD-style (see full text) |
[list_utilities](https://pub.dev/packages/list_utilities/versions/1.0.3/license) | 1.0.3 | BSD-style (see full text) |
[logging](https://pub.dev/packages/logging/versions/1.3.0/license) | 1.3.0 | BSD-style (see full text) |
[markdown](https://pub.dev/packages/markdown/versions/7.3.1/license) | 7.3.1 | BSD-style (see full text) |
[matcher](https://pub.dev/packages/matcher/versions/0.12.20/license) | 0.12.20 | BSD-style (see full text) |
[material_color_utilities](https://pub.dev/packages/material_color_utilities/versions/0.13.0/license) | 0.13.0 | Apache-2.0 |
[material_symbols_icons](https://pub.dev/packages/material_symbols_icons/versions/4.2960.0/license) | 4.2960.0 | Apache-2.0 |
[matrix4_transform](https://pub.dev/packages/matrix4_transform/versions/4.0.1/license) | 4.0.1 | BSD-style (see full text) |
[meta](https://pub.dev/packages/meta/versions/1.19.0/license) | 1.19.0 | BSD-style (see full text) |
[mime](https://pub.dev/packages/mime/versions/2.1.0/license) | 2.1.0 | BSD-style (see full text) |
[mutex](https://pub.dev/packages/mutex/versions/3.1.0/license) | 3.1.0 | BSD-style (see full text) |
[native_toolchain_rust](https://pub.dev/packages/native_toolchain_rust/versions/1.0.4+0/license) | 1.0.4+0 | MIT |
[nested](https://pub.dev/packages/nested/versions/1.0.0/license) | 1.0.0 | MIT |
[nextcloud](https://pub.dev/packages/nextcloud/versions/9.0.0/license) | 9.0.0 | GPL-3.0 (see full text) |
[nm](https://pub.dev/packages/nm/versions/0.5.0/license) | 0.5.0 | GPL-3.0 (see full text) |
[objective_c](https://pub.dev/packages/objective_c/versions/9.5.0/license) | 9.5.0 | BSD-style (see full text) | hook
[one_dollar_unistroke_recognizer](https://pub.dev/packages/one_dollar_unistroke_recognizer/versions/1.3.5/license) | 1.3.5 | BSD-style (see full text) |
[open_file](https://pub.dev/packages/open_file/versions/4.0.0/license) | 4.0.0 | BSD-style (see full text) |
[open_file_android](https://pub.dev/packages/open_file_android/versions/1.1.0/license) | 1.1.0 | BSD-style (see full text) | android
[open_file_ios](https://pub.dev/packages/open_file_ios/versions/1.1.0/license) | 1.1.0 | BSD-style (see full text) |
[open_file_linux](https://pub.dev/packages/open_file_linux/versions/1.1.0/license) | 1.1.0 | BSD-style (see full text) |
[open_file_mac](https://pub.dev/packages/open_file_mac/versions/1.1.0/license) | 1.1.0 | BSD-style (see full text) |
[open_file_platform_interface](https://pub.dev/packages/open_file_platform_interface/versions/1.1.0/license) | 1.1.0 | BSD-style (see full text) |
[open_file_web](https://pub.dev/packages/open_file_web/versions/1.1.0/license) | 1.1.0 | BSD-style (see full text) |
[open_file_windows](https://pub.dev/packages/open_file_windows/versions/1.1.0/license) | 1.1.0 | BSD-style (see full text) |
[packages_extensions](https://pub.dev/packages/packages_extensions/versions/0.1.2/license) | 0.1.2 | MIT |
[path](https://pub.dev/packages/path/versions/1.9.1/license) | 1.9.1 | BSD-style (see full text) |
[path_drawing](https://pub.dev/packages/path_drawing/versions/1.0.1/license) | 1.0.1 | MIT |
[path_parsing](https://pub.dev/packages/path_parsing/versions/1.1.0/license) | 1.1.0 | MIT |
[path_provider](https://pub.dev/packages/path_provider/versions/2.1.6/license) | 2.1.6 | BSD-style (see full text) |
[path_provider_android](https://pub.dev/packages/path_provider_android/versions/2.2.23/license) | 2.2.23 | BSD-style (see full text) | android
[path_provider_foundation](https://pub.dev/packages/path_provider_foundation/versions/2.6.0/license) | 2.6.0 | BSD-style (see full text) |
[path_provider_linux](https://pub.dev/packages/path_provider_linux/versions/2.2.2/license) | 2.2.2 | BSD-style (see full text) |
[path_provider_platform_interface](https://pub.dev/packages/path_provider_platform_interface/versions/2.1.3/license) | 2.1.3 | BSD-style (see full text) |
[path_provider_windows](https://pub.dev/packages/path_provider_windows/versions/2.3.0/license) | 2.3.0 | BSD-style (see full text) |
[path_to_regexp](https://pub.dev/packages/path_to_regexp/versions/0.4.0/license) | 0.4.0 | MIT |
[pdf](https://pub.dev/packages/pdf/versions/3.12.0/license) | 3.12.0 | Apache-2.0 |
[pdf_widget_wrapper](https://pub.dev/packages/pdf_widget_wrapper/versions/1.0.4/license) | 1.0.4 | Apache-2.0 |
[pdfium_dart](https://pub.dev/packages/pdfium_dart/versions/0.2.5/license) | 0.2.5 | MIT | hook
[pdfium_flutter](https://pub.dev/packages/pdfium_flutter/versions/0.2.3/license) | 0.2.3 | MIT | android, hook
[pdfrx](https://pub.dev/packages/pdfrx/versions/2.4.8/license) | 2.4.8 | MIT |
[pdfrx_engine](https://pub.dev/packages/pdfrx_engine/versions/0.4.7/license) | 0.4.7 | MIT |
[perfect_freehand](https://pub.dev/packages/perfect_freehand/versions/2.5.2+1/license) | 2.5.2+1 | MIT |
[petitparser](https://pub.dev/packages/petitparser/versions/7.1.0/license) | 7.1.0 | MIT |
[platform](https://pub.dev/packages/platform/versions/3.2.0/license) | 3.2.0 | BSD-style (see full text) |
[platform_linux](https://pub.dev/packages/platform_linux/versions/0.1.2+1/license) | 0.1.2+1 | GPL-3.0 (see full text) |
[plugin_platform_interface](https://pub.dev/packages/plugin_platform_interface/versions/2.1.8/license) | 2.1.8 | BSD-style (see full text) |
[pointycastle](https://pub.dev/packages/pointycastle/versions/3.9.1/license) | 3.9.1 | MIT |
[pool](https://pub.dev/packages/pool/versions/1.5.3/license) | 1.5.3 | BSD-style (see full text) |
[posix](https://pub.dev/packages/posix/versions/6.5.2/license) | 6.5.2 | MIT |
[power_extensions](https://pub.dev/packages/power_extensions/versions/0.2.4/license) | 0.2.4 | MIT |
[printing](https://pub.dev/packages/printing/versions/5.14.3/license) | 5.14.3 | Apache-2.0 | android, windows
[process](https://pub.dev/packages/process/versions/5.0.6/license) | 5.0.6 | BSD-style (see full text) |
[provider](https://pub.dev/packages/provider/versions/6.1.5+1/license) | 6.1.5+1 | MIT |
[pub_semver](https://pub.dev/packages/pub_semver/versions/2.2.1/license) | 2.2.1 | BSD-style (see full text) |
[qr](https://pub.dev/packages/qr/versions/3.0.2/license) | 3.0.2 | BSD-style (see full text) |
[quill_native_bridge](https://pub.dev/packages/quill_native_bridge/versions/11.2.0/license) | 11.2.0 | MIT |
[quill_native_bridge_android](https://pub.dev/packages/quill_native_bridge_android/versions/0.0.2/license) | 0.0.2 | MIT | android
[quill_native_bridge_ios](https://pub.dev/packages/quill_native_bridge_ios/versions/0.0.3/license) | 0.0.3 | MIT |
[quill_native_bridge_linux](https://pub.dev/packages/quill_native_bridge_linux/versions/0.0.3/license) | 0.0.3 | MIT |
[quill_native_bridge_macos](https://pub.dev/packages/quill_native_bridge_macos/versions/0.0.1/license) | 0.0.1 | MIT |
[quill_native_bridge_platform_interface](https://pub.dev/packages/quill_native_bridge_platform_interface/versions/0.0.2+1/license) | 0.0.2+1 | MIT |
[quill_native_bridge_web](https://pub.dev/packages/quill_native_bridge_web/versions/0.0.2/license) | 0.0.2 | MIT |
[quill_native_bridge_windows](https://pub.dev/packages/quill_native_bridge_windows/versions/0.1.1/license) | 0.1.1 | MIT |
[quiver](https://pub.dev/packages/quiver/versions/3.2.2/license) | 3.2.2 | Apache-2.0 |
[rational](https://pub.dev/packages/rational/versions/2.2.3/license) | 2.2.3 | Apache-2.0 |
[record_use](https://pub.dev/packages/record_use/versions/1.1.1/license) | 1.1.1 | BSD-style (see full text) |
[regexed_validator](https://pub.dev/packages/regexed_validator/versions/2.0.0+1/license) | 2.0.0+1 | MIT |
[rxdart](https://pub.dev/packages/rxdart/versions/0.28.0/license) | 0.28.0 | Apache-2.0 |
[saver_gallery](https://pub.dev/packages/saver_gallery/versions/5.1.0/license) | 5.1.0 | MIT | android
[sbn](packages/sbn/LICENSE.md) | 0.0.1 | GPL-3.0 (see full text) |
[screen_retriever](https://pub.dev/packages/screen_retriever/versions/0.2.2/license) | 0.2.2 | MIT |
[screen_retriever_linux](https://pub.dev/packages/screen_retriever_linux/versions/0.2.2/license) | 0.2.2 | MIT |
[screen_retriever_macos](https://pub.dev/packages/screen_retriever_macos/versions/0.2.2/license) | 0.2.2 | MIT |
[screen_retriever_platform_interface](https://pub.dev/packages/screen_retriever_platform_interface/versions/0.2.2/license) | 0.2.2 | MIT |
[screen_retriever_windows](https://pub.dev/packages/screen_retriever_windows/versions/0.2.2/license) | 0.2.2 | MIT | windows
[screenshot](https://pub.dev/packages/screenshot/versions/3.0.0/license) | 3.0.0 | MIT |
[serial_csv](https://pub.dev/packages/serial_csv/versions/0.5.2/license) | 0.5.2 | MIT |
[share_plus](https://pub.dev/packages/share_plus/versions/13.3.1/license) | 13.3.1 | BSD-style (see full text) | android, windows
[share_plus_platform_interface](https://pub.dev/packages/share_plus_platform_interface/versions/7.2.0/license) | 7.2.0 | BSD-style (see full text) |
[shared_preferences](https://pub.dev/packages/shared_preferences/versions/2.5.6/license) | 2.5.6 | BSD-style (see full text) |
[shared_preferences_android](https://pub.dev/packages/shared_preferences_android/versions/2.4.28/license) | 2.4.28 | BSD-style (see full text) | android
[shared_preferences_foundation](https://pub.dev/packages/shared_preferences_foundation/versions/2.5.7/license) | 2.5.7 | BSD-style (see full text) |
[shared_preferences_linux](https://pub.dev/packages/shared_preferences_linux/versions/2.4.1/license) | 2.4.1 | BSD-style (see full text) |
[shared_preferences_platform_interface](https://pub.dev/packages/shared_preferences_platform_interface/versions/2.4.2/license) | 2.4.2 | BSD-style (see full text) |
[shared_preferences_web](https://pub.dev/packages/shared_preferences_web/versions/2.4.3/license) | 2.4.3 | BSD-style (see full text) |
[shared_preferences_windows](https://pub.dev/packages/shared_preferences_windows/versions/2.4.1/license) | 2.4.1 | BSD-style (see full text) |
[sky_engine](https://github.com/flutter/flutter/blob/abaf9c523780a608bd46686fd5e53740a07077f8/LICENSE) | SDK | MIT |
[slang](https://pub.dev/packages/slang/versions/4.19.2/license) | 4.19.2 | MIT |
[slang_flutter](https://pub.dev/packages/slang_flutter/versions/4.19.0/license) | 4.19.0 | MIT |
[source_span](https://pub.dev/packages/source_span/versions/1.10.2/license) | 1.10.2 | BSD-style (see full text) |
[stack_trace](https://pub.dev/packages/stack_trace/versions/1.12.2/license) | 1.12.2 | BSD-style (see full text) |
[stow](https://pub.dev/packages/stow/versions/0.6.0/license) | 0.6.0 | MIT |
[stow_codecs](https://pub.dev/packages/stow_codecs/versions/1.4.0/license) | 1.4.0 | MIT |
[stow_plain](https://pub.dev/packages/stow_plain/versions/0.6.0/license) | 0.6.0 | MIT |
[stow_secure](https://pub.dev/packages/stow_secure/versions/0.7.0/license) | 0.7.0 | MIT |
[stream_channel](https://pub.dev/packages/stream_channel/versions/2.1.4/license) | 2.1.4 | BSD-style (see full text) |
[string_scanner](https://pub.dev/packages/string_scanner/versions/1.4.1/license) | 1.4.1 | BSD-style (see full text) |
[sync_http](https://pub.dev/packages/sync_http/versions/0.3.1/license) | 0.3.1 | BSD-style (see full text) |
[synchronized](https://pub.dev/packages/synchronized/versions/3.5.0/license) | 3.5.0 | MIT |
[term_glyph](https://pub.dev/packages/term_glyph/versions/1.2.2/license) | 1.2.2 | BSD-style (see full text) |
[test_api](https://pub.dev/packages/test_api/versions/0.7.12/license) | 0.7.12 | BSD-style (see full text) |
[timezone](https://pub.dev/packages/timezone/versions/0.10.1/license) | 0.10.1 | BSD-style (see full text) |
[toml](https://pub.dev/packages/toml/versions/0.18.0/license) | 0.18.0 | MIT |
[tuple](https://pub.dev/packages/tuple/versions/2.0.2/license) | 2.0.2 | BSD-style (see full text) |
[typed_data](https://pub.dev/packages/typed_data/versions/1.4.0/license) | 1.4.0 | BSD-style (see full text) |
[universal_io](https://pub.dev/packages/universal_io/versions/2.3.1/license) | 2.3.1 | Apache-2.0 |
[uri](https://pub.dev/packages/uri/versions/1.0.0/license) | 1.0.0 | BSD-style (see full text) |
[url_launcher](https://pub.dev/packages/url_launcher/versions/6.3.3/license) | 6.3.3 | BSD-style (see full text) |
[url_launcher_android](https://pub.dev/packages/url_launcher_android/versions/6.3.33/license) | 6.3.33 | BSD-style (see full text) | android
[url_launcher_ios](https://pub.dev/packages/url_launcher_ios/versions/6.4.2/license) | 6.4.2 | BSD-style (see full text) |
[url_launcher_linux](https://pub.dev/packages/url_launcher_linux/versions/3.2.3/license) | 3.2.3 | BSD-style (see full text) |
[url_launcher_macos](https://pub.dev/packages/url_launcher_macos/versions/3.2.6/license) | 3.2.6 | BSD-style (see full text) |
[url_launcher_platform_interface](https://pub.dev/packages/url_launcher_platform_interface/versions/2.3.2/license) | 2.3.2 | BSD-style (see full text) |
[url_launcher_web](https://pub.dev/packages/url_launcher_web/versions/2.4.3/license) | 2.4.3 | BSD-style (see full text) |
[url_launcher_windows](https://pub.dev/packages/url_launcher_windows/versions/3.1.6/license) | 3.1.6 | BSD-style (see full text) | windows
[uuid](https://pub.dev/packages/uuid/versions/4.6.0/license) | 4.6.0 | MIT |
[vector_graphics](https://pub.dev/packages/vector_graphics/versions/1.2.3/license) | 1.2.3 | BSD-style (see full text) |
[vector_graphics_codec](https://pub.dev/packages/vector_graphics_codec/versions/1.1.13/license) | 1.1.13 | BSD-style (see full text) |
[vector_graphics_compiler](https://pub.dev/packages/vector_graphics_compiler/versions/1.3.2/license) | 1.3.2 | BSD-style (see full text) |
[vector_math](https://pub.dev/packages/vector_math/versions/2.4.3/license) | 2.4.3 | BSD-style (see full text) |
[version](https://pub.dev/packages/version/versions/3.0.2/license) | 3.0.2 | BSD-style (see full text) |
[vm_service](https://pub.dev/packages/vm_service/versions/15.4.0/license) | 15.4.0 | BSD-style (see full text) |
[watcher](https://pub.dev/packages/watcher/versions/1.2.1/license) | 1.2.1 | BSD-style (see full text) |
[web](https://pub.dev/packages/web/versions/1.1.1/license) | 1.1.1 | BSD-style (see full text) |
[webdriver](https://pub.dev/packages/webdriver/versions/3.2.0/license) | 3.2.0 | Apache-2.0 |
[win32](https://pub.dev/packages/win32/versions/6.4.0/license) | 6.4.0 | BSD-style (see full text) |
[win32_registry](https://pub.dev/packages/win32_registry/versions/3.0.3/license) | 3.0.3 | BSD-style (see full text) |
[window_manager](https://pub.dev/packages/window_manager/versions/0.5.2/license) | 0.5.2 | MIT | windows
[window_to_front](https://pub.dev/packages/window_to_front/versions/0.0.4/license) | 0.0.4 | MIT | windows
[windows_file_picker](https://pub.dev/packages/windows_file_picker/versions/2.0.1/license) | 2.0.1 | MIT |
[worker_manager](https://pub.dev/packages/worker_manager/versions/7.2.9/license) | 7.2.9 | MIT |
[workmanager](https://pub.dev/packages/workmanager/versions/0.10.10/license) | 0.10.10 | MIT |
[workmanager_android](https://pub.dev/packages/workmanager_android/versions/0.10.9/license) | 0.10.9 | MIT | android
[workmanager_apple](https://pub.dev/packages/workmanager_apple/versions/0.9.11/license) | 0.9.11 | MIT |
[workmanager_linux](https://pub.dev/packages/workmanager_linux/versions/0.1.1+1/license) | 0.1.1+1 | MIT |
[workmanager_platform_interface](https://pub.dev/packages/workmanager_platform_interface/versions/0.10.5/license) | 0.10.5 | MIT |
[workmanager_web](https://pub.dev/packages/workmanager_web/versions/0.2.0/license) | 0.2.0 | MIT |
[xdg_directories](https://pub.dev/packages/xdg_directories/versions/1.1.0/license) | 1.1.0 | BSD-style (see full text) |
[xml](https://pub.dev/packages/xml/versions/6.6.1/license) | 6.6.1 | MIT |
[xml_annotation](https://pub.dev/packages/xml_annotation/versions/2.4.0/license) | 2.4.0 | MIT |
[yaml](https://pub.dev/packages/yaml/versions/3.1.4/license) | 3.1.4 | MIT |
[yaru](https://pub.dev/packages/yaru/versions/10.2.0/license) | 10.2.0 | GPL-3.0 (see full text) |
[yaru_window](https://pub.dev/packages/yaru_window/versions/0.2.2/license) | 0.2.2 | GPL-3.0 (see full text) |
[yaru_window_linux](https://pub.dev/packages/yaru_window_linux/versions/0.2.2/license) | 0.2.2 | GPL-3.0 (see full text) |
[yaru_window_manager](https://pub.dev/packages/yaru_window_manager/versions/0.1.3/license) | 0.1.3 | GPL-3.0 (see full text) |
[yaru_window_platform_interface](https://pub.dev/packages/yaru_window_platform_interface/versions/0.1.3/license) | 0.1.3 | GPL-3.0 (see full text) |
[yaru_window_web](https://pub.dev/packages/yaru_window_web/versions/0.0.4/license) | 0.0.4 | GPL-3.0 (see full text) |
