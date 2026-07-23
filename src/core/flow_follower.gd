class_name FlowFollower
extends RefCounted
## Continuous flow-field steering integrator for a single unit (#80, V3·C3).
##
## The crowd-movement sibling of PathFollower. Where PathFollower walks ONE unit's
## private { cell, tier } waypoint list, FlowFollower steers a unit along a SHARED
## FlowField -- so a whole group converging on the same goal needs only one field
## (built once, followed by every unit) instead of one A* path each. It fuses two
## pure cores: the FlowField supplies a per-cell direction toward the goal, and
## Steering blends that "go to goal" pull with a local SEPARATION push so units in
## a crowd fan out instead of stacking into a single sprite.
##
## LIFTED-SPACE INTEGRATION (identical contract to PathFollower). Every world
## target is EntityPlacement.visual_position(cell, tier) -- the on-screen art
## anchor (footprint + the tier's elevation raise) -- so a unit's motion matches
## the rest of the game's geometry rather than re-deriving iso math inline. The
## caller drives a node's drawn position from the returned `pos`.
##
## SINGLE TIER. This follower is pinned to one tier (`tier`, fixed at construction);
## the FlowField itself is a single-tier structure. Cross-tier flow (a unit riding
## the field up a ramp onto tier 1) is DEFERRED -- when it lands, a FlowFollower
## would hand off tier the way PathFollower does on a reached ramp-top waypoint.
##
## WALL GUARD (the load-bearing safety guarantee). The blended velocity can, under
## a strong separation push next to a wall, aim a step into a non-walkable cell.
## Before committing a step the follower checks the stepped cell's cost: if it is
## UNREACHABLE it drops separation and re-steps along the flow alone; if THAT is
## still non-walkable it stays put. So no unit ever ends a frame inside a wall,
## even when crowded hard against one.
##
## Pure / headless: a plain RefCounted with no Node deps. All world geometry comes
## from EntityPlacement (-> IsoCoord + MapConstants); the goal/walkability come from
## the shared FlowField. Fully testable with no live scene.

## World px/sec, reusing PathFollower's constant so flow-followed and path-followed
## units move at the same base speed.
var speed: float = PathFollower.DEFAULT_SPEED_PX_PER_SEC

## Radius (world px) within which neighbours contribute to the separation push.
## Reuses Steering's default so the crowd spacing matches the steering core's tuning.
var separation_radius: float = Steering.DEFAULT_SEPARATION_RADIUS

## Blend weights fed to Steering.combine: how hard the goal pull vs the local
## separation push each count. Separation is deliberately < flow so a crowd fans
## out WITHOUT losing net progress toward the goal.
var flow_weight: float = 1.0
var separation_weight: float = 0.6

## The elevation tier this follower is pinned to (fixed for #80; see class docs).
var tier: int = 0

## A world target within this many px of the goal's visual position counts as
## arrived (a secondary stop condition alongside "current cell == goal cell").
## A touch more generous than PathFollower's 2px snap because a crowd settles in a
## spread arc around the goal rather than dead-centre on it.
var arrival_tolerance: float = 4.0

## Integration-cost distance (in cells, via the field) at or under which a unit
## counts as ARRIVED and stops consuming the flow. 0 = only the exact goal cell.
## Kept at 0 so a lone unit parks dead on the goal; a CROWD still fans out because
## arrived units keep separating (see `advance`).
var arrival_cost: int = 0

## The shared flow field this unit follows. Multiple followers share ONE instance.
var _field: FlowField

## Sticky arrival latch. Once a unit reaches the goal region it STOPS following the
## flow for good and responds to separation alone -- so a crowd converging on one
## goal cell settles into a spread arc AROUND it (each unit pushed to its own resting
## spot) instead of every unit freezing stacked on the single goal cell, and without
## the flow-pull-vs-separation-push jitter that re-engaging the flow would cause.
var _arrived: bool = false


