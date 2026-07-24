#!/usr/bin/env python3
"""Deterministic tangent-space NORMAL-map generator for the Crusade terrain atlas.

Story L1 (#82) of the lighting epic (#66). The diffuse atlas
(assets/tilesets/terrain_atlas.png) is flat art; a Light2D shading it with no
normal map just brightens uniformly. This derives a per-texel normal map from
the diffuse luminance so light picks out surface relief (grass blades, dirt
clumps, water ripple) on the 2:1 diamonds.

REGION-AWARE by construction: the atlas packs 128x64 (true 2:1) regions edge to
edge with ZERO separation, so a naive global gradient would invent steep normals
at every region boundary. Each region is processed in ISOLATION (its gradient
never reads a neighbouring region), and:
  - texels outside the diamond (diffuse alpha below --alpha-threshold) are forced
    NEUTRAL (128,128,255) -- flat, +Z -- so the transparent rectangle corners and
    the diamond rim carry no spurious relief;
  - the 1px outer border of every region is forced NEUTRAL as belt-and-suspenders
    against cross-tile bleed.

A perfectly flat region therefore encodes uniform (128,128,255). Fully
deterministic (pure numpy, no randomness).

Regenerate with:
    python3 tools/gen_normal_atlas.py
It writes assets/tilesets/terrain_atlas_n.png relative to the repo root.
"""

import argparse
import os

import numpy as np
from PIL import Image

# --- Layout constants (mirror src/core/tileset_constants.gd) ---
REGION_W, REGION_H = 128, 64
ATLAS_W, ATLAS_H = 512, 384
COLS, ROWS = ATLAS_W // REGION_W, ATLAS_H // REGION_H   # 4 x 6

# --- Defaults ---
# Near-flat by design (#233 art pass): terrain relief now comes from the world-space
# terrain_tint shader, not this per-tile normal map. A strong per-tile normal creates
# a lit/shadow crease at every diamond edge -> a visible grid. Keeping this low leaves
# only a whisper of tactile detail under the sun without re-drawing the tile lattice.
DEFAULT_STRENGTH = 0.55         # relief exaggeration; higher = steeper normals
DEFAULT_ALPHA_THRESHOLD = 8     # diffuse alpha (0..255) below which a texel is flat
NEUTRAL = np.array([128, 128, 255], dtype=np.uint8)   # flat normal, +Z


def _luminance(rgb: np.ndarray) -> np.ndarray:
    """Rec.601 luma of an (h,w,3) float array in [0,1]."""
    return (0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2])


def _region_normals(rgb: np.ndarray, alpha: np.ndarray, strength: float,
                    alpha_threshold: int, invert_y: bool) -> np.ndarray:
    """Encode one region's (h,w) heightmap as an (h,w,3) uint8 normal image.

    rgb: (h,w,3) float in [0,1]; alpha: (h,w) uint8. Gradient is computed only
    within this array (region-isolated). Returns tangent-space normals with +Z
    up, OpenGL-style (green = +Y up) unless invert_y flips G for Godot's -Y.
    """
    h, w = alpha.shape
    height = _luminance(rgb)
    # Central-difference gradient, confined to this region (no cross-region reads).
    dy, dx = np.gradient(height)
    nx = -dx * strength
    ny = -dy * strength
    nz = np.ones_like(height)
    inv = 1.0 / np.sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx * inv, ny * inv, nz * inv
    if invert_y:
        ny = -ny
    enc = np.empty((h, w, 3), dtype=np.uint8)
    enc[..., 0] = np.clip((nx * 0.5 + 0.5) * 255.0 + 0.5, 0, 255).astype(np.uint8)
    enc[..., 1] = np.clip((ny * 0.5 + 0.5) * 255.0 + 0.5, 0, 255).astype(np.uint8)
    enc[..., 2] = np.clip((nz * 0.5 + 0.5) * 255.0 + 0.5, 0, 255).astype(np.uint8)
    # Outside the diamond (near-transparent) -> neutral.
    enc[alpha < alpha_threshold] = NEUTRAL
    # 1px region border -> neutral (guard against any edge-gradient bleed).
    enc[0, :] = NEUTRAL
    enc[-1, :] = NEUTRAL
    enc[:, 0] = NEUTRAL
    enc[:, -1] = NEUTRAL
    return enc


def build_normal_atlas(diffuse, strength: float = DEFAULT_STRENGTH,
                       alpha_threshold: int = DEFAULT_ALPHA_THRESHOLD,
                       invert_y: bool = False) -> Image.Image:
    """`diffuse` is a path (str) or an already-loaded PIL Image."""
    src = (Image.open(diffuse) if isinstance(diffuse, str) else diffuse).convert("RGBA")
    if src.size != (ATLAS_W, ATLAS_H):
        raise ValueError("diffuse atlas is %s, expected (%d, %d)"
                         % (src.size, ATLAS_W, ATLAS_H))
    arr = np.asarray(src, dtype=np.uint8)
    rgb = arr[..., :3].astype(np.float32) / 255.0
    alpha = arr[..., 3]

    out = np.empty((ATLAS_H, ATLAS_W, 3), dtype=np.uint8)
    out[:] = NEUTRAL
    for row in range(ROWS):
        for col in range(COLS):
            y0, x0 = row * REGION_H, col * REGION_W
            y1, x1 = y0 + REGION_H, x0 + REGION_W
            reg_alpha = alpha[y0:y1, x0:x1]
            if reg_alpha.max() < alpha_threshold:
                continue  # empty region: leave neutral
            out[y0:y1, x0:x1] = _region_normals(
                rgb[y0:y1, x0:x1], reg_alpha, strength, alpha_threshold, invert_y)
    return Image.fromarray(out, mode="RGB")


def main() -> None:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--in", dest="src", default=os.path.join(
        repo_root, "assets", "tilesets", "terrain_atlas.png"))
    ap.add_argument("--out", default=os.path.join(
        repo_root, "assets", "tilesets", "terrain_atlas_n.png"))
    ap.add_argument("--strength", type=float, default=DEFAULT_STRENGTH)
    ap.add_argument("--alpha-threshold", type=int, default=DEFAULT_ALPHA_THRESHOLD)
    ap.add_argument("--invert-y", action="store_true",
                    help="flip green channel for engines expecting -Y (Godot may want this)")
    args = ap.parse_args()

    atlas = build_normal_atlas(args.src, args.strength, args.alpha_threshold, args.invert_y)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    atlas.save(args.out)
    print("wrote %s (%dx%d) strength=%s" % (args.out, atlas.width, atlas.height, args.strength))


if __name__ == "__main__":
    main()
