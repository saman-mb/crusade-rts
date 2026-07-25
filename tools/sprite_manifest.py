#!/usr/bin/env python3
"""Single source of truth for the Crusade iso sprite-sheet layout & manifest (#245).

This is the pure, dependency-free core of the Blender sprite pipeline -- the
`tree_catalog.gd` of the render tooling. It owns the sheet geometry (cell size,
grid packing, ground anchor), the 8-direction facing model, the rig provenance
that gets echoed into every manifest, and the manifest schema itself.

HARD RULE: stdlib only. No `bpy`, no `numpy`, no `Pillow`. The bpy driver
(`render_sprites.py`) and the game both read the numbers from here so the sprite
art, the manifest, and the consumer's frame-picking can never drift apart. This
is also the ONLY file the `python-tools` CI job runs (via test_sprite_manifest).

The 8 sprites are rendered the SC1/AoE way: one 3D model rotated about world Z in
45 deg steps under a WORLD-FIXED orthographic iso camera + NW sun, so every facing
is lit identically. The game works in screen space with the 8 clean directions
below; `frame_for_heading` quantises a screen heading to a frame index and
`direction_facing` is the canonical screen vector each frame depicts.

Keep in sync with docs/ART_PIPELINE.md and src/core/map_constants.gd -- change one,
change the other.
"""

import json
import math

# --- Calibration geometry (mirror src/core/map_constants.gd) ---
TILE_W = 128                 # iso diamond width  (== MapConstants.TILE_SIZE.x)
TILE_H = 64                  # iso diamond height (== MapConstants.TILE_SIZE.y, true 2:1)
ELEVATION_STEP_PX = 32       # == MapConstants.ELEVATION_STEP_PX (TILE_H / 2)
CELL_W = 256                 # sprite cell width  (2 tiles wide -> room for body + shadow)
CELL_H = 256                 # sprite cell height
# Ground-contact point inside every cell (px): world origin (0,0,0) projects here.
# Horizontally centred; low in the cell so the body rises above and the SE shadow
# falls below. The 1x1 ground diamond is centred on this point -> spans (128,64).
ANCHOR = (128, 176)

# --- Rig provenance (echoed verbatim into each manifest's "rig" block) ---
PROJECTION = "orthographic"
CAM_ELEVATION_DEG = 30.0      # iso pitch of the true 2:1 diamond (atan(0.5) rounds here)
CAM_YAW_DEG = 45.0            # iso yaw
# ortho_scale so a 1x1 world tile renders as exactly one TILE_W x TILE_H diamond:
# CELL_W is 2 tiles across, and the iso diamond's world diagonal is sqrt(2).
ORTHO_SCALE = round(math.sqrt(2.0) * (CELL_W / 128.0), 5)   # == 2.82843
SAMPLES = 128
DENOISE = True
VIEW_TRANSFORM = "Standard"   # NOT AgX -- keep sprite colour matching the PIL art
SUN_COMPASS = "NW"            # key sun in the NW -> shadow falls SE (screen lower-right)
BLENDER = "4.5.9 LTS"

# --- 8-direction facing model ---
DIRECTIONS = 8
ORDER = "cw_from_screen_east"
# index 0 = screen +X = East; advancing CLOCKWISE on screen (screen +Y is DOWN).
DIRECTION_NAMES = ["E", "SE", "S", "SW", "W", "NW", "N", "NE"]

# --- Manifest schema ---
SCHEMA = "crusade.sprite_sheet"
VERSION = 1


def _z(x: float) -> float:
    """Round to 3dp and fold -0.0 into 0.0 (keeps JSON facings clean)."""
    v = round(x, 3)
    return v if v != 0.0 else 0.0


def direction_facing(i: int) -> tuple:
    """SCREEN-space unit vector frame `i` depicts (+Y DOWN), rounded to 3dp.

    angle = i*45 deg, (cos, sin). i=0 -> (1,0) East; i=2 -> (0,1) South;
    i=6 -> (0,-1) North. Because screen +Y points down, increasing `i` sweeps
    clockwise on screen (E -> SE -> S -> ...), matching ORDER.
    """
    a = math.radians(45.0 * (i % DIRECTIONS))
    return (_z(math.cos(a)), _z(math.sin(a)))