## `p_field` is the shared FlowField (its `goal` and walkability drive every step);
## `p_tier` pins this follower to a single elevation tier (default 0).
func _init(p_field: FlowField, p_tier: int = 0) -> void:
	_field = p_field
	tier = p_tier


## Integrates one frame of flow-field + separation steering from `world_pos` over
## `delta` seconds, given the current world positions of nearby units
## (`neighbor_positions`, which MAY include this unit's own position -- Steering
## ignores the zero-distance self term).
##
## Returns { "pos": Vector2, "cell": Vector2i, "tier": int, "done": bool } -- the
## SAME shape/types as PathFollower.advance, so a caller can drive either follower
## through one code path.
##
## Contract:
## - No field, or `delta <= 0`: returns `world_pos` unchanged, not done -- no drift.
## - Once arrived (reached the goal region: current cell cost <= `arrival_cost`, or
##   within arrival tolerance of the goal's visual position) the unit LATCHES arrived
##   for good and stops consuming the flow -- from then on it only responds to the
##   separation push. A lone unit (no neighbours) therefore parks exactly where it
##   reached the goal, while a crowd fans out into a spread arc around the goal
##   instead of stacking on the single goal cell, with no re-engaged-flow jitter.
func advance(world_pos: Vector2, neighbor_positions: PackedVector2Array, delta: float) -> Dictionary:
	# Derive the current grid cell from the lifted world position: strip the tier's
	# visual raise to land in the unlifted footprint plane, then pick the diamond.
	var ground: Vector2 = world_pos - EntityPlacement.visual_offset(tier)
	var cell: Vector2i = IsoCoord.pick_cell(ground)

	# Defensive: with no field there is nothing to follow -- no drift, never done.
	if _field == null:
		return { "pos": world_pos, "cell": cell, "tier": tier, "done": false }

	# Latch arrival (sticky). Computed BEFORE moving so a just-arrived unit switches
	# to separation-only this very frame rather than taking one more flow step.
	var goal_pos: Vector2 = EntityPlacement.visual_position(_field.goal, tier)
	var cell_cost: int = _field.cost_at(cell)
	if not _arrived:
		var in_region: bool = cell_cost != FlowField.UNREACHABLE and cell_cost <= arrival_cost
		var within_tol: bool = world_pos.distance_to(goal_pos) <= arrival_tolerance
		if in_region or within_tol:
			_arrived = true
	var done: bool = _arrived

	# No drift: nothing to integrate this frame.
	if delta <= 0.0:
		return { "pos": world_pos, "cell": cell, "tier": tier, "done": done }

	# Flow pull: a cell-space unit vector toward the min-cost neighbour, converted to
	# a WORLD desired direction by aiming at that neighbour cell's visual centre so the
	# pull lives in the same lifted geometry as everything else. Suppressed once
	# arrived -- an arrived unit holds station under separation alone (no flow), which
	# both spreads the crowd around the goal and prevents flow-vs-separation jitter.
	var flow_cell_dir: Vector2 = Vector2.ZERO
	var flow_desired: Vector2 = Vector2.ZERO
	if not _arrived:
		flow_cell_dir = _field.flow_at(cell)
		var next_cell: Vector2i = cell + Vector2i(int(round(flow_cell_dir.x)), int(round(flow_cell_dir.y)))
		var target: Vector2 = EntityPlacement.visual_position(next_cell, tier)
		var to_target: Vector2 = target - world_pos
		var flow_dir_world: Vector2 = Vector2.ZERO
		if to_target.length() > 0.0:
			flow_dir_world = to_target.normalized()
		flow_desired = Steering.desired_velocity(flow_dir_world, speed)

	# Blend the (possibly zero) goal pull with the local separation push.
	var sep: Vector2 = Steering.separation(world_pos, neighbor_positions, separation_radius)
	var vel: Vector2 = Steering.combine(flow_desired, sep, flow_weight, separation_weight, speed)

	# Fully settled (arrived with no neighbour pushing): nothing to integrate, so hand
	# the position back exactly -- a resting crowd is perfectly still, no sub-px drift.
	if vel == Vector2.ZERO:
		return { "pos": world_pos, "cell": cell, "tier": tier, "done": done }

	# Integrate one step, then GUARD it against walls so no unit ever ends a frame
	# inside a solid cell.
	var stepped: Vector2 = _guarded_step(world_pos, cell, flow_cell_dir, flow_desired, vel, delta)

	return {
		"pos": stepped,
		"cell": cell,
		"tier": tier,
		"done": done,
	}


