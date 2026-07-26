# SPIKE — Option B: 3D engine + orthographic camera + pixel-art pipeline

Disposable **architecture spike** (branch `spike/option-b-3d-ortho`) exploring whether
the RTS gameplay layer should move off the shipped **pure-2D** engine
(`Node2D`/`TileMapLayer`) onto Godot's **3D engine with an orthographic camera**, keeping
a retro pixel-art look via a low-resolution render target.

**This is throwaway prototype code, not production.** It is fully self-contained under
`spike/ortho3d/` and does **not** touch the 2D game. Assets are Godot primitive meshes
standing in for future Blender / Quaternius / Kenney CC0 models — the point is the
*pipeline*, not the art.

## Run it

Interactive:

```
godot --path . res://spike/ortho3d/ortho3d_spike.tscn
```

- **Left-click a trooper** to select it (yellow ground ring).
- **Left-click the ground** to move the selected trooper there.
- Unit A automatically strolls from the lower ground, up the ramp, onto the plateau,
  and behind the tower on first run.

Headless screenshot (writes `res://_spike_b.png`, then quits):

```
godot --path . res://spike/ortho3d/ortho3d_spike.tscn -- --shoot
```

## What it demonstrates (the decision criteria)

| Thing that's *hard in 2D* | How Option B gets it |
|---|---|
| **Depth sorting** (unit behind a cliff/building) | Free — the hardware **Z-buffer**. Unit A on the plateau is occluded by the tower with zero y-sort/z-index code. |
| **Verticality** (high/low ground, ramps) | Real — two terrain tiers joined by a tilted ramp; a unit's elevation is just its **Y**. |
| **Pixel-art look** | 3D world renders into a **384×216 `SubViewport`**, upscaled **NEAREST** to the window → crisp pixels. All materials use nearest filtering. |
| **Selection / picking** | A camera ray (`project_ray_*`) + `PhysicsRayQueryParameters3D` against unit colliders; ground-move rays hit the ground collider. |
| **Lighting & shadows** | A real `DirectionalLight3D` casts dynamic shadows across the tiers — not painted into sprites. |

## Files

- `ortho3d_spike.tscn` — root scene (one `Node` + `spike_world.gd`).
- `spike_world.gd` — builds the entire scene in code: SubViewport pixel pipeline, ortho
  camera, sun + environment, tiered terrain + ramp + cliff, tower, tree/rock doodads,
  units, click-select/move input, and the `--shoot` screenshot.
- `unit.gd` — one primitive-mesh trooper: team-coloured body, selection ring, pick
  collider, click-to-move locomotion.

See the ADR (`docs/adr/0001-2d-vs-3d-ortho-engine.md`) for the full comparison and
recommendation.
