extends RefCounted
## Reusable synthetic-input plumbing for HEADED integration harnesses.
##
## Loaded via `preload()` (not a global `class_name`) so a fresh checkout runs
## with no editor import pass first -- new `class_name` scripts aren't in the
## global class cache until reimport, which would break `godot <scene>` headless.
##
## Drives the REAL input pipeline -- Input.warp_mouse() to move the actual OS
## cursor, then InputEventMouseButton / InputEventMouseMotion / InputEventKey
## through Input.parse_input_event() -- rather than calling game code directly.
## This is what makes a harness built on it an integration test of the real
## `_unhandled_input` path, not a unit test in disguise.
##
## Node-free by design: takes the SceneTree + Viewport it drives as constructor
## params instead of reaching for `get_tree()`/globals, so any harness scene can
## build one and hand it around (including to test-case functions that live
## outside the scene tree).
##
## Every step awaits at least one `process_frame` before the next fires, because
## the systems under test (camera transforms, `get_global_mouse_position()`,
## hover state) only reflect a warp/event on the frame(s) after it's processed.

var _tree: SceneTree
var _viewport: Viewport

func _init(tree: SceneTree, viewport: Viewport) -> void:
	_tree = tree
	_viewport = viewport


## Projects a world position through the viewport's LIVE canvas transform (i.e.
## through whatever camera is active) to a screen/window pixel position. Camera
## motion, zoom and any drift is naturally accounted for since this reads the
## transform fresh on each call rather than caching it.
func world_to_screen(world: Vector2) -> Vector2:
	return _viewport.get_canvas_transform() * world


## Cell -> world -> screen for a `TileMapLayer` at a given elevation `level`
## (via `IsoCoord.tile_world_pos`, the same projection the real editor code
## uses), then warps the cursor there. Returns {"world": Vector2, "screen": Vector2}
## so callers can feed exact values into `click`/`drag`/mouse-event helpers
## without re-deriving them (and risking a slightly different rounding).
func warp_to_cell(layer: TileMapLayer, cell: Vector2i, level: int) -> Dictionary:
	var world := IsoCoord.tile_world_pos(layer, cell, level)
	var screen := world_to_screen(world)
	await move_to(screen)
	return {"world": world, "screen": screen}


## Warps the OS cursor to a screen position and settles for two frames -- one
## for the warp to land, one more margin frame for anything reading
## `get_global_mouse_position()` this frame to see it. Two is a pragmatic
## minimum; a harness that still sees stale positions can await more itself.
func move_to(screen: Vector2) -> void:
	Input.warp_mouse(screen)
	await _tree.process_frame
	await _tree.process_frame


## Fires a single InputEventMouseMotion at `screen` (optionally with an explicit
## `world` global_position; defaults to `screen` when omitted, matching Godot's
## own default for an unset global_position).
func mouse_motion(screen: Vector2, world: Vector2 = Vector2.INF) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = screen
	ev.global_position = world if world != Vector2.INF else screen
	Input.parse_input_event(ev)
	await _tree.process_frame


## Fires a single mouse button press or release at `screen_pos`.
func mouse_button(button: int, screen_pos: Vector2, pressed: bool, world_pos: Vector2 = Vector2.INF) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = screen_pos
	ev.global_position = world_pos if world_pos != Vector2.INF else screen_pos
	Input.parse_input_event(ev)
	await _tree.process_frame


## Press + release of `button` at `screen_pos` -- a single, undragged click.
## Does NOT warp the mouse first; call `move_to`/`warp_to_cell` beforehand (most
## callers want the cursor to actually be there before the button goes down).
func click(button: int, screen_pos: Vector2, world_pos: Vector2 = Vector2.INF) -> void:
	await mouse_button(button, screen_pos, true, world_pos)
	await mouse_button(button, screen_pos, false, world_pos)


## Press-drag-release of `button` from one cell to another on `layer` at
## `level`: warps to the start cell, presses, feeds `steps` intermediate
## InputEventMouseMotion events toward the end cell, then releases at the end
## cell. Mirrors a real click-drag paint/erase stroke.
func drag(button: int, layer: TileMapLayer, level: int, from_cell: Vector2i, to_cell: Vector2i, steps: int = 4) -> void:
	var from := await warp_to_cell(layer, from_cell, level)
	await mouse_button(button, from["screen"], true, from["world"])
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var cell := Vector2i(
			int(round(lerp(float(from_cell.x), float(to_cell.x), t))),
			int(round(lerp(float(from_cell.y), float(to_cell.y), t))))
		var p := await warp_to_cell(layer, cell, level)
		await mouse_motion(p["screen"], p["world"])
	var to := await warp_to_cell(layer, to_cell, level)
	await mouse_button(button, to["screen"], false, to["world"])


## Fires a single InputEventKey press or release. Sets BOTH `keycode` and
## `physical_keycode` to the same value: some consumers match raw `keycode`
## (e.g. direct `if key.keycode == KEY_Z` checks) while others match via
## InputMap actions bound to `physical_keycode` (Godot's default when you bind
## a key in the Input Map editor) -- one synthetic event needs to satisfy both.
func key_event(keycode: int, pressed: bool, ctrl: bool = false, shift: bool = false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = pressed
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	Input.parse_input_event(ev)
	await _tree.process_frame


## Press + release of a single key (optionally chorded with Ctrl/Shift).
func tap_key(keycode: int, ctrl: bool = false, shift: bool = false) -> void:
	await key_event(keycode, true, ctrl, shift)
	await key_event(keycode, false, ctrl, shift)
