class_name ModeController
extends RefCounted
## Single source of truth for the dev-menu's mode/pause/editor state. It models two orthogonal facts — the current Mode (EDITOR/PLAY) and whether the menu is open — and derives the three booleans the DevMenu node applies to SceneTree.paused, the overlay visibility, and MapEditor's paint gate. Stateful but Node-free, so it is fully headless-testable.

## Which layer the dev session is in: EDITOR allows map painting, PLAY runs the game.
enum Mode { EDITOR, PLAY }

## Current mode. Painting is only possible in EDITOR.
var mode: Mode = Mode.EDITOR

## Whether the dev menu overlay is open. Drives pause and suppresses painting.
var menu_open: bool = false

## Flips the menu open/closed.
func toggle_menu() -> void:
	menu_open = not menu_open

## Sets the active mode.
func set_mode(m: Mode) -> void:
	mode = m

## Whether the DevMenu overlay should be visible.
func is_menu_visible() -> bool:
	return menu_open

## Whether SceneTree.paused should be set. The MENU drives pause (not the mode).
func is_paused() -> bool:
	return menu_open

## Whether MapEditor may paint: painting only in EDITOR, and never while the menu is up.
func is_editor_enabled() -> bool:
	return mode == Mode.EDITOR and not menu_open