def frame_for_heading(vx: float, vy: float) -> int:
    """Consumer-mirror quantiser: screen heading (vx,vy, +Y down) -> frame index.

    Inverse of `direction_facing` at the 8 octant centres. Snaps to nearest 45 deg.
    """
    return int((round(math.atan2(vy, vx) / (math.pi / 4.0)) % 8 + 8) % 8)


def pack_grid(n_frames: int, cols: int = DIRECTIONS) -> list:
    """Row-major uniform grid of CELL_W x CELL_H rects, one per frame.

    NOT a general packer -- every cell is identical, so a frame's rect is just its
    (col,row) times the cell size. Returns [[x,y,w,h], ...] in frame order.
    """
    if n_frames < 0:
        raise ValueError("n_frames must be >= 0")
    if cols < 1:
        raise ValueError("cols must be >= 1")
    rects = []
    for i in range(n_frames):
        col = i % cols
        row = i // cols
        rects.append([col * CELL_W, row * CELL_H, CELL_W, CELL_H])
    return rects


def sheet_dimensions(n_frames: int, cols: int = DIRECTIONS) -> tuple:
    """(width, height) px of the sheet holding `n_frames` cells in `cols` columns.

    Width is the number of populated columns (min(n_frames, cols)) so a single full
    row is tightly cropped; height is the number of rows. The rects from
    `pack_grid` exactly tile this area when frames fill complete rows.
    """
    if n_frames < 0:
        raise ValueError("n_frames must be >= 0")
    if cols < 1:
        raise ValueError("cols must be >= 1")
    if n_frames == 0:
        return (0, 0)
    used_cols = min(n_frames, cols)
    rows = (n_frames + cols - 1) // cols
    return (used_cols * CELL_W, rows * CELL_H)


def build_manifest(sheet_path: str, model_name: str, n_frames: int,
                   cols: int = DIRECTIONS, anim: str = "default") -> dict:
    """Assemble a schema-v1 manifest dict for a rendered sheet.

    `sheet_path` is the engine path stored verbatim (e.g. res://assets/.../foo.png).
    `model_name` is reserved provenance for forward-compat (#250/#251) and is not
    part of schema v1. Frames are laid out row-major: each row is one animation
    frame across all `DIRECTIONS` directions (with cols == DIRECTIONS, one row per
    anim frame), so `n_frames` should be DIRECTIONS * (anim frame count).

    The rig block reflects the DEFAULT rig constants; the driver may patch
    `samples`/`denoise` post-build if it had to fall back (OIDN unavailable).
    """
    del model_name  # reserved: encoded in sheet_path today; a manifest field later
    if n_frames % DIRECTIONS != 0:
        raise ValueError("n_frames (%d) must be a multiple of DIRECTIONS (%d)"
                         % (n_frames, DIRECTIONS))
    width, height = sheet_dimensions(n_frames, cols)
    rects = pack_grid(n_frames, cols)
    n_anim = n_frames // DIRECTIONS

    frames = []
    for i in range(n_frames):
        d = i % DIRECTIONS
        af = i // DIRECTIONS
        fx, fy = direction_facing(d)
        frames.append({
            "index": i,
            "dir": d,
            "dir_name": DIRECTION_NAMES[d],
            "facing": [fx, fy],
            "anim": anim,
            "frame": af,
            "rect": rects[i],
            "anchor": [ANCHOR[0], ANCHOR[1]],
        })

    return {
        "schema": SCHEMA,
        "version": VERSION,
        "sheet": {
            "path": sheet_path,
            "width": width,
            "height": height,
            "cell": [CELL_W, CELL_H],
        },
        "rig": {
            "projection": PROJECTION,
            "elevation_deg": CAM_ELEVATION_DEG,
            "yaw_deg": CAM_YAW_DEG,
            "ortho_scale": ORTHO_SCALE,
            "samples": SAMPLES,
            "denoise": DENOISE,
            "view_transform": VIEW_TRANSFORM,
            "sun_compass": SUN_COMPASS,
            "blender": BLENDER,
            "tile_size": [TILE_W, TILE_H],
            "elevation_step_px": ELEVATION_STEP_PX,
        },
        "directions": {
            "count": DIRECTIONS,
            "order": ORDER,
            "names": list(DIRECTION_NAMES),
        },
        "anim": {
            anim: {"frames": n_anim, "fps": 0},
        },
        "frames": frames,
    }


