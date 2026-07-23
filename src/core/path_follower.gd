class_name PathFollower
extends RefCounted
## Continuous-steering path integrator for a single unit (#76).
##
## Consumes the ordered { cell, tier } waypoint list that NavGraph.find_path
## returns and integrates a CONTINUOUS world position toward each waypoint in
## turn at `speed`. The grid path is guidance only: the unit does NOT teleport
## cell-to-cell, it slides off-grid along the straight segments between waypoint
## CENTERS, so motion reads as smooth steering rather than a checkerboard hop.
##
## LIFTED-SPACE INTEGRATION. Every waypoint's world target is
## EntityPlacement.visual_position(cell, tier) -- the on-screen art anchor,
## footprint plus the tier's elevation raise -- NOT the unlifted footprint. A
## waypoint on a higher tier therefore sits physically higher on screen, and
## because we interpolate straight toward it, a unit walking a ramp visibly
## RISES across the slope instead of snapping up at the top. The caller drives a
## node's drawn position from `pos`; the depth-sort anchor is the caller's
## separate concern (see EntityPlacement.ground_position) and is untouched here.
##
## HANDOFF ON REACH. `_active_cell` / `_active_tier` are the unit's current grid
## occupancy. They only change when a waypoint is actually REACHED (snapped to),
## never mid-segment. On a cross-tier hop the tier thus flips at the instant the
## higher waypoint is reached -- a clean handoff -- so a mid-ramp query still
## reports the tier the unit is leaving, matching the interpolated art that has
## not yet arrived at the top.
##
## GUARANTEES. No drift: once done, or with no path, `advance` returns the input
## position unchanged. No overshoot: a step is never longer than the remaining
## distance-to-target, and a single large `delta` consumes several close
## waypoints in one call (the loop below) yet still stops EXACTLY on the final
## waypoint rather than sailing past it.
##
## Pure / headless: a plain RefCounted with no Node deps. All world geometry is
## sourced from EntityPlacement (which itself defers to IsoCoord + MapConstants),
## so this core never re-derives a tile size or an elevation offset inline and is
## fully testable with no live scene.

const DEFAULT_SPEED_PX_PER_SEC := 96.0        ## World px/sec when the caller leaves `speed` at its default.
const DEFAULT_ARRIVAL_TOLERANCE_PX := 2.0     ## A waypoint within this many px counts as reached (snap-to).

var speed: float = DEFAULT_SPEED_PX_PER_SEC             ## Traversal speed in world px/sec; scaled by `delta` per call.
var arrival_tolerance: float = DEFAULT_ARRIVAL_TOLERANCE_PX  ## Snap radius: a target this close is treated as reached.

## Ordered waypoints, each a { "cell": Vector2i, "tier": int }. Empty == no path.
var _waypoints: Array = []
## Index of the waypoint currently being steered TOWARD. Reaching it advances the
## index; when it runs past the last waypoint the follow is `_done`.
var _index: int = 0
## True once the final waypoint has been reached (or the path is empty).
var _done: bool = true
## The unit's current grid occupancy -- adopted from a waypoint ONLY on reach
## (the handoff). Seeded from waypoints[0], which find_path guarantees == `from`.
var _active_cell: Vector2i = Vector2i.ZERO
var _active_tier: int = 0


## Installs a fresh route and rewinds the follower to its start. `waypoints` is
## the { cell, tier } Array from NavGraph.find_path (first element == the unit's
## current cell, by that contract). The follow is immediately `_done` when the
## list is empty. Otherwise the active cell/tier are seeded from waypoints[0] so
## a query before the first `advance` already reports the correct occupancy, and
## steering begins at index 0 (the unit is assumed to stand on that first
## waypoint, so it is consumed for free on the first advance).
func set_path(waypoints: Array) -> void:
	_waypoints = waypoints
	_index = 0
	_done = waypoints.is_empty()
	if not _done:
		var first: Dictionary = waypoints[0]
		var c: Vector2i = first["cell"]
		var t: int = first["tier"]
		_active_cell = c
		_active_tier = t


## True when a non-empty route is installed and its end has not yet been reached.
func has_path() -> bool:
	return not _waypoints.is_empty() and not _done


## True when there is no route, or the final waypoint has been reached.
func is_done() -> bool:
	return _done


## Integrates one frame of motion from `current_pos` over `delta` seconds and
## reports the new world position plus the unit's (possibly handed-off) grid
## occupancy.
##
## Returns { "pos": Vector2, "cell": Vector2i, "tier": int, "done": bool }.
##
## Contract:
## - Done, empty path, or `delta <= 0`: returns `current_pos` unchanged with the
##   current active cell/tier -- NO drift, no spurious handoff.
## - Otherwise a distance budget `remaining = speed * delta` is spent walking
##   toward successive waypoints. The loop lets one big `delta` consume several
##   close waypoints in a single call without overshooting any of them.
func advance(current_pos: Vector2, delta: float) -> Dictionary:
	# No drift: nothing to integrate, so hand the input straight back.
	if _done or _waypoints.is_empty() or delta <= 0.0:
		return {
			"pos": current_pos,
			"cell": _active_cell,
			"tier": _active_tier,
			"done": _done,
		}

	var pos: Vector2 = current_pos
	var remaining: float = speed * delta

	# Consume waypoints until the budget runs out (else-branch break) or the path
	# ends (index runs past the last waypoint). Reaching a waypoint is the ONLY
	# place occupancy is handed off, so the tier flips exactly on arrival.
	while _index < _waypoints.size():
		var wp: Dictionary = _waypoints[_index]
		var wp_cell: Vector2i = wp["cell"]
		var wp_tier: int = wp["tier"]
		var target: Vector2 = EntityPlacement.visual_position(wp_cell, wp_tier)
		var dist: float = pos.distance_to(target)

		if dist <= arrival_tolerance or dist <= remaining:
			# REACHED: snap onto the waypoint (kills residual overshoot), charge
			# the traversed distance, and hand occupancy off to this waypoint.
			pos = target
			remaining -= dist
			if remaining < 0.0:
				# A within-tolerance snap can cost more than the budget; clamp so
				# the leftover never drives a backward step on the next target.
				remaining = 0.0
			_active_cell = wp_cell
			_active_tier = wp_tier
			_index += 1
			if _index >= _waypoints.size():
				# Final waypoint reached: stop exactly here.
				_done = true
				break
		else:
			# NOT reached: step toward the target by the whole remaining budget and
			# stop for this frame. Guard the zero-length case so normalized() is
			# never called on a zero vector.
			var to_target: Vector2 = target - pos
			if to_target.length() > 0.0:
				pos += to_target.normalized() * remaining
			remaining = 0.0
			break

	return {
		"pos": pos,
		"cell": _active_cell,
		"tier": _active_tier,
		"done": _done,
	}
