class_name ElevationLerp
extends RefCounted
## Smooth vertical interpolation of a unit's RENDERED elevation offset across a
## ramp/cliff traversal (#79, ramp polish).
##
## The elevation stack gives each tier a DISCRETE vertical raise
## (MapConstants.elevation_offset(tier) == Vector2(0, -32 * tier)). A unit crossing
## a ramp hands its grid occupancy off from the low tier to the high tier at a
## single instant (PathFollower snaps the tier when the top waypoint is reached), so
## if the drawn art offset is keyed off that discrete tier it SNAPS between the two
## heights -- a visible pop, and a jump in the footprint sort-anchor.
##
## This pure core removes the snap: given the tier a unit is coming FROM, the tier it
## is going TO, and its 0..1 PROGRESS across the ramp, it returns the interpolated
## vertical offset (a straight lerp between the two tiers' exact elevation offsets).
## The renderer applies THIS offset to the sprite instead of the discrete-tier one,
## so the body rises continuously across the slope and the origin/footprint anchor
## interpolates cleanly with it (no sort pop at the handoff instant).
##
## Contract guarantees (all unit-tested headless, no live scene):
## - ENDPOINTS EXACT: progress 0 returns elevation_offset(from_tier) to the pixel;
##   progress 1 returns elevation_offset(to_tier) to the pixel -- so it agrees with
##   the discrete offset at both ends of the ramp and hands off seamlessly.
## - CLAMPED / NO OVERSHOOT: progress outside [0,1] is clamped, so the offset never
##   sails past either tier height (a large or negative progress can't overshoot).
## - MONOTONIC: the vertical offset moves monotonically from one tier to the other as
##   progress increases -- no wobble mid-ramp.
## - SAME-TIER is a no-op: from_tier == to_tier returns that tier's offset for every
##   progress (a flat segment never perturbs the art).
##
## Pure / headless: static functions only, no Node deps. The two tier heights come
## from MapConstants (the single source of truth for the elevation step), so this
## core never re-derives the 32 px step inline and always matches the map's per-layer
## transform and EntityPlacement.visual_offset.

## The interpolated vertical offset between two tiers at `progress` in [0,1].
## `progress` is clamped, so values outside the range return the nearer endpoint
## exactly (no overshoot). from_tier == to_tier returns that tier's offset for all
## progress. The result is directly assignable to a sprite's `position`/`offset`.
static func offset(from_tier: int, to_tier: int, progress: float) -> Vector2:
	var t: float = clampf(progress, 0.0, 1.0)
	var a: Vector2 = MapConstants.elevation_offset(from_tier)
	var b: Vector2 = MapConstants.elevation_offset(to_tier)
	return a.lerp(b, t)


## Convenience: just the vertical (y) component of `offset` -- the raise in pixels
## (negative == higher on screen). For callers that only need the scalar height.
static func offset_y(from_tier: int, to_tier: int, progress: float) -> float:
	return offset(from_tier, to_tier, progress).y
