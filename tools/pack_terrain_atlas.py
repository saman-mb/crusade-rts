#!/usr/bin/env python3
"""Deterministic terrain atlas packer for Crusade -- composites REAL CC0 art.

Where gen_placeholder_atlas.py renders an honest flat placeholder, this consumes
the committed CC0 source tiles under assets/tilesets/sources/ and blends grass
over dirt through the EXACT dual-grid corner-triangle geometry defined in
src/core/tileset_constants.gd, producing the final HD terrain atlas.

Source art (CC0 -- Screaming Brain Studios, "1000+ Isometric Floor Tiles",
https://opengameart.org/content/1000-isometric-floor-tiles; see
assets/tilesets/sources/LICENSE.txt):
  grass_dirt.png  -- "128x64 Grass A to Dirt A" autotile sheet (512x448, 4x7)
  water.png       -- "Grass A - Water Flat" autotile sheet (1024x384, 8x6)

Layout (must match src/core/tileset_constants.gd, the single source of truth):
  - 512x320 RGBA, carved into 128x64 (true 2:1) regions -> 4 cols x 5 rows.
  - Rows 0..3 x cols 0..3: the 16 dual-grid cells. Cell (col, row) is corner
    mask m = row*4 + col (bit order TL=1, TR=2, BL=4, BR=8). Mask 0 is left
    transparent (empty sentinel). For masks 1..15 the diamond's four corner
    triangles select GRASS (bit set) vs DIRT (bit clear), feathered at the
    seams so the grass/dirt transition reads naturally.
  - Row 4, cols 0..3: a 4-frame animated water strip (brightness ramp) so
    runtime desync (RANDOM_START_TIMES) is visible.

Fully deterministic: no randomness, no run-to-run variation.

Regenerate with:
    python3 tools/pack_terrain_atlas.py
It writes assets/tilesets/terrain_atlas.png relative to the repo root.
"""

import os

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

# --- Layout constants (mirror tileset_constants.gd) ---
REGION_W, REGION_H = 128, 64
ATLAS_W, ATLAS_H = 512, 384
SS = 4                      # supersample factor for anti-aliasing
FEATHER_PX = 3.0            # grass<->dirt seam softness, in final-res pixels
# Tier 2 terrain-realism (#233): the diamond silhouette is hardened at the very
# end (ALPHA_THRESHOLD) so neighbouring diamonds meet at full coverage instead of
# leaving a semi-transparent 1px band that let the dark void behind the layer show
# through as a visible grid of seams. GRASS_CONTRAST/GRASS_SATURATION knock the
# high-contrast tuft "signature" down toward an even field so the base tile reads
# as texture, not a recognizable stamp -- the variation system (#232) then breaks
# up what little repetition remains.
ALPHA_THRESHOLD = 96        # 0..255; alpha >= this -> fully opaque, else fully clear
GRASS_CONTRAST = 0.70       # <1 flattens the grass tuft contrast toward its mean
GRASS_SATURATION = 1.02     # slight boost so the averaged grass reads green, not muddy

# --- Source sheet cell selection (in source-cell units) ---
GRASS_DIRT_COLS, GRASS_DIRT_ROWS = 4, 7
# The interior grass tile is the AVERAGE of a few grass-dominant source cells
# (#233). Every cell of this Grass A->Dirt A sheet is really a grass/dirt
# transition, so any single crop carries a recognizable patch ("signature") that
# reads as a stamp when tiled. Averaging a few dilutes any one feature into an
# even grass field, which the flip variants (#232) + tint shader then finish off.
GRASS_CELLS = [(1, 3), (0, 0), (2, 3)]
DIRT_CELL = (1, 4)         # the matching fully-dirt cell
WATER_COLS, WATER_ROWS = 8, 6
WATER_BRIGHTNESS = [0.85, 0.95, 1.05, 1.15]  # 4-frame ramp
# Ramp placeholder (#78): a distinct warm tan diamond at (col 0, row 5) so the
# ramp tile is legible but honestly a placeholder (real art is #33).
RAMP_COLOR = (178, 150, 100)


def _crop_cell(sheet, cols, rows, col, row):
    w = sheet.width // cols
    h = sheet.height // rows
    box = (col * w, row * h, (col + 1) * w, (row + 1) * h)
    return sheet.crop(box).convert("RGB").resize(
        (REGION_W * SS, REGION_H * SS), Image.LANCZOS)


def _average(images):
    """Per-pixel mean of several equal-size RGB images (#233): blends grass crops
    into one even field. Deterministic (integer-averaged via PIL)."""
    acc = images[0]
    for i in range(1, len(images)):
        acc = Image.blend(acc, images[i], 1.0 / (i + 1))
    return acc


def _soften(rgb):
    """Tier 2 (#233): flatten a ground crop's contrast + saturation so its high-
    frequency 'signature' features stop reading as a stamp when tiled. Purely a
    tone operation on the RGB crop; the diamond alpha is applied later."""
    out = ImageEnhance.Contrast(rgb).enhance(GRASS_CONTRAST)
    return ImageEnhance.Color(out).enhance(GRASS_SATURATION)


def _harden_silhouette(atlas):
    """Tier 2 (#233): threshold the atlas alpha so every diamond is fully opaque
    up to a crisp edge. A soft (anti-aliased) diamond edge leaves a semi-
    transparent band where two tiles meet, and the dark void behind the layer
    shows through it as a grid of seams. An inclusive threshold grows each diamond
    by a hair so neighbours overlap at the shared edge -> full coverage, no seam.
    Only the diamond SILHOUETTE hardens; the grass<->dirt blend lives in the RGB
    (via the corner selector), so soft interior transitions are untouched."""
    r, g, b, a = atlas.split()
    a = a.point(lambda v: 255 if v >= ALPHA_THRESHOLD else 0)
    return Image.merge("RGBA", (r, g, b, a))


