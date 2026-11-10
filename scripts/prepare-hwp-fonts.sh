#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python="${PYTHON:-python3}"
"$python" - "$project_root" "$@" <<'PY'
from pathlib import Path
import argparse
import hashlib
import json
import os
import tempfile
import urllib.request

parser = argparse.ArgumentParser(description="Prepare the pinned OFL HWP rendering font.")
parser.add_argument("output_directory", nargs="?")
parser.add_argument("--font-source-path")
parser.add_argument("--check", action="store_true")
parser.add_argument("--manifest-name", choices=("manifest.json", "portable-export.json"), default="manifest.json")
import sys
project_root = Path(sys.argv[1])
args = parser.parse_args(sys.argv[2:])
metadata = project_root / "packages/ink_hwp_native/fonts"
manifest = json.loads((metadata / args.manifest_name).read_text(encoding="utf-8"))
length = manifest["bytes"]
if not isinstance(length, int) or not 0 < length <= 50 * 1024 * 1024:
    raise SystemExit("Invalid pinned HWP font size.")
destination = Path(args.output_directory) if args.output_directory else project_root / Path(manifest["assetPath"]).parent
destination = destination.resolve()
font_path = destination / manifest["fileName"]
license_path = destination / manifest["license"]["fileName"]
license_source = metadata / manifest["license"]["fileName"]

def verify(path, expected_length, expected_hash):
    if not path.is_file() or path.stat().st_size != expected_length:
        raise SystemExit(f"HWP font file missing or size mismatch: {path}")
    with path.open("rb") as stream:
        actual_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual_hash != expected_hash:
        raise SystemExit(f"HWP font file checksum mismatch: {path}")

verify(license_source, manifest["license"]["bytes"], manifest["license"]["sha256"])
for path, size, digest in ((font_path, length, manifest["sha256"]), (license_path, manifest["license"]["bytes"], manifest["license"]["sha256"])):
    if path.exists() or args.check:
        verify(path, size, digest)
if args.check:
    print(font_path)
    raise SystemExit(0)
destination.mkdir(parents=True, exist_ok=True)

def publish(stage, target):
    # Do not replace a concurrently created or previously invalid destination.
    os.link(stage, target)

temporary = None
try:
    if not font_path.exists():
        with tempfile.NamedTemporaryFile(prefix=".hwp-font-", suffix=".tmp", dir=destination, delete=False) as output:
            temporary = Path(output.name)
            if args.font_source_path:
                source = Path(args.font_source_path)
                verify(source, length, manifest["sha256"])
                with source.open("rb") as stream:
                    while chunk := stream.read(65536):
                        output.write(chunk)
            else:
                request = urllib.request.Request(manifest["sourceUrl"], headers={"User-Agent": "PersonalInkVault-HwpFontPreparer/1"})
                with urllib.request.urlopen(request, timeout=60) as response:
                    header_length = response.headers.get("Content-Length")
                    if header_length is not None and int(header_length) != length:
                        raise SystemExit("Pinned HWP font download has an unexpected Content-Length.")
                    received = 0
                    while chunk := response.read(65536):
                        received += len(chunk)
                        if received > length:
                            raise SystemExit("Pinned HWP font download exceeded its size limit.")
                        output.write(chunk)
        verify(temporary, length, manifest["sha256"])
        publish(temporary, font_path)
        temporary.unlink()
        temporary = None
    if not license_path.exists():
        with tempfile.NamedTemporaryFile(prefix=".hwp-font-", suffix=".tmp", dir=destination, delete=False) as output:
            temporary = Path(output.name)
            output.write(license_source.read_bytes())
        verify(temporary, manifest["license"]["bytes"], manifest["license"]["sha256"])
        publish(temporary, license_path)
        temporary.unlink()
        temporary = None
    verify(font_path, length, manifest["sha256"])
    verify(license_path, manifest["license"]["bytes"], manifest["license"]["sha256"])
    print(font_path)
finally:
    if temporary is not None:
        temporary.unlink(missing_ok=True)
PY
