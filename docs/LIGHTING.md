# Dynamic Lighting

How the map's 2D lighting fits together, and the design decisions behind each
layer. This is the epic #66 lighting stack (terrain-first; unit/prop point-lights
are deferred to post-V3). All four layers are self-verified by rendering the real
Forward+ project offscreen (rootless Xvfb + software Vulkan), not by eyeballing.

## The stack

| Layer | Node / model | What it does |
|---|---|---|
| **L1** — normal atlas (#82) | `tools/gen_normal_atlas.py` → `terrain_atlas_n.png` | Per-texel surface normals derived from the diffuse atlas, so light shades relief instead of flat-brightening. |
| **L2** — ambient / day-night (#83) | `DayNight` (`src/core/day_night.gd`) + `day_night_driver.gd` on a `CanvasModulate` | A time-of-day ambient color that MULTIPLIES all world rendering (warm dawn/dusk, cool-dim night, neutral noon). |
| **L3** — sun (#84) | `Sun` = `DirectionalLight2D` (`src/nodes/sun_light.gd`) + normal map wired onto the TileSet `CanvasTexture` (`tileset_builder.gd`) | A directional sun that sweeps highlights across the normal-mapped diamonds; tinted by the L2 day/night palette each frame. |
| **L4** — elevation shading (#85) | `ElevationShade` (`src/core/elevation_shade.gd`), applied in `map_system.gd` | A per-tier `modulate` ramp so higher elevation tiers catch more light and a terraced map reads with height. |

## L4 — elevation-aware shading

The isometric map is a stack of flat `TileMapLayer`s, one per elevation tier,
each lifted `MapConstants.ELEVATION_STEP_PX` (32 px) higher than the tier below.
L1–L3 light **every tier identically** — the sun and normal map don't know a tile
is on a plateau — so a raised tier reads at the same brightness as the flat ground
it sits on, flattening the height illusion.

`ElevationShade.shade_at(level)` supplies the missing cue: a `modulate` color that
brightens with elevation, with a warm sun-ward bias (consistent with the L3 sun
tint). `MapSystem._apply_elevation_shading()` writes it onto each elevation
layer's `modulate` once at `_ready` (and in-editor via `@tool`).

Key properties:

- **Tier 0 is exactly neutral white**, so existing flat single-tier maps render
  byte-identically to pre-L4 — the height cue only lifts *raised* tiers.
- **Multiplies with the L2 ambient.** Because `TileMapLayer.modulate` composes
  with the `CanvasModulate`, tier contrast is preserved proportionally across the
  whole day/night cycle — a plateau stays relatively brighter at dusk and at
  night, not just at noon.
- **Sorting is untouched.** The shading sets `modulate` only; it never changes
  `position` or `y_sort_origin`, so per-tile Y-sort at tier boundaries is exactly
  as before (no new z-fighting surface).
- **Tunable** on `MapSystem`: `elevation_shade_step` (per-tier brighten;
  default 0.09 ≈ +9 % luminance/tier, measured) and `elevation_shade_tint` (the
  warm color of the added light). `elevation_shade_step = 0` opts out entirely.

Rendered measurement (noon, software Vulkan): mean grass luminance
**tier 0 ≈ 0.421 → tier 1 ≈ 0.457 (+8.6 %) → tier 2 ≈ 0.494 (+17.2 %)** — a clearly
readable, monotonic step with no clipping.

### Honest scope: no cliff-*face* geometry yet

Elevation in the terrain is a pure vertical **pixel offset** of stacked flat
diamonds — there are **no cliff-face or riser tiles** (cliffs exist only in the
nav mesh as hard walls, `nav_ramp.gd`). And because `ELEVATION_STEP_PX` (32) is
exactly the iso half-row, a *filled* plateau tiles almost seamlessly into the row
behind it, so height reads at the plateau **silhouette / edges**, reinforced by
the L4 brightness step — not as a shaded vertical wall. Bold, directional
cliff-face shading needs authored riser art (relates to #33) and/or per-cell
ambient-occlusion on the tier below an overhang; both are future work layered on
top of this model, which establishes the per-tier lighting contract.