def _diamond_points():
    """Diamond vertices at supersampled region resolution (origin 0,0)."""
    cx, cy = REGION_W * SS / 2.0, REGION_H * SS / 2.0
    top = (cx, 0.0)
    right = (REGION_W * SS, cy)
    bottom = (cx, REGION_H * SS)
    left = (0.0, cy)
    center = (cx, cy)
    return top, right, bottom, left, center


def _diamond_alpha():
    """Full-diamond alpha mask (L) at supersampled region resolution."""
    top, right, bottom, left, _ = _diamond_points()
    a = Image.new("L", (REGION_W * SS, REGION_H * SS), 0)
    ImageDraw.Draw(a).polygon([top, right, bottom, left], fill=255)
    return a


def _corner_selector(mask):
    """Grass-vs-dirt selector (L): 255 in grass corners, feathered at seams.

    Triangles fan out from the diamond center, matching gen_placeholder_atlas.py
    and tileset_constants.gd: TL=(center,top,left), TR=(center,top,right),
    BL=(center,bottom,left), BR=(center,bottom,right).
    """
    top, right, bottom, left, center = _diamond_points()
    sel = Image.new("L", (REGION_W * SS, REGION_H * SS), 0)
    d = ImageDraw.Draw(sel)
    corners = [
        ((center, top, left), 1),      # TL
        ((center, top, right), 2),     # TR
        ((center, bottom, left), 4),   # BL
        ((center, bottom, right), 8),  # BR
    ]
    for tri, bit in corners:
        if mask & bit:
            d.polygon(list(tri), fill=255)
    return sel.filter(ImageFilter.GaussianBlur(FEATHER_PX * SS))


def _compose_tile(grass_ss, dirt_ss, dia_ss, mask):
    """Blend grass over dirt via the mask's corner selector; clip to diamond."""
    sel = _corner_selector(mask)
    rgb = Image.composite(grass_ss, dirt_ss, sel)
    tile = rgb.convert("RGBA")
    tile.putalpha(dia_ss)
    return tile


def _water_tile(water_cell_ss, dia_ss, brightness):
    rgb = ImageEnhance.Brightness(water_cell_ss).enhance(brightness)
    tile = rgb.convert("RGBA")
    tile.putalpha(dia_ss)
    return tile


def _solid_tile(color, dia_ss):
    """Flat-color diamond tile clipped to the diamond alpha (placeholder art)."""
    rgb = Image.new("RGB", (REGION_W * SS, REGION_H * SS), color)
    tile = rgb.convert("RGBA")
    tile.putalpha(dia_ss)
    return tile


def _pick_water_cell(water_sheet):
    """Deterministically pick the most water-dominant cell (max mean B - R)."""
    best, best_score = None, None
    for row in range(WATER_ROWS):
        for col in range(WATER_COLS):
            cell = _crop_cell(water_sheet, WATER_COLS, WATER_ROWS, col, row)
            small = cell.resize((16, 8), Image.LANCZOS)
            px = list(small.getdata())
            n = len(px)
            mean_r = sum(p[0] for p in px) / n
            mean_b = sum(p[2] for p in px) / n
            score = mean_b - mean_r
            if best_score is None or score > best_score:
                best_score, best = score, cell
    return best


def build_atlas(sources_dir):
    grass_sheet = Image.open(os.path.join(sources_dir, "grass_dirt.png"))
    water_sheet = Image.open(os.path.join(sources_dir, "water.png"))

    grass_crops = [_crop_cell(grass_sheet, GRASS_DIRT_COLS, GRASS_DIRT_ROWS, c, r)
                   for (c, r) in GRASS_CELLS]
    grass_ss = _soften(_average(grass_crops))
    dirt_ss = _soften(_crop_cell(grass_sheet, GRASS_DIRT_COLS, GRASS_DIRT_ROWS, *DIRT_CELL))
    water_ss = _pick_water_cell(water_sheet)
    dia_ss = _diamond_alpha()

    big = Image.new("RGBA", (ATLAS_W * SS, ATLAS_H * SS), (0, 0, 0, 0))

    # Rows 0..3 x cols 0..3: dual-grid cells.
    for row in range(4):
        for col in range(4):
            mask = row * 4 + col
            if mask == 0:
                continue  # empty sentinel: leave transparent
            tile = _compose_tile(grass_ss, dirt_ss, dia_ss, mask)
            big.alpha_composite(tile, (col * REGION_W * SS, row * REGION_H * SS))

    # Row 4: 4-frame animated water strip.
    for col in range(4):
        tile = _water_tile(water_ss, dia_ss, WATER_BRIGHTNESS[col])
        big.alpha_composite(tile, (col * REGION_W * SS, 4 * REGION_H * SS))

    # Row 5, col 0: placeholder ramp tile (#78).
    ramp_tile = _solid_tile(RAMP_COLOR, dia_ss)
    big.alpha_composite(ramp_tile, (0, 5 * REGION_H * SS))

    return _harden_silhouette(big.resize((ATLAS_W, ATLAS_H), Image.LANCZOS))


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sources_dir = os.path.join(repo_root, "assets", "tilesets", "sources")
    out_path = os.path.join(repo_root, "assets", "tilesets", "terrain_atlas.png")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    atlas = build_atlas(sources_dir)
    atlas.save(out_path)
    print("wrote %s (%dx%d)" % (out_path, atlas.width, atlas.height))


if __name__ == "__main__":
    main()
