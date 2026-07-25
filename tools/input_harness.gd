extends Node2D
## THROWAWAY DEV TOOL -- not part of the shipped game.
##
## Integration test SUITE for the map editor (`src/editor/map_editor.gd`): instances
## the real `map_system.tscn`, drives it through the ACTUAL input pipeline via
## `tools/harness/input_driver.gd` (synthetic mouse warps + InputEventMouseButton /
## InputEventMouseMotion / InputEventKey), and asserts the 9 documented editor
## behaviors: paint, erase, eyedropper, bucket fill, elevation cycle ([/]),
## number-key tier jump, undo, redo, save/reload.
##
## This file is the map-editor-SPECIFIC part: scene setup + one `_case_*` method
## per behavior. The reusable plumbing (`InputDriver`) and the case runner
## (`HarnessRunner`) live in `tools/harness/` and are meant to be reused by future
## harnesses testing other interactions -- see tools/harness/README.md.
##
## Run: ./tools/run_harness.sh   (or directly: godot --path <project> res://tools/input_harness.tscn)

const MAP_SYSTEM_SCENE := preload("res://src/nodes/map_system.tscn")
const SHOTS_DIR := "res://tools/shots"

# Preloaded (not referenced by global class_name) so a fresh checkout runs with
# no editor import pass -- see input_driver.gd header.
const InputDriver := preload("res://tools/harness/input_driver.gd")
const HarnessRunner := preload("res://tools/harness/harness_runner.gd")

var _map_system: MapSystem
var _editor: MapEditor
var _persistence: Node
var _camera: RtsCamera
var _driver: InputDriver

## Scratch state threaded between the eyedropper sub-cases (sampled tile from
## cell A, checked when it's re-applied to cell B).
var _eyedrop_expect_src: int
var _eyedrop_expect_atlas: Vector2i
var _eyedrop_cell_a: Vector2i
var _eyedrop_cell_b: Vector2i

## Cells used across cases, resolved once terrain exists (see `_run`).
var _center: Vector2i
var _bucket_origin: Vector2i
var _undo_cell: Vector2i
var _undo_painted_src: int


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOTS_DIR))
	_reset_user_map()
	_run()


