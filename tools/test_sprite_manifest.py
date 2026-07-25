#!/usr/bin/env python3
"""Invariant tests for sprite_manifest (#245). Pure stdlib; run directly:
    python3 tools/test_sprite_manifest.py

This is the ONLY sprite-pipeline file CI runs (the `python-tools` job) -- it must
never import bpy/numpy/PIL, and it guards that sprite_manifest stays that clean
too. It exercises the pure core AND the committed golden manifest so the sheet,
the manifest, and the consumer's frame-picking can never silently drift.
"""

import math
import os
import subprocess
import sys

import sprite_manifest as sm

_pass = 0
_fail = 0


def ok(cond, msg):
    global _pass, _fail
    if cond:
        _pass += 1
    else:
        _fail += 1
        print("FAIL:", msg)


def _golden_path():
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in ("assets/sprites/_test/suzanne.json",
                 os.path.join(here, "..", "assets", "sprites", "_test", "suzanne.json")):
        if os.path.exists(cand):
            return cand
    return None


def test_pack_grid_tiles_and_covers():
    n, cols = sm.DIRECTIONS, sm.DIRECTIONS
    rects = sm.pack_grid(n, cols)
    w, h = sm.sheet_dimensions(n, cols)
    ok(len(rects) == n, "pack_grid returns one rect per frame")
    # exact cover: total rect area == sheet area, and every rect in-bounds.
    area = sum(rw * rh for _x, _y, rw, rh in rects)
    ok(area == w * h, "rects exactly cover sheet_dimensions (area %d == %d)" % (area, w * h))
    in_bounds = all(0 <= x and 0 <= y and x + rw <= w and y + rh <= h
                    for x, y, rw, rh in rects)
    ok(in_bounds, "every rect lies within the sheet bounds")
    # no overlaps (pairwise).
    overlap = False
    for a in range(len(rects)):
        for b in range(a + 1, len(rects)):
            if sm._rects_overlap(rects[a], rects[b]):
                overlap = True
    ok(not overlap, "no two rects overlap")
    # multi-row case also tiles exactly (2 full rows).
    n2 = sm.DIRECTIONS * 2
    w2, h2 = sm.sheet_dimensions(n2, cols)
    area2 = sum(rw * rh for _x, _y, rw, rh in sm.pack_grid(n2, cols))
    ok(area2 == w2 * h2, "two full rows tile exactly")
    ok((w2, h2) == (sm.CELL_W * cols, sm.CELL_H * 2), "two-row sheet dims correct")


def test_cell_and_anchor_in_bounds():
    m = sm.build_manifest("res://x.png", "suzanne", sm.DIRECTIONS)
    for fr in m["frames"]:
        ax, ay = fr["anchor"]
        ok(0 <= ax <= sm.CELL_W and 0 <= ay <= sm.CELL_H,
           "anchor %s inside cell for frame %d" % ((ax, ay), fr["index"]))
    ok(sm.ANCHOR == (128, 176), "ANCHOR pinned to (128,176)")
    ok((sm.CELL_W, sm.CELL_H) == (256, 256), "cell pinned to 256x256")


def test_heading_round_trip_octants():
    for i in range(sm.DIRECTIONS):
        fx, fy = sm.direction_facing(i)
        got = sm.frame_for_heading(fx, fy)
        ok(got == i, "frame_for_heading(direction_facing(%d)) == %d (got %d)" % (i, i, got))


def test_heading_boundaries():
    # Just inside each octant (center +/- 20 deg) must snap to that octant.
    for i in range(sm.DIRECTIONS):
        center = 45.0 * i
        for off in (-20.0, +20.0):
            a = math.radians(center + off)
            got = sm.frame_for_heading(math.cos(a), math.sin(a))
            ok(got == i, "heading %.0f deg -> frame %d (got %d)" % (center + off, i, got))
    # Exact half-octant boundary uses banker's rounding: 22.5 deg -> even side (0).
    a = math.radians(22.5)
    ok(sm.frame_for_heading(math.cos(a), math.sin(a)) in (0, 1),
       "22.5 deg boundary resolves to an adjacent octant")
    # Wrap-around: heading just below 360 maps back to East (0).
    a = math.radians(359.0)
    ok(sm.frame_for_heading(math.cos(a), math.sin(a)) == 0, "359 deg wraps to E (0)")


def test_facing_values():
    ok(sm.direction_facing(0) == (1.0, 0.0), "E facing (1,0)")
    ok(sm.direction_facing(2) == (0.0, 1.0), "S facing (0,1) [screen +Y down]")
    ok(sm.direction_facing(6) == (0.0, -1.0), "N facing (0,-1) [no -0.0]")
    # No negative-zero leaks into the manifest.
    for i in range(sm.DIRECTIONS):
        for v in sm.direction_facing(i):
            ok(not (v == 0.0 and math.copysign(1.0, v) < 0), "no -0.0 in facing %d" % i)


