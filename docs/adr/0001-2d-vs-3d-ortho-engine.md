# ADR 0001 — Gameplay engine: pure-2D vs 3D-orthographic

- **Status:** Proposed (spike branch `spike/option-b-3d-ortho`)
- **Date:** 2026-07-26
- **Deciders:** project owner (to ratify)

## Context

`crusade-rts` is a Godot 4.4.1 isometric RTS. Its **map/terrain layer is mature and
pure-2D**: a positional mega-tile HD-atlas terrain system (seamless de-gridded ground,
HD cliffs, trees, water), a tile map editor, map save/load serialization, and a
hand-rolled elevation + navigation stack — `nav_tier_grid`, `nav_portal_graph`,
`nav_ramp`, `flow_field`, `steering`, `cliff_renderer`, `shore_renderer`,
`elevation_lerp`, `elevation_shade`. Rendering is `Node2D` + dimetric `TileMapLayer`,
`Camera2D`, `canvas_item` shaders, `Light2D`.

The **gameplay layer is greenfield**: units are still magenta placeholders, there are no
buildings, and combat/projectiles/production don't exist. The nav stack is a library not
yet driving any units. This is the cheapest possible moment to reconsider the engine
before we build hundreds of units on top of one.

**The question:** build the gameplay layer on **Option A** (continue pure-2D) or
**Option B** (Godot's 3D engine + orthographic `Camera3D` + a low-res pixel-art render
pipeline, with 3D-mesh / billboard actors)?

### Criteria

Depth sorting at unit scale · verticality (high/low ground, ramps) · migration cost off
the shipped 2D terrain · **reversibility** (this is a foundational, one-way-door choice) ·
aesthetic fit (our terrain art is now HD painted/photographic, not strict pixel-art) ·
second-system / rewrite risk vs sunk value.

## Options considered

### Option A — Pure 2D (`Node2D` + `TileMapLayer`) — status quo

The shipped engine. Everything Blizzard hand-built for SC1/BW, we also hand-build:

- **Depth sorting** is manual `y_sort` / `z_index`. Works for terrain; gets fragile with
  200+ units, air units, tall buildings, and multi-tier occlusion (units clipping walls,
  offset selection, projectiles as math hacks).
- **Verticality** is *faked* — and we're already paying for it: `nav_tier_grid`,
  `nav_portal_graph`, `nav_ramp`, `elevation_lerp/shade`, `cliff_renderer`,
  `shore_renderer` exist precisely to simulate high/low ground the 2D engine has no
  concept of.
- **Migration cost: zero** — it's what we have, and the map already looks great (the
  HD terrain overhaul just shipped).
- Proven (SC1/BW shipped this way); the team is fluent in it.

### Option B — 3D engine + orthographic camera + pixel-art pipeline — the spike

A ~200-line vertical slice (`spike/ortho3d/`) proved this works in Godot 4.4.1:

- **Pixel-art for free** — the 3D world renders into a low-res `SubViewport`
  (384×216, `stretch_shrink`) upscaled **NEAREST** → crisp pixels. (Rendered fine on
  software Vulkan.)
- **Depth sorting for free** — a unit on the plateau is occluded by the tower purely by
  the hardware **Z-buffer**; zero sort code.
- **Real verticality** — two terrain tiers + a ramp; a unit's elevation is just its `Y`.
  The entire faked-elevation stack above collapses into real transforms +
  `NavigationServer3D` + raycasts.
- **3D picking** — camera ray + `PhysicsRayQueryParameters3D`.
- **Real dynamic lighting/shadows** — a `DirectionalLight3D` rakes the tiers; not painted
  into sprites.
- Asset pipeline fits epic #244's "model in 3D" direction natively (and can still
  pre-render to sprites if desired).

**Migration cost is the catch:** the mature 2D terrain — mega-tile atlas system, editor,
save/load serialization — does **not** port to `TileMapLayer`-free 3D. Terrain would be
rebuilt as a 3D heightmap/mesh. The map *data model*, art direction, and HD textures
(as 3D materials) carry over; the *renderer* and the faked-elevation code do not.

## Decision

**Adopt Option B (3D + orthographic camera) as the engine _destination_ — but reach it
through a _staged migration gated on epic #221_, not a flip now.** Preference order:
**staged-toward-B behind the #221 seam ≫ pure-B-now ≫ pure-A-forever.** Status: **Proposed**
(ratify only after the gating conditions below are green).

Three findings drive this:

1. **"3D gameplay on the 2D map" is not a coherent hybrid.** A `Camera3D` cannot
   depth-sort a `MeshInstance3D` unit against a `TileMapLayer` cliff — different render
   paths. So B necessarily drags the terrain renderer into 3D too (the spike quietly
   proves this by rebuilding terrain as 3D boxes). **B is a whole-render-engine
   migration, and its real blast radius is the mature terrain + editor pipeline** — the
   part that is shipped and looks good. That is the true cost, easy to under-count from
   the spike's ~200 lines.

