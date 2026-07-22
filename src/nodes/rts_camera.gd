class_name RtsCamera
extends Camera2D
## Thin RTS camera node: keyboard/edge/drag panning plus cursor-anchored zoom.
##
## All math is delegated to the pure `CameraMath` library; this node only wires
## engine input and state to those static calls and applies the results.
##
## Target/actual decoupling: input never mutates `position` or `zoom` directly.
## It moves `target_position` and `target_zoom`, and each frame the live values
## are eased toward the targets via `CameraMath.decay_vec2`. This keeps input
## responsive while motion stays smooth, and lets drag snap 1:1 (no easing)
## without fighting the smoothing.
##
## Frame-rate independence: the easing uses exponential decay (a per-second
## `decay` rate scaled by `delta`), so the camera settles at the same real-time
## rate regardless of frame rate — high and low FPS converge identically.

## Keyboard pan speed in world pixels per second (at zoom 1.0).
@export_group("Panning")
@export var pan_speed: float = 1200.0
## Edge-of-screen pan speed in screen pixels per second.
@export var edge_speed: float = 1000.0
## Screen border thickness that triggers edge panning, as a fraction of viewport size.
@export var edge_fraction: float = 0.04
## Master toggle for mouse edge panning.
@export var edge_pan_enabled: bool = true

## Minimum (most zoomed-out) zoom factor.
@export_group("Zoom")
@export var zoom_min: float = 0.5
## Maximum (most zoomed-in) zoom factor.
@export var zoom_max: float = 2.5
## Multiplicative step applied per scroll notch.
@export var zoom_step: float = 1.1

## Per-second exponential decay rate for position easing (higher = snappier).
@export_group("Smoothing")
@export var pan_decay: float = 15.0
## Per-second exponential decay rate for zoom easing (higher = snappier).
@export var zoom_decay: float = 14.0

## World-space rectangle the view is clamped to. Empty (zero area) => unbounded.
@export_group("Bounds")
@export var world_bounds: Rect2 = Rect2()

## Desired camera position; live `position` eases toward this each frame.
var target_position: Vector2
## Desired uniform zoom factor; live `zoom` eases toward this each frame.
var target_zoom: float
## True while a middle-mouse drag pan is active (position snaps 1:1, no easing).
var _dragging := false
## True while the OS cursor is inside this window (gates edge panning).
var _mouse_in_window := true


func _ready() -> void:
	target_position = position
	target_zoom = zoom.x
	position_smoothing_enabled = false   # our exponential decay is the only smoothing


func _process(delta: float) -> void:
	# 1. Keyboard pan (get_vector auto-normalizes diagonals).
	target_position += CameraMath.keyboard_pan_delta(
		Input.get_vector("cam_left", "cam_right", "cam_up", "cam_down"),
		pan_speed, zoom.x, delta)

	# 2. Edge pan, only when the window is focused, the cursor is inside it, no
	#    GUI control is hovered (so panning does not fight UI interaction), and no
	#    middle-drag is active (#20: edge velocity must not fight a 1:1 grab).
	if edge_pan_enabled and _mouse_in_window and not _dragging and get_window().has_focus() \
			and get_viewport().gui_get_hovered_control() == null:
		target_position += CameraMath.edge_pan_velocity(
			get_viewport().get_mouse_position(), get_viewport_rect().size,
			edge_fraction, edge_speed) * delta / zoom.x

	# 3. Clamp the zoom target (the anchor step below consumes it).
	target_zoom = CameraMath.clamp_zoom(target_zoom, zoom_min, zoom_max)

	# 4. Cursor-anchored zoom, corrected against the mid-transition zoom every
	#    frame so the world point under the cursor stays fixed (drift-free).
	var before := get_global_mouse_position()
	zoom = CameraMath.decay_vec2(zoom, Vector2(target_zoom, target_zoom), zoom_decay, delta)
	var after := get_global_mouse_position()
	target_position += before - after
	position += before - after

	# 5. Clamp the position target AFTER the anchor step so it is strictly
	#    contained every frame (#19: the anchor can nudge it past an edge); uses
	#    the post-decay zoom for the correct view inset. Only when bounds have area.
	if world_bounds.size.x > 0.0 and world_bounds.size.y > 0.0:
		target_position = CameraMath.clamp_target_position(
			target_position, world_bounds, get_viewport_rect().size, zoom.x)

	# 6. Position smoothing: snap 1:1 while dragging, otherwise ease.
	if _dragging:
		position = target_position
	else:
		position = CameraMath.decay_vec2(position, target_position, pan_decay, delta)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_MIDDLE:
				_dragging = button.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					target_zoom = CameraMath.step_zoom(target_zoom, 1, zoom_step, zoom_min, zoom_max)
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					target_zoom = CameraMath.step_zoom(target_zoom, -1, zoom_step, zoom_min, zoom_max)
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		target_position -= motion.relative / zoom.x   # 1:1 drag


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_WM_MOUSE_ENTER:
			_mouse_in_window = true
		NOTIFICATION_WM_MOUSE_EXIT:
			_mouse_in_window = false
