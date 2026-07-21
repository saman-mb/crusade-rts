#!/usr/bin/env python3
"""Deterministic placeholder terrain atlas generator for Crusade.

This renders an HONEST, LABELED PLACEHOLDER -- flat-shaded diamonds that make
the dual-grid autotiling legible at a glance -- NOT final art. Output is fully
reproducible: no randomness, no run-to-run variation.

Layout (must match src/core/tileset_constants.gd, the single source of truth):
  - 512x320 RGBA, carved into 128x64 (true 2:1) regions -> 4 cols x 5 rows.
  - Rows 0..3 x cols 0..3: the 16 dual-grid cells. The physical cell at
    (col, row) represents corner mask m = row*4 + col (bit order TL=1, TR=2,
    BL=4, BR=8). Cell (0,0) / mask 0 is left transparent (empty sentinel).
    For masks 1..15 the diamond's four corner triangles are shaded to show
    which corners are filled (grass green) vs empty (water blue).
  - Row 4, cols 0..3: a 4-frame animated water strip, each frame a visibly
    distinct blue so runtime desync (RANDOM_START_TIMES) is visible.

Regenerate with:
    python3 tools/gen_placeholder_atlas.py
It writes assets/tilesets/terrain_atlas.png relative to the repo root.
"""

import os

from PIL import Image, ImageDraw

# --- Layout constants (mirror tileset_constants.gd) ---
REGION_W, REGION_H = 128, 64
ATLAS_W, ATLAS_H = 512, 320
SS = 4  # supersample factor for anti-aliasing

# --- Flat-shaded placeholder palette ---
GRASS = (86, 160, 68, 255)          # filled corner
WATER = (58, 120, 190, 255)         # empty corner
OUTLINE = (30, 40, 30, 255)         # thin diamond edge for crispness
# Four visibly distinct water frames (brightness ramp) so desync is visible.
WATER_FRAMES = [
	(40, 96, 168, 255),
	(56, 120, 192, 255),
	(80, 148, 214, 255),
	(104, 176, 232, 255),
]


def _region_origin(col, row):
	return col * REGION_W, row * REGION_H


def _diamond_points(ox, oy):
	"""Diamond vertices (supersampled) for a region at pixel origin (ox, oy)."""
	cx = (ox + REGION_W / 2.0) * SS
	cy = (oy + REGION_H / 2.0) * SS
	top = (cx, (oy) * SS)
	right = ((ox + REGION_W) * SS, cy)
	bottom = (cx, (oy + REGION_H) * SS)
	left = ((ox) * SS, cy)
	center = (cx, cy)
	return top, right, bottom, left, center


def _draw_masked_diamond(draw, ox, oy, mask):
	"""Draw a diamond split into 4 corner triangles shaded per the mask bits."""
	top, right, bottom, left, center = _diamond_points(ox, oy)
	# Corner -> (triangle vertices, bit). Triangles fan out from the center.
	corners = [
		((center, top, left), 1),     # TL
		((center, top, right), 2),    # TR
		((center, bottom, left), 4),  # BL
		((center, bottom, right), 8), # BR
	]
	for tri, bit in corners:
		color = GRASS if (mask & bit) else WATER
		draw.polygon(list(tri), fill=color)
	# Crisp outline around the whole diamond.
	draw.line([top, right, bottom, left, top], fill=OUTLINE, width=SS)


def _draw_solid_diamond(draw, ox, oy, color):
	top, right, bottom, left, _ = _diamond_points(ox, oy)
	draw.polygon([top, right, bottom, left], fill=color)
	draw.line([top, right, bottom, left, top], fill=OUTLINE, width=SS)


def build_atlas():
	big = Image.new("RGBA", (ATLAS_W * SS, ATLAS_H * SS), (0, 0, 0, 0))
	draw = ImageDraw.Draw(big)

	# Rows 0..3 x cols 0..3: dual-grid cells.
	for row in range(4):
		for col in range(4):
			mask = row * 4 + col
			ox, oy = _region_origin(col, row)
			if mask == 0:
				continue  # empty sentinel: leave transparent
			_draw_masked_diamond(draw, ox, oy, mask)

	# Row 4: 4-frame animated water strip.
	for col in range(4):
		ox, oy = _region_origin(col, 4)
		_draw_solid_diamond(draw, ox, oy, WATER_FRAMES[col])

	return big.resize((ATLAS_W, ATLAS_H), Image.LANCZOS)


def main():
	repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
	out_path = os.path.join(repo_root, "assets", "tilesets", "terrain_atlas.png")
	os.makedirs(os.path.dirname(out_path), exist_ok=True)
	atlas = build_atlas()
	atlas.save(out_path)
	print("wrote %s (%dx%d)" % (out_path, atlas.width, atlas.height))


if __name__ == "__main__":
	main()
