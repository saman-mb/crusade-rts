#!/usr/bin/env python3
"""Deterministic cliff-face artwork for Crusade (#235 art pass).

Replaces the flat Polygon2D cliff walls with real rocky artwork. Each raised
tier's front (SE / SW) edge cell shows one pre-skewed parallelogram face piece;
the pieces are 64px-wide crops of ONE horizontally-PERIODIC rock strip (per
direction), indexed by posmod(x+y, 8) at runtime -- consecutive cells along a
wall chain are consecutive crops, so strata and cracks flow continuously along
the whole wall exactly like the terrain mega-tiles flow across the ground.

Art spec (lead artist): warm earthen rock, top-lit -> base-dark gradient
(#96805C -> #5C4A34 -> #3A2E20), 2 broken jagged strata bands, hairline cracks
with a lit upper-left rim, an irregular bottom silhouette, a sunlit grass lip
with overhanging tufts breaking the top edge, and a boulder-cluster corner cap
so the prism point never shows.

Layout of assets/cliffs/cliffs.png (PIECE_W x PIECE_H cells):
  row 0: 8 SE face pieces   row 1: 8 SW face pieces   row 2, col 0: corner cap
Geometry per piece (canvas coords, top edge slope matches the 2:1 diamond):
  SE: top edge (64, TOP) -> (0, TOP+32);  SW: top edge (0, TOP) -> (64, TOP+32)
  extruded FACE_H px straight down; silhouette noise extends a few px below.

Fully deterministic (fixed seed). Regenerate:  python3 tools/gen_cliffs.py
Keep in sync with src/core/cliff_catalog.gd.
"""

import math
import os
import random

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

SS = 2                      # supersample
PIECE_W, PIECE_H = 64, 144  # per-piece canvas (final px; fits the 64px tall faces)
TOP = 20                    # px above the top edge reserved for tufts/lip
FACE_H = 32                 # one tier of wall
PIECES = 8                  # crops per direction (periodic along the wall)
SEED = 20260725

ROCK_TOP = (0xAC, 0x94, 0x6C)
ROCK_MID = (0x92, 0x78, 0x58)
ROCK_LOW = (0x70, 0x5A, 0x42)
ROCK_BASE = (0x4A, 0x3B, 0x2B)
STRATA = (0x4E, 0x3D, 0x2A)
STRATA_LIGHT = (0x8A, 0x74, 0x58)
CRACK = (0x45, 0x36, 0x24)
CRACK_RIM = (0xA8, 0x90, 0x6A)
LIP = (0xA5, 0x8A, 0x55)
TUFT_LIT = (0x7E, 0x9C, 0x4C)
TUFT_DARK = (0x45, 0x60, 0x2E)


def _grad(t, stops):
    """Piecewise-linear colour ramp over stops [(pos, rgb), ...] for t in 0..1."""
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        if t <= p1 or i == len(stops) - 2:
            f = 0.0 if p1 == p0 else max(0.0, min(1.0, (t - p0) / (p1 - p0)))
            return tuple(int(c0[k] + (c1[k] - c0[k]) * f) for k in range(3))
    return stops[-1][1]


