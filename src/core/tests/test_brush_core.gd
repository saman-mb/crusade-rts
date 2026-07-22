extends GdTest
## Pure-logic tests for BrushCore (no Node deps; drives only static decision funcs).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Guards the "empty is -1, never 0" pitfall and the PAINT/ERASE resolve matrix.


func _run() -> void:
	_test_is_empty()
	_test_resolve_paint()
	_test_resolve_erase()
	_test_clamp_level()
	_test_cycle_level()


# --- tests ---

## is_empty() must key off -1 ONLY; source_id 0 is a valid, non-empty source.
func _test_is_empty() -> void:
	_ok(BrushCore.is_empty(-1) == true, "is_empty(-1) true")
	_ok(BrushCore.is_empty(0) == false, "is_empty(0) false (0 is a valid source, NOT empty)")
	_ok(BrushCore.is_empty(1) == false, "is_empty(1) false")
	_ok(BrushCore.is_empty(5) == false, "is_empty(5) false")
	_i_eq(BrushCore.EMPTY_SOURCE_ID, -1, "EMPTY_SOURCE_ID sentinel is -1")

## PAINT: writes on empty/changed cells, no-ops only when source AND atlas match.
func _test_resolve_paint() -> void:
	var target_src := 2
	var target_atlas := Vector2i(1, 3)

	# PAINT onto an empty cell (current source -1) -> WRITE the target.
	var on_empty := BrushCore.resolve(BrushCore.Mode.PAINT, -1, Vector2i(-1, -1), target_src, target_atlas)
	_ok(on_empty["action"] == BrushCore.Action.WRITE, "PAINT on empty -> WRITE")
	_i_eq(on_empty["source_id"], target_src, "PAINT on empty source_id == target")
	_v_eq(on_empty["atlas_coords"], target_atlas, "PAINT on empty atlas == target")

	# PAINT where current already == target (source AND atlas) -> idempotent NONE.
	var same := BrushCore.resolve(BrushCore.Mode.PAINT, target_src, target_atlas, target_src, target_atlas)
	_ok(same["action"] == BrushCore.Action.NONE, "PAINT identical -> NONE")
	_i_eq(same["source_id"], target_src, "PAINT identical keeps source_id")
	_v_eq(same["atlas_coords"], target_atlas, "PAINT identical keeps atlas")

	# PAINT where source matches but atlas differs -> WRITE.
	var atlas_diff := BrushCore.resolve(BrushCore.Mode.PAINT, target_src, Vector2i(0, 0), target_src, target_atlas)
	_ok(atlas_diff["action"] == BrushCore.Action.WRITE, "PAINT same source diff atlas -> WRITE")
	_i_eq(atlas_diff["source_id"], target_src, "PAINT atlas-diff source_id == target")
	_v_eq(atlas_diff["atlas_coords"], target_atlas, "PAINT atlas-diff atlas == target")

	# PAINT where atlas matches but source differs -> WRITE.
	var src_diff := BrushCore.resolve(BrushCore.Mode.PAINT, 9, target_atlas, target_src, target_atlas)
	_ok(src_diff["action"] == BrushCore.Action.WRITE, "PAINT diff source same atlas -> WRITE")
	_i_eq(src_diff["source_id"], target_src, "PAINT source-diff source_id == target")
	_v_eq(src_diff["atlas_coords"], target_atlas, "PAINT source-diff atlas == target")

## ERASE: NONE on an already-empty cell; CLEAR to -1 on any filled cell (incl. source 0).
func _test_resolve_erase() -> void:
	# ERASE on empty (current -1) -> NONE.
	var on_empty := BrushCore.resolve(BrushCore.Mode.ERASE, -1, Vector2i(-1, -1), 0, Vector2i(0, 0))
	_ok(on_empty["action"] == BrushCore.Action.NONE, "ERASE on empty -> NONE")
	_i_eq(on_empty["source_id"], BrushCore.EMPTY_SOURCE_ID, "ERASE on empty source_id == -1")

	# ERASE on a cell filled with source 0 (the "never 0" trap) -> CLEAR.
	var on_zero := BrushCore.resolve(BrushCore.Mode.ERASE, 0, Vector2i(1, 1), 0, Vector2i(0, 0))
	_ok(on_zero["action"] == BrushCore.Action.CLEAR, "ERASE on source 0 -> CLEAR (0 is filled)")
	_i_eq(on_zero["source_id"], BrushCore.EMPTY_SOURCE_ID, "ERASE on source 0 source_id == -1")
	_v_eq(on_zero["atlas_coords"], Vector2i(-1, -1), "ERASE on source 0 atlas == (-1,-1)")

	# ERASE on a cell filled with source 3 -> CLEAR.
	var on_filled := BrushCore.resolve(BrushCore.Mode.ERASE, 3, Vector2i(2, 2), 0, Vector2i(0, 0))
	_ok(on_filled["action"] == BrushCore.Action.CLEAR, "ERASE on source 3 -> CLEAR")
	_i_eq(on_filled["source_id"], BrushCore.EMPTY_SOURCE_ID, "ERASE on source 3 source_id == -1")
	_v_eq(on_filled["atlas_coords"], Vector2i(-1, -1), "ERASE on source 3 atlas == (-1,-1)")

## clamp_level() pins into [0, count-1] and guards an empty set.
func _test_clamp_level() -> void:
	_i_eq(BrushCore.clamp_level(-1, 3), 0, "clamp below -> 0")
	_i_eq(BrushCore.clamp_level(5, 3), 2, "clamp above -> count-1")
	_i_eq(BrushCore.clamp_level(1, 3), 1, "clamp in-range -> unchanged")
	_i_eq(BrushCore.clamp_level(0, 3), 0, "clamp at low bound -> 0")
	_i_eq(BrushCore.clamp_level(2, 3), 2, "clamp at high bound -> count-1")
	_i_eq(BrushCore.clamp_level(4, 0), 0, "clamp count<=0 -> 0")
	_i_eq(BrushCore.clamp_level(4, -2), 0, "clamp count negative -> 0")

## cycle_level() wraps within [0, count) in both directions and guards an empty set.
func _test_cycle_level() -> void:
	_i_eq(BrushCore.cycle_level(0, 1, 3), 1, "cycle +1 within range")
	_i_eq(BrushCore.cycle_level(2, 1, 3), 0, "cycle +1 wraps up to 0")
	_i_eq(BrushCore.cycle_level(0, -1, 3), 2, "cycle -1 wraps down to count-1")
	_i_eq(BrushCore.cycle_level(1, 3, 3), 1, "cycle +count returns same index")
	_i_eq(BrushCore.cycle_level(1, 0, 3), 1, "cycle +0 unchanged")
	_i_eq(BrushCore.cycle_level(0, 1, 0), 0, "cycle count<=0 -> 0")
	_i_eq(BrushCore.cycle_level(2, -1, -5), 0, "cycle count negative -> 0")
