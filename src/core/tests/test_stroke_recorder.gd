extends GdTest
## Pure-logic tests for StrokeRecorder (no Node / TileMapLayer deps; drives the recorder
## plus a thin in-memory UndoRedo sink). Self-contained SceneTree runner:
## godot --headless --script <this file>.
##
## Focus (#109): the recorder must track alternative_tile per cell so a record->undo cycle
## restores it losslessly. Backs the sink with an in-memory grid (Vector2i -> {src,atlas,alt})
## via a method-Callable -- mirroring the runtime's Callable(layer, "set_cell") shape, now
## (cell, source_id, atlas_coords, alternative_tile) -- so the undo/redo drive is headless.
## Also proves alt-only changes are NOT dropped as no-ops, and that a truly-identical touch
## (incl. alt) IS dropped.

## In-memory tile grid the sink writes to (Vector2i -> { src, atlas, alt }). Reset per test.
var _grid: Dictionary = {}


func _run() -> void:
	_test_entry_captures_alt()
	_test_alt_only_change_is_not_noop()
	_test_identical_incl_alt_is_noop()
	_test_alt_preserved_through_undo_redo()


# --- sink ---

## set_cell(cell, source_id, atlas_coords, alternative_tile)-shaped sink over `_grid`.
## Matches the runtime's Callable(_active_layer, "set_cell"); source_id -1 clears the cell.
func _apply(cell: Vector2i, src: int, atlas: Vector2i, alt: int) -> void:
	if src == -1:
		_grid.erase(cell)
	else:
		_grid[cell] = { "src": src, "atlas": atlas, "alt": alt }


# --- tests ---

## 1. A recorded entry keeps both before- and after-alt (the raw capture, no undo drive).
func _test_entry_captures_alt() -> void:
	var rec := StrokeRecorder.new()
	rec.record(Vector2i(0, 0), 1, Vector2i(2, 2), 0, 4, Vector2i(3, 3), 7)
	var changes := rec.changes()
	_i_eq(changes.size(), 1, "one net change recorded")
	var c: Dictionary = changes[0]
	var before_alt: int = c["before_alt"]
	var after_alt: int = c["after_alt"]
	_i_eq(before_alt, 0, "entry preserves before alt")
	_i_eq(after_alt, 7, "entry preserves after alt")

## 2. A change in alternative_tile ALONE (same src+atlas) is a real net change, not a no-op.
func _test_alt_only_change_is_not_noop() -> void:
	var rec := StrokeRecorder.new()
	rec.record(Vector2i(1, 1), 2, Vector2i(0, 0), 3, 2, Vector2i(0, 0), 5)
	_ok(not rec.is_empty(), "alt-only change (3 -> 5) is NOT empty")
	_i_eq(rec.changes().size(), 1, "alt-only change yields one change entry")

## 3. An identical touch -- same src, atlas AND alt -- nets to zero and is dropped.
func _test_identical_incl_alt_is_noop() -> void:
	var rec := StrokeRecorder.new()
	rec.record(Vector2i(2, 2), 2, Vector2i(0, 0), 3, 2, Vector2i(0, 0), 3)
	_ok(rec.is_empty(), "identical before/after (incl. alt) is a net no-op")
	_i_eq(rec.changes().size(), 0, "no-op produces no change entry")

## 4. Full record -> commit -> undo -> redo cycle with a NONZERO alt: undo restores the
##    before-alt, redo restores the after-alt. commit() is execute=false, so the grid is
##    pre-seeded with the AFTER state to mirror the live drag the runtime already applied.
func _test_alt_preserved_through_undo_redo() -> void:
	_grid = {}
	var sink := Callable(self, "_apply")
	var cell := Vector2i(2, 3)
	var rec := StrokeRecorder.new()
	# before: src 1, atlas (0,0), alt 3 ; after: same src+atlas, alt 5 (alt-only flip).
	rec.record(cell, 1, Vector2i(0, 0), 3, 1, Vector2i(0, 0), 5)
	# Simulate the live paint the runtime does during the drag: grid holds the AFTER state.
	_grid[cell] = { "src": 1, "atlas": Vector2i(0, 0), "alt": 5 }

	var ur := UndoRedo.new()
	rec.commit(ur, "Paint", sink)

	ur.undo()
	var undone: Dictionary = _grid[cell]
	var undone_alt: int = undone["alt"]
	_i_eq(undone_alt, 3, "undo restores the before alt")

	ur.redo()
	var redone: Dictionary = _grid[cell]
	var redone_alt: int = redone["alt"]
	_i_eq(redone_alt, 5, "redo restores the after alt")

	ur.free()
