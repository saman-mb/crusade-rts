#!/usr/bin/env python3
"""Deterministic procedural DOODAD atlas for Crusade terrain (#234, Tier 3).

Scatterable decor -- rocks, bushes, grass tufts, flowers, pebbles -- that break
up the flat ground and make it read as DESIGNED terrain rather than a bare field
(the way StarCraft's tilesets pepper doodads over the ground). The sprites are
generated procedurally here rather than sourced, so the art is project-owned and
unambiguously free to license (see CREDITS.md) -- no third-party pack, no
attribution ambiguity.

Layout: a CELL x CELL grid, one ROW per doodad type, VARIANTS columns of jittered
variants per type. Each doodad is drawn centred horizontally with its visual BASE
on the cell's bottom edge, plus a soft contact shadow, so the runtime can anchor
the sprite's base at the unit footprint and let it Y-sort like any entity.

Fully deterministic: a fixed-seed RNG per (type, variant), no run-to-run drift.

Regenerate with:  python3 tools/gen_doodads.py
Writes assets/doodads/doodads.png relative to the repo root. Keep the layout in
sync with src/core/doodad_catalog.gd (the single source of truth the runtime reads).
"""

import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter

CELL = 64                      # px per doodad cell (square)
VARIANTS = 4                   # jittered variants per type (columns)
SS = 4                         # supersample for smooth edges
# Row order MUST match DoodadCatalog.TYPE_* in src/core/doodad_catalog.gd.
TYPES = ["rock", "bush", "grass", "flower", "pebble"]
ATLAS_W = CELL * VARIANTS
ATLAS_H = CELL * len(TYPES)


def _new_cell():
    return Image.new("RGBA", (CELL * SS, CELL * SS), (0, 0, 0, 0))


def _contact_shadow(draw, cx, base_y, rx, ry):
    """Soft dark ellipse on the ground under a doodad so it sits, not floats."""
    draw.ellipse([cx - rx, base_y - ry, cx + rx, base_y + ry], fill=(0, 0, 0, 70))


def _radial_blob(img, cx, cy, rx, ry, base, light, sun=(-0.5, -0.6)):
    """A shaded blob: base colour with a sun-side highlight, drawn at SS scale."""
    d = ImageDraw.Draw(img)
    d.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=base + (255,))
    # A smaller, offset lighter ellipse for the lit side.
    hx, hy = cx + sun[0] * rx * 0.45, cy + sun[1] * ry * 0.45
    d.ellipse([hx - rx * 0.55, hy - ry * 0.55, hx + rx * 0.55, hy + ry * 0.55],
              fill=light + (150,))


def _draw_rock(img, rng):
    cx = CELL * SS / 2
    base_y = CELL * SS - 6 * SS
    w = rng.uniform(0.34, 0.46) * CELL * SS
    h = w * rng.uniform(0.62, 0.78)
    d = ImageDraw.Draw(img)
    _contact_shadow(d, cx, base_y, w * 0.62, h * 0.28)
    g = rng.randint(120, 150)
    base = (g, g - 6, g - 12)
    light = (min(g + 55, 255),) * 3
    # main mass + a couple of side lobes for an irregular silhouette
    _radial_blob(img, cx, base_y - h * 0.55, w * 0.5, h * 0.6, base, light)
    _radial_blob(img, cx - w * 0.28, base_y - h * 0.3, w * 0.28, h * 0.32, base, light)
    _radial_blob(img, cx + w * 0.3, base_y - h * 0.34, w * 0.26, h * 0.3, base, light)


def _draw_bush(img, rng):
    cx = CELL * SS / 2
    base_y = CELL * SS - 6 * SS
    w = rng.uniform(0.4, 0.5) * CELL * SS
    h = w * rng.uniform(0.7, 0.85)
    d = ImageDraw.Draw(img)
    _contact_shadow(d, cx, base_y, w * 0.6, h * 0.24)
    dark = (34 + rng.randint(-6, 6), 74 + rng.randint(-8, 8), 34 + rng.randint(-6, 6))
    light = (96, 150, 66)
    lobes = rng.randint(4, 6)
    for i in range(lobes):
        a = math.pi * (0.15 + 0.7 * i / max(lobes - 1, 1))
        lx = cx + math.cos(a) * w * 0.34
        ly = base_y - h * 0.35 - math.sin(a) * h * 0.42
        _radial_blob(img, lx, ly, w * 0.3, h * 0.34, dark, light)
    _radial_blob(img, cx, base_y - h * 0.5, w * 0.4, h * 0.44, dark, light)


