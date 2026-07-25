#!/usr/bin/env python3
"""Deterministic tree sprites for Crusade (#249 trees & doodads v2).

Replaces the single lumpy "cauliflower" crown with value-separated, multi-species
foliage that sits on the HD grass ground without merging into it. Four species,
each built as a float DENSITY field (the silhouette) that a shared POINTILLIST
renderer fills with thousands of small leaf dabs -- brightest toward the NW sun and
crown top, darkest in the SE underside -- so the canopy reads as textured 3D
foliage that matches the HD ground, not a flat shape:

  * oak   -- broadleaf: several overlapping clumps, 1-2 sky gaps, a forked trunk.
  * pine  -- conifer: stacked drooping triangular tiers, tall & narrow, darker
             blue-green so it reads as a different hue-family from the oaks.
  * scrub -- low wide bush, several ground-hugging clumps, no real trunk.
  * dead  -- bare branching trunk (brown) with a few sparse dead-leaf tufts.

Separation from grass is by VALUE, not hue: the crown mid-tone (#3f6a2e) sits a
clear step darker than the lush grass (~#5E7A3A/#6B8A42), with an underside core
(#2f4a24) and only a thin sunlit rim (#7a9a48) reaching grass-brightness -- so the
mass squints DARKER than the field it stands on. The silhouette is a ragged,
perlin-displaced foliage edge, not an ellipse. Sun is NW, so every tree bakes a
soft warm SE cast shadow anchored at the trunk base -- keeping Y-sort trivial
(anything SE of the tree sorts later and draws over the shadow).

Layout of assets/doodads/trees.png: VARIANTS cells in a row, CELL_W x CELL_H each,
column order = SPECS. Trunk base sits at ANCHOR in every cell (left-of-centre so
the SE shadow has room). Keep in sync with src/core/tree_catalog.gd.

Fully deterministic (fixed seed). Regenerate:  python3 tools/gen_trees.py
"""

import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SS = 3
CELL_W, CELL_H = 288, 232
ANCHOR = (96, 190)          # trunk-base point in every cell (final px)
SEED = 20260727

# Column layout: (species, size scale). Oak/pine/scrub each at 3 sizes (>=3
# species x 3 sizes, per art-direction), plus one bare/dead tree for variety.
# Variants are scattered UNIFORMLY by DoodadScatter, so keeping dead to a single
# column keeps it rare (~1/10) rather than blighting the meadow.
SPECS = [
    ("oak", 1.00), ("oak", 0.74), ("oak", 0.52),
    ("pine", 1.00), ("pine", 0.74), ("pine", 0.54),
    ("scrub", 0.95), ("scrub", 0.70), ("scrub", 0.50),
    ("dead", 0.85),
]
VARIANTS = len(SPECS)

# Shared warm-dark cast shadow (sun NW -> shadow SE), ~35% opacity.
SHADOW = (0x26, 0x1C, 0x14)
SHADOW_A = 92

GRAD_K = 6.0        # normal-tilt gain: how strongly D slopes shade as lumps
SHARP = 20.0        # silhouette edge crispness after fBm displacement
# Light comes from the NW and slightly above the canvas (screen up-left).
LIGHT = np.array([-0.55, -0.78, 0.62], dtype=np.float32)
LIGHT /= np.linalg.norm(LIGHT)
# SE "downhill" axis for the crown-wide core-shadow tilt (matches the sun).
SED = np.array([0.55, 1.0], dtype=np.float32)
SED /= np.linalg.norm(SED)


