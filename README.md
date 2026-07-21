# Crusade — Isometric Map Engine & Editor Framework (V2)

[![CI](https://github.com/saman-mb/crusade-rts/actions/workflows/ci.yml/badge.svg)](https://github.com/saman-mb/crusade-rts/actions/workflows/ci.yml)

> **Codename:** Crusade (`crusade-rts`)

A high-performance 2D isometric map runtime and in-game editor built in **Godot 4**.

The goal is a polished, modern look and feel — think a **2D isometric StarCraft II**: high-resolution
sprites, crisp 2:1 diamond projection, smooth RTS camera, animated terrain, and a fast in-game editing
loop for iterating on tilesets and layouts without needing units in the scene.

> **Status:** In development. Story #1 (project architecture & multi-layer map system) is implemented on `main`; the remaining stories are tracked as GitHub issues.

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

## License

MIT — see [LICENSE](LICENSE).