def _draw_grass(img, rng):
    cx = CELL * SS / 2
    base_y = CELL * SS - 6 * SS
    d = ImageDraw.Draw(img)
    _contact_shadow(d, cx, base_y, 0.22 * CELL * SS, 0.06 * CELL * SS)
    blades = rng.randint(5, 8)
    spread = 0.3 * CELL * SS
    for _i in range(blades):
        x0 = cx + rng.uniform(-spread, spread)
        hgt = rng.uniform(0.32, 0.52) * CELL * SS
        lean = rng.uniform(-0.16, 0.16) * CELL * SS
        # -15% saturation toward luma (#241 nit 3: the blades read neon under the warm grade).
        g = (52 + rng.randint(-8, 12), 115 + rng.randint(-16, 24), 49 + rng.randint(-8, 12))
        wdt = max(2 * SS, int(0.03 * CELL * SS))
        d.line([(x0, base_y), (x0 + lean, base_y - hgt)], fill=g + (255,), width=wdt)


def _draw_flower(img, rng):
    _draw_grass(img, rng)
    cx = CELL * SS / 2
    base_y = CELL * SS - 6 * SS
    d = ImageDraw.Draw(img)
    palette = [(230, 90, 90), (240, 220, 90), (235, 235, 245), (200, 120, 220)]
    n = rng.randint(2, 4)
    col = rng.choice(palette)
    for _i in range(n):
        fx = cx + rng.uniform(-0.22, 0.22) * CELL * SS
        fy = base_y - rng.uniform(0.34, 0.5) * CELL * SS
        r = rng.uniform(0.05, 0.07) * CELL * SS
        d.ellipse([fx - r, fy - r, fx + r, fy + r], fill=col + (255,))
        d.ellipse([fx - r * 0.4, fy - r * 0.4, fx + r * 0.4, fy + r * 0.4],
                  fill=(250, 240, 180, 255))


def _draw_pebble(img, rng):
    base_y = CELL * SS - 7 * SS
    d = ImageDraw.Draw(img)
    n = rng.randint(3, 5)
    for _i in range(n):
        px = CELL * SS / 2 + rng.uniform(-0.28, 0.28) * CELL * SS
        py = base_y - rng.uniform(-0.04, 0.06) * CELL * SS
        r = rng.uniform(0.05, 0.09) * CELL * SS
        g = rng.randint(120, 165)
        _contact_shadow(d, px, py + r * 0.6, r * 1.1, r * 0.45)
        d.ellipse([px - r, py - r * 0.7, px + r, py + r * 0.7], fill=(g, g - 5, g - 10, 255))
        d.ellipse([px - r * 0.5, py - r * 0.6, px + r * 0.2, py], fill=(min(g + 45, 255),) * 3 + (180,))


_DRAW = {
    "rock": _draw_rock,
    "bush": _draw_bush,
    "grass": _draw_grass,
    "flower": _draw_flower,
    "pebble": _draw_pebble,
}


def build_atlas():
    atlas = Image.new("RGBA", (ATLAS_W, ATLAS_H), (0, 0, 0, 0))
    for row, kind in enumerate(TYPES):
        for col in range(VARIANTS):
            cell = _new_cell()
            # Deterministic per (type, variant): fixed seed, no run-to-run drift.
            rng = random.Random(1000 * row + col + 7)
            _DRAW[kind](cell, rng)
            cell = cell.resize((CELL, CELL), Image.LANCZOS)
            atlas.alpha_composite(cell, (col * CELL, row * CELL))
    return atlas


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(repo_root, "assets", "doodads", "doodads.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    build_atlas().save(out)
    print("wrote %s (%dx%d)" % (out, ATLAS_W, ATLAS_H))


if __name__ == "__main__":
    main()
