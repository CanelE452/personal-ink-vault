# Saber source provenance and validation changes

Integrated on 2026-10-22 from [saber-notes/saber](https://github.com/saber-notes/saber),
exact commit [`55eec16ad6f858bc68b7c229e497c5ed44d7c5fd`](https://github.com/saber-notes/saber/tree/55eec16ad6f858bc68b7c229e497c5ed44d7c5fd).
The copied upstream package is version 1.36.3+136030. The Dart package remains named
`saber` to preserve internal import paths. This is an independent Personal Ink Vault
validation build, not an official Saber product.

## Imported source and license

The foundation imports upstream `lib/`, `packages/`, `assets/`, `shaders/`, `test/`,
`patches/`, `scripts/`, `android/`, `windows/`, `pubspec.yaml`, `pubspec.lock`, lint
and localization configuration. Other platform runners, upstream signing secrets,
personal notes and account data were not imported. Original source copyright and
translation credits remain. The root GNU GPL v3 text is retained in `LICENSE.md`.
`packages/sbn/LICENSE.md` is a materialized copy of the upstream root-license
symlink for Windows portability. Asset and resolved dependency notices are in
[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

## Foundation modifications

- Product title: Personal Ink Vault; Android namespace/application ID:
  `io.github.canele452.personalinkvault`; independent clipboard provider authority.
  The old Nextcloud callback scheme is removed.
- Windows executable/CMake project: `personal_ink_vault`; product/company metadata
  and initial window title identify the fork. Original Saber copyright remains.
- Default FileManager root and export album: `PersonalInkVault`. There is no
  automatic import/migration from the sibling `Saber` directory. Fresh Android
  identity and Windows product metadata isolate platform preference storage.
- Android debug uses the standard Android debug signing configuration. Optional
  `android/key.properties` is read only for an explicitly configured release
  signer; missing upstream release secrets do not break debug configuration.
  The fallback signing key is never used. No release signing key is committed.
- `main.dart` no longer starts Nextcloud refresh, background WorkManager sync or
  upstream HTTP overrides. Legacy credential values cannot mark the app logged in;
  upstream client creation returns null. FileManager write/move/delete no longer
  enqueue Nextcloud transfers. The login route redirects home, and the Nextcloud
  settings profile is removed. Unused source is retained for provenance.
- Home automatic update/consent dialogs, settings update controls and insecure
  Nextcloud-connection controls are removed. Update defaults are false.
- The upstream `patches/pre/remove_proprietary_dependencies.sh` was inspected;
  its relevant Onyx/Sentry removals were applied directly for PowerShell portability.
  Onyx canvas/init use and the insecure Onyx/JitPack Maven repositories are gone.
  The FOSS Sentry initializer replaces the network initializer. Sentry runtime,
  logging and symbol-upload dependencies are absent from the resolved graph.
- `patches/pre/remove_permission_handler.sh` was inspected and its Windows-oriented
  dependency/helper changes applied. This removes native permission_handler code.
  Gallery export permissions on Android remain outside the verified scope; PDF
  import and local note storage do not depend on gallery permissions.
- Unused `packages/onyxsdk_pen/**` is excluded from analysis because it is retained
  source without an active application dependency. Its files are not built.
- Image clipboard paste and `super_clipboard` were removed from the validation
  build. Canvas paste explains this limitation and directs users to image import;
  focused text fields keep normal Flutter/Quill paste. File/image import remains.
  This eliminates the Rust clipboard native hook required by the original package.
- The two upstream live Nextcloud integration tests are skipped and their password
  literals removed. They must not call upstream accounts during local test runs.
  Bootstrap tests use only synthetic credentials, temporary directories and local
  state. Upstream golden baselines are not accepted as new-fork UI verification.
- New `ink_vault_core` path dependency and Markdown/math/Google authentication UI
  dependencies were resolved in `pubspec.lock`. Core/workspace implementation is
  described separately in the MVP documents and is not an upstream Saber feature.

## Branding and distribution limits

The inherited launcher/about icons are retained solely for local validation. The
about dialog names the independent validation build. Replace the icons and inspect
all branding before distributing a binary; no use of Saber's trademark is claimed.
The notices inventory records package LICENSE files but is not a complete native
Gradle/Cargo/PDFium dependency audit. unDraw assets have separate restrictions and
their exact historical license provenance remains open. Distribution readiness is
not established by a passing Dart test.

## Actual foundation verification

- Flutter 3.47.7 / Dart 3.13.5; Windows host.
- `flutter --suppress-analytics pub get`: exit 0, including a second resolution after
  removing `super_clipboard`. CLI analytics suppression is per invocation; no global
  Flutter configuration was changed.
- Initial `flutter test test/bootstrap_isolation_test.dart --no-pub` failed before
  Dart test execution because upstream `super_native_extensions` required missing
  `rustup`. After removal, the same command with `--suppress-analytics` exited 0:
  **3 tests passed** (legacy credentials blocked, isolated local mutation with no
  upload enqueue, previous telemetry consent cannot reactivate Sentry).
- Initial root analysis exited 1 with 41 diagnostics: unused Onyx package sources
  could not resolve their removed package, plus core/style lints. The obsolete-source
  exclude and owned Sentry constant lint were corrected. This records the initial
  result; final analysis and platform build results belong in the project validation
  results/history after all workers finish.
- Follow-up scoped analysis of the 8 changed bootstrap source/test files exited 0:
  `No issues found!` (16.0 seconds). This does not substitute for final root analysis.
- Android APK, Windows C++ build, physical S9+ input, actual Drive authorization and
  transfer, PDF round trips, gallery export and release distribution are not claimed
  validated by these bootstrap tests.


## Default tests and explicit upstream suites (2026-10-22)

The original imported suite on this Windows/Flutter toolchain produced 237 passes,
14 skips and 62 failing test cases. These were investigated rather than treated
collectively as missing fixtures: 39 inherited PNG comparisons differed, 12
upstream release screenshots required their original fixtures/plugin setup,
7 checks referenced omitted release/platform fixtures, 2 Home-route tests expected
the replaced welcome/settings UI, and 2 exposed actual FileManager defects.
The Windows watcher now emits virtual relative paths, and SBA import closes its
input stream in `finally`, including invalid archives. Tests immediately delete
both valid and invalid source archives, with no retry workaround.

Default validation is `flutter test --no-pub`. The latest complete run passed
235 tests and explicitly skipped 105: 96 upstream PNG/screenshot cases, 7 upstream
packaging checks, and 2 disabled live Nextcloud integration tests. No PNG baseline
was regenerated or accepted. The PNG discrepancies remain unresolved and are not
claims about the new workspace's visual correctness.

- `flutter test --no-pub --dart-define=UPSTREAM_GOLDENS=true` opts into the retained
  exact inherited PNG assertions, including SBN light/dark/LOD/PDF and upstream
  release screenshots. Ghostscript is still required for PDF raster comparisons;
  the original release metadata/demo fixtures and platform mocks must also be
  supplied for those screenshot cases. The source baseline is the pinned Saber
  revision recorded above, not a regenerated fork baseline.
- `flutter test --no-pub --dart-define=UPSTREAM_PACKAGING=true` opts into omitted
  iOS/macOS localization manifests, metadata spelling/changelogs, Flatpak release
  layout and the upstream version-bump script's packaging checks. Restore the
  appropriate upstream release fixtures before using it. Android localization
  and pure Dart version/model checks remain in the default suite.
- All 13 SBN examples still receive default parsing/page/stroke checks. The SBA
  round-trip still checks parsed content and byte-exact attachment preservation;
  only its inherited pixel comparison is conditional on `UPSTREAM_GOLDENS`.
- Current startup and legacy-route redirects are exercised against the real App
  router. The editor undo/redo interaction test waits for loading to complete,
  then keeps its real draw/undo/redo sequence in the default suite.

Added regressions cover delayed remote reads during local input, completed ink
saves during remote reads, capture/save/reload ordering, overlapping Markdown
saves, debounced local durability, live pen/eraser/selection gestures, delayed PDF
imports with failed-first-save retry and stable page IDs/source bytes, stale
session callbacks, and Windows close failure/retry. PDF transaction tests replace
only the native PDF parser boundary with a controlled one-page document; they do
not establish native PDF rendering or physical tablet behavior. Windows close
waits for normal saves and keeps a visible retry action on failure; forced OS
termination before a save completes is not guaranteed recoverable.