def _hex(s):
    s = s.lstrip("#")
    return np.array([int(s[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float32)


PALETTES = {
    "oak":   dict(under=_hex("#2f4a24"), mid=_hex("#3f6a2e"), top=_hex("#7a9a48"),
                  rim=_hex("#9fba58"), trunk=_hex("#4a3826"), trunk_lit=_hex("#6e5638")),
    # Conifer: darker + a step BLUER/cooler than the oaks so species read apart.
    "pine":  dict(under=_hex("#1e3a29"), mid=_hex("#2c5540"), top=_hex("#5f8460"),
                  rim=_hex("#82a46e"), trunk=_hex("#3f3020"), trunk_lit=_hex("#5c472f")),
    # Scrub: a touch drier/olive so it separates from the oak greens.
    "scrub": dict(under=_hex("#33461f"), mid=_hex("#4c6a2c"), top=_hex("#86a050"),
                  rim=_hex("#aabf62"), trunk=_hex("#4a3826"), trunk_lit=_hex("#6e5638")),
    # Dead: no green -- bark browns, separated from grass by hue alone.
    "dead":  dict(under=_hex("#43331f"), mid=_hex("#5f4a30"), top=_hex("#856a44"),
                  rim=_hex("#a2865a"), trunk=_hex("#43331f"), trunk_lit=_hex("#6b5236")),
}


def _fbm(H, W, seed, octaves=4, base_cells=4, persistence=0.5):
    """Deterministic value-noise fBm in [0,1] over an HxW field (bilinear-upsampled
    coarse grids, scaling amplitude by `persistence` / doubling frequency per
    octave -- higher persistence keeps more fine detail)."""
    rng = np.random.default_rng(seed)
    acc = np.zeros((H, W), dtype=np.float32)
    amp, tot, cells = 1.0, 0.0, base_cells
    for _o in range(octaves):
        g = rng.random((cells + 2, cells + 2)).astype(np.float32)
        layer = np.asarray(
            Image.fromarray((g * 255).astype("uint8")).resize((W, H), Image.BILINEAR),
            dtype=np.float32,
        ) / 255.0
        acc += layer * amp
        tot += amp
        amp *= persistence
        cells *= 2
    return acc / tot


def _bump(xs, ys, cx, cy, rx, ry, power=0.75):
    """Soft elliptical density bump: 1 at centre, 0 at the (rx,ry) radius."""
    d = ((xs - cx) / rx) ** 2 + ((ys - cy) / ry) ** 2
    return np.clip(1.0 - d, 0.0, 1.0) ** power


def _crown(img, D, ccx, ccy, span, pal, seed, edge_amp=0.5, gaps=(), rim=165):
    """Render density D as thousands of small leaf DABS -- pointillist foliage.

    Instead of shading D as one smooth normal-mapped surface (which read as a flat
    balloon), we scatter many small leaf dabs inside the ragged silhouette. Each dab
    is coloured by a world-VALUE ramp -- brightest toward the NW sun and the crown
    top, darkest in the SE underside -- and dabs are painted dark-first, so sunlit
    leaves layer over shadowed ones and the mass reads as textured 3D foliage that
    still squints a clear value step DARKER than the grass. Optional `gaps` punch
    sky holes. The `rim` arg is retained for call-site compatibility (the value ramp
    now supplies the NW-top highlight, so no separate rim pass is needed)."""
    H, W = D.shape
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    # Ragged silhouette: crisp the soft density skirt, then bite it with hi-freq
    # noise so the outline is a leaf-mass edge, not a smooth balloon.
    Dc = np.clip((D - 0.34) * 2.7, 0.0, 1.0)
    efbm = _fbm(H, W, seed + 3, octaves=3, base_cells=34, persistence=0.6)
    field = Dc + (efbm - 0.5) * edge_amp
    ragged = np.clip((field - 0.5) * SHARP + 0.5, 0.0, 1.0)
    for (gx, gy, grx, gry) in gaps:
        dd = ((xs - gx) / grx) ** 2 + ((ys - gy) / gry) ** 2
        # Soft sky dip (floor ~0.4), not a punched hole, so gaps read as darker
        # thinning between leaf masses rather than a bite out of the canopy.
        ragged *= np.clip(dd * 1.3 + 0.4, 0.0, 1.0)
    mask = ragged > 0.5

    # Per-pixel leaf VALUE: NW+top bright -> SE+base dark, mottled per leaf-clump so
    # no broad region lights as a single hot disc.
    proj = ((xs - ccx) * SED[0] + (ys - ccy) * SED[1]) / max(span, 1.0)   # - NW .. + SE
    vert = (ccy - ys) / max(span * 1.3, 1.0)
    mott = (0.55 * _fbm(H, W, seed + 17, octaves=3, base_cells=14)
            + 0.45 * _fbm(H, W, seed + 29, octaves=3, base_cells=34, persistence=0.6))
    V = 0.52 - proj * 0.5 + vert * 0.16 + (mott - 0.5) * 0.5
    low = np.clip((ys - (ccy + span * 0.35)) / (span * 0.7), 0.0, 1.0)
    V = np.clip(V - low * 0.14, 0.0, 1.0)

    # Value -> colour ramp (under..mid..top), vectorised over the whole field.
    under, mid, top = pal["under"], pal["mid"], pal["top"]
    lo = (V < 0.5)[..., None]
    tt = np.where(V < 0.5, V / 0.5, (V - 0.5) / 0.5)[..., None]
    cfield = np.where(lo, under + (mid - under) * tt, mid + (top - mid) * tt)

    # 1) SOLID base fill (the smooth value ramp) so the canopy can never pinhole --
    #    the dabs on top are texture, not the only coverage.
    base = np.dstack([np.clip(cfield, 0, 255), ragged * 255.0]).astype("uint8")
    img.alpha_composite(Image.fromarray(base, "RGBA"))

    # 2) Leaf DABS on top: small dabs tinted +/- around the base value give the
    #    pointillist grain over the solid base, painted dark-first.
    idx = np.argwhere(mask)
    if len(idx):
        r = 2.4 * SS
        n = int(len(idx) / (math.pi * r * r) * 1.7)
        n = max(40, min(n, 7000))
        rng = np.random.default_rng(seed + 5)
        pick = rng.integers(0, len(idx), n)
        pv = V[idx[pick, 0], idx[pick, 1]]
        order = np.argsort(pv)                                 # dark first
        jit = rng.uniform(-0.9 * SS, 0.9 * SS, size=(n, 2))
        rad = r * rng.uniform(0.7, 1.15, size=n)
        bright = rng.uniform(0.80, 1.16, size=n)               # per-leaf value jitter
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        for k in order:
            py, px = idx[pick[k]]
            col = np.clip(cfield[py, px] * bright[k], 0, 255)
            cx = float(px) + jit[k, 1]; cy = float(py) + jit[k, 0]; rr = rad[k]
            d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr],
                      fill=tuple(int(c) for c in col) + (235,))
        la = np.asarray(layer, dtype=np.float32)
        la[..., 3] *= ragged                                   # keep grain inside silhouette
        img.alpha_composite(Image.fromarray(la.astype("uint8"), "RGBA"))


def _paste_shadow(img, ax, ay, half_w, length):
    """Soft warm elliptical cast shadow to the SE, anchored at the trunk base."""
    W, H = img.size
    sh = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    cx, cy = ax + length * 0.42, ay + length * 0.11
    sd.ellipse([cx - length * 0.55, cy - half_w * 0.5, cx + length * 0.55, cy + half_w * 0.5],
               fill=SHADOW + (SHADOW_A,))
    sh = sh.rotate(-14, center=(ax, ay), resample=Image.BILINEAR)
    sh = sh.filter(ImageFilter.GaussianBlur(6 * SS))
    img.alpha_composite(sh)


def _trunk(img, ax, ay, top_y, half_w, pal):
    """A tapered trunk from the base up to `top_y`, lit on the NW face."""
    d = ImageDraw.Draw(img)
    tw = half_w
    d.polygon([(ax - tw, ay), (ax + tw, ay), (ax + tw * 0.7, top_y), (ax - tw * 0.7, top_y)],
              fill=tuple(pal["trunk"].astype(int)) + (255,))
    d.polygon([(ax - tw, ay), (ax - tw * 0.15, ay), (ax - tw * 0.12, top_y), (ax - tw * 0.7, top_y)],
              fill=tuple(pal["trunk_lit"].astype(int)) + (255,))


# ---------------------------------------------------------------- species ----

def _build_oak(img, ax, ay, s, pal, seed, rng):
    W, H = img.size
    cw, ch = 86 * s * SS, 74 * s * SS          # crown half-extents
    trunk_h = 24 * s * SS
    top_y = ay - trunk_h
    # Forked trunk: a short bole that splits into two limbs entering the crown.
    tw = max(3 * SS, 7 * s * SS)
    _trunk(img, ax, ay, top_y + ch * 0.35, tw, pal)
    d = ImageDraw.Draw(img)
    for sgn in (-1, 1):
        lx = ax + sgn * cw * 0.28
        d.line([(ax, top_y + ch * 0.30), (lx, top_y - ch * 0.15)],
               fill=tuple(pal["trunk"].astype(int)) + (255,), width=int(tw * 1.1))

    ccx, ccy = ax, top_y - ch * 0.55
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    D = np.zeros((H, W), dtype=np.float32)
    # A ring of overlapping sub-masses around the upper crown (no single dominant
    # smooth bump -> the highlight scatters into per-clump leaf tops).
    n = rng.randint(6, 7)
    for i in range(n):
        a = math.pi * (1.02 + 0.96 * i / max(n - 1, 1)) + rng.uniform(-0.14, 0.14)
        dist = cw * rng.uniform(0.34, 0.6)
        lx = ccx + math.cos(a) * dist
        ly = ccy + math.sin(a) * dist * 0.72 - ch * 0.1
        lr = cw * rng.uniform(0.32, 0.44)
        D = np.maximum(D, _bump(xs, ys, lx, ly, lr, lr * 0.92, 0.7))
    # a modest lower-central filler + two lower flank clumps
    D = np.maximum(D, _bump(xs, ys, ccx, ccy + ch * 0.28, cw * 0.44, ch * 0.46, 0.7))
    for sgn in (-1, 1):
        D = np.maximum(D, _bump(xs, ys, ccx + sgn * cw * 0.52, ccy + ch * 0.42,
                                cw * 0.32, ch * 0.34, 0.7))
    # 1-2 sky gaps high in the canopy: punched near the upper silhouette so they
    # read as breaks between leaf masses, not holes in the middle of the mass.
    gaps = []
    for _i in range(rng.randint(1, 2)):
        gx = ccx + rng.uniform(-0.4, 0.4) * cw
        gy = ccy - rng.uniform(0.1, 0.45) * ch
        gr = cw * rng.uniform(0.13, 0.2)
        gaps.append((gx, gy, gr, gr * 0.8))
    _crown(img, D, ccx, ccy, ch * 1.35, pal, seed, edge_amp=0.55, gaps=gaps)


def _build_pine(img, ax, ay, s, pal, seed, rng):
    W, H = img.size
    total_h = 150 * s * SS
    maxhw = 42 * s * SS
    apex = ay - 10 * s * SS - total_h
    base_y = ay - 4 * SS
    tw = max(3 * SS, 5 * s * SS)
    _trunk(img, ax, ay, base_y - total_h * 0.05, tw, pal)

    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    D = np.zeros((H, W), dtype=np.float32)
    tiers = 5
    for i in range(tiers):
        f0 = i / tiers
        f1 = (i + 1) / tiers
        a_y = apex + (base_y - apex) * f0 * 0.86            # this tier's apex
        b_y = apex + (base_y - apex) * (f1 + 0.04)          # this tier's droop base
        hw = maxhw * (0.30 + 0.78 * f1)
        span = max(b_y - a_y, 1.0)
        frac = np.clip((ys - a_y) / span, 0.0, 1.0)
        half = hw * frac
        inside = (ys >= a_y) & (ys <= b_y) & (np.abs(xs - ax) <= np.maximum(half, 1.0))
        # High along the tier apex ridge, falling to ~0.5 at the drooping base, so
        # the shader carves a shadow trough under every tier -> layered look.
        val = np.where(inside, 1.0 - 0.5 * frac, 0.0).astype(np.float32)
        D = np.maximum(D, val)
    ccx, ccy = ax, apex + total_h * 0.45
    _crown(img, D, ccx, ccy, total_h * 0.55, pal, seed, edge_amp=0.42, rim=150)


def _build_scrub(img, ax, ay, s, pal, seed, rng):
    W, H = img.size
    cw, ch = 62 * s * SS, 40 * s * SS
    # barely-there stubby trunk
    _trunk(img, ax, ay, ay - ch * 0.5, max(2 * SS, 5 * s * SS), pal)
    ccx, ccy = ax, ay - ch * 0.8
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    D = np.zeros((H, W), dtype=np.float32)
    D = np.maximum(D, _bump(xs, ys, ccx, ccy + ch * 0.2, cw * 0.7, ch * 0.75, 0.7))
    n = rng.randint(4, 6)
    for i in range(n):
        a = math.pi * (0.12 + 0.76 * i / max(n - 1, 1))
        lx = ccx + math.cos(a) * cw * 0.55
        ly = ccy - math.sin(a) * ch * 0.55 + ch * 0.05
        lr = cw * rng.uniform(0.3, 0.4)
        D = np.maximum(D, _bump(xs, ys, lx, ly, lr, lr * 0.9, 0.7))
    _crown(img, D, ccx, ccy, ch * 1.5, pal, seed, edge_amp=0.6, rim=170)


def _draw_branch(d, x, y, ang, length, width, pal, depth, rng):
    if depth <= 0 or length < 4 * SS:
        return
    x2 = x + math.cos(ang) * length
    y2 = y - math.sin(ang) * length
    lit = math.cos(ang) < 0 or math.sin(ang) > 0.4      # NW/up faces catch light
    col = tuple((pal["trunk_lit"] if lit else pal["trunk"]).astype(int)) + (255,)
    d.line([(x, y), (x2, y2)], fill=col, width=max(1, int(width)))
    branches = rng.randint(2, 3)
    for _i in range(branches):
        na = ang + rng.uniform(-0.7, 0.7)
        _draw_branch(d, x2, y2, na, length * rng.uniform(0.62, 0.78),
                     width * 0.66, pal, depth - 1, rng)


def _build_dead(img, ax, ay, s, pal, seed, rng):
    W, H = img.size
    d = ImageDraw.Draw(img)
    trunk_h = 60 * s * SS
    top_y = ay - trunk_h
    _trunk(img, ax, ay, top_y, max(3 * SS, 8 * s * SS), pal)
    # Branch out from a couple of nodes up the bole.
    for frac in (0.55, 0.8, 1.0):
        bx, by = ax, ay - trunk_h * frac
        for _i in range(rng.randint(2, 3)):
            ang = rng.uniform(0.35, math.pi - 0.35)
            _draw_branch(d, bx, by, ang, trunk_h * rng.uniform(0.32, 0.5),
                         6 * s * SS, pal, 3, rng)
    # A few sparse ochre dead-leaf tufts clinging to the crown.
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    D = np.zeros((H, W), dtype=np.float32)
    for _i in range(rng.randint(3, 5)):
        lx = ax + rng.uniform(-0.5, 0.5) * 46 * s * SS
        ly = top_y - rng.uniform(-0.1, 0.5) * 40 * s * SS
        lr = rng.uniform(0.16, 0.26) * 46 * s * SS
        D = np.maximum(D, _bump(xs, ys, lx, ly, lr, lr * 0.85, 0.8) * rng.uniform(0.7, 0.9))
    _crown(img, D, ax, top_y - 20 * s * SS, 40 * s * SS, pal, seed,
           edge_amp=0.7, rim=130)


_BUILD = {"oak": _build_oak, "pine": _build_pine, "scrub": _build_scrub, "dead": _build_dead}
# Cast-shadow footprint (half-width, length) as multiples of the size scale.
_SHADOW_FOOT = {"oak": (0.62, 1.9), "pine": (0.30, 1.35), "scrub": (0.55, 1.5), "dead": (0.34, 1.7)}


def _draw_tree(variant, rng):
    species, s = SPECS[variant]
    W, H = CELL_W * SS, CELL_H * SS
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ax, ay = ANCHOR[0] * SS, ANCHOR[1] * SS
    hw_f, ln_f = _SHADOW_FOOT[species]
    _paste_shadow(img, ax, ay, 92 * s * SS * hw_f, 150 * s * SS * ln_f)
    _BUILD[species](img, ax, ay, s, PALETTES[species], SEED + variant, rng)
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
    sheet = build_sheet()
    sheet.save(out)
    print("wrote %s (%dx%d, %d variants)" % (out, sheet.width, sheet.height, VARIANTS))


if __name__ == "__main__":
    main()
