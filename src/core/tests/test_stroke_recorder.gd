extends SceneTree
## Pure-logic tests for StrokeRecorder (the Command Pattern wrapper): per-cell change
## accumulation, first-before-wins / last-after-wins, net-zero + no-op dropping, and the
## real UndoRedo batch driven through an in-memory grid (no TileMapLayer needed, since
## UndoRedo is an instantiable RefCounted). Self-contained SceneTree runner:
## godot --headless --script <this file>. Guards the "empty is -1, never 0" convention and
## the one-commit-equals-one-undo-step contract. CI greps "FAIL: ".

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_record_and_changes()
	_test_first_before_wins_last_after_wins()
	_test_net_zero_drop()
	_test_noop_drop()
	_test_is_empty_and_clear()
	_test_erase_and_paint_over_empty()
	_test_undo_redo_batch()
	_test_empty_recorder_creates_no_action()

	print("PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- helpers ---

## Increments counters; prints only on failure so passing runs stay quiet.
func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % msg)

## Exact int equality check with message.
func _i_eq(a: int, b: int, msg: String) -> void:
	_ok(a == b, "%s: expected %d got %d" % [msg, b, a])

## Exact Vector2i equality check with message.
func _v_eq(a: Vector2i, b: Vector2i, msg: String) -> void:
	_ok(a == b, "%s: expected %s got %s" % [msg, b, a])

## Minimal Dictionary-backed target that mimics a TileMapLayer's set_cell seam so the
## UndoRedo batch can be tested with no live Godot nodes. src -1 means an empty/cleared
## cell (the -1 sentinel). Returns -1 / (-1,-1) for never-written cells.
class Grid extends RefCounted:
	var cells: Dictionary = {}
	## Counts sink invocations so a test can distinguish execute=false (no call on
	## commit) from a spurious re-execution -- state alone can't, since set_cell is
	## idempotent. (#56)
	var calls: int = 0
	func set_cell(cell: Vector2i, src: int, atlas: Vector2i) -> void:
		calls += 1
		cells[cell] = { "src": src, "atlas": atlas }
	func src_at(cell: Vector2i) -> int:
		return cells[cell]["src"] if cells.has(cell) else -1
	func atlas_at(cell: Vector2i) -> Vector2i:
		return cells[cell]["atlas"] if cells.has(cell) else Vector2i(-1, -1)

## Finds the single change entry for `cell` in a changes() array, or {} if absent.
func _find(list: Array, cell: Vector2i) -> Dictionary:
	for c in list:
		if c["cell"] == cell:
			return c
	return {}

# --- tests ---

## record + changes: a single genuinely-changed cell appears with correct before/after.
func _test_record_and_changes() -> void:
	var r := StrokeRecorder.new()
	r.record(Vector2i(1, 1), -1, Vector2i(-1, -1), 2, Vector2i(3, 4))
	var ch := r.changes()
	_i_eq(ch.size(), 1, "one recorded change emitted")
	var e := _find(ch, Vector2i(1, 1))
	_ok(not e.is_empty(), "changed cell present in changes()")
	_i_eq(e["before_src"], -1, "before_src carried through")
	_v_eq(e["before_atlas"], Vector2i(-1, -1), "before_atlas carried through")
	_i_eq(e["after_src"], 2, "after_src carried through")
	_v_eq(e["after_atlas"], Vector2i(3, 4), "after_atlas carried through")

## first-before-wins / last-after-wins: revisiting a cell in one stroke keeps the ORIGINAL
## before and the LATEST after, so the whole stroke still undoes to original contents.
func _test_first_before_wins_last_after_wins() -> void:
	var r := StrokeRecorder.new()
	var cell := Vector2i(5, 5)
	# First touch: original contents src=0 -> painted src=2.
	r.record(cell, 0, Vector2i(1, 1), 2, Vector2i(2, 2))
	# Same cell revisited: its "before" now reads the mid-stroke src=2, but we must NOT
	# adopt it -- and its after moves on to src=7.
	r.record(cell, 2, Vector2i(2, 2), 7, Vector2i(8, 9))
	var ch := r.changes()
	_i_eq(ch.size(), 1, "revisited cell collapses to one change")
	var e := _find(ch, cell)
	_i_eq(e["before_src"], 0, "first-seen before_src wins (0, not 2)")
	_v_eq(e["before_atlas"], Vector2i(1, 1), "first-seen before_atlas wins")
	_i_eq(e["after_src"], 7, "last-write after_src wins (7)")
	_v_eq(e["after_atlas"], Vector2i(8, 9), "last-write after_atlas wins")

