# Crusade — Isometric Map Engine & Editor Framework (V2)

[![CI](https://github.com/saman-mb/crusade-rts/actions/workflows/ci.yml/badge.svg)](https://github.com/saman-mb/crusade-rts/actions/workflows/ci.yml)

> **Codename:** Crusade (`crusade-rts`)

A high-performance 2D isometric map runtime and in-game editor built in **Godot 4**.

The goal is a polished, modern look and feel — think a **2D isometric StarCraft II**: high-resolution
sprites, crisp 2:1 diamond projection, smooth RTS camera, animated terrain, and a fast in-game editing
loop for iterating on tilesets and layouts without needing units in the scene.

> **Status:** In development. Story #1 (project architecture & multi-layer map system), Story #3 (TileSet configuration & animated tiles), and Story #4 (in-game map editor core tooling) are implemented on `main`; the remaining stories are tracked as GitHub issues.

## Objective

Establish the project architecture, tile rendering, RTS camera movement, elevation layers, map
serialization, and seamless developer workflows to quickly test tilesets and map layouts.

## Scope (Epic V2)

| # | User Story |
|---|------------|
| 1 | Project Architecture & Multi-Layer System Setup |
| 2 | RTS Camera & Viewport Controls |
| 3 | TileSet Configuration & Animated Tiles Support |
| 4 | In-Game Map Editor Core Tooling |
| 5 | Serialization & In-Game Load/Save Engine |
| 6 | In-Game Menu & Dev Mode Switching |
| 7 | Map File Schema & Validation Specification |
| 8 | Coordinate Systems & Elevation Projection Core Math |
| 9 | Advanced Editor Architecture & Command Pattern Undo/Redo |
| 10 | Multi-Level Navigation Mesh Generation & Ramp Transitions |

## Planned Directory Layout

```
res://
├── src/
│   ├── core/      # runtime map system, math, serialization
│   ├── editor/    # in-game editor tooling, brushes, undo/redo
│   └── nodes/     # reusable scene nodes
├── assets/
│   ├── tilesets/  # .tres TileSet resources
│   └── maps/      # serialized map JSON
```

## Engine

- **Godot 4.x** (Forward+ / Mobile renderer)
- `TileMapLayer`-based stacked elevation layers with Y-Sort

## TileSets & Animated Tiles (Story #3)

Terrain rendering is driven by a programmatically built TileSet — no `.tres` is
hand-authored in the editor, so the whole thing is constructible headlessly and
diff-reviewable in code.

- **Isometric geometry.** The TileSet is `TILE_SHAPE_ISOMETRIC` +
  `TILE_LAYOUT_DIAMOND_DOWN` with a `128x64` true 2:1 HD diamond tile. Geometry
  comes from `MapConstants.TILE_SIZE` (the single source of truth); the atlas
  layout (region size, atlas dimensions, lookup table) lives in
  `TileSetConstants`. `TileSetBuilder.build_terrain_tileset(texture)` assembles
  the atlas source, one tile per distinct dual-grid coord, and the water tile.
- **Animated water.** The water tile is a 4-frame strip at `0.2s`/frame (~5 fps)
  using Godot's `TILE_ANIMATION_MODE_RANDOM_START_TIMES`, so neighbouring water
  tiles desync instead of rippling in lockstep.
- **Dual-grid autotiling.** Clean SC2-style edges come from a dual grid: the
  display grid is offset half a tile from the logical grid, so each drawn tile
  straddles 4 logical cells whose filled/empty states form a 4-bit corner mask
  (16 states → 15 non-empty tiles, mask 0 is the empty sentinel). The mask
  selects an atlas coord via `TileSetConstants.LOOKUP`. This is our own pure
  integer-space `DualGrid` core (`src/core/dual_grid.gd`) — a **deliberate
  choice** over the `TileMapDual` editor plugin, so the logic stays testable,
  Node-free, and decoupled from any editor tooling.
- **HD render settings.** The StarCraft II-style look relies on Forward+
  rendering, MSAA 2D 2x, Linear texture filtering, and 2D pixel snapping turned
  OFF (see `[rendering]` in `project.godot`). Mipmaps are intentionally left off
  the global default to avoid atlas-seam bleed on the zero-separation terrain
  atlas; layers that need them opt in per-texture.

The Story-#3 `_demo_paint_pond()` placeholder has been removed from
`src/nodes/map_system.gd`. Runtime painting is now driven by the in-game
MapEditor (Story #4): **Left-click = Paint**, **Right-click = Erase**, **`[` /
`]` or number keys = switch the active elevation layer**, and a translucent
hover preview shows the tile under the cursor. The editor reuses
`IsoCoord.pick_cell_global` for camera-safe, edge-robust screen→cell projection,
so painting stays accurate at any zoom or pan.

## In-Game Map Editor (Story #4)

The in-game editor is instanced live in the main scene as a `MapEditor` child of
`MapSystem`, so painting works at runtime without any Godot-editor tooling.

- **Controls.** Left-click paints the active tile, right-click erases, `[` and
  `]` (or the number keys) switch the active elevation layer, and a translucent
  hover preview renders the tile under the cursor before you commit it.
- **Camera-safe projection.** Screen→cell picking goes through
  `IsoCoord.pick_cell_global`, so paints land on the correct cell regardless of
  camera zoom or pan and stay robust at diamond edges.
- **Split of concerns.** `BrushCore` (`src/editor/brush_core.gd`) holds the
  pure, headless-tested brush decision logic — what a paint/erase at a given cell
  and layer resolves to — with no Node or scene dependencies, so it stays unit
  testable. `MapEditor` (`src/editor/map_editor.gd`) is the thin runtime node
  that wires input and the hover preview to that core and drives the
  `MapSystem` layer stack it points at via its exported `map_system_path`.

### Regenerating the placeholder atlas

The terrain atlas at `assets/tilesets/terrain_atlas.png` (512x320) is an honest,
**programmatic placeholder** — flat-shaded diamonds that make the autotiling
legible, not final art. Real SC2-grade art is a tracked follow-up. Regenerate it
deterministically with:

```
python3 tools/gen_placeholder_atlas.py
```

## License

MIT — see [LICENSE](LICENSE).
