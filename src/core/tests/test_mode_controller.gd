extends GdTest
## Pure-logic tests for ModeController (no Node deps; drives only its stateful decision funcs).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## ModeController is stateful, so each test builds a fresh ModeController.new().


func _run() -> void:
	_test_initial_state()
	_test_toggle_menu_open()
	_test_toggle_menu_round_trip()
	_test_set_mode_play()
	_test_set_mode_editor()
	_test_compose_play_menu_open()
	_test_editor_menu_open()


# --- tests ---

## A fresh controller starts in EDITOR with the menu closed: editing on, no pause.
func _test_initial_state() -> void:
	var mc := ModeController.new()
	_ok(mc.is_menu_visible() == false, "initial is_menu_visible false")
	_ok(mc.is_paused() == false, "initial is_paused false")
	_ok(mc.is_editor_enabled() == true, "initial is_editor_enabled true")
	_ok(mc.mode == ModeController.Mode.EDITOR, "initial mode EDITOR")

## Opening the menu shows it, pauses, and suppresses editing.
func _test_toggle_menu_open() -> void:
	var mc := ModeController.new()
	mc.toggle_menu()
	_ok(mc.is_menu_visible() == true, "toggle open is_menu_visible true")
	_ok(mc.is_paused() == true, "toggle open is_paused true")
	_ok(mc.is_editor_enabled() == false, "toggle open suppresses editing")

## Two toggles return to the initial open/pause/edit state.
func _test_toggle_menu_round_trip() -> void:
	var mc := ModeController.new()
	mc.toggle_menu()
	mc.toggle_menu()
	_ok(mc.is_menu_visible() == false, "round-trip is_menu_visible false")
	_ok(mc.is_paused() == false, "round-trip is_paused false")
	_ok(mc.is_editor_enabled() == true, "round-trip is_editor_enabled true")

## PLAY with the menu closed disables editing but does NOT pause.
func _test_set_mode_play() -> void:
	var mc := ModeController.new()
	mc.set_mode(ModeController.Mode.PLAY)
	_ok(mc.is_editor_enabled() == false, "play is_editor_enabled false")
	_ok(mc.is_paused() == false, "play does not pause")
	_ok(mc.is_menu_visible() == false, "play is_menu_visible false")

## Switching back to EDITOR (menu closed) restores editing.
func _test_set_mode_editor() -> void:
	var mc := ModeController.new()
	mc.set_mode(ModeController.Mode.PLAY)
	mc.set_mode(ModeController.Mode.EDITOR)
	_ok(mc.is_editor_enabled() == true, "editor restores is_editor_enabled true")

## PLAY with the menu open: menu pauses and suppresses editing; overlay visible.
func _test_compose_play_menu_open() -> void:
	var mc := ModeController.new()
	mc.set_mode(ModeController.Mode.PLAY)
	mc.toggle_menu()
	_ok(mc.is_paused() == true, "play+menu is_paused true")
	_ok(mc.is_editor_enabled() == false, "play+menu is_editor_enabled false")
	_ok(mc.is_menu_visible() == true, "play+menu is_menu_visible true")

## EDITOR with the menu open: the menu gate wins over EDITOR, so editing stays off.
func _test_editor_menu_open() -> void:
	var mc := ModeController.new()
	mc.set_mode(ModeController.Mode.EDITOR)
	mc.toggle_menu()
	_ok(mc.is_editor_enabled() == false, "editor+menu gate wins, editing off")