## net-zero drop: a cell painted then reverted within the stroke (final after == original
## before) is NOT emitted, even though it was touched twice.
func _test_net_zero_drop() -> void:
	var r := StrokeRecorder.new()
	var cell := Vector2i(6, 6)
	r.record(cell, 3, Vector2i(1, 1), 9, Vector2i(2, 2))   # 3 -> 9
	r.record(cell, 9, Vector2i(2, 2), 3, Vector2i(1, 1))   # 9 -> back to original 3/(1,1)
	var ch := r.changes()
	_i_eq(ch.size(), 0, "net-zero (painted then reverted) cell dropped")
	_ok(r.is_empty(), "recorder with only a net-zero cell is_empty()")

## no-op drop: a single record where after == before is never emitted.
func _test_noop_drop() -> void:
	var r := StrokeRecorder.new()
	r.record(Vector2i(7, 7), 4, Vector2i(1, 2), 4, Vector2i(1, 2))
	_i_eq(r.changes().size(), 0, "no-op record (after==before) dropped")
	_ok(r.is_empty(), "recorder with only a no-op is_empty()")

## is_empty() tracks net changes; clear() resets the recorder for reuse.
func _test_is_empty_and_clear() -> void:
	var r := StrokeRecorder.new()
	_ok(r.is_empty(), "fresh recorder is_empty()")
	r.record(Vector2i(8, 8), -1, Vector2i(-1, -1), 1, Vector2i(0, 0))
	_ok(not r.is_empty(), "recorder with a real change is NOT empty")
	_i_eq(r.changes().size(), 1, "one change before clear")
	r.clear()
	_ok(r.is_empty(), "cleared recorder is_empty() again")
	_i_eq(r.changes().size(), 0, "no changes after clear")

## erase path (paint -> empty) and paint-over-empty (empty -> paint) both emit, and the
## -1 sentinel flows through untouched in each direction.
func _test_erase_and_paint_over_empty() -> void:
	var r := StrokeRecorder.new()
	# Erase: filled src=0 (the "never 0" trap -- 0 is a valid source) -> cleared src=-1.
	var erase_cell := Vector2i(3, 3)
	r.record(erase_cell, 0, Vector2i(3, 3), -1, Vector2i(-1, -1))
	# Paint over empty: src=-1 -> filled src=2.
	var paint_cell := Vector2i(4, 4)
	r.record(paint_cell, -1, Vector2i(-1, -1), 2, Vector2i(1, 1))
	var ch := r.changes()
	_i_eq(ch.size(), 2, "erase and paint-over-empty both emitted")

	var e := _find(ch, erase_cell)
	_i_eq(e["before_src"], 0, "erase before_src is the filled 0")
	_i_eq(e["after_src"], -1, "erase after_src is the -1 sentinel")
	_v_eq(e["after_atlas"], Vector2i(-1, -1), "erase after_atlas is (-1,-1)")

	var p := _find(ch, paint_cell)
	_i_eq(p["before_src"], -1, "paint-over-empty before_src is -1")
	_i_eq(p["after_src"], 2, "paint-over-empty after_src is 2")