def test_build_dumps_loads_validate_round_trip():
    m = sm.build_manifest("res://assets/sprites/_test/suzanne.png", "suzanne", sm.DIRECTIONS)
    sm.validate(m)                                   # must not raise
    text = sm.dumps(m)
    ok(text.endswith("\n"), "dumps ends with trailing newline")
    ok(text == sm.dumps(sm.loads(text)), "dumps -> loads -> dumps is stable")
    back = sm.loads(text)
    ok(back == m, "loads(dumps(m)) round-trips to an equal dict")
    sm.validate(back)                                # loaded copy also valid


def test_schema_and_version_pinned():
    m = sm.build_manifest("res://x.png", "suzanne", sm.DIRECTIONS)
    ok(m["schema"] == "crusade.sprite_sheet" and m["version"] == 1, "schema/version pinned")
    bad = sm.build_manifest("res://x.png", "suzanne", sm.DIRECTIONS)
    bad["version"] = 2
    raised = False
    try:
        sm.validate(bad)
    except ValueError:
        raised = True
    ok(raised, "validate rejects a wrong version")
    # A tampered rect (overlap / out of order) is rejected.
    bad2 = sm.build_manifest("res://x.png", "suzanne", sm.DIRECTIONS)
    bad2["frames"][1]["rect"] = [0, 0, sm.CELL_W, sm.CELL_H]   # collide with frame 0
    raised2 = False
    try:
        sm.validate(bad2)
    except ValueError:
        raised2 = True
    ok(raised2, "validate rejects a duplicated/overlapping rect")
    # An anchor outside the cell is rejected.
    bad3 = sm.build_manifest("res://x.png", "suzanne", sm.DIRECTIONS)
    bad3["frames"][0]["anchor"] = [sm.CELL_W + 5, 0]
    raised3 = False
    try:
        sm.validate(bad3)
    except ValueError:
        raised3 = True
    ok(raised3, "validate rejects an out-of-cell anchor")


def test_build_requires_multiple_of_directions():
    raised = False
    try:
        sm.build_manifest("res://x.png", "suzanne", 3)
    except ValueError:
        raised = True
    ok(raised, "build_manifest rejects a non-multiple-of-DIRECTIONS frame count")


def test_golden_consistency():
    path = _golden_path()
    if path is None:
        print("skip golden test (suzanne.json not found)")
        return
    with open(path) as fh:
        golden = sm.loads(fh.read())
    sm.validate(golden)                              # committed manifest is well-formed
    n = len(golden["frames"])
    recomputed = sm.build_manifest(golden["sheet"]["path"], "suzanne", n)
    ok(golden["sheet"]["width"] == recomputed["sheet"]["width"]
       and golden["sheet"]["height"] == recomputed["sheet"]["height"],
       "golden sheet dims match recomputed")
    ok(golden["sheet"]["cell"] == recomputed["sheet"]["cell"], "golden cell matches")
    ok(golden["directions"] == recomputed["directions"], "golden directions match")
    ok([f["rect"] for f in golden["frames"]] == [f["rect"] for f in recomputed["frames"]],
       "golden rects match recomputed pack_grid")
    ok([f["facing"] for f in golden["frames"]] == [f["facing"] for f in recomputed["frames"]],
       "golden facings match recomputed direction_facing")
    ok([f["dir_name"] for f in golden["frames"]] == list(sm.DIRECTION_NAMES),
       "golden dir_names are E,SE,S,SW,W,NW,N,NE in order")


def test_no_bpy_numpy_pil_leak():
    src_path = os.path.join(os.path.dirname(os.path.abspath(sm.__file__)), "sprite_manifest.py")
    with open(src_path) as fh:
        src = fh.read()
    for forbidden in ("import bpy", "import numpy", "import PIL", "from bpy",
                      "from numpy", "from PIL"):
        ok(forbidden not in src, "sprite_manifest.py has no `%s`" % forbidden)
    # It must import cleanly under a plain python3 (no Blender) with nothing but stdlib.
    tools_dir = os.path.dirname(src_path)
    proc = subprocess.run([sys.executable, "-c", "import sprite_manifest"],
                          cwd=tools_dir, capture_output=True, text=True)
    ok(proc.returncode == 0, "`import sprite_manifest` works under plain python3 (%s)"
       % proc.stderr.strip())


def main():
    test_pack_grid_tiles_and_covers()
    test_cell_and_anchor_in_bounds()
    test_heading_round_trip_octants()
    test_heading_boundaries()
    test_facing_values()
    test_build_dumps_loads_validate_round_trip()
    test_schema_and_version_pinned()
    test_build_requires_multiple_of_directions()
    test_golden_consistency()
    test_no_bpy_numpy_pil_leak()
    print("PASS %d / FAIL %d" % (_pass, _fail))
    sys.exit(1 if _fail else 0)


if __name__ == "__main__":
    main()
