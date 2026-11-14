# Windows App Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Root alone runs tests, builds and GUI operations. Workers edit only assigned files.

**Goal:** Start the real Windows app with a separate persistent profile so library creation, ink, Office and back navigation can be checked without opening the user's saved vault or credentials.

**Architecture:** Parse `--profile-directory` before `initSentry` first touches eager Stows. A production `PathProviderPlatform` and file-backed `SharedPreferencesStorePlatform` select the explicit directory; the existing DPAPI secure-storage backend remains in use. Default startup keeps its current providers and paths.

**Tech Stack:** Existing Flutter/Dart; locked path_provider_platform_interface 2.1.3, shared_preferences_platform_interface 2.4.2 and shared_preferences 2.5.6. No package-version upgrade or global configuration change.

**Spec:** This document implements the Windows runtime acceptance gate in HANDOFF_KO.md and the user's library/create/back-navigation requirements. It enables acceptance of the complete requested app; it does not redefine Office, Obsidian, Notion, MCP or Android/Drive completion as this profile feature.

## Global Constraints

- The user opted out of further questions. Continue within the existing authorization; no commit, push, publication or canonical build promotion.
- Preserve build66 and older installation candidates. Use a new owned build directory for the changed app.
- A profile is a separate settings namespace, not an OS security sandbox. Never copy existing user preferences, connection files or vault selection into the fresh acceptance profile.
- Windows profile startup changes no Android background task identity. Reject explicit profiles on other OSes until their secure-storage/isolate behavior is implemented.
- Profile bootstrap must not access `stows` before `Stows.markAsOnMainIsolate()` in the existing `initSentry` flow.
- Keep secrets in the current Windows DPAPI backend. Its high-level WindowsOptions default is `useBackwardCompatibility:false`; the earlier broad claim about legacy migration was incorrect.
- `Directory.systemTemp` is independent of path_provider. Set only the acceptance child process's TEMP/TMP to its owned temp folder when running GUI checks.
- Shared preferences must use public platform interfaces, not mock setters, resetStatic, in-memory test stores or @visibleForTesting plugin hooks in production.
- Existing complete-source analysis does not require a redundant REA invocation (REA skill42 explicitly says so). Prior StarNote/Obsidian/Office/HWP artifact investigations remain distinct evidence.

## Review Focus

- Relative/empty/unsupported profile arguments must fail before any saved user settings are read.
- An absent option must leave original providers unchanged.
- Concurrent eager Stow writes must not lose unrelated preferences; failed writes must preserve the last valid file.
- Prefix/allow-list clear must retain unrelated keys and preserve bool/int/double/string/string-list values across reopening.
- Existing profile files can explicitly refer to external vaults; only a fresh owned profile is used for private-data-free acceptance.

## Task 1: Profile parsing and persistent providers

**Files:** Create lib/data/app_profile.dart and test/app_profile_test.dart. Root updates pubspec.yaml/lock with direct declarations for the already locked interfaces and a test declaration for shared_preferences.

**Interfaces:** `AppStartupOptions.parse(List<String>)` returns `verbose` and nullable `Directory profileDirectory`. `Future<void> configureAppProfile(Directory?)` is a no-op for null; otherwise it prepares Windows profile providers before returning. Persistent folders are support, documents, cache, temp and downloads; preferences are support/shared_preferences.json.

- [x] Write behavioral tests for argument rejection, no-op startup, real preference persistence/types, prefix filtering, concurrent writes and failure preservation.
- [x] Root records the missing-feature failure before implementation: missing API, then 3PASS/7FAIL against the minimal behavior stub.
- [x] Implement only the parser, path provider and serialized file-backed preference store. Load/validate before installing either global provider; do not fall back to user settings after failure.
- [x] Root runs the focused tests and checks lock-file versions stayed unchanged: 11PASS/0skip; five direct/development classifications changed, with no version/source/checksum changes.
- [x] Root checks real Windows DPAPI persistence/reopening in two synthetic profiles, with the legacy MethodChannel trapped and the Flutter test target explicitly set to Windows. Locked Windows4.2.2/interface2.1.1 are test-only direct declarations.

## Task 2: Normal app startup and Windows acceptance

**Files:** Root modifies lib/main.dart; uses existing workspace/controller/Drive/MCP paths unchanged.

- [x] Parse options and configure the profile before initSentry; pass parsed verbosity to appRunner.
- [x] Run existing bootstrap, workspace/navigation and full Flutter checks plus analysis appropriate to the startup change: final2103PASS/107skip/0FAIL, analysis2 issues0 after fixing10 original style infos.
- [x] Build the changed Windows app in a new owned source mirror with normal native tasks; preserve build66. Release67 build1 exit0; actual installed DLL/SDK17PASS/0skip.
- [x] Launch only with a new empty owned profile and child-local TEMP/TMP. Real Release67 accepted a Korean/spaced profile argument, created an offline format2 vault and stayed alive8seconds after initialization without fatal logs. Harness termination was used, not graceful UI close.
- [ ] Observe the actual GUI for library, create, edit/save, back and reopen; record real failures rather than inferring GUI success from widgets. Both provided UI runtimes failed before observation with kernel-asset path error3; keep this gate open.
- [ ] Keep Android/S Pen, two physical Drive devices and external LLM client acceptance unverified until actually exercised.
- [x] Update the existing history and handoff with actual evidence and remaining work; add docs/windows-app-profile.md. No additional commits or publication.

## Current evidence and ownership

Previous goal turn made progress: build66 Windows/Android candidates and their actual verification completed. Current starting source scope is runtime701/c3bbdf7c..., tracked-test357/705d31ce..., full-test453/36ef6020.... Before images are in build/validation/windows-profile1.

Two read-only explorers traced current locked plugin APIs and workspace paths. Main-isolate support override covers the workspace, Drive settings/secrets, MCP settings and HWP font cache. Large ink workers receive an explicit documents path. Shared preferences' separate Windows PathProviderWindows requires a separate production backend. These are source observations, not standalone GUI execution evidence.

## Verified result

Root created build/validation/windows-profile1/checkpoint1.json (15731bytes, SHA256 92edce17d3d4a4404255ef75cec3ee20b158dfe1f1c4b4c4bce8b9a07c45ee53). Final runtime702/4ec18670... and both test maps remained identical through final tests, preparation, build and boot. Counts overlap and must not be summed. No new Android APK or Windows ZIP was produced for67; packaged installation pair66 remains current. The complete requested goal remains active and unverified gates above are preserved.
