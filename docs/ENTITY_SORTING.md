# Entity Depth-Sorting Contract

How a game entity — a unit, or an elevated prop — sits ON a raised terrain tier
yet still depth-sorts correctly against the cliffs and the ground below it. This
is the epic #64 / issue #107 contract that lets moving things live on the stacked
isometric elevation terrain without popping in front of or behind geometry they
should not. The vertical geometry is defined once in `MapConstants` and the
sort-safe placement math once in `EntityPlacement` (`src/core/entity_placement.gd`),
consumed by `MapSystem` (`src/nodes/map_system.gd`); this doc is the human-readable
mirror of those. The pure core is locked by `test_entity_placement.gd`.

## The problem

The isometric map is not one TileMapLayer — it is a **stack** of them, one per
elevation tier. Each `Elevation{n}` layer is lifted on screen by
`MapConstants.elevation_offset(n)` (`position.y = -32·n`) so tier 1 draws a
half-row above tier 0, and given a compensating `y_sort_origin = 32·n` so it still
*sorts* at the ground it represents (see below). The whole thing lives under a
`y_sort_enabled` root (`MapSystem`).

Dropping a plain Y-sorted sprite into that stack is the classic Godot isometric
failure mode. If you place a unit at a raised tile's screen position, the lift you
add to make it stand ON the plateau *also* shifts its Y-sort key — so the unit
sorts as if it were a half-row further back per tier, and it renders **behind**
the cliff it is standing on, or **in front of** a unit that is actually south of
it. If instead you place it at the unlifted footprint depth so it sorts right, it
floats visually below the ground it is supposed to be on. You cannot satisfy both
"stands on the tier" and "sorts by footprint" by picking a single `position` — the
two pull in opposite directions by exactly the lift. The contract resolves this by
splitting the two concerns onto two different transforms: the **node origin**
(which sorts) and the **art offset** (which draws).

## The sorting fact this is built on

Under a `y_sort_enabled` parent, a **TileMapLayer** exposes a `y_sort_origin`
knob: it can advertise a sort depth different from where its pixels land. Each
elevation layer uses it precisely this way. It draws its tiles lifted by `-32·tier`
but carries `y_sort_origin = +32·tier`, so its effective sort key is

```
(footprint_y − 32·tier) + 32·tier == footprint_y
```

i.e. every tier sorts at its **unlifted footprint depth** `tile_y`, regardless of
how high it is drawn. The load-bearing invariant is that the lift and the
compensation are exact negatives:

```
elevation_offset(tier).y + ELEVATION_STEP_PX·tier == −32t + 32t == 0
```

`ELEVATION_STEP_PX` is `32` = `TILE_SIZE.y / 2`, one iso half-row — the reason a
lifted-and-compensated tier tiles seamlessly against the row behind it.

**The catch for entities:** `y_sort_origin` exists **only on `TileMapLayer`**, not
on a plain `Node2D`. (Verify: `"y_sort_origin" in Node2D.new()` is `false`.) A
`Node2D` unit under a Y-sorted parent is sorted purely by the **global Y of its
origin** — there is no per-node knob to decouple its sort depth from its drawn
position. So entities cannot copy the layer's lift-and-compensate trick. They
invert it instead.

## The contract

An entity keeps its **origin at the unlifted footprint** and raises only its
**art**:

1. Parent it to `MapSystem.entity_parent_for_tier(tier)` — a plain Y-sorted
   `Node2D` container **at the origin** (no lift, no `y_sort_origin`).
2. Set the entity node's `position = EntityPlacement.ground_position(cell)` —
   exactly `IsoCoord.cart_to_iso(cell)`, the unlifted diamond center. Because a
   `Node2D` sorts by its origin, the entity now sorts at `cell`'s footprint depth,
   **identical to that tier's floor tile**.
3. Offset the entity's **art** (its `Sprite2D`/child `position` or `offset`) by
   `EntityPlacement.visual_offset(tier)` = `(0, −32·tier)`, lifting the drawn body
   onto the raised ground **without moving the origin** — so the lift never enters
   the sort key.

That split is the whole idea: **origin sorts, art draws.** A unit on a hill
interleaves with units on the ground below it by real footprint order, is occluded
by a cliff genuinely south of it, and still visually stands on its plateau.

| Concern | Transform | Value |
|---|---|---|
| Sort depth (footprint) | entity node `position` | `EntityPlacement.ground_position(cell)` — tier-independent |
| Visual lift onto the tier | entity **art** `position`/`offset` | `EntityPlacement.visual_offset(tier)` = `(0, −32·tier)` |

Moving up or down a ramp changes the tier's *visual lift* (and, for tidiness, the
parent container), but **not** the sort anchor — the origin stays at the footprint
throughout. Reparent to `entity_parent_for_tier(new_tier)` and update the art
offset to `visual_offset(new_tier)`.

### Why per-tier containers at all

The `EntityTier0/1/2` containers are all plain Y-sorted `Node2D`s **at the origin**
— they contribute nothing to sorting (they have no lift and no `y_sort_origin`; a
`Node2D` has none to give). They exist purely for **organization**: you can tell a
unit's tier from its parent, and a ramp traversal is a clean reparent. All three
containers share the single Y-sort space of the map root, so a unit under
`EntityTier2` still interleaves cell-for-cell with a unit under `EntityTier0`.

