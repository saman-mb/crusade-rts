#!/usr/bin/env python3
"""Invariant tests for gen_normal_atlas (L1 / #82). Pure Python; run directly:
    python3 tools/test_gen_normal_atlas.py
Not part of the Godot CI gd-test glob (CI runs only godot suites); this is the
headless verification of the generator's contract. Calls the REAL builder
(which accepts an in-memory Image), so it never re-implements the code it tests.
"""

import os
import sys

import numpy as np
from PIL import Image

import gen_normal_atlas as g

_pass = 0
_fail = 0


def ok(cond, msg):
    global _pass, _fail
    if cond:
        _pass += 1
    else:
        _fail += 1
        print("FAIL:", msg)


def _atlas(rgb=150, alpha=255):
    a = np.zeros((g.ATLAS_H, g.ATLAS_W, 4), dtype=np.uint8)
    a[..., :3] = rgb
    a[..., 3] = alpha
    return Image.fromarray(a, "RGBA")


def test_flat_opaque_is_neutral():
    out = np.asarray(g.build_normal_atlas(_atlas(rgb=150, alpha=255)))
    ok(np.all(out == g.NEUTRAL), "flat opaque atlas -> all neutral (128,128,255)")


def test_transparent_is_neutral():
    out = np.asarray(g.build_normal_atlas(_atlas(rgb=200, alpha=0)))
    ok(np.all(out == g.NEUTRAL), "fully-transparent atlas -> all neutral")


def test_determinism():
    a = np.random.RandomState(0).randint(0, 256, (g.ATLAS_H, g.ATLAS_W, 4), dtype=np.uint8)
    a[..., 3] = 255
    img = Image.fromarray(a, "RGBA")
    o1 = np.asarray(g.build_normal_atlas(img))
    o2 = np.asarray(g.build_normal_atlas(img))
    ok(np.array_equal(o1, o2), "same input -> identical output")


def test_borders_neutral():
    # A noisy opaque atlas: every region's 1px border must still be neutral.
    a = np.random.RandomState(1).randint(0, 256, (g.ATLAS_H, g.ATLAS_W, 4), dtype=np.uint8)
    a[..., 3] = 255
    out = np.asarray(g.build_normal_atlas(Image.fromarray(a, "RGBA")))
    borders_ok = True
    for row in range(g.ROWS):
        for col in range(g.COLS):
            y0, x0 = row * g.REGION_H, col * g.REGION_W
            reg = out[y0:y0 + g.REGION_H, x0:x0 + g.REGION_W]
            for edge in (reg[0, :], reg[-1, :], reg[:, 0], reg[:, -1]):
                if not np.all(edge == g.NEUTRAL):
                    borders_ok = False
    ok(borders_ok, "every region's 1px border is neutral (no cross-tile bleed)")


def test_real_atlas_dims_and_relief():
    path = "assets/tilesets/terrain_atlas.png"
    if not os.path.exists(path):
        path = os.path.join(os.path.dirname(__file__), "..", "assets", "tilesets", "terrain_atlas.png")
    if not os.path.exists(path):
        print("skip real-atlas test (atlas not found)")
        return
    img = g.build_normal_atlas(path)
    out = np.asarray(img)
    ok(img.size == (g.ATLAS_W, g.ATLAS_H), "output is ATLAS_PX (512x320)")
    ok(img.mode == "RGB", "output is RGB")
    ok(out[..., 2].mean() > out[..., 0].mean() and out[..., 2].mean() > out[..., 1].mean(),
       "blue (+Z) dominant: mean B %.1f R %.1f G %.1f" % (out[..., 2].mean(), out[..., 0].mean(), out[..., 1].mean()))
    ok(not np.all(out[..., 0] == 128), "real atlas carries non-neutral relief")


def main():
    test_flat_opaque_is_neutral()
    test_transparent_is_neutral()
    test_determinism()
    test_borders_neutral()
    test_real_atlas_dims_and_relief()
    print("PASS %d / FAIL %d" % (_pass, _fail))
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
