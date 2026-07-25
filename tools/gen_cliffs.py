#!/usr/bin/env python3
"""Deterministic cliff-face artwork for Crusade (#248 Cliffs v2).

Replaces the flat Polygon2D cliff walls with real rocky artwork. Each raised
tier's front (SE / SW) edge cell shows one pre-skewed parallelogram face piece;
the pieces are 64px-wide crops of ONE horizontally-PERIODIC rock strip (per
direction), indexed by posmod(x+y, 8) at runtime -- consecutive cells along a
wall chain are consecutive crops, so strata and cracks flow continuously along
the whole wall exactly like the terrain mega-tiles flow across the ground.

Art spec (#248, art-director): warm GREY sandstone (NOT the old brown
"chocolate-bar" paint), so the rock reads as a different material from the brown
dirt paths and separates from the grass by VALUE. A CC0 HD photo texture
(rock_boulder_dry, Poly Haven) is high-passed to a warm-grey rock GRAIN and
composited UNDER a top-lit palette gradient with a strict lip:face:base value
ratio ~ 100:60:35:
    top lip / rim  #b8a884   upper face #8a7f6e   mid #6a6052   base/AO #45403a
Over that: 3-5 HORIZONTAL sedimentary strata (each 8-16px, +/-6% value step, a
2-4px inner overhang shadow under each band lip), vertical fracture cracks every
40-70px (dark core + a sun-side lit rim), and a lush grass sod cap drooping over
each top lip. SW faces sit a touch darker (sky-fill split).

Layout of assets/cliffs/cliffs.png (PIECE_W x PIECE_H cells):
  row 0: 8 SE face pieces   row 1: 8 SW face pieces   row 2, col 0: corner cap
  rows 3/4: the same but TALL (64px, two-tier merged) faces
Geometry per piece (canvas coords, top edge slope matches the 2:1 diamond):
  SE: top edge (64, TOP) -> (0, TOP+32);  SW: top edge (0, TOP) -> (64, TOP+32)
  extruded FACE_H px straight down; silhouette noise extends a few px below.

Fully deterministic (fixed seed). Regenerate:  python3 tools/gen_cliffs.py
Keep in sync with src/core/cliff_catalog.gd.
"""

import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

SS = 2                      # supersample
PIECE_W, PIECE_H = 64, 144  # per-piece canvas (final px; fits the 64px tall faces)
TOP = 20                    # px above the top edge reserved for tufts/lip
FACE_H = 32                 # one tier of wall
PIECES = 8                  # crops per direction (periodic along the wall)
SEED = 20260725

# Warm-grey sandstone palette (art-director #248). Value ratio top:mid:base ~
# 100:60:35 (0xb8=184 -> 0x6a=106 -> 0x45=69), all low-saturation grey.
LIP_RIM = (0xB8, 0xA8, 0x84)    # sunlit top rim (brightest)
FACE_UP = (0x8A, 0x7F, 0x6E)    # upper face band
FACE_MID = (0x76, 0x6B, 0x5C)   # mid face (opens the value spread to ~60%)
FACE_BASE = (0x38, 0x33, 0x2E)  # base / ground-contact AO (darkest, ~35%)
CRACK_CORE = (0x2E, 0x2A, 0x24) # fracture core + inner overhang shadow
CRACK_RIM = (0xB6, 0xA8, 0x88)  # sun-side (upper-left) lit rim of a fracture
# Grass sod cap -- matches the ground grass blades (pack_terrain_atlas.py).
GRASS_MID = (0x5E, 0x7A, 0x3A)
GRASS_LIT = (0x7E, 0x9C, 0x4C)
GRASS_DARK = (0x45, 0x60, 0x2E)

# HD rock grain source (CC0 Poly Haven; see assets/tilesets/sources/SOURCE.txt).
HD_ROCK_SRC = "rock_boulder_dry.png"
GRAIN_STRENGTH = 0.55       # how hard the HD tooth modulates the palette value
FACE_MAX_SAT = 0.85         # global desaturate so it reads GREY rock, not brown


