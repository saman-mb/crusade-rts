class_name UnitCommand
extends RefCounted
## Pure decision core for the debug spawn/target click gesture (#75/#76). It models a
## single fact — does a unit exist yet? — and turns each click into either a SPAWN (the
## first click, when there is no unit) or a MOVE (every later click, repeatable). The NODE
## layer owns the actual work: it reads the picked cell/tier, calls on_click, and on SPAWN
## instantiates the unit while on MOVE it runs the pathfinder toward the echoed cell. This
## core does no spawning, no nav, and holds no Node refs, so the gesture logic is fully
## headless-testable and the node keeps only input plumbing.

## What the node should do with a click: NONE is a reserved default, SPAWN creates the unit,
## MOVE retargets the existing unit.
enum Action { NONE, SPAWN, MOVE }

## Whether a unit has been spawned. Flips true on the first click and back to false on
## on_despawn; drives the SPAWN-vs-MOVE decision.
var _has_unit: bool = false

## Decides SPAWN vs MOVE for a click at the given cell/tier and echoes them back to the
## node. The first click (no unit yet) is a SPAWN and records that a unit now exists; every
## click after that is a MOVE and leaves the unit in place, so MOVE is repeatable.
func on_click(cell: Vector2i, tier: int) -> Dictionary:
	var action: Action = Action.MOVE if _has_unit else Action.SPAWN
	_has_unit = true
	return {"action": action, "cell": cell, "tier": tier}

## Forgets the current unit so the next on_click spawns again. The node calls this after it
## despawns/destroys the unit.
func on_despawn() -> void:
	_has_unit = false

## Whether a unit currently exists (i.e. the next click will MOVE rather than SPAWN).
func has_unit() -> bool:
	return _has_unit
