#!/usr/bin/env python3
"""Deterministic tree sprites for Crusade (#234 art, SC1 convergence).

Top-down-ish isometric canopy trees. The crown is built as ONE unified
silhouette (union of lobes -> single organic hull with concave edge notches),
shaded by ONE top-down gradient across the whole crown (lit NW-top -> mid ->
core-shadow SE-bottom, lower 45% multiplied down) rather than per-lobe circular
shading -- discrete per-lobe balls + polka-dot highlights read as a bunch of
grapes, not a tree (lead-artist note). Interior clumpiness comes from low-
contrast hard value-noise; a single NW sun rim separates each crown from its
neighbours. A long soft SE cast shadow is baked in (sun NW) so Y-sorting stays
trivially correct: anything SE of the tree sorts later and draws over the shadow.

Layout of assets/doodads/trees.png: 4 variants in a row, CELL_W x CELL_H each.
Trunk base sits at ANCHOR in every cell -- keep in sync with src/core/tree_catalog.gd.

Fully deterministic (fixed seed). Regenerate:  python3 tools/gen_trees.py
"""

import math
import os
import random

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 2
CELL_W, CELL_H = 288, 232
ANCHOR = (96, 190)          # trunk-base point in every cell (final px)
VARIANTS = 4
SEED = 20260727

SHADOW = (0x1E, 0x23, 0x34)
LIT = np.array([0x7F, 0xA0, 0x3A], dtype=np.float32)      # NW-top
MID = np.array([0x56, 0x7A, 0x2C], dtype=np.float32)
CORE = np.array([0x3A, 0x52, 0x20], dtype=np.float32)     # SE-bottom shadow
RIM = (0xA9, 0xC0, 0x4F)
TRUNK = (0x4A, 0x38, 0x26)
TRUNK_LIT = (0x6E, 0x56, 0x38)

# Per-variant: canopy radius (final px), lobe count, trunk visible height.
SPECS = [
    (86, 9, 16),   # hero oak
    (78, 8, 14),   # oak 2
    (58, 7, 12),   # medium
    (38, 5, 10),   # shrub-tree
]


def _canopy_mask(ccx, ccy, r, lobes, rng):
    """Union-of-lobes silhouette -> one organic hull, softened + thresholded,
    then bitten by a few concave edge notches so it isn't a smooth dome."""
    W, H = CELL_W * SS, CELL_H * SS
    mask = Image.new("L", (W, H), 0)
    md = ImageDraw.Draw(mask)
    md.ellipse([ccx - r * 0.74, ccy - r * 0.66, ccx + r * 0.74, ccy + r * 0.68], fill=255)
    for i in range(lobes):
        a = 2 * math.pi * i / lobes + rng.uniform(-0.2, 0.2)
        dist = r * rng.uniform(0.4, 0.56)
        lr = r * rng.uniform(0.36, 0.5)
        lx, ly = ccx + math.cos(a) * dist, ccy + math.sin(a) * dist * 0.82
        md.ellipse([lx - lr, ly - lr, lx + lr, ly + lr], fill=255)
    for _i in range(rng.randint(1, 2)):        # taller top lobes
        lx = ccx + rng.uniform(-0.3, 0.3) * r
        ly = ccy - r * rng.uniform(0.55, 0.82)
        lr = r * rng.uniform(0.3, 0.42)
        md.ellipse([lx - lr, ly - lr, lx + lr, ly + lr], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(2 * SS))
    mask = mask.point(lambda v: 255 if v > 110 else 0)
    md = ImageDraw.Draw(mask)
    for _i in range(rng.randint(3, 4)):        # edge notches (nibble the outline)
        a = rng.uniform(0.0, 2 * math.pi)
        ex, ey = ccx + math.cos(a) * r * 1.02, ccy + math.sin(a) * r * 0.9
        nr = r * rng.uniform(0.14, 0.26)
        md.ellipse([ex - nr, ey - nr, ex + nr, ey + nr], fill=0)
    return mask


