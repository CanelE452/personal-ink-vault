"""Reproduce the Rust notice bundle from checksum-verified Cargo archives.

Requires Python 3.11+, the pinned cargo toolchain, and cached registry archives.
No compilation or dependency update is performed. --metadata accepts saved
`cargo +1.99.1 metadata --locked --all-features --format-version 1` output.
--manifest-path selects another application crate in this repository.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
import tomllib


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--manifest-path", type=Path)
    parser.add_argument("--cargo-home", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    default_crate = Path(__file__).resolve().parent
    manifest_path = args.manifest_path.resolve() if args.manifest_path else default_crate / "Cargo.toml"
    crate = manifest_path.parent
    legacy_bundle = False
    root = crate.parent.parent
    own_manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    own_name = own_manifest["package"]["name"]
    own_version = own_manifest["package"]["version"]
    cargo_home = args.cargo_home or Path(os.environ.get("CARGO_HOME", Path.home() / ".cargo"))
    lock_bytes = (crate / "Cargo.lock").read_bytes()
    lock = tomllib.loads(lock_bytes.decode("utf-8"))
    locked = {(p["name"], p["version"]): p for p in lock["package"] if "source" in p}
    if args.metadata:
        metadata = json.loads(args.metadata.read_text(encoding="utf-8-sig"))
    else:
        metadata = json.loads(subprocess.check_output([
            "cargo", "+1.99.1", "metadata", "--locked", "--offline", "--all-features",
            "--format-version", "1", "--manifest-path", str(manifest_path),
        ], text=True, encoding="utf-8"))
    packages = sorted((p for p in metadata["packages"] if p["source"]), key=lambda p: (p["name"], p["version"]))
    if set(locked) != {(p["name"], p["version"]) for p in packages}:
        raise ValueError("Cargo metadata does not cover the exact lockfile package set")

    supported = {
        "MIT": "MIT", "MIT OR Apache-2.0": "MIT", "Apache-2.0 OR MIT": "MIT",
        "Unlicense OR MIT": "MIT", "Zlib OR Apache-2.0 OR MIT": "MIT",
        "(MIT OR Apache-2.0) AND Unicode-3.0": "MIT AND Unicode-3.0",
        "0BSD OR MIT OR Apache-2.0": "MIT",
        "BSD-2-Clause": "BSD-2-Clause",
        "CC0-1.0 OR MIT-0 OR Apache-2.0": "MIT-0",
        "MIT/Apache-2.0": "MIT", "Apache-2.0 / MIT": "MIT",
        "(Apache-2.0 OR MIT) AND BSD-3-Clause": "MIT AND BSD-3-Clause",
        "bzip2-1.0.6": "bzip2-1.0.6",
        "Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT": "MIT",
        "Apache-2.0": "Apache-2.0", "MIT OR Zlib OR Apache-2.0": "MIT",
        "BSD-3-Clause OR Apache-2.0": "Apache-2.0",
        "CC0-1.0 OR MIT-0": "MIT-0",
        "MIT OR Apache-2.0 OR LGPL-2.1-or-later": "MIT",
        "Apache-2.0 OR BSL-1.0": "Apache-2.0",
        "Zlib": "Zlib", "BSD-3-Clause": "BSD-3-Clause",
        "MIT OR Apache-2.0 OR Zlib": "MIT",
        "Unicode-3.0": "Unicode-3.0",
        "MIT AND BSD-3-Clause": "MIT AND BSD-3-Clause",
    }
    notice_name = re.compile(r"^(LICENSE|LICENCE|COPYING|NOTICE|UNLICENSE|COPYRIGHT)(?:$|[._-])", re.I)
    if not legacy_bundle:
        notice_name = re.compile(r"^(LICENSE|LICENCE|COPYING|NOTICE|UNLICENSE|COPYRIGHT|AUTHORS)(?:$|[._-])", re.I)
    texts = {}
    records = []
    git_sources = {}

    def add_text(raw):
        normalized = raw.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n").encode("utf-8")
        digest = sha256(normalized)
        texts[digest] = normalized
        return digest

    def check_elected_texts(name, declared, notices):
        if not notices:
            raise ValueError(f"License text missing for {name}")
        content = "\n".join(texts[n["text"]].decode("utf-8") for n in notices).casefold()
        elected = supported[declared]
        if "MIT" in elected and "permission is hereby granted" not in content:
            raise ValueError(f"Elected MIT license text missing for {name}")
        if "Apache-2.0" in elected and not ("apache license" in content and "version 2.0" in content):
            raise ValueError(f"Elected Apache license text missing for {name}")
        if "BSD-" in elected and not ("redistribution and use" in content and "disclaimer" in content):
            # BSD notices commonly have no literal DISCLAIMER heading.
            if not ("redistribution and use" in content and "this software is provided" in content):
                raise ValueError(f"Elected BSD license text missing for {name}")
        if elected == "Zlib" and not ("altered source versions" in content and "this notice" in content):
            raise ValueError(f"Elected Zlib license text missing for {name}")
        if elected == "bzip2-1.0.6" and not ("bzip2" in content and "redistribution and use" in content):
            raise ValueError(f"Elected bzip2 license text missing for {name}")
        if "Unicode-3.0" in declared and not ("unicode license v3" in content or any("UNICODE" in n["file"].upper() for n in notices)):
            raise ValueError(f"Mandatory Unicode license text missing for {name}")

    def git_notices(package, pinned):
        source = pinned["source"]
        revision = "4e6e8c2a61694899e37b4f7c2f97523153a623b9"
        expected = f"git+https://github.com/STAIxBWLB/hwp-cli?rev={revision}#{revision}"
        reviewed = {"hwp-model", "hwp5", "hwpx", "hwp-convert", "hwp-render"}
        if source != expected or package["name"] not in reviewed or package["version"] != "1.3.1":
            raise ValueError(f"Unreviewed Git source: {package['name']} {source}")
        package_root = Path(package["manifest_path"]).resolve().parent
        git_root = Path(subprocess.check_output([
            "git", "-C", str(package_root), "rev-parse", "--show-toplevel",
        ], text=True, encoding="utf-8").strip()).resolve()
        if git_root not in git_sources:
            head = subprocess.check_output([
                "git", "-C", str(git_root), "rev-parse", "HEAD",
            ], text=True, encoding="utf-8").strip()
            if head != revision:
                raise ValueError(f"Git checkout does not match Cargo.lock: {git_root}")
            subprocess.run(["git", "-C", str(git_root), "diff", "--quiet", "HEAD", "--"], check=True)
            files = subprocess.check_output([
                "git", "-C", str(git_root), "ls-tree", "-r", "--name-only", revision,
            ], text=True, encoding="utf-8").splitlines()
            git_sources[git_root] = files

        def committed(relative):
            return subprocess.check_output(["git", "-C", str(git_root), "show", f"{revision}:{relative}"])

        relative_root = package_root.relative_to(git_root).as_posix()
        package_manifest = tomllib.loads(committed(relative_root + "/Cargo.toml").decode("utf-8"))
        declared = package_manifest["package"].get("license")
        if isinstance(declared, dict) and declared.get("workspace") is True:
            workspace = tomllib.loads(committed("Cargo.toml").decode("utf-8"))
            declared = workspace["workspace"]["package"]["license"]
        if declared != package["license"] or declared not in supported:
            raise ValueError(f"Unreviewed Git license expression: {package['name']} {declared}")
        notices = []
        for relative in git_sources[git_root]:
            if not notice_name.match(PurePosixPath(relative).name):
                continue
            if "/" in relative and not relative.startswith(relative_root + "/"):
                continue
            raw = committed(relative)
            notices.append({"file": relative, "source_sha256": sha256(raw), "text": add_text(raw)})
        for required in ("LICENSE-MIT", "LICENSE-APACHE", "NOTICE"):
            if not any(n["file"] == required for n in notices):
                raise ValueError(f"Required Git notice missing: {required}")
        check_elected_texts(package["name"], declared, notices)
        return {
            "name": package["name"], "version": package["version"], "declared": declared,
            "elected": supported[declared], "source": source,
            "git_revision": revision, "notices": notices,
        }

    for package in packages:
        name, version = package["name"], package["version"]
        pinned = locked[(name, version)]
        if package["source"] != pinned["source"]:
            raise ValueError(f"Unreviewed package source: {name} {version}")
        if package["source"].startswith("git+"):
            records.append(git_notices(package, pinned))
            continue
        if not package["source"].startswith("registry+"):
            raise ValueError(f"Unreviewed package source: {name} {version}")
        archives = sorted(cargo_home.glob(f"registry/cache/*/{name}-{version}.crate"))
        archive = next((path for path in archives if sha256(path.read_bytes()) == pinned["checksum"]), None)
        if archive is None:
            raise ValueError(f"Missing checksum-matching registry archive: {name} {version}")
        prefix = f"{name}-{version}/"
        notices = []
        with tarfile.open(archive, "r:gz") as source:
            manifest = tomllib.loads(source.extractfile(prefix + "Cargo.toml").read().decode("utf-8"))
            declared = manifest["package"].get("license")
            if declared != package["license"] or declared not in supported:
                raise ValueError(f"Unreviewed license expression: {name} {declared}")
            license_file = manifest["package"].get("license-file")
            for member in sorted(source.getmembers(), key=lambda item: item.name):
                if not member.isfile() or not member.name.startswith(prefix):
                    continue
                relative = member.name[len(prefix):]
                if not notice_name.match(PurePosixPath(relative).name) and relative != license_file:
                    continue
                raw = source.extractfile(member).read()
                notices.append({"file": relative, "source_sha256": sha256(raw), "text": add_text(raw)})
        if legacy_bundle:
            if not notices or not any("MIT" in p["file"] or p["file"] == "LICENSE" for p in notices):
                raise ValueError(f"MIT license text missing for {name}")
            if "Unicode-3.0" in declared and not any("UNICODE" in p["file"] for p in notices):
                raise ValueError(f"Mandatory Unicode license text missing for {name}")
        else:
            check_elected_texts(name, declared, notices)
        records.append({
            "name": name, "version": version, "declared": declared, "elected": supported[declared],
            "source": pinned["source"], "archive_sha256": pinned["checksum"], "notices": notices,
        })

    gpl_raw = (root / "LICENSE.md").read_bytes()
    gpl_text = add_text(gpl_raw)
    lines = [
        "Personal Ink Vault - Rust common engine license notices", "",
        f"{own_name} {own_version} is original application code distributed under GNU GPL v3.",
        f"The complete application GPL text is reproduced in TEXT {gpl_text}.",
        "Third-party packages retain their own copyrights and license terms below.", "",
        "Source pin:",
    ]
    if not legacy_bundle:
        lines[0] = "Personal Ink Vault - Rust MCP server license notices"
    filenames = ["Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "src/lib.rs"]
    if not legacy_bundle:
        filenames = filenames[:3] + sorted(path.relative_to(crate).as_posix() for path in (crate / "src").rglob("*.rs"))
        filenames += [name for name in ("fonts/manifest.json", "fonts/OFL.txt") if (crate / name).exists()]
        filenames += ["generate_licenses.py"]
    relative_crate = crate.relative_to(root).as_posix()
    for filename in filenames:
        lines.append(f"  {relative_crate}/{filename}: SHA-256 {sha256((crate / filename).read_bytes())}")
    lines.extend([
        "  Rust toolchain: 1.99.1 (rust-toolchain.toml and build scripts)", "",
        f"Coverage: all {len(records)} third-party packages in Cargo.lock and cargo metadata.",
        "This deliberately includes optional, target-specific and build-time packages;",
        "a package listing does not assert that its code is present in every DLL/SO.",
        "Each registry .crate archive was checked against its Cargo.lock SHA-256.",
        "Declared expressions were read from the checksum-verified package manifests.",
        "Distribution election: MIT wherever the declared OR expression permits MIT;",
        "Unicode-3.0 is additionally retained wherever the expression requires it.",
        "All shipped license/notice alternatives are reproduced, including Apache-2.0,",
        "Zlib and Unlicense, plus nested notices such as regex-syntax Unicode data.",
        "Only line endings are normalized to LF; identical complete texts are stored",
        "once and unambiguously referenced by their normalized text SHA-256.", "",
        "Scope: this bundle covers the Cargo registry dependencies, not a complete",
        "binary audit. Rust standard-library/compiler runtime, NDK/Windows runtimes,",
        "Flutter, PDFium, Office engines and other application assets need their own",
        "notices. It is not a substitute for the exact corresponding source and build",
        "materials required when distributing this GPL application.", "",
        "Reproduce: run generate_licenses.py with the pinned cargo available and a",
        "populated CARGO_HOME, or pass --metadata and --cargo-home. --check verifies",
        "that this file matches the lockfile and the checksum-verified source notices.", "",
        "PACKAGE INVENTORY", "=================", "",
    ])
    asset_notices = []
    if not legacy_bundle:
        registry_count = sum("archive_sha256" in p for p in records)
        git_count = len(records) - registry_count
        lines[lines.index("Declared expressions were read from the checksum-verified package manifests.")] = "Declared expressions were read from verified registry archives and Git manifests."
        lines[lines.index("Scope: this bundle covers the Cargo registry dependencies, not a complete")] = "Scope: this bundle covers the listed Cargo and font dependencies, not a complete"
        start = lines.index("Distribution election: MIT wherever the declared OR expression permits MIT;")
        end = lines.index("Only line endings are normalized to LF; identical complete texts are stored")
        lines[start:end] = [
            f"Sources: {registry_count} checksum-verified registry archives and {git_count} Git packages.",
            "Git source HEAD and tracked files were verified against the exact Cargo.lock revision.",
            "Full repository LICENSE-MIT, LICENSE-APACHE and NOTICE are retained for Git packages,",
            "together with package-local notices such as the renderer's ICC profile license.",
            "Distribution election: MIT where permitted; otherwise the explicit elected terms",
            "are listed per package. AND clauses retain every required additional license.",
            "All shipped license/notice alternatives are reproduced without summarizing them.",
        ]
        start = lines.index("Reproduce: run generate_licenses.py with the pinned cargo available and a")
        lines[start:start + 3] = [
            "Reproduce from the repository root:",
            "  python packages/ink_vault_native/generate_licenses.py",
            f"    --manifest-path {relative_crate}/Cargo.toml",
            "Pass --metadata / --cargo-home for saved Cargo metadata and archive caches.",
            "Add --check to verify source pins and exact notice content without writing.",
        ]
        font_manifest = crate / "fonts/manifest.json"
        if font_manifest.exists():
            font = json.loads(font_manifest.read_text(encoding="utf-8"))
            if font["license"]["spdx"] != "OFL-1.1":
                raise ValueError("Unreviewed font license expression")
            notice_file = crate / "fonts" / font["license"]["fileName"]
            raw = notice_file.read_bytes()
            if len(raw) != font["license"]["bytes"] or sha256(raw) != font["license"]["sha256"]:
                raise ValueError("Font notice does not match its pinned manifest")
            upstream_length = font["license"]["sourceBytes"]
            if sha256(raw[-upstream_length:]) != font["license"]["sourceSha256"]:
                raise ValueError("Font upstream license text does not match its pin")
            asset = {"name": font["family"], "version": font["version"], "source": font["sourceUrl"],
                     "source_revision": font["sourceCommit"], "font_sha256": font["sha256"],
                     "license": font["license"]["spdx"], "source_sha256": sha256(raw), "text": add_text(raw)}
            asset_notices.append(asset)
            lines.extend([
                f"ASSET {asset['name']} {asset['version']}",
                f"  Source: {asset['source']}", f"  Git revision: {asset['source_revision']}",
                f"  Font SHA-256: {asset['font_sha256']}", f"  License: {asset['license']}",
                f"  Full notice SHA-256: {asset['source_sha256']}", f"  Full text: TEXT {asset['text']}", "",
            ])
    for package in records:
        lines.append(f"PACKAGE {package['name']} {package['version']}")
        if "git_revision" in package:
            lines.extend([f"  Source: {package['source']}", f"  Git revision: {package['git_revision']}"])
        else:
            lines.extend([
                f"  Source: https://crates.io/crates/{package['name']}/{package['version']}",
                f"  Registry: {package['source']}", f"  Archive SHA-256: {package['archive_sha256']}",
            ])
        lines.extend([
            f"  Declared SPDX expression: {package['declared']}",
            f"  Elected terms: {package['elected']}",
        ])
        for notice in package["notices"]:
            lines.extend([
                f"  File: {notice['file']}",
                f"    Source-file SHA-256: {notice['source_sha256']}",
                f"    Full text: TEXT {notice['text']}",
            ])
        lines.append("")
    bundle = ("\n".join(lines) + "\nFULL LICENSE AND NOTICE TEXTS\n=============================\n\n").encode("utf-8")
    for digest, content in sorted(texts.items()):
        bundle += f"TEXT {digest}\n".encode("utf-8") + content
        if not content.endswith(b"\n"):
            bundle += b"\n"
        bundle += f"END TEXT {digest}\n\n".encode("utf-8")
    output = crate / "THIRD_PARTY_LICENSES.txt"
    if args.check:
        if not output.exists() or output.read_bytes() != bundle:
            raise ValueError("Notice bundle is missing or stale")
    else:
        output.write_bytes(bundle)
    report = {
        "packages": records, "package_count": len(records),
        "source_notice_count": sum(len(p["notices"]) for p in records),
        "unique_text_count_including_gpl": len(texts), "bundle_bytes": len(bundle),
        "bundle_sha256": sha256(bundle), "lock_sha256": sha256(lock_bytes),
    }
    if not legacy_bundle:
        report["asset_notices"] = asset_notices
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"{'Verified' if args.check else 'Generated'} {len(records)} packages, {report['source_notice_count']} notice files, {len(texts)} full texts, {len(bundle)} bytes")


if __name__ == "__main__":
    main()