## MapPersistence deliberately does NOT auto-load a saved user map on start (only
## the first-run showcase, and only when no user map exists yet) -- so a map
## saved by a PRIOR harness run (our own "save" case writes here) would leave
## the next run's map blank forever, since nothing auto-loads it. Wipe it before
## each run so the harness always starts from the same first-run-showcase state.
func _reset_user_map() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		var p: String = "user://maps/dev_map.json" + str(suffix)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _run() -> void:
	var map_instance := MAP_SYSTEM_SCENE.instantiate()
	add_child(map_instance)
	_map_system = map_instance as MapSystem

	# MapEditor/MapPersistence bind via call_deferred one frame after _ready (see
	# their _setup() comments); wait several frames for that plus the first-run
	# showcase-map load + terrain-variation pass to finish.
	for i in 10:
		await get_tree().process_frame

	_editor = _map_system.get_node("MapEditor") as MapEditor
	_persistence = _map_system.get_node("MapPersistence")
	_driver = InputDriver.new(get_tree(), get_viewport())

	# Defensively keep the DevMenu out of the hover/hit-test path -- Root already
	# starts hidden in the scene (visible=false), but belt-and-suspenders here
	# since MapEditor no-ops every action while gui_get_hovered_control() != null.
	var dev_menu := _map_system.get_node_or_null("DevMenu")
	if dev_menu != null:
		var root := dev_menu.get_node_or_null("Root")
		if root is Control:
			(root as Control).visible = false
			(root as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Wait for terrain to actually exist before trusting used_cell_rect() to pick
	# an on-screen, paintable center cell.
	var rect := Rect2i()
	for i in 60:
		rect = _map_system.used_cell_rect()
		if rect.size.x > 0 and rect.size.y > 0:
			break
		await get_tree().process_frame

	if rect.size.x <= 0 or rect.size.y <= 0:
		print("FAIL: setup - used_cell_rect() never populated; no terrain to test against")
		print("HARNESS SUMMARY: 0 passed, 1 failed")
		get_tree().quit(1)
		return

	# Freeze the RTS camera once it has settled near its map-clamped bounds, so
	# edge-pan/zoom easing (RtsCamera._process) can't shift the view between our
	# mouse warp and the synthetic button events fired a frame or two later.
	_camera = _map_system.get_node_or_null("Camera") as RtsCamera
	for i in 90:
		await get_tree().process_frame
	if _camera != null:
		_camera.set_process(false)

	# Warm-up: the very first Input.warp_mouse()+parse_input_event() in a fresh
	# process can lag a frame behind on some window managers (observed as a
	# false paint-case failure where the picked cell trailed the warp by one
	# frame). One throwaway warp here absorbs that cold-start latency so it
	# doesn't masquerade as a real editor bug in the first real case.
	await _driver.move_to(get_viewport().get_visible_rect().size / 2.0)

	_center = rect.position + Vector2i(rect.size.x / 2, rect.size.y / 2)
	_bucket_origin = _center + Vector2i(-8, -8)
	_undo_cell = _center + Vector2i(1, 1)

	var cases: Array[Dictionary] = [
		{"name": "paint", "fn": Callable(self, "_case_paint")},
		{"name": "erase", "fn": Callable(self, "_case_erase")},
		{"name": "eyedropper_sample", "fn": Callable(self, "_case_eyedropper_sample")},
		{"name": "eyedropper_apply", "fn": Callable(self, "_case_eyedropper_apply")},
		{"name": "bucket_fill", "fn": Callable(self, "_case_bucket_fill")},
		{"name": "elevation_brackets", "fn": Callable(self, "_case_elevation_brackets")},
		{"name": "number_key", "fn": Callable(self, "_case_number_key")},
		{"name": "undo", "fn": Callable(self, "_case_undo")},
		{"name": "redo", "fn": Callable(self, "_case_redo")},
		{"name": "save", "fn": Callable(self, "_case_save")},
		{"name": "reload", "fn": Callable(self, "_case_reload")},
	]
	await HarnessRunner.new(get_tree(), get_viewport(), SHOTS_DIR).run(cases)


## Convenience wrapper local to this suite: warp to a cell on the editor's
## active layer, then click there. (Kept here rather than in InputDriver since
## it bakes in this harness's "active layer + level 0" assumption.)
func _click_cell(cell: Vector2i, level: int, button_index: int) -> void:
	var p := await _driver.warp_to_cell(_editor._active_layer, cell, level)
	await _driver.click(button_index, p["screen"], p["world"])


# --- cases -----------------------------------------------------------------
# Sequenced so state built up by an earlier case (a painted cell, a selected
# tool) feeds the next, matching how a real editing session actually plays out.
# To add a new case: write a `_case_foo()` method returning bool or
# {"ok":.., "detail":..}, then add one line to the `cases` array above.

func _case_paint() -> Dictionary:
	_editor._active_layer.erase_cell(_center)  # setup only: force empty; not the assertion
	await _driver.tap_key(KEY_B)
	await _click_cell(_center, 0, MOUSE_BUTTON_LEFT)
	var src := _editor._active_layer.get_cell_source_id(_center)
	return {"ok": src != -1, "detail": "source_id=%d" % src}


func _case_erase() -> Dictionary:
	await _click_cell(_center, 0, MOUSE_BUTTON_RIGHT)
	var src := _editor._active_layer.get_cell_source_id(_center)
	return {"ok": src == -1, "detail": "source_id=%d" % src}


func _case_eyedropper_sample() -> Dictionary:
	_eyedrop_cell_a = _center
	_eyedrop_cell_b = _center + Vector2i(3, 0)
	_editor._active_layer.erase_cell(_eyedrop_cell_b)  # setup only: guarantee a clean target

	await _driver.tap_key(KEY_B)
	await _click_cell(_eyedrop_cell_a, 0, MOUSE_BUTTON_LEFT)
	_eyedrop_expect_src = _editor._active_layer.get_cell_source_id(_eyedrop_cell_a)
	_eyedrop_expect_atlas = _editor._active_layer.get_cell_atlas_coords(_eyedrop_cell_a)

	await _driver.tap_key(KEY_I)
	await _click_cell(_eyedrop_cell_a, 0, MOUSE_BUTTON_LEFT)
	var ok := _editor._source_id == _eyedrop_expect_src and _editor._atlas_coords == _eyedrop_expect_atlas
	return {"ok": ok, "detail": "brush=(%d,%s) expected=(%d,%s)" % [_editor._source_id, _editor._atlas_coords, _eyedrop_expect_src, _eyedrop_expect_atlas]}


func _case_eyedropper_apply() -> Dictionary:
	await _driver.tap_key(KEY_B)
	await _click_cell(_eyedrop_cell_b, 0, MOUSE_BUTTON_LEFT)
	var b_src := _editor._active_layer.get_cell_source_id(_eyedrop_cell_b)
	var b_atlas := _editor._active_layer.get_cell_atlas_coords(_eyedrop_cell_b)
	var ok := b_src == _eyedrop_expect_src and b_atlas == _eyedrop_expect_atlas
	return {"ok": ok, "detail": "cellB src=%d atlas=%s expected=(%d,%s)" % [b_src, b_atlas, _eyedrop_expect_src, _eyedrop_expect_atlas]}


func _case_bucket_fill() -> Dictionary:
	await _driver.tap_key(KEY_B)
	var block: Array[Vector2i] = []
	for dy in range(3):
		for dx in range(3):
			block.append(_bucket_origin + Vector2i(dx, dy))
	for c in block:
		await _click_cell(c, 0, MOUSE_BUTTON_LEFT)

	# Switch the brush to a tile visibly different from the block just painted, so
	# the flood fill is a real, assertable mutation rather than a same-tile no-op
	# (StrokeRecorder drops net-zero cells -- see map_editor.gd _bucket_fill_at_mouse).
	_editor._atlas_coords = TileSetConstants.WATER_ANIM_COORDS
	_editor._alt = 0

	var before := {}
	for c in block:
		before[c] = _editor._active_layer.get_cell_atlas_coords(c)

	await _driver.tap_key(KEY_G)
	await _click_cell(block[4], 0, MOUSE_BUTTON_LEFT)  # seed = center of the 3x3

	var changed := 0
	for c in block:
		if _editor._active_layer.get_cell_atlas_coords(c) != before[c]:
			changed += 1
	return {"ok": changed > 1, "detail": "changed=%d/9" % changed}


func _case_elevation_brackets() -> Dictionary:
	var start: int = _editor._active_level
	await _driver.tap_key(KEY_BRACKETRIGHT)
	var after_right: int = _editor._active_level
	await _driver.tap_key(KEY_BRACKETLEFT)
	var after_left: int = _editor._active_level
	var ok := after_right != start and after_left == start
	return {"ok": ok, "detail": "start=%d after]=%d after[=%d" % [start, after_right, after_left]}


func _case_number_key() -> Dictionary:
	if _map_system.tier_count() <= 1:
		return {"ok": true, "detail": "skipped: tier_count<=1"}
	await _driver.tap_key(KEY_2)
	var level: int = _editor._active_level
	await _driver.tap_key(KEY_1)  # restore level 0 for the remaining cases
	return {"ok": level == 1, "detail": "active_level=%d" % level}


func _case_undo() -> Dictionary:
	_editor._active_layer.erase_cell(_undo_cell)  # setup only: guarantee a fresh empty cell
	await _driver.tap_key(KEY_B)
	await _click_cell(_undo_cell, 0, MOUSE_BUTTON_LEFT)
	_undo_painted_src = _editor._active_layer.get_cell_source_id(_undo_cell)

	await _driver.key_event(KEY_Z, true, true)
	await _driver.key_event(KEY_Z, false, true)
	var undone_src := _editor._active_layer.get_cell_source_id(_undo_cell)
	var ok := _undo_painted_src != -1 and undone_src == -1
	return {"ok": ok, "detail": "painted_src=%d after_undo_src=%d" % [_undo_painted_src, undone_src]}


func _case_redo() -> Dictionary:
	await _driver.key_event(KEY_Y, true, true)
	await _driver.key_event(KEY_Y, false, true)
	var redone_src := _editor._active_layer.get_cell_source_id(_undo_cell)
	return {"ok": redone_src == _undo_painted_src, "detail": "after_redo_src=%d expected=%d" % [redone_src, _undo_painted_src]}


func _case_save() -> Dictionary:
	var path: String = _persistence.get("current_map_path")
	var before_exists := MapFileIO.file_exists(path)
	var before_size := _file_size(path) if before_exists else 0

	await _driver.tap_key(KEY_F6)
	for i in 10:
		await get_tree().process_frame

	var after_exists := MapFileIO.file_exists(path)
	var after_size := _file_size(path) if after_exists else 0
	var ok := after_exists and (after_size > 0) and (not before_exists or after_size != before_size)
	return {"ok": ok, "detail": "before=(exists:%s,size:%d) after=(exists:%s,size:%d)" % [before_exists, before_size, after_exists, after_size]}


func _case_reload() -> Dictionary:
	var rect_before := _map_system.used_cell_rect()
	await _driver.tap_key(KEY_F5)
	for i in 10:
		await get_tree().process_frame
	var rect_after := _map_system.used_cell_rect()
	var ok := rect_after.size.x > 0 and rect_after.size.y > 0
	return {"ok": ok, "detail": "rect_before=%s rect_after=%s" % [rect_before, rect_after]}


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return n