def _face_strip(is_se, rng):
    """One periodic rock strip: PIECES*64 wide, drawn at SS, wrapped noise.

    The strip is drawn in "face plane" space (u = along-wall px, v = down-face
    px in 0..FACE_H) then sheared per-piece when cut, so strata stay parallel to
    the top edge and the texture wraps at the strip ends (period = PIECES*64)."""
    W = PIECES * PIECE_W * SS
    H = (FACE_H + 14) * SS   # face + silhouette overhang zone
    strip = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    px = strip.load()
    period = W
    # Wrapped per-column jitter for silhouette + shade.
    ncols = 64
    col_noise = [rng.uniform(-1.0, 1.0) for _i in range(ncols)]

    def noise_at(u, cells):
        f = (u / period) * cells
        i0 = int(f) % cells
        i1 = (i0 + 1) % cells
        fr = f - int(f)
        fr = fr * fr * (3 - 2 * fr)
        return col_noise[i0 % ncols] * (1 - fr) + col_noise[i1 % ncols] * fr

    stops = [(0.0, ROCK_TOP), (0.35, ROCK_MID), (0.72, ROCK_LOW), (1.0, ROCK_BASE)]
    sil_amp = 5.0 * SS
    for x in range(W):
        sil = FACE_H * SS + sil_amp * (0.5 + 0.5 * noise_at(x, 20)) + \
            2.0 * SS * math.sin(x * 0.11 / SS)
        shade = 1.0 + 0.08 * noise_at(x + period / 3.0, 12)
        for y in range(H):
            v = y / (FACE_H * SS)
            if y > sil:
                continue
            c = _grad(min(v, 1.0), stops)
            c = tuple(min(255, int(ch * shade)) for ch in c)
            px[x, y] = c + (255,)
    d = ImageDraw.Draw(strip)
    # Broken jagged strata bands at ~35% / ~70% height.
    for band_v, seg_seed, band_col in ((0.18, 4, STRATA_LIGHT), (0.35, 1, STRATA), (0.50, 3, (0x8F, 0x74, 0x43)), (0.62, 5, STRATA_LIGHT), (0.78, 2, STRATA), (0.90, 6, (0x8F, 0x74, 0x43))):
        srng = random.Random(SEED + seg_seed + (100 if is_se else 200))
        u = 0
        while u < W:
            seg = srng.randint(30, 90) * SS
            gap = srng.randint(12, 40) * SS
            y0 = band_v * FACE_H * SS + srng.uniform(-2, 2) * SS
            d.line([(u, y0), (min(u + seg, W), y0 + srng.uniform(-2, 2) * SS)],
                   fill=band_col + (210,), width=max(1, int(1.4 * SS)))
            u += seg + gap
    # Hairline cracks with a lit rim on the upper-left.
    crng = random.Random(SEED + (11 if is_se else 22))
    for _i in range(PIECES * 3):
        u = crng.uniform(0, W)
        v0 = crng.uniform(0.05, 0.5) * FACE_H * SS
        ln = crng.uniform(0.15, 0.35) * FACE_H * SS
        pts = [(u, v0)]
        vv = v0
        while vv < v0 + ln:
            vv += crng.uniform(3, 7) * SS
            u += crng.uniform(-2.5, 2.5) * SS
            pts.append((u, vv))
        d.line([(p[0] - 0.8 * SS, p[1] - 0.8 * SS) for p in pts[:2]],
               fill=CRACK_RIM + (160,), width=max(1, SS))
        d.line(pts, fill=CRACK + (140,), width=max(1, int(crng.uniform(1.0, 1.8) * SS)))
        if crng.random() < 0.5 and len(pts) > 2:
            fx, fy = pts[len(pts) // 2]
            d.line([(fx, fy), (fx + crng.uniform(-8, 8) * SS, fy + crng.uniform(4, 10) * SS)],
                   fill=CRACK + (150,), width=max(1, SS))
    # Strip-wide value blotches: an irregular +/-6L wash across the WHOLE strip
    # (wrapped), so no tonal frequency aligns with the 64px piece cut -- kills
    # the "fence plank" read. Then desaturate toward grey-brown rock.
    brng = random.Random(SEED + (7 if is_se else 8))
    blotch = Image.new("L", (W, strip.height), 128)
    bd = ImageDraw.Draw(blotch)
    for _i in range(90):
        bx = brng.uniform(0, W)
        by = brng.uniform(0, strip.height)
        br = brng.uniform(8, 30) * SS
        val = brng.randint(108, 148)
        for wrap in (-W, 0, W):
            bd.ellipse([bx + wrap - br, by - br * 0.6, bx + wrap + br, by + br * 0.6], fill=val)
    blotch = blotch.filter(ImageFilter.GaussianBlur(3 * SS))
    r2, g2, b2, a2 = strip.split()
    import numpy as _np
    arr = _np.asarray(strip, dtype=_np.float32)
    bl = (_np.asarray(blotch, dtype=_np.float32) - 128.0) / 128.0 * 0.12
    for ch in range(3):
        arr[..., ch] = _np.clip(arr[..., ch] * (1.0 + bl), 0, 255)
    strip = Image.fromarray(arr.astype("uint8"), "RGBA")
    strip = Image.merge("RGBA", (*ImageEnhance.Color(strip.convert("RGB")).enhance(0.85).split(), a2))
    return strip


def _shear_piece(strip, piece, is_se):
    """Cuts piece `piece` from the strip (WITH wrapped padding, so adjacent
    pieces share edge pixels exactly -- two anti-aliased sprite edges butting
    would otherwise draw a hairline at every piece boundary) and shears it onto
    the diamond edge slope: SE top edge falls down-left (right end high), SW the
    mirror. Returns the padded supersampled canvas plus the pad; the caller
    downsamples and crops the centre PIECE_W x PIECE_H."""
    w = PIECE_W * SS
    pad = 2 * SS
    tiled = Image.new("RGBA", (strip.width * 3, strip.height), (0, 0, 0, 0))
    for i in range(3):
        tiled.paste(strip, (i * strip.width, 0))
    x0 = strip.width + piece * w - pad
    src = tiled.crop((x0, 0, x0 + w + 2 * pad, strip.height))
    canvas = Image.new("RGBA", (w + 2 * pad, PIECE_H * SS), (0, 0, 0, 0))
    for x in range(w + 2 * pad):
        # Column x maps to piece-local position (x - pad); t may run slightly
        # outside [0,1] for padding columns, extending the shear linearly.
        t = (w - 1 - (x - pad)) / (w - 1) if is_se else (x - pad) / (w - 1)
        dy = int(TOP * SS + t * 32 * SS)
        col = src.crop((x, 0, x + 1, src.height))
        canvas.paste(col, (x, max(0, dy)))
    return canvas, pad


def _decorate_piece(canvas, piece, is_se, rng, pad=0):
    """Sunlit lip + overhanging grass tufts along the (sheared) top edge."""
    d = ImageDraw.Draw(canvas)
    w = PIECE_W * SS

    def edge_y(x):
        t = (w - 1 - (x - pad)) / (w - 1) if is_se else (x - pad) / (w - 1)
        return TOP * SS + t * 32 * SS

    # Lip drawn across the padding too, so it stays continuous across pieces.
    pts = [(x, edge_y(x)) for x in range(0, w + 2 * pad, max(1, SS))]
    d.line(pts, fill=LIP + (235,), width=max(2, int(1.8 * SS)))
    # Tufts: irregular clumps HANGING over the face (not sitting on the lip like
    # hedge balls): random spacing with occasional pairs and bare stretches,
    # widths 3-10px, drooping 4-9px down the rock.
    if rng.random() < 0.8:
        n = rng.randint(1, 4)
        for _i in range(n):
            x0 = pad + rng.uniform(3 * SS, w - 5 * SS)
            y0 = edge_y(int(x0))
            tw = rng.uniform(3, 10) * SS
            th = rng.uniform(4, 9) * SS
            d.ellipse([x0 - tw, y0 - th * 0.2, x0 + tw, y0 + th],
                      fill=TUFT_DARK + (225,))
            d.ellipse([x0 - tw * 0.8, y0 - th * 0.3, x0 + tw * 0.6, y0 + th * 0.5],
                      fill=TUFT_LIT + (225,))
            if rng.random() < 0.4:
                d.ellipse([x0 + tw * 0.5, y0, x0 + tw * 1.3, y0 + th * 0.7],
                          fill=TUFT_DARK + (200,))
    return canvas


def _corner_cap(rng):
    """Boulder cluster hiding the razor prism point where SE and SW walls meet."""
    s = 56 * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, base = s / 2, s * 0.72
    d.ellipse([cx - 22 * SS, base - 6 * SS, cx + 22 * SS, base + 10 * SS], fill=(0, 0, 0, 70))
    for i, (ox, oy, r) in enumerate(((-10, 2, 12), (10, 4, 10), (0, -6, 13), (-2, 8, 8))):
        g = 0.85 + 0.1 * math.sin(i * 2.1)
        c = tuple(min(255, int(ch * g)) for ch in ROCK_MID)
        hi = tuple(min(255, int(ch * g * 1.35)) for ch in ROCK_TOP)
        x, y, rr = cx + ox * SS, base + oy * SS - 8 * SS, r * SS
        d.ellipse([x - rr, y - rr * 0.8, x + rr, y + rr * 0.8], fill=c + (255,))
        d.ellipse([x - rr * 0.55, y - rr * 0.62, x + rr * 0.1, y - rr * 0.05], fill=hi + (200,))
    return img.resize((56, 56), Image.LANCZOS)


def build_sheet():
    global FACE_H
    rng = random.Random(SEED)
    sheet = Image.new("RGBA", (PIECES * PIECE_W, 5 * PIECE_H), (0, 0, 0, 0))
    # Rows 0/1: single-tier 32px faces. Rows 3/4: TALL 64px faces used where two
    # tiers stack at the same cells, so a sheer 2-tier wall is ONE artwork with
    # continuous strata instead of two parallel "fences" (lead-artist note).
    for row, is_se, face_h in ((0, True, 32), (1, False, 32), (3, True, 64), (4, False, 64)):
        FACE_H = face_h
        strip = _face_strip(is_se, random.Random(SEED + (row % 3)))
        # SW faces sit ~8% darker/warmer than SE (sky-fill split, lead artist).
        if not is_se:
            r, g, b, a = strip.split()
            r = r.point(lambda v: int(v * 0.96))
            g = g.point(lambda v: int(v * 0.90))
            b = b.point(lambda v: int(v * 0.86))
            strip = Image.merge("RGBA", (r, g, b, a))
        for piece in range(PIECES):
            canvas, pad = _shear_piece(strip, piece, is_se)
            canvas = _decorate_piece(canvas, piece, is_se, random.Random(SEED + row * 50 + piece), pad)
            padf = pad // SS
            small = canvas.resize((PIECE_W + 2 * padf, PIECE_H), Image.LANCZOS)
            tile = small.crop((padf, 0, padf + PIECE_W, PIECE_H))
            sheet.paste(tile, (piece * PIECE_W, row * PIECE_H))
    FACE_H = 32
    sheet.paste(_corner_cap(rng), (0, 2 * PIECE_H))
    return sheet


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(repo_root, "assets", "cliffs", "cliffs.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    build_sheet().save(out)
    print("wrote %s" % out)


if __name__ == "__main__":
    main()
