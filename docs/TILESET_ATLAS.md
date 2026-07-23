# Terrain Atlas Authoring Contract

How to author `assets/tilesets/terrain_atlas.png` so it drops into the engine
without reading the generator source. The layout is defined once in
`src/core/tileset_constants.gd` (`TileSetConstants`) and consumed by the tileset
builder, the dual-grid autotiler, and the water-animation driver. This doc is the
human-readable mirror of those constants — if you change one, change the other
(the tests in `test_tileset_builder.gd` / `test_dual_grid.gd` lock the contract).

## Geometry

| Constant | Value | Meaning |
|---|---|---|
| `REGION_SIZE` | `128 × 64` px | One tile region (HD 2:1 isometric diamond; equals `MapConstants.TILE_SIZE`) |
| `ATLAS_PX` | `512 × 384` px | Whole atlas = **4 columns × 6 rows** of regions (row 5 = ramp tile) |
| `DUALGRID_ORIGIN` | `(0, 0)` | Atlas cell of the 4×4 dual-grid block's top-left |

Atlas **cell** coordinates below are `(col, row)`, each cell being one
`REGION_SIZE` region. Pixel rect of cell `(c, r)` is
`(c·128, r·64)` → `(c·128 + 128, r·64 + 64)`.

## Dual-grid block — rows 0–3

The dual-grid autotiler draws *display* tiles that each straddle the corners of 4
*logical* cells. Those 4 corners' filled/empty states form a **4-bit corner
mask**. The bit convention is:

```
corner -> bit:   TL = 1   TR = 2   BL = 4   BR = 8
```

Mask `m` (1–15) selects atlas cell `(m & 3, m >> 2)`. Mask `0` (nothing filled)
is the empty sentinel `(-1, -1)` — **leave physical atlas cell `(0, 0)` blank**.
Author each mask's art at exactly this cell:

| mask | corners filled | atlas cell (col,row) |
|----:|---|:---:|
| 0 | *(none)* | — *(blank; sentinel)* |
| 1 | TL | (1, 0) |
| 2 | TR | (2, 0) |
| 3 | TL TR | (3, 0) |
| 4 | BL | (0, 1) |
| 5 | TL BL | (1, 1) |
| 6 | TR BL | (2, 1) |
| 7 | TL TR BL | (3, 1) |
| 8 | BR | (0, 2) |
| 9 | TL BR | (1, 2) |
| 10 | TR BR | (2, 2) |
| 11 | TL TR BR | (3, 2) |
| 12 | BL BR | (0, 3) |
| 13 | TL BL BR | (1, 3) |
| 14 | TR BL BR | (2, 3) |
| 15 | TL TR BL BR *(full)* | (3, 3) |

The rule is just `cell = (mask & 3, mask >> 2)` — column is the low 2 bits
(TL/TR), row is the high 2 bits (BL/BR).

## Water animation strip — row 4

| Constant | Value | Meaning |
|---|---|---|
| `WATER_ANIM_COORDS` | `(0, 4)` | Atlas cell of the first animation frame |
| `WATER_FRAMES` | `4` | Number of frames |
| `WATER_COLUMNS` | `4` | Frames per row before wrapping to the next row |
| `WATER_FRAME_DURATION` | `0.2 s` | ~5 fps; mode is `RANDOM_START_TIMES` |

Frames run left→right from `WATER_ANIM_COORDS`, wrapping downward every
`WATER_COLUMNS`. With the current values that's cells `(0,4) (1,4) (2,4) (3,4)`.
The whole strip must fit inside the region grid — `test_animation_bounds_independent`
fails if `WATER_FRAMES`/`WATER_COLUMNS`/`WATER_ANIM_COORDS` push it past the edge.

## Ramp tile — row 5

| Constant | Value | Meaning |
|---|---|---|
| `RAMP_COORDS` | `[(0, 5)]` | Atlas cell(s) of the ramp tile(s), row 5 col 0 |
| `RAMP_LAYER` | `"ramp"` | Name of the `TYPE_BOOL` custom-data layer the builder populates |

