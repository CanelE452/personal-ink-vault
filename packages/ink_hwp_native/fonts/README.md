# HWP rendering font

The preparation scripts materialize the unmodified **Noto Sans CJK KR Regular 2.004** from the official [notofonts/noto-cjk](https://github.com/notofonts/noto-cjk/tree/523d033d6cb47f4a80c58a35753646f5c3608a78) source. The fixed commit is `523d033d6cb47f4a80c58a35753646f5c3608a78` (`Sans2.004`). The font is 16,433,112 bytes, below the 50 MiB limit. Its exact SHA-256 and source URL are in `manifest.json`.

Run `scripts/prepare-hwp-fonts.ps1` on Windows or `scripts/prepare-hwp-fonts.sh` on Linux/macOS before the application build. The shell script uses Python 3.11 or later; set `PYTHON` to select an existing interpreter. No system fonts or packages are installed. `-Check` / `--check` verifies an existing preparation without downloading. An existing file with the wrong size or hash causes an error and is preserved. The optional `-FontSourcePath` / `--font-source-path` accepts the exact pinned local font for offline preparation.

Default generated assets:

- `build/native/fonts/NotoSansCJKkr-Regular.otf`
- `build/native/fonts/OFL.txt`

These generated files stay outside Git. `flutter clean` removes them, so run preparation again afterwards. The Flutter asset declaration must include both paths. A different output directory can be passed with `-OutputDirectory` or the shell script's first positional argument; an application using that directory must update its asset declaration too. The Dart adapter should validate the font hash and copy these prepared assets into a private cache before native rendering.

The bundled `OFL.txt` contains the font's actual copyright/trademark notices, followed by the complete, unmodified upstream LICENSE text. `manifest.json` distinguishes the upstream license hash from this combined notice hash. The font metadata declares `© 2014-2021 Adobe (http://www.adobe.com/).` and `Noto is a trademark of Google Inc.`; the font's OS/2 `fsType` is zero. Both font and license must accompany redistribution. No Microsoft or Hancom font is copied.

This gives both platforms a common lawful font input. Its availability does not establish that its metrics match a document's original font, nor that every HWP layout can be rendered correctly.