## Tie-break rationale

Two things can share a sort key. The important tie is a unit standing on the tile
it occupies: same footprint cell, so same sort depth. Godot breaks equal-key ties
by **tree order** — later sibling draws on top. In `map_system.tscn` the entity
containers are declared **after** the terrain layers:

```
Elevation0, Elevation1, Elevation2, Objects, EntityTier0, EntityTier1, EntityTier2
```

So a same-footprint tie between a unit and the floor tile it stands on breaks in
the **unit's** favor — it draws on top of its own floor, which is what you want.

This tie-break is only doing work for the coincident-footprint case. **Cross-cell
occlusion** — a cliff or a unit one row south — is resolved by a real Y difference
in the sort key, not by tree order; the tie-break never has to adjudicate it.

## The pure core — `EntityPlacement`

All the geometry is a headless `RefCounted` with no Node dependencies, so it is
unit-testable. Every vertical value is sourced from `MapConstants` — the core never
re-derives a tile size or an elevation step inline.

| Method | Returns | Use |
|---|---|---|
| `ground_position(cell)` | `IsoCoord.cart_to_iso(cell)` | The entity node's `position` — the **sort anchor** (unlifted footprint). Tier-independent. |
| `visual_offset(tier)` | `MapConstants.elevation_offset(tier)` = `(0, −32·tier)` | Offset applied to the entity's **art** — the visual raise onto the tier. |
| `visual_position(cell, tier)` | `ground_position(cell) + visual_offset(tier)` | Convenience: where the art anchor lands on screen. **Never** use this as the node `position` — that re-bakes the lift into the sort key. |

The load-bearing guarantee, checked directly in `test_entity_placement.gd`: an
entity's sort anchor (`ground_position(cell)`) takes **no tier** and equals
`cart_to_iso(cell)` for every cell — so its sort depth is its footprint depth on
**every** tier (the tier-independent interleave). `visual_offset` carries the whole
elevation and never touches that anchor; `visual_position` differs from the anchor
by exactly the lift, confirming the raise is a draw offset kept out of the sort key.
Tier 0 is a pure no-op (`visual_offset(0) == Vector2.ZERO`), so a flat single-tier
map behaves exactly as if the contract were not involved.

## Elevated props / Objects, and why not `Objects0/1/2`

The map has a single `Objects` TileMapLayer, and it is **tier-0-only by contract**:
it carries no lift and no `y_sort_origin` compensation, so it can only place a prop
on the ground plane. It structurally **cannot** put a prop on an elevated tile —
there is no lifted Objects layer for tiers 1+.

The recommendation is **not** to grow a parallel `Objects0/1/2` layer stack.
Elevated props should go through this entity contract instead — an elevated prop is
just *a unit that does not move*: parent it to the tier's `EntityTier{n}` container,
set `position = ground_position(cell)`, and raise its art by `visual_offset(tier)`.
One mechanism then covers both units and raised props, and both interleave with
terrain and with each other by the same rule.

(This is a separate concern from issue #69, which is about the `Objects` overlay's
own TileSet / source type, not about elevation.)

## Verification

Two legs, matching the house standard of "prove the core headless, prove the look
by rendering the real project."

- **Headless core tests.** `test_entity_placement.gd` runs under
  `godot --headless` and locks the pure geometry: the tier-independence of
  `ground_position`, its delegation to `IsoCoord`, tier-0 neutrality, the
  `visual_offset` single-source wiring back to `MapConstants`, and that
  `visual_position` raises the art by the lift only while the sort anchor is
  untouched. This proves the **math** is sort-safe — it does not, and cannot, prove
  the runtime scene tree is wired to it.
- **Visual render-harness.** The runtime wiring is proven with a companion
  render-harness scene, `src/nodes/entity_sort_harness.tscn`, driven offscreen
  under Xvfb + software Vulkan (the same rootless harness the lighting stack uses):
  markers parented to `EntityTier0/1/2` over a stepped cliff — origin at footprint,
  art raised by `visual_offset(tier)` — must occlude and interleave with the terrain
  correctly (a marker drawn over its own floor, and behind a cliff that is south of
  it). This closes the gap the headless tests leave (that `MapSystem` actually hands
  out working containers and that a footprint-origin entity sorts as predicted).

## Honest scope

- The contract sorts entities by their **single footprint cell**. A unit is a point
  on the grid for depth purposes; multi-cell footprints (a large prop straddling
  several tiles at different depths) are not modeled and would need a richer sort
  key.
- Tier changes are a discrete **reparent** at ramp boundaries, not a continuous
  blend. Mid-step interpolation up a ramp (a unit visually halfway between tier 0
  and tier 1) is out of scope; the entity belongs to exactly one tier at a time.
  This matches the current terrain, which has no cliff-face geometry (see
  `docs/LIGHTING.md`, "no cliff-face geometry yet") — the entity contract inherits
  the same stepped-not-ramped world model.
- The contract assumes **unscaled** containers and entities (1:1). Camera zoom is
  fine — it scales the whole canvas uniformly — but per-node scaling of a container
  or entity would desync the footprint math, the same caveat
  `IsoCoord.tile_world_pos` carries (#15).