Cell `(0, 5)` is the **ramp tile**. Like walkability it carries a per-tile
`ramp` `TYPE_BOOL` custom-data flag (a second layer alongside `walkable`), set
`true` for cells in `RAMP_COORDS`. A ramp tile is painted **on the HIGH tier at a
transition cell** and marks a low↔high cross-tier connection:
`NavMapBuilder.ramps_from_layers` derives a `NavRamp` from each painted ramp tile
to each walkable cartesian-neighbor cell on the tier below (#78). The ramp tile is
itself **walkable** (a unit stands on it) — it is deliberately *not* in
`NON_WALKABLE_COORDS`, so `coord_walkable((0, 5))` is already `true`. Placeholder
art for now; real ramp/cliff art is authored under #33.

## Per-tile origin

`TEXTURE_ORIGIN` is `(0, 0)`: art that is centered on the cell origin and exactly
fills the diamond needs no correction (Godot's even-dimension half-offset quirk,
godotengine/godot#65963, already re-centers it). For **taller** art — props whose
rect extends above the diamond — shift `texture_origin.y` by `-REGION_SIZE.y / 2`
to re-anchor the visual base onto the diamond (see issue #29).

## Normal map (lighting)

For dynamic lighting (epic #66), a tangent-space **normal map** is derived from
the diffuse atlas so `Light2D` shades the diamonds with surface relief instead of
flat-brightening. It is generated, not hand-authored:

```
python3 tools/gen_normal_atlas.py    # -> assets/tilesets/terrain_atlas_n.png
```

`gen_normal_atlas.py` (L1 / #82) computes per-texel normals from diffuse
luminance, **region-aware**: each 128×64 region is processed in isolation so
gradients never bleed across the zero-separation region borders, texels outside
the diamond (low diffuse alpha) are forced neutral `(128,128,255)`, and each
region's 1px border is neutralised. A flat region therefore encodes uniform
`(128,128,255)`. The output (`terrain_atlas_n.png`, `512×384` RGB) is a **CC0
derivative** of the CC0 diffuse atlas. Invariants are covered by
`tools/test_gen_normal_atlas.py` (run manually — Python tools are outside the
Godot CI test glob). `--invert-y` is available if Godot wants the green channel
flipped.

**Wiring (L3 / #84).** `TileSetBuilder.make_atlas_texture(diffuse, normal)`
pairs the diffuse + normal atlases into a **`CanvasTexture`** (`diffuse_texture`
+ `normal_texture`) that backs the atlas source, so a `Light2D` shades the
diamonds via the normal map. `build_default_terrain_tileset()` loads both from
`TileSetConstants.ATLAS_PATH` / `NORMAL_ATLAS_PATH` — the single place the editor
boot and the dev-menu catalog get the pairing. The world sun is a
`DirectionalLight2D` (`src/nodes/sun_light.gd`) with tunable angle/energy/color
that tints from the L2 `DayNight` ambient. Because the terrain diffuse is
mid-tone and the normal map is deliberately gentle (flat grass, not authored
height), the sun produces **fine-grained directional relief that shifts with sun
angle** — bold per-*tile* depth is L4 (#85), and richer relief awaits authored
art (#33).

## Import / filtering

The atlas relies on the project-global `default_texture_filter = 1` (Linear, no
mipmaps): mipmaps would bleed neighbouring zero-separation atlas regions into each
other and show seams at zoom-out. See the comment block in `project.godot`.
Pinning this per-atlas via a committed `.import` is tracked in issue #28.

**Mipmaps decision (L3 / #84): stay OFF.** The lighting epic flagged an open
question — lighting benefits from mipmaps, but the zero-separation atlas bleeds
region seams at zoom-out with them on. Rendering the lit terrain at **zoom 0.5**
(min zoom, worst-case minification) showed **no seams** with mipmaps off, and
normal-mapped `Light2D` shading does **not** require mipmaps. So the atlas keeps
mipmaps off; no filtering changed for L3, so seams are identical to pre-lighting.