## The UndoRedo batch driven through an in-memory Grid, no TileMapLayer. Story: the caller
## has ALREADY applied the stroke live (we pre-apply the AFTER state), so commit uses
## execute=false and does NOT re-touch the grid. One undo reverts ALL cells (one step);
## redo re-applies ALL. Includes an erased cell to exercise the -1 undo path.
func _test_undo_redo_batch() -> void:
	var grid := Grid.new()
	var r := StrokeRecorder.new()

	# Three cells: two paints and one erase (before filled, after cleared).
	r.record(Vector2i(1, 0), -1, Vector2i(-1, -1), 2, Vector2i(1, 1))  # empty -> paint
	r.record(Vector2i(2, 0), 5, Vector2i(0, 0), 7, Vector2i(2, 2))     # repaint
	r.record(Vector2i(3, 0), 4, Vector2i(3, 3), -1, Vector2i(-1, -1))  # erase

	# Caller applies the stroke live during the drag -> grid holds the AFTER state.
	grid.set_cell(Vector2i(1, 0), 2, Vector2i(1, 1))
	grid.set_cell(Vector2i(2, 0), 7, Vector2i(2, 2))
	grid.set_cell(Vector2i(3, 0), -1, Vector2i(-1, -1))

	var ur := UndoRedo.new()
	# Reset the sink counter so we measure ONLY invocations from commit/undo/redo,
	# not the live pre-apply above. (#56)
	grid.calls = 0
	r.commit(ur, "Paint stroke", Callable(grid, "set_cell"))

	# DISCRIMINATING execute=false check: commit must invoke the sink ZERO times.
	# The grid already holds AFTER (pre-applied live), so a wrong execute=true would
	# leave identical STATE -- only the call count distinguishes the two. (#56)
	_i_eq(grid.calls, 0, "commit(execute=false) did not invoke the sink")
	_ok(ur.has_undo(), "committed stroke created an undoable action")
	_i_eq(grid.src_at(Vector2i(1, 0)), 2, "after commit: paint cell holds AFTER")
	_i_eq(grid.src_at(Vector2i(2, 0)), 7, "after commit: repaint cell holds AFTER")
	_i_eq(grid.src_at(Vector2i(3, 0)), -1, "after commit: erased cell holds AFTER (-1)")

	# ONE undo reverts ALL THREE cells to their BEFORE state (one commit = one step).
	ur.undo()
	_i_eq(grid.calls, 3, "undo invoked the sink once per changed cell (3)")
	_i_eq(grid.src_at(Vector2i(1, 0)), -1, "undo: paint cell back to empty (-1)")
	_i_eq(grid.src_at(Vector2i(2, 0)), 5, "undo: repaint cell back to 5")
	_v_eq(grid.atlas_at(Vector2i(2, 0)), Vector2i(0, 0), "undo: repaint cell atlas back to (0,0)")
	_i_eq(grid.src_at(Vector2i(3, 0)), 4, "undo: erased cell restored to filled 4")
	_v_eq(grid.atlas_at(Vector2i(3, 0)), Vector2i(3, 3), "undo: erased cell atlas restored")
	_ok(not ur.has_undo(), "single undo drained the one-action history")

	# ONE redo re-applies ALL THREE cells to their AFTER state.
	ur.redo()
	_i_eq(grid.calls, 6, "redo invoked the sink once per changed cell again (total 6)")
	_i_eq(grid.src_at(Vector2i(1, 0)), 2, "redo: paint cell AFTER again")
	_i_eq(grid.src_at(Vector2i(2, 0)), 7, "redo: repaint cell AFTER again")
	_i_eq(grid.src_at(Vector2i(3, 0)), -1, "redo: erased cell cleared again (-1)")

## Empty recorder (no net changes): commit must create NO UndoRedo action, so the history
## stays clean. Also checks a fully net-zero stroke via the same path.
func _test_empty_recorder_creates_no_action() -> void:
	var grid := Grid.new()
	var ur := UndoRedo.new()

	var empty := StrokeRecorder.new()
	empty.commit(ur, "Nothing", Callable(grid, "set_cell"))
	_ok(not ur.has_undo(), "empty recorder commit creates no action")

	# A recorder holding only a net-zero cell must likewise create no action.
	var netzero := StrokeRecorder.new()
	netzero.record(Vector2i(9, 9), 1, Vector2i(1, 1), 2, Vector2i(2, 2))
	netzero.record(Vector2i(9, 9), 2, Vector2i(2, 2), 1, Vector2i(1, 1))
	netzero.commit(ur, "Net zero", Callable(grid, "set_cell"))
	_ok(not ur.has_undo(), "net-zero-only recorder commit creates no action")
