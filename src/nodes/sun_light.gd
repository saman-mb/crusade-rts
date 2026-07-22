extends DirectionalLight2D
## The world's sun (Story L3, #84).
##
## A DirectionalLight2D that, combined with the terrain atlas NORMAL MAP (L1,
## #82) wired onto the TileSet's CanvasTexture, makes the isometric diamonds
## catch DIRECTIONAL relief instead of flat brightening: because the terrain
## diffuse is mid-tone (grass/dirt), the parallel sun adds highlights on the
## faces whose normals point toward it, so rotating the sun sweeps highlights
## across the terrain. Angle / energy / color are tunable in the inspector.
##
## If a sibling DayNight (L2, #83) node exists, the sun tints itself from the
## current time-of-day each frame, so the direct sun shares the ambient palette
## (warm at dawn/dusk, cool and dim at night) instead of staying a fixed white.
##
## Runtime node (not @tool): does nothing during a headless --import in CI.

## Compass angle (degrees) the sunlight travels toward. Sets the node rotation,
## which is what decides which way surface highlights face; sweep it to move them.
@export var sun_angle_degrees: float = 130.0:
	set(v):
		sun_angle_degrees = v
		rotation_degrees = v

## Base energy of the direct sun term. Kept modest so it sculpts relief on the
## already-ambient-lit terrain without blowing the mid-tones out to white.
@export_range(0.0, 4.0) var sun_energy: float = 0.85:
	set(v):
		sun_energy = v
		energy = v

## Base sun tint (slightly warm), multiplied by the day/night color when
## tint_from_day_night is on.
@export var sun_color: Color = Color(1.0, 0.96, 0.88):
	set(v):
		sun_color = v
		if not _tinting():
			color = v

## Tint the sun by the sibling DayNight ambient each frame (warm dawn/dusk, cool
## dim night) so the direct light shares the time-of-day palette.
@export var tint_from_day_night: bool = true

## Path to the DayNight node whose color tints the sun (sibling by default).
@export var day_night_path: NodePath = ^"../DayNight"

## Resolved DayNight node (CanvasModulate); left untyped so its `color` is
## duck-typed (DayNight carries no class_name).
var _day_night


func _ready() -> void:
	rotation_degrees = sun_angle_degrees
	energy = sun_energy
	color = sun_color
	if not day_night_path.is_empty():
		_day_night = get_node_or_null(day_night_path)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _tinting():
		# Component-wise multiply: the sun rides the day/night palette but keeps
		# its own warm base bias.
		color = sun_color * _day_night.color


## Whether the day/night tint is active and wired.
func _tinting() -> bool:
	return tint_from_day_night and _day_night != null
