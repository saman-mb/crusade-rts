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
import random

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

# --- Layout constants (mirror tileset_constants.gd) ---
REGION_W, REGION_H = 128, 64
ATLAS_W, ATLAS_H = 512, 1408
SS = 4                      # supersample factor for anti-aliasing

# --- Positional mega-tile windows (the REAL seam killer) -----------------------
# A field of ONE repeated tile bitmap always reads as a grid, however soft its
# edges. SC1's actual technique: make the artwork CONTINUOUS across cells. One
# large SEAMLESS (torus-periodic) texture is cut into 128x64 diamond "window"
# crops at the exact screen offsets of the cells they land on, and the runtime
# assigns each cell the window for its position -- the texture then flows across
# every tile edge, and the repeat period becomes the whole mega texture.
#
# Indexing: screen-x depends only on p = x - y and screen-y only on q = x + y
# (cell (x,y)'s bounding-box top-left sits at (64p, 32q)). With window class
# (a, b) = (p mod 8, q mod 8), two cells share a class iff their screen offset is
# a multiple of (512, 256) = the mega texture's period, so one crop is correct
# everywhere its class appears -- and adjacent cells are adjacent crops of the
# same image, so shared edges match EXACTLY. p and q always share parity, so only
# the 32 same-parity classes occur; window index = a*4 + b//2 (0..31), stored as
# 8 atlas rows of 4. Grass windows at rows 6..13, water windows at rows 14..21.
# Water windows are STATIC on purpose: the old desynced brightness frames put
# neighbouring tiles on different frames, which re-created a checkerboard.
MEGA_W, MEGA_H = 512, 256   # mega texture size == the window period, world px
WINDOW_N = 8                # window classes per axis (p mod 8, q mod 8)
GRASS_WINDOW_ROW0 = 6       # first atlas row of the 32 grass windows
WATER_WINDOW_ROW0 = 14      # first atlas row of the 32 water windows
MEGA_SEED = 20260724        # fixed seed -> fully deterministic mega textures
FEATHER_PX = 3.0            # grass<->dirt seam softness, in final-res pixels
# Tier 2 terrain-realism (#233): the diamond silhouette is hardened at the very
# end (ALPHA_THRESHOLD) so neighbouring diamonds meet at full coverage instead of
# leaving a semi-transparent 1px band that let the dark void behind the layer show
# through as a visible grid of seams. GRASS_CONTRAST/GRASS_SATURATION knock the
# high-contrast tuft "signature" down toward an even field so the base tile reads
# as texture, not a recognizable stamp -- the variation system (#232) then breaks
# up what little repetition remains.
ALPHA_THRESHOLD = 96        # 0..255; alpha >= this -> fully opaque, else fully clear
GRASS_CONTRAST = 0.72       # <1 flattens the grass tuft contrast toward its mean
GRASS_SATURATION = 1.28     # boost so the averaged grass reads lush green, not muddy
# De-mud tint (#233 art pass): multiply the softened grass toward green and lift
# shadows toward a cool green-grey instead of brown, per the lead-artist palette
# (lit ~#6E8B45, shadow greener/cooler). Applied after contrast/saturation.
GRASS_TINT = (0.92, 1.06, 0.82)   # R,G,B multipliers -> push green, cut red/blue

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
    """Tier 2 (#233): flatten a ground crop's contrast, then push it lush-green
    (saturation + a green colour balance) so it stops reading as muddy olive and
    its high-frequency 'signature' stops reading as a stamp when tiled. Purely a
    tone operation on the RGB crop; the diamond alpha is applied later."""
    out = ImageEnhance.Contrast(rgb).enhance(GRASS_CONTRAST)
    out = ImageEnhance.Color(out).enhance(GRASS_SATURATION)
    r, g, b = out.split()
    r = r.point(lambda v: min(255, int(v * GRASS_TINT[0])))
    g = g.point(lambda v: min(255, int(v * GRASS_TINT[1])))
    b = b.point(lambda v: min(255, int(v * GRASS_TINT[2])))
    return Image.merge("RGB", (r, g, b))


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


