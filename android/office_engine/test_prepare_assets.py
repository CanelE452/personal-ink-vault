"""Exercise APK asset preparation with real ZIPs and private temporary caches.

The two legacy ART profiles are read from the pinned local APK; no network,
Gradle process, Android runtime, or real generated cache is modified here.
"""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

import prepare_engine


PROFILES = {
    "assets/dexopt/baseline.prof": (
        2228, "fbd771b3c546c376f058689a01d1abfc6d1714dd357c498532e07c69311ce74b"),
    "assets/dexopt/baseline.profm": (
        265, "78b2be62be615dc9477c939371fc5c5a7d6013738e8b7e3fcec0b72a6ec47ed5"),
}
ENGINE_ASSETS = {
    "assets/dist/cool.html": b"<html>engine</html>",
    "assets/dist/images/baseline-edit.svg": b"<svg>keep the UI icon</svg>",
    "assets/dist/images/baseline-edit-24px.svg": b"<svg>keep this icon too</svg>",
    "assets/program/services.rdb": b"engine service registry",
    "assets/share/fonts/truetype/LiberationSans-Regular.ttf": b"engine font",
    "assets/templates/default.ott": b"engine document template",
    "assets/unpack/program/fundamentalrc": b"engine unpack configuration",
    "assets/license.html": b"engine component license",
    "assets/notice.txt": b"engine notices",
    "assets/dexoptimization/engine-data.bin": b"exact namespace only",
}
FONTS_CONFIG = "assets/unpack/etc/fonts/fonts.conf"
APK_METADATA = {
    "META-INF/MANIFEST.MF": b"APK signature metadata",
    "META-INF/com/android/build/gradle/app-metadata.properties": b"APK app metadata",
    "AndroidManifest.xml": b"APK manifest",
    "resources.arsc": b"APK resource table",
    "classes.dex": b"foreign application DEX",
    "DebugProbesKt.bin": b"foreign application Kotlin metadata",
    "r8-version.properties": b"foreign application R8 metadata",
    "res/drawable/app_icon.xml": b"foreign application resources",
}


def files(directory):
    return {
        path.relative_to(directory).as_posix(): path.read_bytes()
        for path in directory.rglob("*") if path.is_file()
    }


class PrepareAssetsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # The current producer and its existing lifecycle tests already require
        # this pinned cache. Only these small immutable entries become fixtures.
        apk = prepare_engine.ROOT / "cache/collabora-arm64.apk"
        with zipfile.ZipFile(apk) as archive:
            cls.profiles = {name: archive.read(name) for name in PROFILES}

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="office-apk-assets-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.module = self.directory / "module"
        self.module.mkdir()
        self.root = self.directory / "build"
        self.generated = self.root / "generated"
        self.source_license = b"pinned upstream source license\n"
        source = self.root / "cache/source/COPYING"
        source.parent.mkdir(parents=True)
        source.write_bytes(self.source_license)
        self.apk = self.root / "cache/collabora-arm64.apk"
        self.entries = {
            **ENGINE_ASSETS,
            **APK_METADATA,
            **self.profiles,
            # Even newly encountered files in this application metadata
            # namespace must never be imported into the engine library.
            "assets/dexopt/future-app-only.bin": b"other APK dexopt metadata",
            FONTS_CONFIG: b"/data/data/com.collabora.libreoffice/fontconfig",
            "lib/arm64-v8a/libc++_shared.so": b"pinned shared C++ runtime",
            "lib/arm64-v8a/liblo-native-code.so": b"pinned native engine",
        }
        with zipfile.ZipFile(self.apk, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, data in self.entries.items():
                archive.writestr(name, data)
        apk_bytes = self.apk.read_bytes()
        self.lock = {
            "engine": "Synthetic pinned Office engine",
            "version": "fixture-1",
            "sourceRevision": "fixture-source",
            "sourceBaseUrl": "https://network-must-not-be-used.invalid/",
            "apk": {
                "url": "https://network-must-not-be-used.invalid/office.apk",
                "sha256": hashlib.sha256(apk_bytes).hexdigest(),
                "bytes": len(apk_bytes),
                "maximumBytes": len(apk_bytes),
            },
            "sources": [{
                "path": "COPYING",
                "sha256": hashlib.sha256(self.source_license).hexdigest(),
                "bytes": len(self.source_license),
            }],
        }
        (self.module / "engine.lock.json").write_text(
            json.dumps(self.lock), encoding="utf-8")

    def prepare(self):
        with (
            mock.patch.object(prepare_engine, "MODULE", self.module),
            mock.patch.object(prepare_engine, "ROOT", self.root),
            mock.patch.object(sys, "argv", ["prepare_engine.py"]),
            mock.patch.object(
                prepare_engine.urllib.request, "urlopen",
                side_effect=AssertionError("Preparation must reuse the pinned local cache")),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            prepare_engine.main()

    def seed_profiles(self):
        for name, data in self.profiles.items():
            path = self.generated / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        return self.generated / "assets/dexopt"

    def symlink(self, link, target, *, directory=False):
        link.parent.mkdir(parents=True, exist_ok=True)
        try:
            link.symlink_to(target, target_is_directory=directory)
        except (OSError, NotImplementedError) as error:
            self.skipTest(f"This filesystem cannot create the actual link fixture: {error}")
        self.assertTrue(link.is_symlink(), "The fixture must be an actual filesystem link")

    def assert_engine_assets(self):
        for name, expected in ENGINE_ASSETS.items():
            self.assertEqual((self.generated / name).read_bytes(), expected, name)
        self.assertEqual(
            (self.generated / FONTS_CONFIG).read_bytes(),
            b"/data/data/io.github.canele452.personalinkvault/cache/office-fontconfig")
        self.assertEqual(
            (self.generated / "assets/office-engine-source-license.txt").read_bytes(),
            self.source_license)
        self.assertEqual(
            (self.generated / "jniLibs/arm64-v8a/liblo-native-code.so").read_bytes(),
            self.entries["lib/arm64-v8a/liblo-native-code.so"])
        runtime = self.entries["lib/arm64-v8a/libc++_shared.so"]
        self.assertEqual(
            (self.generated / "jniLibs/arm64-v8a/libc++_shared.so").read_bytes(), runtime)
        self.assertEqual(
            (self.generated / "app-jni/arm64-v8a/libc++_shared.so").read_bytes(), runtime)
        for name in APK_METADATA:
            self.assertFalse((self.generated / name).exists(), name)

    def test_legacy_profile_fixture_authenticates_all_2493_pinned_bytes(self):
        self.assertEqual(sum(len(data) for data in self.profiles.values()), 2493)
        for name, (length, sha256) in PROFILES.items():
            self.assertEqual(len(self.profiles[name]), length)
            self.assertEqual(hashlib.sha256(self.profiles[name]).hexdigest(), sha256)

    def test_fresh_prepare_excludes_only_dexopt_metadata_and_preserves_engine_assets(self):
        self.prepare()
        imported = files(self.generated)
        self.assertFalse(any(name.startswith("assets/dexopt/") for name in imported))
        self.assert_engine_assets()

    def test_exact_legacy_profiles_are_removed_without_broad_generated_cleanup(self):
        self.seed_profiles()
        opaque = self.generated / "assets/unrelated-retained.bin"
        opaque.write_bytes(b"unrelated generated data must stay")
        self.prepare()
        for name in PROFILES:
            self.assertFalse((self.generated / name).exists(), name)
        self.assertEqual(opaque.read_bytes(), b"unrelated generated data must stay")
        self.assert_engine_assets()

    def test_foreign_profile_rejects_before_removing_either_original_profile(self):
        namespace = self.seed_profiles()
        (namespace / "baseline.profm").write_bytes(b"foreign retained profile")
        before = files(namespace)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(files(namespace), before)

    def test_unknown_namespace_file_is_rejected_and_all_existing_files_are_preserved(self):
        namespace = self.seed_profiles()
        # This entry is present in the pinned synthetic APK but is not one of
        # the two authenticated legacy generated profile paths.
        (namespace / "future-app-only.bin").write_bytes(
            self.entries["assets/dexopt/future-app-only.bin"])
        before = files(namespace)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(files(namespace), before)

    def test_profile_link_is_rejected_without_touching_its_external_target(self):
        namespace = self.seed_profiles()
        linked = namespace / "baseline.prof"
        linked.unlink()
        target = self.directory / "external-profile.bin"
        target.write_bytes(b"foreign link target stays exact")
        self.symlink(linked, target)
        other = (namespace / "baseline.profm").read_bytes()
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertTrue(linked.is_symlink())
        self.assertEqual(target.read_bytes(), b"foreign link target stays exact")
        self.assertEqual((namespace / "baseline.profm").read_bytes(), other)

    def test_dexopt_directory_link_preserves_all_external_files(self):
        external = self.directory / "external-dexopt"
        external.mkdir()
        for name, data in self.profiles.items():
            (external / Path(name).name).write_bytes(data)
        before = files(external)
        self.symlink(self.generated / "assets/dexopt", external, directory=True)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertTrue((self.generated / "assets/dexopt").is_symlink())
        self.assertEqual(files(external), before)

    def test_assets_parent_link_is_rejected_before_any_external_asset_write(self):
        external = self.directory / "external-assets"
        external.mkdir()
        (external / "sentinel.bin").write_bytes(b"retained external tree")
        before = files(external)
        self.symlink(self.generated / "assets", external, directory=True)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertTrue((self.generated / "assets").is_symlink())
        self.assertEqual(files(external), before)

    def test_generated_root_link_is_rejected_before_any_external_write(self):
        external = self.directory / "external-generated"
        external.mkdir()
        (external / "sentinel.bin").write_bytes(b"retained external tree")
        before = files(external)
        self.symlink(self.generated, external, directory=True)
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertTrue(self.generated.is_symlink())
        self.assertEqual(files(external), before)

    def test_finished_prepare_is_idempotent_and_records_the_asset_policy(self):
        self.seed_profiles()
        self.prepare()
        self.assertEqual(
            json.loads((self.generated / "prepared.json").read_text())["assetPolicyVersion"], 1)
        self.assertEqual(
            json.loads((self.generated / "assets/office-engine-provenance.json").read_text())["assetPolicyVersion"], 1)
        before = files(self.generated)
        times = {path.relative_to(self.generated).as_posix(): path.stat().st_mtime_ns
                 for path in self.generated.rglob("*") if path.is_file()}
        self.prepare()
        self.assertEqual(files(self.generated), before)
        self.assertEqual(
            {path.relative_to(self.generated).as_posix(): path.stat().st_mtime_ns
             for path in self.generated.rglob("*") if path.is_file()}, times)
        self.assertFalse(any(name.startswith("assets/dexopt/") for name in before))
        self.assert_engine_assets()


if __name__ == "__main__":
    unittest.main(verbosity=2)