def _draw_tree(variant, rng):
    radius, lobes, trunk_h = SPECS[variant]
    W, H = CELL_W * SS, CELL_H * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ax, ay = ANCHOR[0] * SS, ANCHOR[1] * SS
    r = radius * SS

    # --- Long soft SE cast shadow (baked golden-hour signature). ---
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    ln, sw = 1.6 * 2 * r, 0.62 * r
    cxs, cys = ax + ln * 0.42, ay + ln * 0.105
    sd.ellipse([cxs - ln * 0.55, cys - sw * 0.5, cxs + ln * 0.55, cys + sw * 0.5], fill=SHADOW + (96,))
    sh = sh.rotate(-14, center=(ax, ay), resample=Image.BILINEAR).filter(ImageFilter.GaussianBlur(6 * SS))
    img.alpha_composite(sh)

    # --- Trunk. ---
    d = ImageDraw.Draw(img)
    tw = max(4 * SS, r // 7)
    ty0 = ay - trunk_h * SS - r * 0.5
    d.polygon([(ax - tw, ay), (ax + tw, ay), (ax + tw * 0.7, ty0), (ax - tw * 0.7, ty0)], fill=TRUNK + (255,))
    d.polygon([(ax - tw, ay), (ax - tw * 0.2, ay), (ax - tw * 0.15, ty0), (ax - tw * 0.7, ty0)], fill=TRUNK_LIT + (255,))

    # --- Unified canopy: one silhouette, one crown-wide gradient. ---
    ccx, ccy = ax, ay - trunk_h * SS - r * 0.72
    mask = _canopy_mask(ccx, ccy, r, lobes, rng)
    marr = np.asarray(mask, dtype=np.float32) / 255.0
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    sed = np.array([0.55, 1.0], dtype=np.float32)
    sed /= np.linalg.norm(sed)
    proj = ((xs - ccx) * sed[0] + (ys - ccy) * sed[1]) / (r * 1.5)
    t = np.clip(proj * 0.5 + 0.5, 0.0, 1.0)[..., None]
    shade = np.where(t < 0.5, LIT + (MID - LIT) * (t * 2.0), MID + (CORE - MID) * ((t - 0.5) * 2.0))
    nrng = np.random.default_rng(SEED + variant)
    small = nrng.random((H // (6 * SS) + 2, W // (6 * SS) + 2)).astype(np.float32)
    noise = np.asarray(Image.fromarray((small * 255).astype("uint8")).resize((W, H), Image.BILINEAR), dtype=np.float32) / 255.0
    shade *= (1.0 + (noise[..., None] - 0.5) * 0.12)
    ymask = marr > 0.5
    if ymask.any():
        yrows = np.where(ymask.any(axis=1))[0]
        y0, y1 = float(yrows[0]), float(yrows[-1])
        low = np.clip((ys - (y0 + 0.55 * (y1 - y0))) / (0.25 * (y1 - y0) + 1.0), 0.0, 1.0)
        shade *= (1.0 - low[..., None] * 0.40)
    shade = np.clip(shade, 0, 255)
    canopy = np.dstack([shade, marr * 255.0]).astype("uint8")
    img.alpha_composite(Image.fromarray(canopy, "RGBA"))

    # --- Single NW-top sun rim on the unified silhouette. ---
    d = ImageDraw.Draw(img)
    eroded = mask.filter(ImageFilter.MinFilter(2 * SS + 1))
    edge = np.asarray(ImageChops.subtract(mask, eroded), dtype=np.float32) / 255.0
    nw = np.clip(0.5 - proj * 0.5, 0.0, 1.0)      # 1 at NW, 0 at SE
    rim_a = (edge * nw * 175.0).astype("uint8")
    rim_img = np.zeros((H, W, 4), dtype="uint8")
    rim_img[..., 0], rim_img[..., 1], rim_img[..., 2] = RIM
    rim_img[..., 3] = rim_a
    img.alpha_composite(Image.fromarray(rim_img, "RGBA"))
    for _i in range(max(3, lobes)):
        a = rng.uniform(math.pi * 1.0, math.pi * 1.5)
        dist = r * rng.uniform(0.25, 0.7)
        sx, sy = ccx + math.cos(a) * dist, ccy + math.sin(a) * dist * 0.8
        px = int(min(max(sx, 0), W - 1))
        py = int(min(max(sy, 0), H - 1))
        if mask.getpixel((px, py)) == 0:
            continue
        sr = rng.uniform(1.0, 2.0) * SS
        d.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=(0x92, 0xAE, 0x50, 60))

    return img.resize((CELL_W, CELL_H), Image.LANCZOS)


def build_sheet():
    sheet = Image.new("RGBA", (CELL_W * VARIANTS, CELL_H), (0, 0, 0, 0))
    for v in range(VARIANTS):
        sheet.paste(_draw_tree(v, random.Random(SEED + v * 31)), (v * CELL_W, 0))
    return sheet


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(repo_root, "assets", "doodads", "trees.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    build_sheet().save(out)
    print("wrote %s" % out)


if __name__ == "__main__":
    main()
