extends CanvasModulate
## Ambient / day-night tint over the world (Story L2, #83).
##
## A thin runtime node: it owns a pure `DayNight` clock and, each frame, advances
## it and writes `DayNight.current_color()` into its own `color`. Being a
## CanvasModulate on the base canvas layer, that color MULTIPLIES all world
## rendering (the terrain tilemaps), so the map reads as lit by a shifting
## ambient instead of flat full-white. The dev_menu overlay lives on a separate
## CanvasLayer, so it is deliberately NOT tinted.
##
## All decision math lives in `DayNight` (headless-tested); this node only wires
## the engine clock and the dev scrub input. It is NOT `@tool`, so it does
## nothing during a headless `--import` in CI.
##
## Dev scrub: hold `]` (dev_time_fwd) / `[` (dev_time_back) to sweep time of day
## fast for a live preview of the ramp; releasing resumes the normal cycle.

## Seconds for one full midnight->midnight cycle. Feeds DayNight.cycle_seconds.
@export var cycle_seconds: float = DayNight.DEFAULT_CYCLE_SECONDS

## Initial time-of-day in [0, 1) (0.5 = noon). Feeds DayNight.t.
@export_range(0.0, 1.0) var start_time: float = 0.5

## Time-of-day units swept per second while a scrub key is held (fast preview).
const SCRUB_RATE := 0.25

var _day_night: DayNight


func _ready() -> void:
	_day_night = DayNight.new(DayNight.DEFAULT_RAMP, start_time, cycle_seconds)
	color = _day_night.current_color()


func _process(delta: float) -> void:
	# The @tool-free node never runs in-editor, but guard anyway for safety.
	if Engine.is_editor_hint():
		return
	var scrub := 0.0
	if Input.is_action_pressed(&"dev_time_fwd"):
		scrub += 1.0
	if Input.is_action_pressed(&"dev_time_back"):
		scrub -= 1.0
	if scrub != 0.0:
		_day_night.scrub(scrub * SCRUB_RATE * delta)
	else:
		_day_night.advance(delta)
	color = _day_night.current_color()