def dumps(m: dict) -> str:
    """Serialise a manifest with stable (insertion) key order + trailing newline."""
    return json.dumps(m, indent=2, sort_keys=False) + "\n"


def loads(s: str) -> dict:
    """Parse a manifest string (dicts keep file order)."""
    return json.loads(s)


def _rects_overlap(a: list, b: list) -> bool:
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah


def validate(m: dict) -> None:
    """Raise ValueError if `m` is not a well-formed schema-v1 manifest.

    Checks schema/version pins, the frozen direction block, sheet dims consistent
    with the frame count, and every frame's rect in-bounds & non-overlapping with
    its anchor inside the cell.
    """
    if m.get("schema") != SCHEMA:
        raise ValueError("schema mismatch: %r (expected %r)" % (m.get("schema"), SCHEMA))
    if m.get("version") != VERSION:
        raise ValueError("version mismatch: %r (expected %d)" % (m.get("version"), VERSION))

    dirs = m.get("directions", {})
    if dirs.get("count") != DIRECTIONS:
        raise ValueError("directions.count %r != %d" % (dirs.get("count"), DIRECTIONS))
    if dirs.get("order") != ORDER:
        raise ValueError("directions.order %r != %r" % (dirs.get("order"), ORDER))
    if dirs.get("names") != DIRECTION_NAMES:
        raise ValueError("directions.names %r != %r" % (dirs.get("names"), DIRECTION_NAMES))

    sheet = m.get("sheet", {})
    if sheet.get("cell") != [CELL_W, CELL_H]:
        raise ValueError("sheet.cell %r != %r" % (sheet.get("cell"), [CELL_W, CELL_H]))
    width, height = sheet.get("width"), sheet.get("height")
    if not isinstance(width, int) or not isinstance(height, int) or width < 0 or height < 0:
        raise ValueError("sheet width/height must be non-negative ints")

    frames = m.get("frames", [])
    n = len(frames)
    cols = width // CELL_W if CELL_W else 0
    if cols < 1:
        raise ValueError("sheet width %r yields < 1 column" % width)
    if (width, height) != sheet_dimensions(n, cols):
        raise ValueError("sheet dims (%d,%d) != recomputed %r"
                         % (width, height, sheet_dimensions(n, cols)))

    expected = pack_grid(n, cols)
    seen = []
    for i, fr in enumerate(frames):
        rect = fr.get("rect")
        if rect != expected[i]:
            raise ValueError("frame %d rect %r != expected %r" % (i, rect, expected[i]))
        x, y, w, h = rect
        if x < 0 or y < 0 or x + w > width or y + h > height:
            raise ValueError("frame %d rect %r out of sheet bounds" % (i, rect))
        for prev in seen:
            if _rects_overlap(rect, prev):
                raise ValueError("frame %d rect %r overlaps %r" % (i, rect, prev))
        seen.append(rect)

        ax, ay = fr.get("anchor", [None, None])
        if not (0 <= ax <= CELL_W and 0 <= ay <= CELL_H):
            raise ValueError("frame %d anchor %r outside cell" % (i, (ax, ay)))

        d = fr.get("dir")
        if d != i % DIRECTIONS:
            raise ValueError("frame %d dir %r != %d" % (i, d, i % DIRECTIONS))
        if fr.get("dir_name") != DIRECTION_NAMES[d]:
            raise ValueError("frame %d dir_name %r wrong" % (i, fr.get("dir_name")))
        fx, fy = direction_facing(d)
        if fr.get("facing") != [fx, fy]:
            raise ValueError("frame %d facing %r != %r" % (i, fr.get("facing"), [fx, fy]))
