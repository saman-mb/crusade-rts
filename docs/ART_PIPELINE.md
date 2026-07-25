# Iso Sprite Pipeline (Blender)

How the Crusade unit/prop sprites are baked from a 3D model into a 2D
**8-direction** iso sprite sheet + JSON manifest, the StarCraft-1 / Age-of-Empires
way: the model lives in 3D, an orthographic iso camera + a fixed NW sun render it
onto a transparent film, and the model is spun about world Z in 45 deg steps to
produce the 8 facings. This story (#245) uses Blender's built-in **Suzanne** as
the stand-in model — no external art yet (that is #250/#251).

The layout, geometry, facing model, rig provenance and manifest schema are defined
**once** in `tools/sprite_manifest.py` (`SpriteManifest`, pure stdlib) and consumed
by the bpy driver (`tools/render_sprites.py`) and, in-engine, by whatever picks a
frame for a unit heading. This doc is the human-readable mirror of that module — if
you change one, change the other (the invariants in `tools/test_sprite_manifest.py`
lock the contract, and the `python-tools` CI job runs them on every push).

## Regenerate

```
blender --background --python tools/render_sprites.py -- --model suzanne --out assets/sprites/_test
```

writes `assets/sprites/_test/suzanne.png` (a **2048 x 256** RGBA sheet) and
`assets/sprites/_test/suzanne.json` (the manifest). Blender 4.5.9 LTS with a
Cycles-CPU render; ~1–2 min headless. Golden outputs are committed.

Calibration self-check (renders a 1x1 world tile through the same rig; the diamond
must measure ~128 x 64 centred on the anchor):

```
blender --background --python tools/render_sprites.py -- --calibrate --out /tmp/cal
blender --background --python tools/render_sprites.py -- --calibrate --markers --out /tmp/cal
```

## Geometry (mirror of `sprite_manifest` and `src/core/map_constants.gd`)

| Constant | Value | Meaning |
|---|---|---|
| `TILE_W x TILE_H` | `128 x 64` px | one iso diamond, true 2:1 (== `MapConstants.TILE_SIZE`) |
| `ELEVATION_STEP_PX` | `32` | == `MapConstants.ELEVATION_STEP_PX` (`TILE_H/2`) |
| `CELL_W x CELL_H` | `256 x 256` px | one sprite cell (2 tiles wide: room for body + SE shadow) |
| `ANCHOR` | `(128, 176)` | ground-contact point in every cell; world origin `(0,0,0)` projects here |

The 1x1 world tile renders as a `128 x 64` diamond centred on `ANCHOR`: horizontally
centred (`ANCHOR.x == CELL_W/2`) and low in the cell so the body rises above and the
SE cast shadow falls below. The manifest anchor is the sprite's Y-sort / placement
point (same contract as `TreeCatalog.ANCHOR` and `EntityPlacement`).

## Rig (echoed into every manifest's `rig` block)

| Setting | Value | Notes |
|---|---|---|
| projection | `orthographic` | ortho iso, no perspective |
| camera euler | `(60 deg, 0, 45 deg)` | 30 deg iso pitch (2:1), 45 deg yaw |
| `ortho_scale` | `2.82843` | `sqrt(2) * (CELL_W/128)` — makes a 1x1 tile a 128x64 diamond |
| `shift_y` | `+0.1875` | pushes world origin down onto `ANCHOR.y=176` (verified by `--calibrate`) |
| view transform | `Standard` | **not** AgX — keep sprite colour matching the flat PIL art |
| film | `transparent` | RGBA 8-bit PNG |
| samples / denoise | `128` / OpenImageDenoise | falls back to `256` / no-denoise if OIDN is unavailable headless (manifest records what was used) |
| key sun | NW, `energy 3.5`, warm `(1.0,0.86,0.66)`, `angle 2.5 deg` | the **only** shadow-caster; casts the SE (screen lower-right) shadow |
| fill sun | cool `(0.70,0.80,1.0)`, `energy 1.0`, no shadow | lifts the shadow side |
| world ambient | `(0.45,0.55,0.70)` @ `0.20` | cool sky bounce |
| ground | shadow-catcher plane at `Z=0` | transparent film keeps only the cast shadow |
| model | Suzanne, scale `0.7`, base on `Z=0`, warm-neutral Principled, smooth | footprint ~1 tile |

**Camera / lights / shadow are WORLD-FIXED; only the model rotates.** That is what
makes every facing lit identically and keeps the SE shadow from swinging — do not
parent lights to the model or rotate the camera.

### The NW-sun / SE-shadow convention (deviation note)

The art-director brief specified the key sun as `rotation_euler=(radians(58),0,0)`.
The marker calibration proved that pitch aims the sun toward **world +Y == screen
NE**, which throws the shadow to the screen *upper*-right. The manifest pins
`sun_compass = "NW"` and the terrain/tree art (`tools/gen_trees.py`) bakes a
NW-sun → **SE (screen lower-right)** shadow. So the driver pitches the sun about Y
instead — `rotation_euler=(0, radians(-58), 0)`, same 58 deg from vertical (~32 deg
sun elevation) — aiming the light toward **world +X == screen SE** so unit shadows
agree with the doodad/tree shadows. `--calibrate --markers` prints the world→screen
mapping used to derive this.

## 8-direction facing model

`DIRECTIONS = 8`, `ORDER = "cw_from_screen_east"`,
`DIRECTION_NAMES = [E, SE, S, SW, W, NW, N, NE]`.

`direction_facing(i)` is the SCREEN-space unit vector frame `i` depicts, `(cos, sin)`
of `i*45 deg` with **screen +Y pointing DOWN**: `i=0 -> (1,0)` East, `i=2 -> (0,1)`
South, `i=6 -> (0,-1)` North. Because +Y is down, increasing `i` sweeps **clockwise**
on screen. `frame_for_heading(vx, vy)` is the consumer's inverse — it snaps a screen
heading to the nearest of the 8 frames (`round(atan2/(pi/4)) mod 8`).

**How the model maps to a frame.** For frame `i` the driver sets
`model.rotation_euler.z = radians(BASE + STEP*i)` with **`BASE = 135`, `STEP = -45`**.
Suzanne's mesh faces world **-Y**; `BASE=135` puts frame 0's front on the world
direction that projects to screen East, and `STEP` is **negative** on purpose:
with screen +Y down and the manifest's clockwise order, a clockwise-on-screen advance
is a *negative* world-Z rotation. The 8 world rotations are exactly 45 deg apart (the
SC1/AoE way); on the foreshortened 2:1 screen the diagonals (SE/SW/NW/NE) read at
~27 deg from horizontal, not 45 — that is correct iso, and the game still works in
clean 45 deg screen space via `direction_facing` / `frame_for_heading`. Verified: the
S frame is perfectly frontal, the N frame is the back of the head, and every frame's
projected front matches its label.

## Sheet layout

`pack_grid(n_frames, cols=8)` is a **uniform** grid (every cell identical, not a
general packer): frame `i` sits at row-major cell `(i % cols, i // cols)`,
`CELL_W x CELL_H` each. With `cols == DIRECTIONS`, each row is one animation frame
across all 8 directions. `sheet_dimensions(n, cols)` returns the tight `(width,
height)`; the rects exactly tile it when frames fill complete rows. For this story
`n_frames = 8` (one static pose per direction) → a single `2048 x 256` row.

## Manifest schema (`schema: crusade.sprite_sheet`, `version: 1`)

```
{ "schema":"crusade.sprite_sheet", "version":1,                          // frozen
  "sheet":{"path":"res://.../suzanne.png","width":2048,"height":256,"cell":[256,256]},
  "rig":{"projection":"orthographic","elevation_deg":30.0,"yaw_deg":45.0,
         "ortho_scale":2.82843,"samples":128,"denoise":true,
         "view_transform":"Standard","sun_compass":"NW","blender":"4.5.9 LTS",
         "tile_size":[128,64],"elevation_step_px":32},
  "directions":{"count":8,"order":"cw_from_screen_east",
                "names":["E","SE","S","SW","W","NW","N","NE"]},          // frozen
  "anim":{"default":{"frames":1,"fps":0}},
  "frames":[ {"index":0,"dir":0,"dir_name":"E","facing":[1.0,0.0],
              "anim":"default","frame":0,"rect":[0,0,256,256],"anchor":[128,176]}, ... ] }
```

Frozen: `schema`, `version`, the `directions` block, the `sheet` keys, and every
`frames[i]` key. `validate()` rejects a wrong version/schema, a mismatched direction
block, sheet dims inconsistent with the frame count, and any out-of-bounds or
overlapping rect / out-of-cell anchor.

**Forward-compatible (additive-only).** More `anim` clips with `frames > 1` (idle /
walk, #250) become extra row groups and bump `anim.<clip>.frames`; a per-frame
`mask_rect` (team colour, #250) and a `footprint` (#251) are additive keys — none of
that is built yet. Bump `version` only for a *breaking* change.

## Determinism

Fixed Cycles seed (`0`), adaptive sampling off, `Standard` view transform, and the
pure `sprite_manifest` core make the sheet + manifest reproducible run-to-run.
Regenerate with the command above and diff — the golden `assets/sprites/_test/`
outputs should match (Cycles CPU is deterministic for a fixed seed/thread build).
`tools/test_sprite_manifest.py` (stdlib only — no bpy/numpy/PIL) asserts the golden
manifest still equals what `sprite_manifest` recomputes.
