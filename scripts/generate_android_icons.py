#!/usr/bin/env python3
"""Rasterize the checked-in Android brand artwork and mipmap inputs."""

from io import BytesIO
from pathlib import Path

import pymupdf
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'assets/icon'
MIPMAPS = ROOT / 'android/app/src/main/res'
SIZES = {'mdpi': (48, 108), 'hdpi': (72, 162), 'xhdpi': (96, 216),
         'xxhdpi': (144, 324), 'xxxhdpi': (192, 432)}


def render(stem):
    with pymupdf.open(stream=(ASSETS / f'{stem}.svg').read_bytes(), filetype='svg') as document:
        page = document[0]
        scale = 1024 / page.rect.width
        pixmap = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=True)
        return Image.open(BytesIO(pixmap.tobytes('png'))).convert('RGBA')


for stem, output, size_index in (
    ('icon', 'ic_launcher', 0),
    ('icon_maskable', 'ic_launcher_foreground', 1),
    ('icon_monochrome', 'ic_launcher_monochrome', 1),
):
    source = render(stem)
    source.save(ASSETS / f'{stem}.png', format='PNG', optimize=True)
    for density, sizes in SIZES.items():
        size = sizes[size_index]
        target = MIPMAPS / f'mipmap-{density}' / f'{output}.png'
        source.resize((size, size), Image.Resampling.LANCZOS).save(target, format='PNG', optimize=True)
