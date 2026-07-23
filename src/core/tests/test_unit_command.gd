extends GdTest
## Pure-logic tests for UnitCommand (no Node deps; drives only its stateful decision func).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## UnitCommand is stateful, so each test builds a fresh UnitCommand.new().


func _run() -> void:
	_test_first_click_spawns()
	_test_later_clicks_move()
	_test_despawn_respawns()
	_test_enum_values_distinct()


# --- tests ---

## A fresh command has no unit; the first click SPAWNs at the picked cell/tier and records
## that a unit now exists.
func _test_first_click_spawns() -> void:
	var cmd := UnitCommand.new()
	_ok(cmd.has_unit() == false, "fresh has_unit false")
	var r: Dictionary = cmd.on_click(Vector2i(3, 1), 0)
	var action: UnitCommand.Action = r["action"]
	var cell: Vector2i = r["cell"]
	var tier: int = r["tier"]
	_ok(action == UnitCommand.Action.SPAWN, "first click action SPAWN")
	_v_eq(cell, Vector2i(3, 1), "first click echoes cell")
	_i_eq(tier, 0, "first click echoes tier")
	_ok(cmd.has_unit() == true, "after spawn has_unit true")

## With a unit present, the second click MOVEs and echoes its cell/tier; a third click also
## MOVEs, and the unit stays present throughout (MOVE is repeatable).
func _test_later_clicks_move() -> void:
	var cmd := UnitCommand.new()
	cmd.on_click(Vector2i(3, 1), 0)
	var r2: Dictionary = cmd.on_click(Vector2i(5, 2), 1)
	var action2: UnitCommand.Action = r2["action"]
	var cell2: Vector2i = r2["cell"]
	var tier2: int = r2["tier"]
	_ok(action2 == UnitCommand.Action.MOVE, "second click action MOVE")
	_v_eq(cell2, Vector2i(5, 2), "second click echoes cell")
	_i_eq(tier2, 1, "second click echoes tier")
	_ok(cmd.has_unit() == true, "after move has_unit still true")
	var r3: Dictionary = cmd.on_click(Vector2i(7, 3), 2)
	var action3: UnitCommand.Action = r3["action"]
	_ok(action3 == UnitCommand.Action.MOVE, "third click action MOVE (repeatable)")
	_ok(cmd.has_unit() == true, "after third click has_unit still true")

## on_despawn forgets the unit, so has_unit goes false and the next click SPAWNs again.
func _test_despawn_respawns() -> void:
	var cmd := UnitCommand.new()
	cmd.on_click(Vector2i(3, 1), 0)
	cmd.on_despawn()
	_ok(cmd.has_unit() == false, "after despawn has_unit false")
	var r: Dictionary = cmd.on_click(Vector2i(4, 4), 1)
	var action: UnitCommand.Action = r["action"]
	_ok(action == UnitCommand.Action.SPAWN, "click after despawn action SPAWN")
	_ok(cmd.has_unit() == true, "respawn sets has_unit true")

## The three Action values are pairwise distinct so the node can switch on them.
func _test_enum_values_distinct() -> void:
	_ok(UnitCommand.Action.NONE != UnitCommand.Action.SPAWN, "NONE != SPAWN")
	_ok(UnitCommand.Action.SPAWN != UnitCommand.Action.MOVE, "SPAWN != MOVE")
	_ok(UnitCommand.Action.NONE != UnitCommand.Action.MOVE, "NONE != MOVE")
