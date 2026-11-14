import contextlib
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import prepare_runtime as prepare


LEGACY_CRITICAL_FILES = (
    "program/soffice.exe",
    "program/soffice.bin",
    "program/python.exe",
    "program/pyuno.pyd",
    "program/uno.py",
)
REQUIRED_CRITICAL_FILES = LEGACY_CRITICAL_FILES + (
    "program/soffice.com",
    "program/mergedlo.dll",
    "program/python-core-3.13.17/bin/python.exe",
    "program/python313.dll",
    "program/unohelper.py",
    "program/pythonloader.py",
    "program/pythonloaderlo.dll",
    "program/pythonscript.py",
    "program/pythonloader.uno.ini",
    "program/services/pyuno.rdb",
    "program/services/scriptproviderforpython.rdb",
    "program/version.ini",
    "program/fundamental.ini",
)


class RuntimeRepairTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="piv-runtime-repair-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.runtime = self.root / "runtime"
        self.raw = self.root / "cab-files"
        self.raw.mkdir()
        self.package = self.root / "LibreOffice_26.8.2_Win_x86-64.msi"
        self.package.write_bytes(b"synthetic pinned package")
        wheel = self.root / "pypdf.whl"
        with zipfile.ZipFile(wheel, "w") as archive:
            archive.writestr("pypdf/__init__.py", "")
        self.seven_zip = self.root / "7z.exe"
        self.seven_zip.write_bytes(b"test placeholder never executed")
        self.lock = {"version": "26.8.2.2", "url": "https://invalid.test/not-downloaded",
            "bytes": self.package.stat().st_size, "maximumBytes": 1000,
            "sha256": hashlib.sha256(self.package.read_bytes()).hexdigest(), "pdfReader": {
                "url": "https://invalid.test/not-downloaded", "bytes": wheel.stat().st_size,
                "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest()}}
        (self.root / "runtime.lock.json").write_text(json.dumps(self.lock), encoding="utf-8")
        self.expected = {name: ("fresh:" + name).encode() for name in REQUIRED_CRITICAL_FILES}
        self.file_rows = []
        for index, (name, data) in enumerate(self.expected.items()):
            destination = self.runtime / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            component = "python_core" if "/bin/" in name else "services" if "/services/" in name else "program"
            self.file_rows.append(["file_" + str(index), component, destination.name, str(len(data))])
        (self.raw / "file_0").write_bytes(b"stale raw extraction cache")

    def write_manifest(self, names):
        prepared = {"sha256": self.lock["sha256"], "criticalFiles": {
            name: hashlib.sha256(self.expected[name]).hexdigest() for name in names}}
        (self.root / "prepared.json").write_text(json.dumps(prepared), encoding="utf-8")
        return prepared

    def run_prepare(self):
        def extract(*_, **__):
            for row, data in zip(self.file_rows, self.expected.values()):
                (self.raw / row[0]).write_bytes(data)

        def rows(_, query, __):
            if "FROM `Directory`" in query:
                return [["INSTALLLOCATION", "TARGETDIR", "."], ["PROGRAM", "INSTALLLOCATION", "program"],
                    ["PYTHON_CORE", "PROGRAM", "python-core-3.13.17"], ["PYTHON_CORE_BIN", "PYTHON_CORE", "bin"],
                    ["SERVICES", "PROGRAM", "services"]]
            if "FROM `Component`" in query:
                return [["program", "PROGRAM"], ["python_core", "PYTHON_CORE_BIN"], ["services", "SERVICES"]]
            return self.file_rows

        output = io.StringIO()
        with patch.object(prepare, "ROOT", self.root), patch.object(prepare, "MODULE", self.root), \
                patch.object(prepare, "msi_rows", side_effect=rows), \
                patch.object(prepare.shutil, "which", return_value=str(self.seven_zip)), \
                patch.object(prepare.subprocess, "run", side_effect=extract) as extractor, \
                patch.object(prepare.urllib.request, "urlopen", side_effect=AssertionError("Unexpected download")), \
                contextlib.redirect_stdout(output):
            prepare.main()
        return extractor, json.loads(output.getvalue())

    def assert_complete_runtime(self, prepared):
        for name, data in self.expected.items():
            self.assertEqual((self.runtime / name).read_bytes(), data, name)
        self.assertEqual(set(prepared["criticalFiles"]), set(REQUIRED_CRITICAL_FILES))
        for name, digest in prepared["criticalFiles"].items():
            self.assertEqual(digest, hashlib.sha256(self.expected[name]).hexdigest(), name)
        self.assertEqual(json.loads((self.root / "prepared.json").read_text(encoding="utf-8")), prepared)

    def test_legacy_subset_manifest_cannot_hide_embedded_provider_damage(self):
        provider = self.runtime / "program/pythonscript.py"
        for damage in ("missing", "same-size"):
            with self.subTest(damage=damage):
                self.write_manifest(LEGACY_CRITICAL_FILES)
                if damage == "missing":
                    provider.unlink()
                else:
                    provider.write_bytes(b"x" * len(self.expected["program/pythonscript.py"]))
                extractor, prepared = self.run_prepare()
                extractor.assert_called_once()
                self.assert_complete_runtime(prepared)

    def test_same_size_corruption_is_replaced_from_fresh_verified_package(self):
        for name, damage in (("program/pyuno.pyd", "same-size"),
                ("program/pythonscript.py", "missing"), ("program/pythonscript.py", "same-size")):
            with self.subTest(name=name, damage=damage):
                self.write_manifest(REQUIRED_CRITICAL_FILES)
                target = self.runtime / name
                if damage == "missing":
                    target.unlink()
                else:
                    target.write_bytes(b"x" * len(self.expected[name]))
                extractor, prepared = self.run_prepare()
                extractor.assert_called_once()
                self.assert_complete_runtime(prepared)

    def test_complete_critical_manifest_preserves_cache_without_extraction(self):
        original = self.write_manifest(REQUIRED_CRITICAL_FILES)
        extractor, prepared = self.run_prepare()
        extractor.assert_not_called()
        self.assertEqual(prepared, original)
        self.assert_complete_runtime(prepared)


if __name__ == "__main__":
    unittest.main()