## Picks the frame's actual step, escalating through progressively safer fallbacks so
## the result is ALWAYS a walkable cell:
##   1. the full blended (flow + separation) velocity -- the common case;
##   2. flow alone (drop separation) -- for when a hard separation push beside a wall
##      aimed the blended step into it;
##   3. a WALL SLIDE toward the lowest-cost walkable CARDINAL neighbour -- for when
##      even the flow points at a DIAGONAL neighbour whose straight line clips the
##      orthogonal wall cell between them (a unit funnelling through a 1-cell gap
##      would otherwise freeze, since both 1 and 2 land in the wall);
##   4. stay put -- boxed in this frame; never step into a wall.
func _guarded_step(world_pos: Vector2, cell: Vector2i, flow_cell_dir: Vector2, flow_desired: Vector2, vel: Vector2, delta: float) -> Vector2:
	var full: Vector2 = world_pos + vel * delta
	if _is_walkable_world(full):
		return full
	var flow_only: Vector2 = world_pos + flow_desired * delta
	if _is_walkable_world(flow_only):
		return flow_only
	return _slide_along_wall(world_pos, cell, flow_cell_dir, delta)


## Wall slide: steer toward the lower-cost of the (up to two) CARDINAL neighbour cells
## the flow points between, skipping any that is solid or whose step would still clip a
## wall. Returns `world_pos` unchanged when neither cardinal is a safe move (boxed in).
## Decomposing the (possibly diagonal) flow into cardinals is what lets a unit hug a
## wall around a corner and thread a single-cell gap instead of stalling against it.
func _slide_along_wall(world_pos: Vector2, cell: Vector2i, flow_cell_dir: Vector2, delta: float) -> Vector2:
	var cx: int = int(sign(flow_cell_dir.x))
	var cy: int = int(sign(flow_cell_dir.y))
	var candidates: Array[Vector2i] = []
	if cx != 0:
		candidates.append(cell + Vector2i(cx, 0))
	if cy != 0:
		candidates.append(cell + Vector2i(0, cy))

	var best: Vector2 = world_pos
	var best_cost: int = 0x7FFFFFFF
	for nc: Vector2i in candidates:
		var nc_cost: int = _field.cost_at(nc)
		if nc_cost == FlowField.UNREACHABLE:
			continue
		var target: Vector2 = EntityPlacement.visual_position(nc, tier)
		var to: Vector2 = target - world_pos
		var dist: float = to.length()
		if dist <= 0.0:
			continue
		# Never overshoot the neighbour centre (a step longer than the gap could sail
		# through it into the far wall).
		var step_len: float = min(speed * delta, dist)
		var candidate_pos: Vector2 = world_pos + to.normalized() * step_len
		if not _is_walkable_world(candidate_pos):
			continue
		if nc_cost < best_cost:
			best_cost = nc_cost
			best = candidate_pos
	return best


## True iff the cell under `world_pos` (in this follower's tier plane) is walkable,
## i.e. the shared field reports a non-UNREACHABLE cost there. Strips the tier lift
## first so the cell is picked in the unlifted footprint plane, matching `advance`.
func _is_walkable_world(world_pos: Vector2) -> bool:
	var ground: Vector2 = world_pos - EntityPlacement.visual_offset(tier)
	var cell: Vector2i = IsoCoord.pick_cell(ground)
	return _field.cost_at(cell) != FlowField.UNREACHABLE
