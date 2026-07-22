class_name DayNight
extends RefCounted
## Pure time-of-day model for the ambient/day-night lighting (Story L2, #83).
##
## Holds the current time-of-day `t` in [0, 1) (0.0 = midnight, 0.5 = noon), a
## configurable cycle length, and a keyed ambient-color RAMP. `color_at(t)`
## resolves any time to an ambient `Color` by linear RGBA interpolation between
## the two bracketing keyframes, treating the ramp as CYCLIC (the last stop
## wraps back to the first across the 1.0 boundary). Node-free and stateful, so
## the whole ramp/advance contract is headless-testable; the DayNightDriver node
## just reads `current_color()` each frame into a CanvasModulate.

## Default keyed ramp: `[t, Color]` stops, `t` strictly ascending, first stop at
## exactly 0.0 (midnight). Noon is neutral white (full ambient); dawn/dusk are
## warm; night is dim and blue. Tuned for the HD terrain to read bright at noon
## and cool/dark — but not black — at night.
const DEFAULT_RAMP: Array = [
	[0.00, Color(0.16, 0.20, 0.38)],  # midnight — dim, cool blue
	[0.25, Color(0.95, 0.70, 0.55)],  # dawn — warm, low sun
	[0.50, Color(1.00, 1.00, 1.00)],  # noon — neutral, full ambient
	[0.75, Color(0.98, 0.62, 0.42)],  # dusk — warm orange
]

## Default cycle length in seconds for one full midnight->midnight loop.
const DEFAULT_CYCLE_SECONDS := 120.0

## Current time-of-day in [0, 1). Starts at noon so a fresh world is bright.
var t: float = 0.5

## Seconds for one full day. `advance()` is a no-op when this is <= 0 (frozen).
var cycle_seconds: float = DEFAULT_CYCLE_SECONDS

## Active ramp; same shape as DEFAULT_RAMP. Set via `_init`.
var _ramp: Array


## `ramp` defaults to DEFAULT_RAMP; must be ascending in `t` with the first stop
## at 0.0. `start_t` seeds the clock, `cycle` the loop length.
func _init(ramp: Array = DEFAULT_RAMP, start_t: float = 0.5,
		cycle: float = DEFAULT_CYCLE_SECONDS) -> void:
	_ramp = ramp
	t = fposmod(start_t, 1.0)
	cycle_seconds = cycle


## Advances the clock by `delta` seconds, wrapping at 1.0. No-op if the cycle is
## frozen (cycle_seconds <= 0), which lets a caller hold time still and scrub.
func advance(delta: float) -> void:
	if cycle_seconds <= 0.0:
		return
	t = fposmod(t + delta / cycle_seconds, 1.0)


## Nudges the clock directly (for the dev scrub), wrapping at 1.0.
func scrub(dt: float) -> void:
	t = fposmod(t + dt, 1.0)


## Ambient color at the current `t`.
func current_color() -> Color:
	return color_at(t)


## Ambient color at an arbitrary time-of-day. `time` is wrapped into [0, 1), so
## color_at(1.0) == color_at(0.0). Exact at every keyframe; linearly blended
## between them, cyclically across the 1.0 seam (last stop -> first stop).
func color_at(time: float) -> Color:
	var u := fposmod(time, 1.0)
	var n := _ramp.size()
	# Walk segments [stop i, stop i+1). The final segment wraps: its end is the
	# first stop shifted to t0 + 1.0, so `u` in [last_t, 1.0) blends last->first.
	for i in n:
		var t0: float = _ramp[i][0]
		var c0: Color = _ramp[i][1]
		var next: int = (i + 1) % n
		var t1: float = _ramp[next][0]
		var c1: Color = _ramp[next][1]
		if i == n - 1:
			t1 += 1.0  # wrap the closing segment past the seam
		if u >= t0 and u < t1:
			var span := t1 - t0
			var f := 0.0 if span <= 0.0 else (u - t0) / span
			return c0.lerp(c1, f)
	# u < first stop's t (only if the ramp does not start at 0.0): clamp to first.
	return _ramp[0][1]