2. **But the gameplay layer is unbuilt, so B throws away _zero_ gameplay.** Units are
   placeholders; there is no combat/projectile/building code. The sunk value at risk is
   entirely terrain + editor + nav-cores + save/load. We are choosing an engine for a
   layer that does not exist yet — the cheapest such moment there will ever be.

3. **Epic #221 (decouple the logical terrain model from `TileMapLayer`s) is the linchpin
   that converts this one-way door into a sequence of two-way doors.** Once the logical
   model is the source of truth and the `TileMapLayer` stack is a pure *view*, swapping to
   a 3D view is a view-adapter swap, the save format stores terrain *types* (not atlas
   coords), and **A keeps building behind the seam** — so B can be A/B-tested against the
   *same* model before committing. **Do #221 regardless of this decision; it is pure
   upside.**

### Aesthetic correction (important)

The spike's pixel-art `SubViewport` proves the technique, but for *this* project it is a
**mismatch, not the target.** Our terrain art is now **HD painted/photographic** (Poly
Haven). B's real value here is **3D spatial math + real dynamic lighting**, run at **full
resolution with HD PBR materials** — which fits the HD look *better* than hand-painted 2D
lighting. We would keep the ortho camera and depth buffer; we would drop the pixel
down-res. (If a retro look were ever wanted, the pipeline is there — but that is a
separate art call, not the reason to adopt B.)

## Consequences

**What we gain:** free depth sorting (hardware Z-buffer — including the air-unit and
multi-cell-building cases the current 2D `y_sort` contract explicitly cannot model),
real verticality (Y = elevation, ramps/cliffs are geometry), real dynamic light/shadow,
and native fit with epic #244's "model in 3D" direction. We **delete ~340 LOC of
accidental complexity** — `cliff_renderer`, `shore_renderer`, `elevation_shade`,
`elevation_lerp`, and the `EntityPlacement` origin-sort contract — all of which exist only
to fake 3D in a 2D renderer.

**What we reuse (do NOT rewrite):** the pure cores are dimension-agnostic — nav
grid/portal/ramp, `flow_field`, `steering`, `formation`, `selection` reason over
`(cell, tier)` and `Vector2` plane math (→ the XZ plane). Also the map
schema/serializer/migrator, the editor brush/flood/stroke/undo *logic*, and the HD Poly
Haven textures (as triplanar 3D materials, as the spike already does).

**What must be rebuilt (the real cost):** the mega-tile HD-atlas terrain renderer
(`tileset_builder`, `dual_grid`, `variation_picker`, the `TileMapLayer` stack) and the
editor's paint target. Plus a **bounded `v2 → v3` save-schema migration** — today
`MapSerializer` persists per-cell `source_id`/`atlas_coords` (names 2D tiles); #221 moves
it to terrain *types*. The codebase already runs a `map_migrator` at `CURRENT_SCHEMA = 2`,
so this is a known pattern, not new machinery.

**Reversibility:** one-way *unless* gated on #221. With #221 in place, conditions 1–4
below keep every step a two-way door.

**Second-system risk (the honest counter):** A is ~14k LOC, 44 headless suites, shipped
and good-looking *today*; the hard depth cases are speculative (SC1 shipped exactly this
2D model). The cliff/shore work is partly *authored art direction*, not pure waste — a
generic `DirectionalLight3D` gives correct-but-generic light where hand-placed sprites give
silhouette control. **If B cannot re-host the HD terrain look at parity, A wins by
default.** Which is why B is gated, not flipped.

### Gating conditions — ratify B only when all are green

1. **#221 shipped** — logical model is the nav + serialization source of truth, the 2D
   view is a pure adapter, and A still builds behind the seam.
2. **HD look-parity slice on the _real_ project** (not primitives): Poly Haven terrain as
   heightmesh/triplanar under the real day/night grade, screenshotted A-vs-B. If 3D can't
   match the shipped look → **stop, A wins** (and #221 was still worth doing).
3. **Perf floor at 10×**: 200+ animated actors + shadows in the ortho viewport, on both
   the software-Vulkan CI floor and a real GPU.
4. **Editor parity + map migration**: paint/flood/undo/save work against the 3D view;
   existing `showcase.json` migrates cleanly.
5. **Nav decision explicit**: default to *reusing the grid-A\* cores* (cheap, proven) over
   adopting `NavigationServer3D` (new dependency/failure surface) — choose deliberately.
6. **Actor art pipeline provisioned** — confirm low-poly/billboard production (the Blender
   render harness is a positive signal) before committing.

Conditions **1–4 are the gate**. Until they are green, every step stays a two-way door.

### Next step

Not "start rewriting in 3D." The next unit of work is **epic #221** — it is required
either way, and it is the mechanism that de-risks B. After #221, build gating condition 2
(the HD look-parity slice) as the real go/no-go.

## Verification

The Option B claims are not hand-waved — the spike renders and demonstrates each one.
See `spike/ortho3d/README.md` to run it (`godot --path . res://spike/ortho3d/ortho3d_spike.tscn`)
and `_spike_b.png` for the captured frame.