def _repo_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _grad_color(v, stops):
    """Piecewise-linear colour ramp over stops [(pos, rgb), ...] for v in 0..1."""
    v = max(0.0, min(1.0, v))
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        if v <= p1 or i == len(stops) - 2:
            f = 0.0 if p1 == p0 else max(0.0, min(1.0, (v - p0) / (p1 - p0)))
            return tuple(c0[k] + (c1[k] - c0[k]) * f for k in range(3))
    return stops[-1][1]


# Vertical face gradient: bright sunlit rim at the top edge fading through the
# upper/mid bands to a dark ground-contact base. Enforces the 100:60:35 ratio.
FACE_STOPS = [(0.00, LIP_RIM), (0.08, FACE_UP), (0.50, FACE_MID), (1.00, FACE_BASE)]


def _hd_rock_grain(w, h, seed):
    """Horizontally-PERIODIC warm-grey rock grain from the CC0 HD source.

    The square photo is squashed into the wide face plane (period = w px = one
    source pass per 8-piece wall cycle) and HIGH-PASSED (divide by a blurred
    copy) so only the crisp rock tooth survives -- the big soft brightness clouds
    that would read as odd blobs are removed, and the mean lands at 1.0 so the
    grain MODULATES the palette value without shifting it. Returns an (h, w)
    float32 array centred on 1.0, or a procedural fallback if the source is
    absent (keeps CI/regen working without the vendored photo)."""
    src_path = os.path.join(_repo_root(), "assets", "tilesets", "sources", HD_ROCK_SRC)
    if os.path.exists(src_path):
        src = Image.open(src_path).convert("L")
        sw, sh = src.size
        band_h = max(8, int(round(sw * h / w)))
        y0 = (sh - band_h) // 2
        band = src.crop((0, y0, sw, y0 + band_h))
        # Tile 2x wide then resample so the result wraps exactly at period w.
        tiled = Image.new("L", (sw * 2, band_h))
        tiled.paste(band, (0, 0))
        tiled.paste(band, (sw, 0))
        big = tiled.resize((2 * w, h), Image.LANCZOS).crop((0, 0, w, h))
        arr = np.asarray(big, dtype=np.float32)
        lo = np.asarray(big.filter(ImageFilter.GaussianBlur(max(4, w // 24))),
                        dtype=np.float32)
        grain = arr / np.clip(lo, 1.0, None)   # high-pass -> mean ~1, crisp tooth
    else:
        rng = np.random.default_rng(seed)
        n = rng.random((h, w)).astype(np.float32)
        grain = 0.5 + 0.5 * (n + np.roll(n, 1, 1) + np.roll(n, 1, 0)) / 3.0
        grain /= max(1e-3, float(grain.mean()))
    grain = 1.0 + (grain - float(grain.mean())) * GRAIN_STRENGTH
    return np.clip(grain, 0.6, 1.4)


def _strata_shade(w, h, face_px, is_se):
    """Multiplicative shade map (h, w) drawing HORIZONTAL sedimentary strata:
    irregular 8-16px bands each stepped +/-6% in value, with a bright lit lip at
    every band boundary and a 2-4px dark inner-shadow overhang just under it. The
    whole band set undulates with a PERIODIC wander along the wall so strata stay
    parallel to the top edge and wrap at the strip seam."""
    srng = random.Random(SEED + (300 if is_se else 400))
    # Irregular band boundaries (fractions of face height).
    heights = []
    acc = 0.0
    face_final = face_px / SS
    while acc < face_final - 4:
        bh = srng.uniform(8, 16)
        heights.append(bh)
        acc += bh
    total = sum(heights)
    boundaries = []
    run = 0.0
    for bh in heights[:-1]:
        run += bh
        boundaries.append(run / total)          # interior boundaries, 0..1
    n_strata = len(boundaries) + 1
    # Per-stratum value offset: alternate +/-6% with a little jitter.
    offs = np.array([(0.06 if k % 2 == 0 else -0.06) + srng.uniform(-0.015, 0.015)
                     for k in range(n_strata)], dtype=np.float32)
    # Periodic wander (integer frequencies -> wraps at period w).
    waves = [(srng.randint(2, 5), srng.uniform(0, 2 * math.pi),
              srng.uniform(0.4, 1.0) * SS) for _ in range(3)]
    U = np.arange(w, dtype=np.float32)[None, :]
    Y = np.arange(h, dtype=np.float32)[:, None]
    un = U / w
    wander = np.zeros((1, w), dtype=np.float32)
    for f, ph, amp in waves:
        wander += amp * np.sin(2 * math.pi * f * un + ph)

    shade = np.ones((h, w), dtype=np.float32)
    idx = np.zeros((h, w), dtype=np.int32)
    shadow_px = srng.uniform(2.5, 4.0) * SS
    for bv in boundaries:
        by = bv * face_px + wander                 # (1, w) boundary row per column
        dist = Y - by                              # >0 below the boundary
        idx += (dist >= 0).astype(np.int32)
        # Dark inner overhang shadow just below the band lip (fades down).
        sh_mask = (dist >= 0) & (dist < shadow_px)
        shade = np.where(sh_mask, shade * (0.80 + 0.20 * (dist / shadow_px)), shade)
        # Thin lit lip catching the sun just above the boundary.
        lit_mask = (dist < 0) & (dist > -1.3 * SS)
        shade = np.where(lit_mask, shade * 1.16, shade)
    idx = np.clip(idx, 0, n_strata - 1)
    shade *= (1.0 + offs[idx])
    return shade


def _face_strip(is_se, rng):
    """One periodic rock strip: PIECES*64 wide, drawn at SS. Built as the palette
    gradient (top-lit -> dark) modulated by HD rock grain and sedimentary strata,
    then vertical cracks and a wrapped low-frequency value blotch, clipped to an
    irregular silhouette. Drawn in face-plane space (u along-wall, v down-face)
    then sheared per-piece when cut, so strata stay parallel to the top edge and
    the texture wraps at the strip ends (period = PIECES*64)."""
    w = PIECES * PIECE_W * SS
    h = (FACE_H + 14) * SS      # face + silhouette overhang zone
    face_px = FACE_H * SS

    # Palette gradient column (varies only with depth v).
    grad = np.empty((h, 3), dtype=np.float32)
    for y in range(h):
        grad[y] = _grad_color(y / face_px, FACE_STOPS)
    face = np.repeat(grad[:, None, :], w, axis=1)

    # HD rock grain (value modulation) + sedimentary strata (value steps/lips).
    grain = _hd_rock_grain(w, h, SEED + (5 if is_se else 6))
    shade = _strata_shade(w, h, face_px, is_se)
    face *= (grain * shade)[..., None]

    # Wrapped low-frequency value blotch so no tonal frequency locks to the 64px
    # piece cut (kills the "fence plank" read); periodic -> wraps at the seam.
    brng = np.random.default_rng(SEED + (7 if is_se else 8))
    cx, cy = 6, 3
    lat = brng.random((cy, cx)).astype(np.float32)
    xs = np.linspace(0, cx, w, endpoint=False)
    ys = np.linspace(0, cy, h, endpoint=False)
    x0 = np.floor(xs).astype(int) % cx
    y0 = np.floor(ys).astype(int) % cy
    fx = (xs - np.floor(xs))[None, :]
    fy = (ys - np.floor(ys))[:, None]
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)
    x1 = (x0 + 1) % cx
    y1 = (y0 + 1) % cy
    a = lat[np.ix_(y0, x0)]
    b = lat[np.ix_(y0, x1)]
    c = lat[np.ix_(y1, x0)]
    dd = lat[np.ix_(y1, x1)]
    blot = (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + dd * fx) * fy
    face *= (1.0 + (blot - 0.5) * 0.12)[..., None]

    face = np.clip(face, 0, 255).astype(np.uint8)
    strip = Image.fromarray(face, "RGB").convert("RGBA")

    # Vertical fracture cracks every 40-70px (kept off the seam so nothing
    # straddles the period boundary). Dark core + a sun-side lit rim upper-left.
    d = ImageDraw.Draw(strip)
    crng = random.Random(SEED + (11 if is_se else 22))
    u = crng.uniform(20 * SS, 40 * SS)
    while u < w - 6 * SS:
        v0 = crng.uniform(0.0, 0.15) * face_px
        v1 = crng.uniform(0.60, 1.0) * face_px
        pts = []
        yy, xx = v0, u
        while yy < v1:
            yy += crng.uniform(4, 8) * SS
            xx += crng.uniform(-2.0, 2.0) * SS
            pts.append((xx, yy))
        if len(pts) >= 2:
            rim = [(px - 1.0 * SS, py - 0.6 * SS) for px, py in pts]
            d.line(rim, fill=CRACK_RIM + (110,), width=max(1, SS))
            d.line(pts, fill=CRACK_CORE + (200,),
                   width=max(1, int(crng.uniform(1.2, 1.8) * SS)))
            if crng.random() < 0.5 and len(pts) > 2:
                fx0, fy0 = pts[len(pts) // 2]
                d.line([(fx0, fy0), (fx0 + crng.uniform(-7, 7) * SS,
                                     fy0 + crng.uniform(4, 9) * SS)],
                       fill=CRACK_CORE + (150,), width=max(1, SS))
        u += crng.uniform(40, 70) * SS

    # Irregular bottom silhouette (per-column wrapped noise).
    ncols = 64
    srng = random.Random(SEED + (33 if is_se else 44))
    col_noise = [srng.uniform(-1.0, 1.0) for _ in range(ncols)]

    def noise_at(uu, cells):
        fpos = (uu / w) * cells
        i0 = int(fpos) % cells
        i1 = (i0 + 1) % cells
        fr = fpos - int(fpos)
        fr = fr * fr * (3 - 2 * fr)
        return col_noise[i0 % ncols] * (1 - fr) + col_noise[i1 % ncols] * fr

    alpha = np.asarray(strip.split()[3], dtype=np.uint8).copy()
    sil_amp = 5.0 * SS
    for x in range(w):
        sil = face_px + sil_amp * (0.5 + 0.5 * noise_at(x, 20)) + \
            2.0 * SS * math.sin(x * 0.11 / SS)
        cut = int(min(h, sil))
        alpha[cut:, x] = 0
    strip.putalpha(Image.fromarray(alpha, "L"))

    if FACE_MAX_SAT != 1.0:
        r, g, b, al = strip.split()
        rgb = ImageEnhance.Color(Image.merge("RGB", (r, g, b))).enhance(FACE_MAX_SAT)
        strip = Image.merge("RGBA", (*rgb.split(), al))
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
    """Lush grass SOD cap drooping over the (sheared) top lip -- a 5-8px green
    fringe that reads as sod grown over the rock, matching the ground grass, with
    an irregular drooping lower margin and occasional longer trailing tufts."""
    d = ImageDraw.Draw(canvas)
    w = PIECE_W * SS

    def edge_y(x):
        t = (w - 1 - (x - pad)) / (w - 1) if is_se else (x - pad) / (w - 1)
        return TOP * SS + t * 32 * SS

    # Base sod band: a continuous green fringe hanging over the lip, drawn column
    # by column across the padding too so it stays continuous across pieces.
    nrng = random.Random(SEED + 900 + piece + (0 if is_se else 40))
    fringe = [nrng.uniform(5, 8) * SS for _ in range(64)]

    def droop(x):
        fpos = ((x - pad) / w) * 62
        i0 = int(fpos) % 62
        fr = fpos - int(fpos)
        fr = fr * fr * (3 - 2 * fr)
        return fringe[i0] * (1 - fr) + fringe[i0 + 1] * fr

    for x in range(0, w + 2 * pad, max(1, SS)):
        ey = edge_y(x)
        dp = droop(x)
        # dark under-shadow of the sod, then the lit blade band on top.
        d.line([(x, ey - 1.5 * SS), (x, ey + dp)], fill=GRASS_DARK + (235,),
               width=max(1, SS))
        d.line([(x, ey - 2.0 * SS), (x, ey + dp * 0.55)], fill=GRASS_MID + (235,),
               width=max(1, SS))
        d.line([(x, ey - 2.0 * SS), (x, ey - 0.2 * SS)], fill=GRASS_LIT + (235,),
               width=max(1, SS))
    # Longer trailing blade tufts breaking the fringe edge.
    if rng.random() < 0.85:
        n = rng.randint(2, 5)
        for _i in range(n):
            x0 = pad + rng.uniform(3 * SS, w - 4 * SS)
            y0 = edge_y(int(x0)) + droop(int(x0))
            bw = rng.uniform(2, 5) * SS
            bh = rng.uniform(3, 8) * SS
            d.line([(x0, y0 - bh * 0.4), (x0 + rng.uniform(-2, 2) * SS, y0 + bh)],
                   fill=GRASS_DARK + (220,), width=max(1, SS))
            d.line([(x0, y0 - bh * 0.4), (x0 + rng.uniform(-1, 1) * SS,
                                          y0 + bh * 0.7)],
                   fill=GRASS_LIT + (215,), width=max(1, SS))
    return canvas


def _corner_cap(rng):
    """Boulder cluster hiding the razor prism point where SE and SW walls meet.
    Warm-grey rock to match the faces (top-lit highlights, dark ground AO)."""
    s = 56 * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, base = s / 2, s * 0.72
    d.ellipse([cx - 22 * SS, base - 6 * SS, cx + 22 * SS, base + 10 * SS],
              fill=CRACK_CORE + (90,))
    for i, (ox, oy, r) in enumerate(((-10, 2, 12), (10, 4, 10), (0, -6, 13), (-2, 8, 8))):
        g = 0.9 + 0.12 * math.sin(i * 2.1)
        c = tuple(min(255, int(ch * g)) for ch in FACE_MID)
        hi = tuple(min(255, int(ch * 1.12)) for ch in LIP_RIM)
        lo = tuple(int(ch * 0.7) for ch in FACE_BASE)
        x, y, rr = cx + ox * SS, base + oy * SS - 8 * SS, r * SS
        d.ellipse([x - rr, y - rr * 0.8, x + rr, y + rr * 0.8], fill=c + (255,))
        d.ellipse([x - rr, y + rr * 0.2, x + rr, y + rr * 0.8], fill=lo + (150,))
        # Soft top-left sheen (not a spotlight): smaller, offset toward the sun.
        d.ellipse([x - rr * 0.55, y - rr * 0.55, x - rr * 0.08, y - rr * 0.15],
                  fill=hi + (95,))
    # Match the faces' grey material (same desaturate) so the cap reads as the
    # same rock, not a warmer boulder.
    r, g, b, al = img.split()
    rgb = ImageEnhance.Color(Image.merge("RGB", (r, g, b))).enhance(FACE_MAX_SAT)
    img = Image.merge("RGBA", (*rgb.split(), al))
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
        # SW faces sit ~7% darker than SE (sky-fill split). Uniform value drop so
        # the grey stays grey (no hue shift).
        if not is_se:
            r, g, b, a = strip.split()
            r = r.point(lambda v: int(v * 0.93))
            g = g.point(lambda v: int(v * 0.93))
            b = b.point(lambda v: int(v * 0.93))
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
    repo_root = _repo_root()
    out = os.path.join(repo_root, "assets", "cliffs", "cliffs.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    build_sheet().save(out)
    print("wrote %s" % out)


if __name__ == "__main__":
    main()
