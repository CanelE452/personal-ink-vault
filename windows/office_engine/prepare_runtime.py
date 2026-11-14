import ctypes
from ctypes import wintypes
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile

MODULE = Path(__file__).resolve().parent
ROOT = MODULE.parent.parent / "build" / "windows-office-engine"
CRITICAL_FILES = (
    "program/soffice.exe",
    "program/soffice.bin",
    "program/python.exe",
    "program/pyuno.pyd",
    "program/uno.py",
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


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def msi_rows(path, query, columns):
    library = ctypes.WinDLL("msi")
    library.MsiOpenDatabaseW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, ctypes.POINTER(wintypes.UINT)]
    library.MsiDatabaseOpenViewW.argtypes = [wintypes.UINT, wintypes.LPCWSTR, ctypes.POINTER(wintypes.UINT)]
    library.MsiViewExecute.argtypes = [wintypes.UINT, wintypes.UINT]
    library.MsiViewFetch.argtypes = [wintypes.UINT, ctypes.POINTER(wintypes.UINT)]
    library.MsiRecordGetStringW.argtypes = [wintypes.UINT, wintypes.UINT, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    database, view = wintypes.UINT(), wintypes.UINT()
    if library.MsiOpenDatabaseW(str(path), None, ctypes.byref(database)) != 0:
        raise RuntimeError("Cannot read the pinned MSI database")
    result = []
    try:
        if library.MsiDatabaseOpenViewW(database, query, ctypes.byref(view)) != 0:
            raise RuntimeError("Cannot query the pinned MSI table")
        if library.MsiViewExecute(view, 0) != 0:
            raise RuntimeError("Cannot read the pinned MSI table")
        while True:
            record = wintypes.UINT()
            status = library.MsiViewFetch(view, ctypes.byref(record))
            if status == 259:
                break
            if status != 0:
                raise RuntimeError("Cannot read an MSI record")
            try:
                values = []
                for column in range(1, columns + 1):
                    length = wintypes.DWORD(32767)
                    text = ctypes.create_unicode_buffer(length.value)
                    if library.MsiRecordGetStringW(record, column, text, ctypes.byref(length)) != 0:
                        raise RuntimeError("Cannot decode an MSI record")
                    values.append(text.value)
                result.append(values)
            finally:
                library.MsiCloseHandle(record)
    finally:
        if view.value:
            library.MsiCloseHandle(view)
        library.MsiCloseHandle(database)
    return result


def main():
    lock = json.loads((MODULE / "runtime.lock.json").read_text(encoding="utf-8"))
    ROOT.mkdir(parents=True, exist_ok=True)
    runtime = ROOT / "runtime"
    reader = lock["pdfReader"]
    wheel = ROOT / "pypdf.whl"
    if not wheel.exists() or sha256(wheel) != reader["sha256"]:
        data = urllib.request.urlopen(reader["url"], timeout=30).read(2000000)
        if len(data) != reader["bytes"] or hashlib.sha256(data).hexdigest() != reader["sha256"]:
            raise ValueError("PDF reader checksum mismatch")
        wheel.write_bytes(data)
    if not (runtime / "python-deps/pypdf/__init__.py").is_file():
        with zipfile.ZipFile(wheel) as archive:
            for name in archive.namelist():
                destination = runtime / "python-deps" / name
                if not destination.resolve().is_relative_to((runtime / "python-deps").resolve()):
                    raise ValueError("Unsafe PDF reader package path")
            archive.extractall(runtime / "python-deps")
    prepared_file = ROOT / "prepared.json"
    if prepared_file.exists():
        try:
            prepared = json.loads(prepared_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            prepared = {}
        critical = prepared.get("criticalFiles") if isinstance(prepared, dict) else None
        if isinstance(critical, dict) and set(critical) == set(CRITICAL_FILES) and \
                prepared.get("sha256") == lock["sha256"] and all(
                    (runtime / name).is_file() and sha256(runtime / name) == critical[name]
                    for name in CRITICAL_FILES):
            print(json.dumps(prepared))
            return
    package = ROOT / "LibreOffice_26.8.2_Win_x86-64.msi"
    if not package.exists() or sha256(package) != lock["sha256"]:
        partial = package.with_suffix(".part")
        with urllib.request.urlopen(lock["url"], timeout=60) as response, partial.open("wb") as output:
            total = 0
            while block := response.read(1024 * 1024):
                total += len(block)
                if total > lock["maximumBytes"]:
                    raise ValueError("Windows Office runtime exceeds its download bound")
                output.write(block)
        if total != lock["bytes"] or sha256(partial) != lock["sha256"]:
            raise ValueError("Windows Office runtime checksum mismatch")
        partial.replace(package)
    seven_zip = shutil.which("7z") or "C:/Program Files/7-Zip/7z.exe"
    if not Path(seven_zip).is_file():
        raise RuntimeError("7-Zip is required for registry-free MSI/CAB extraction")
    raw = ROOT / "cab-files"
    raw.mkdir(exist_ok=True)
    with (ROOT / "extraction.log").open("w", encoding="utf-8") as log:
        subprocess.run([seven_zip, "x", "-y", "-o" + str(raw), str(package)],
                       check=True, stdout=log, stderr=subprocess.STDOUT,
                       creationflags=subprocess.CREATE_NO_WINDOW)
    directories = {row[0]: row[1:] for row in msi_rows(package,
        "SELECT `Directory`, `Directory_Parent`, `DefaultDir` FROM `Directory`", 3)}
    components = dict(msi_rows(package, "SELECT `Component`, `Directory_` FROM `Component`", 2))
    files = msi_rows(package, "SELECT `File`, `Component_`, `FileName`, `FileSize` FROM `File`", 4)

    def relative_directory(identifier):
        if identifier == "INSTALLLOCATION":
            return Path()
        if identifier not in directories:
            return None
        parent, name = directories[identifier]
        if not parent:
            return None
        previous = relative_directory(parent)
        if previous is None:
            return None
        name = name.split(":")[0].split("|")[-1]
        return previous if name == "." else previous / name

    mapped = []
    unpacked = 0
    for key, component, name, size in files:
        directory = relative_directory(components[component])
        if directory is None:
            continue
        name = name.split("|")[-1]
        destination = runtime / directory / name
        if not destination.resolve().is_relative_to(runtime.resolve()):
            raise ValueError("Unsafe path in pinned MSI")
        source = raw / key
        if not source.is_file() or source.stat().st_size != int(size):
            raise ValueError("MSI/CAB file identity mismatch: " + key)
        unpacked += int(size)
        if unpacked > 2000000000:
            raise ValueError("Windows Office extraction exceeds2GB bound")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        mapped.append({"file": str(destination.relative_to(runtime)), "bytes": int(size)})
    if not (runtime / "program/soffice.exe").is_file():
        raise RuntimeError("MSI directory mapping did not produce a runtime")
    critical = {name: sha256(runtime / name) for name in CRITICAL_FILES}
    provenance = {**lock, "extraction": "7-Zip CAB + read-only MSI File/Directory/Component tables; no installation",
                  "files": len(mapped), "unpackedBytes": unpacked,
                  "sofficeSha256": sha256(runtime / "program/soffice.exe"), "criticalFiles": critical}
    (ROOT / "prepared.json").write_text(json.dumps(provenance, indent=2), encoding="utf-8")
    (ROOT / "runtime-files.json").write_text(json.dumps(mapped, indent=2), encoding="utf-8")
    print(json.dumps(provenance))


if __name__ == "__main__":
    main()
