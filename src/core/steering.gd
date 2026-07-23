class_name Steering
extends RefCounted
## Pure world-space local-avoidance vector math (#80, V3·C1).
##
## Static functions only — like NavMapBuilder / EntityPlacement, this core has no
## Node, grid, iso or TileMap deps. It works purely on abstract 2D vectors so the
## same math drives any consumer regardless of how world space is derived.
##
## The model is the classic two-term steering blend: a flow-field DESIRED
## velocity (where the unit wants to go) plus a SEPARATION push (how it peels off
## its crowding neighbours), combined and clamped to the unit's max speed. Keeping
## it a pure library means every branch — including the NaN traps around
## zero-length normalize and inverse-distance divide-by-zero — is unit-tested
## headless with no live scene.

## Default neighbour-search radius, roughly one unit body (~px). Consumers that
## don't have a tuned radius pass this so "who is crowding me" stays consistent.
const DEFAULT_SEPARATION_RADIUS := 28.0

## Guards both the zero-vector normalize traps and the inverse-distance
## divide-by-zero: any distance below this is treated as "coincident".
const EPSILON := 0.0001


## Sum of inverse-distance push-away vectors from every neighbour within `radius`,
## returned as a UNIT direction (or ZERO if nothing is in range / all pushes
## cancel). Each in-range neighbour contributes a vector pointing FROM the
## neighbour TOWARD `pos`, weighted by 1/distance so a closer neighbour pushes
## harder than a farther one. Coincident-safe: a neighbour at (approximately) the
## same position — including `pos` itself if it appears in the array — pushes in a
## deterministic fallback direction with a finite (capped) weight, so the result
## is never NaN. The unit-length return is what `combine` scales by max_speed.
static func separation(pos: Vector2, neighbors: PackedVector2Array, radius: float) -> Vector2:
	var push: Vector2 = Vector2.ZERO
	for n: Vector2 in neighbors:
		var offset: Vector2 = pos - n
		var dist: float = offset.length()
		if dist > radius:
			continue
		var dir: Vector2
		var weight: float
		if dist < EPSILON:
			# Coincident (or self): deterministic direction, finite capped weight.
			# Avoids both offset.normalized() -> 0 collapse and 1/0 -> inf/NaN.
			dir = Vector2.RIGHT
			weight = 1.0 / EPSILON
		else:
			dir = offset / dist          # == offset.normalized(), dist proven >= EPSILON
			weight = 1.0 / dist          # inverse distance: closer => stronger
		push += dir * weight
	if push.length_squared() < EPSILON * EPSILON:
		return Vector2.ZERO              # nothing in range, or pushes cancelled out
	return push.normalized()


## Scales an already-world-space flow DIRECTION up to `max_speed`. A ZERO flow
## direction (no field gradient here) yields ZERO — the unit has nowhere to go.
static func desired_velocity(flow_dir_world: Vector2, max_speed: float) -> Vector2:
	if flow_dir_world.length_squared() < EPSILON * EPSILON:
		return Vector2.ZERO
	return flow_dir_world.normalized() * max_speed


## Weighted blend of the flow desired velocity and the separation push, clamped to
## `max_speed`. `separation_vec` is a unit direction (from `separation`), so it is
## scaled to speed before weighting to be comparable to `flow_desired`. With a ZERO
## separation the result is exactly `flow_weight * flow_desired` (direction of the
## pure flow preserved); a non-zero separation deflects it, and the final magnitude
## never exceeds `max_speed`.
static func combine(
	flow_desired: Vector2,
	separation_vec: Vector2,
	flow_weight: float,
	separation_weight: float,
	max_speed: float
) -> Vector2:
	var blended: Vector2 = flow_weight * flow_desired + separation_weight * (separation_vec * max_speed)
	if blended.length() > max_speed:
		blended = blended.normalized() * max_speed
	return blended