def _ramp_tile(dia_ss):
    """Worn-dirt ramp diamond (lead-artist spec): a #7D6A52 -> #5E4C3A gradient
    down-slope with scattered pebbles and faint wear lines, replacing the flat
    tan placeholder that read as an orange orphan under the warm grade."""
    w, h = REGION_W * SS, REGION_H * SS
    top = (0x7D, 0x6A, 0x52)
    bot = (0x5E, 0x4C, 0x3A)
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c
    d = ImageDraw.Draw(img)
    prng = random.Random(20260726)
    for _i in range(26):
        x = prng.uniform(w * 0.2, w * 0.8)
        y = prng.uniform(h * 0.2, h * 0.8)
        r = prng.uniform(0.8, 2.2) * SS
        g = prng.randint(120, 160)
        d.ellipse([x - r, y - r * 0.6, x + r, y + r * 0.6], fill=(g, g - 8, g - 18))
    for _i in range(8):
        y = prng.uniform(h * 0.15, h * 0.9)
        x0 = prng.uniform(0, w * 0.5)
        ln = prng.uniform(w * 0.2, w * 0.5)
        d.line([(x0, y), (x0 + ln, y + prng.uniform(-2, 2) * SS)],
               fill=(0x52, 0x42, 0x32), width=max(1, SS // 2))
    tile = img.convert("RGBA")
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


# --- Mega-texture generation (torus-periodic => window crops share edges) ------

def _torus_noise(w, h, cells_x, cells_y, rng):
    """Smooth value noise, PERIODIC in both axes (lattice indices wrap), in [0,1].
    Periodicity is what makes every window crop's edge match its neighbour's."""
    lattice = rng.random((cells_y, cells_x))
    ys = np.linspace(0.0, cells_y, h, endpoint=False)
    xs = np.linspace(0.0, cells_x, w, endpoint=False)
    y0 = np.floor(ys).astype(int)
    x0 = np.floor(xs).astype(int)
    fy = (ys - y0)[:, None]
    fx = (xs - x0)[None, :]
    fy = fy * fy * (3.0 - 2.0 * fy)
    fx = fx * fx * (3.0 - 2.0 * fx)
    y1 = (y0 + 1) % cells_y
    x1 = (x0 + 1) % cells_x
    a = lattice[np.ix_(y0, x0)]
    b = lattice[np.ix_(y0, x1)]
    c = lattice[np.ix_(y1, x0)]
    d = lattice[np.ix_(y1, x1)]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def _hex(c):
    return tuple(int(c[i:i + 2], 16) for i in (1, 3, 5))


def _lerp_rgb(c0, c1, t):
    """t is an (h,w) array in [0,1]; returns an (h,w,3) uint8 array."""
    out = np.empty(t.shape + (3,), dtype=np.float32)
    for i in range(3):
        out[..., i] = c0[i] * (1.0 - t) + c1[i] * t
    return out


def _gen_mega_grass(ss):
    """Seamless grass mega texture at ss scale (MEGA_W*ss x MEGA_H*ss), RGB.

    Lead-artist layer stack: fresh-green base; two octaves of warm<->cool hue
    drift (value swing kept small -- contrast belongs to LIGHTING, not albedo);
    lush/dry clump patches (dry = yellow-green, never brown); thousands of tiny
    near-vertical blade strokes with lit tips; a whisper of dirt speckle. All
    noise is torus-periodic and strokes are drawn 9-way wrapped, so the texture
    tiles seamlessly -- which is exactly what makes the window crops seamless.
    """
    w, h = MEGA_W * ss, MEGA_H * ss
    rng = np.random.default_rng(MEGA_SEED)
    base = _hex("#5E7A3A")
    warm = _hex("#6B8A42")
    cool = _hex("#4F7038")
    lush = _hex("#55763C")
    dry = _hex("#7C8A44")

    drift = 0.65 * _torus_noise(w, h, 2, 1, rng) + 0.35 * _torus_noise(w, h, 5, 3, rng)
    rgb = _lerp_rgb(cool, warm, drift)
    # Blend a touch of base back in so the drift never dominates.
    for i in range(3):
        rgb[..., i] = 0.55 * rgb[..., i] + 0.45 * base[i]

    # Mid-band mottle (SC1 grit): HARD-edged posterized clumps 48-160px with
    # strong local contrast -- the painterly mid frequencies SC1 lives in.
    clump = _torus_noise(w, h, 12, 6, rng)
    clump2 = _torus_noise(w, h, 26, 13, rng)
    lush_m = np.clip((0.44 - clump) * 8.0, 0.0, 1.0) * 0.55
    dry_m = np.clip((clump - 0.60) * 8.0, 0.0, 1.0) * 0.45
    mid_m = np.clip((clump2 - 0.58) * 10.0, 0.0, 1.0) * 0.3
    mid_dark = tuple(int(c * 0.78) for c in lush)
    for i in range(3):
        rgb[..., i] = rgb[..., i] * (1 - lush_m) + lush[i] * lush_m
        rgb[..., i] = rgb[..., i] * (1 - dry_m) + dry[i] * dry_m
        rgb[..., i] = rgb[..., i] * (1 - mid_m) + mid_dark[i] * mid_m
    # Earth showing through: irregular dirt patches (~15% coverage) with a
    # broken dark rim -- breaks the mono-green lawn into jungle floor.
    dirtn = _torus_noise(w, h, 10, 6, rng)
    dirt_m = np.clip((dirtn - 0.74) * 9.0, 0.0, 1.0)
    rim_m = np.clip((dirtn - 0.70) * 9.0, 0.0, 1.0) - dirt_m
    dirt_fill = (0x84, 0x74, 0x4E)
    rim_fill = (0x5D, 0x4F, 0x33)
    for i in range(3):
        rgb[..., i] = rgb[..., i] * (1 - dirt_m * 0.55) + dirt_fill[i] * dirt_m * 0.55
        rgb[..., i] = rgb[..., i] * (1 - rim_m * 0.3) + rim_fill[i] * rim_m * 0.3

    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    prng = random.Random(MEGA_SEED)
    blade_base = _hex("#45602E")
    blade_tip = _hex("#7E9C4C")
    spark = _hex("#93AE5C")
    dirt = _hex("#8A7448")
    pebble = _hex("#9A9077")

    def wrapped(draw_fn, x, y):
        for dx in (-w, 0, w):
            for dy in (-h, 0, h):
                draw_fn(x + dx, y + dy)

    n_blades = 6400
    for _i in range(n_blades):
        x = prng.uniform(0, w)
        y = prng.uniform(0, h)
        ln = prng.uniform(0.9, 3.0) * ss
        lean = prng.uniform(-0.6, 0.6) * ss
        t = prng.random()
        # +30% stroke contrast (lead artist): darker bases, brighter tips.
        lo = tuple(int(c * 0.82) for c in blade_base)
        hi = tuple(min(255, int(c * 1.18)) for c in blade_tip)
        col = tuple(int(lo[i] + (hi[i] - lo[i]) * t) for i in range(3))
        if prng.random() < 0.02:
            col = spark
        wd = max(1, int(0.35 * ss))
        wrapped(lambda px, py, c=col, L=ln, e=lean, W=wd:
                d.line([(px, py), (px + e, py - L)], fill=c, width=W), x, y)

    # Directional stroke layer: painterly dashes aligned +/-25 deg around the
    # NW->SE sun axis (SC1 brushwork read).
    import math as _m
    for _i in range(600):
        x = prng.uniform(0, w)
        y = prng.uniform(0, h)
        ang = _m.atan2(1.0, 2.0) + prng.uniform(-0.44, 0.44)
        ln = prng.uniform(3.0, 10.0) * ss
        dxs, dys = _m.cos(ang) * ln, _m.sin(ang) * ln
        dark = prng.random() < 0.6
        f = 0.92 if dark else 1.08
        sc = tuple(max(0, min(255, int(c * f))) for c in base)
        wrapped(lambda px, py, c=sc, DX=dxs, DY=dys:
                d.line([(px, py), (px + DX, py + DY)], fill=c, width=max(1, int(0.5 * ss))), x, y)
    for _i in range(420):
        x = prng.uniform(0, w)
        y = prng.uniform(0, h)
        r = prng.uniform(0.3, 0.9) * ss
        col = dirt if prng.random() < 0.8 else pebble
        wrapped(lambda px, py, c=col, R=r:
                d.ellipse([px - R, py - R * 0.6, px + R, py + R * 0.6], fill=c), x, y)
    # Final green rebalance (lead-artist target swatches): ~8 deg greener hue,
    # +8% saturation, so the field reads green-olive, never cooked yellow.
    img = ImageEnhance.Color(img).enhance(1.08)
    r2, g2, b2 = img.split()
    r2 = r2.point(lambda v: int(v * 0.93))
    g2 = g2.point(lambda v: min(255, int(v * 1.03)))
    return Image.merge("RGB", (r2, g2, b2))


def _gen_mega_water(ss):
    """Seamless water mega texture at ss scale: deep-blue base, large soft depth
    mottling, sparse short wave dashes. Torus-periodic like the grass mega."""
    w, h = MEGA_W * ss, MEGA_H * ss
    rng = np.random.default_rng(MEGA_SEED + 7)
    base = _hex("#4A6B70")
    deep = _hex("#2E4E56")
    depth = 0.7 * _torus_noise(w, h, 3, 2, rng) + 0.3 * _torus_noise(w, h, 7, 4, rng)
    rgb = _lerp_rgb(deep, base, np.clip(0.3 + depth * 0.85, 0.0, 1.0))
    img = Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    prng = random.Random(MEGA_SEED + 7)
    wave = _hex("#7FB8CC")
    for _i in range(340):
        x = prng.uniform(0, w)
        y = prng.uniform(0, h)
        ln = prng.uniform(1.5, 5.0) * ss
        col = tuple(int(wave[i] * 0.55 + base[i] * 0.45) for i in range(3))
        if prng.random() < 0.25:
            col = wave
        for dx in (-w, 0, w):
            for dy in (-h, 0, h):
                d.line([(x + dx, y + dy), (x + dx + ln, y + dy)], fill=col,
                       width=max(1, int(0.3 * ss)))
    return img


HD_GRASS_SRC = "aerial_grass_rock.png"   # CC0 Poly Haven, seamless top-down HD grass/soil


def _load_hd_grass_mega(ss):
    """Torus-periodic grass mega from a seamless CC0 HD *aerial* (top-down) texture.

    The iso ground plane foreshortens 2:1 vertically, so the square source is
    squashed to the MEGA 2:1 aspect -- which is exactly correct for the projection.
    Seamlessness is guaranteed by resampling a 2x2 tiling and taking one full
    period (the resize kernel then only ever sees continuous tiled content, so the
    result wraps in both axes). Falls back to the procedural grass if absent.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.join(here, "..", "assets", "tilesets", "sources", HD_GRASS_SRC)
    if not os.path.exists(src):
        return _gen_mega_grass(ss)
    w, h = MEGA_W * ss, MEGA_H * ss
    img = Image.open(src).convert("RGB")
    tw, th = img.size
    tiled = Image.new("RGB", (tw * 2, th * 2))
    for ox in (0, tw):
        for oy in (0, th):
            tiled.paste(img, (ox, oy))
    big = tiled.resize((w * 2, h * 2), Image.LANCZOS)   # period becomes exactly (w, h)
    mega = big.crop((0, 0, w, h))                       # one full period -> torus-periodic

    # Colour-correct the raw aerial source toward the art-director's LUSH warm-olive
    # grass target (#5f6d38 base) -- the stock photo is a dirt-heavy yellow-grey, so
    # ease red/blue and lift green, then gently desaturate so it reads grass, not mud.
    # Channel multiply preserves every grain of the HD micro-detail.
    arr = np.asarray(mega, dtype=np.float32)
    arr[..., 0] *= 0.80                                  # red   down (kill the mud/yellow)
    arr[..., 1] *= 1.06                                  # green up  (read as grass)
    arr[..., 2] *= 0.78                                  # blue  down (kill the cool grey cast)
    lum = arr @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    arr = lum[..., None] * 0.14 + arr * 0.86             # slight desaturate, no neon
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


def _window_tiles(mega_ss, ss):
    """Yields (index, FINAL-res RGBA tile) for the 32 same-parity window crops.

    Crop for class (a, b) is the 128x64 rect at (64a, 32b) of the mega, sampled
    from a 3x3 tiling so crops (and their padding) wrap correctly. Each crop is
    downsampled INDIVIDUALLY with true mega-texture padding around it -- if the
    whole atlas were downsampled at once, the resampling kernel would bleed the
    NEIGHBOURING ATLAS REGION's colours into each tile edge and re-draw a faint
    seam; padding from the mega itself means the kernel sees exactly what the
    adjacent map cell will contain, so edges stay continuous. The full rect's RGB
    is kept under the diamond alpha (built-in colour bleed for edge filtering)."""
    big = Image.new("RGB", (MEGA_W * ss * 3, MEGA_H * ss * 3))
    for tx in range(3):
        for ty in range(3):
            big.paste(mega_ss, (tx * MEGA_W * ss, ty * MEGA_H * ss))
    pad = 8  # final-res px of context on each side while downsampling
    dia_final = _diamond_alpha().resize((REGION_W, REGION_H), Image.LANCZOS)
    dia_final = dia_final.point(lambda v: 255 if v >= ALPHA_THRESHOLD else 0)
    for a in range(WINDOW_N):
        for b in range(WINDOW_N):
            if (a + b) % 2 != 0:
                continue
            idx = a * 4 + b // 2
            # +1 period so the padded crop never leaves the 3x3 tiling.
            x0 = (a * (REGION_W // 2) + MEGA_W - pad) * ss
            y0 = (b * (REGION_H // 2) + MEGA_H - pad) * ss
            crop = big.crop((x0, y0,
                             x0 + (REGION_W + 2 * pad) * ss,
                             y0 + (REGION_H + 2 * pad) * ss))
            small = crop.resize((REGION_W + 2 * pad, REGION_H + 2 * pad), Image.LANCZOS)
            tile = small.crop((pad, pad, pad + REGION_W, pad + REGION_H)).convert("RGBA")
            tile.putalpha(dia_final)
            yield idx, tile


def build_atlas(sources_dir):
    grass_sheet = Image.open(os.path.join(sources_dir, "grass_dirt.png"))

    # The mega textures are the authoritative ground art. The dual-grid
    # transition tiles blend the SAME mega grass (one crop) over CC0 dirt, so
    # map borders stay coherent with the seamless interior field.
    mega_grass_ss = _load_hd_grass_mega(SS)   # HD CC0 aerial grass (falls back to procedural)
    mega_water_ss = _gen_mega_water(SS)
    grass_ss = mega_grass_ss.crop((0, 0, REGION_W * SS, REGION_H * SS))
    dirt_ss = _soften(_crop_cell(grass_sheet, GRASS_DIRT_COLS, GRASS_DIRT_ROWS, *DIRT_CELL))
    water_ss = mega_water_ss.crop((0, 0, REGION_W * SS, REGION_H * SS))
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

    # Row 4: the legacy 4-frame water strip (kept so painted maps and the editor
    # brush stay valid; the runtime remaps water cells onto the static windows).
    for col in range(4):
        tile = _water_tile(water_ss, dia_ss, WATER_BRIGHTNESS[col])
        big.alpha_composite(tile, (col * REGION_W * SS, 4 * REGION_H * SS))

    # Row 5, col 0: worn-dirt ramp tile.
    big.alpha_composite(_ramp_tile(dia_ss), (0, 5 * REGION_H * SS))

    # Legacy rows are supersampled then downsampled together; the window tiles
    # are downsampled INDIVIDUALLY (see _window_tiles) and pasted at final res
    # afterwards, so no resampling kernel ever crosses two unrelated regions.
    atlas = _harden_silhouette(big.resize((ATLAS_W, ATLAS_H), Image.LANCZOS))

    # Rows 6..13: the 32 positional grass windows; rows 14..21: water windows.
    for idx, tile in _window_tiles(mega_grass_ss, SS):
        atlas.paste(tile, ((idx % 4) * REGION_W, (GRASS_WINDOW_ROW0 + idx // 4) * REGION_H))
    for idx, tile in _window_tiles(mega_water_ss, SS):
        atlas.paste(tile, ((idx % 4) * REGION_W, (WATER_WINDOW_ROW0 + idx // 4) * REGION_H))
    return atlas


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
