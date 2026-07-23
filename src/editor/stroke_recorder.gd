class_name StrokeRecorder
extends RefCounted
## Accumulates ONE editing stroke's per-cell changes and commits them as a single
## composite UndoRedo action, so a single Ctrl+Z reverts the whole stroke. Pure logic
## plus a thin UndoRedo seam: no Node / TileMapLayer deps -- the target is abstracted
## behind a set_cell(cell, source_id, atlas_coords, alternative_tile)-shaped `sink` Callable.
## Follows the "empty is -1, never 0" rule (BrushCore.EMPTY_SOURCE_ID); source_id -1 means
## clear. Records alternative_tile per cell (#109) so undo/redo restore it losslessly.

## Backing store, keyed by cell. Each value is
## { "before_src": int, "before_atlas": Vector2i, "before_alt": int,
##   "after_src": int, "after_atlas": Vector2i, "after_alt": int }.
## The before-state is first-seen-wins; the after-state is last-write-wins. `alt` is the
## cell's alternative_tile index (#109): it round-trips on disk, so undo must restore it too.
var _cells: Dictionary = {}

## Records one cell touch. The FIRST before-state seen for a cell is kept (so a drag that
## revisits a cell still undoes to the ORIGINAL contents); the after-state is overwritten
## every call (last write wins). No net-change filtering happens here -- see changes().
## `alt` is the alternative_tile index (#109): tracked before/after so undo/redo restore it.
func record(cell: Vector2i, before_src: int, before_atlas: Vector2i, before_alt: int, after_src: int, after_atlas: Vector2i, after_alt: int) -> void:
	if _cells.has(cell):
		var e: Dictionary = _cells[cell]
		e["after_src"] = after_src
		e["after_atlas"] = after_atlas
		e["after_alt"] = after_alt
	else:
		_cells[cell] = {
			"before_src": before_src,
			"before_atlas": before_atlas,
			"before_alt": before_alt,
			"after_src": after_src,
			"after_atlas": after_atlas,
			"after_alt": after_alt,
		}

## Returns only cells whose NET state changed (before != after), as an Array of
## { "cell", "before_src", "before_atlas", "before_alt", "after_src", "after_atlas", "after_alt" }.
## Drops no-op records AND paint-then-reverted-within-stroke cells (net zero). A change in
## alternative_tile alone (#109) counts as a net change. Order is not guaranteed but is
## deterministic per run (iterates the backing dict's insertion order).
func changes() -> Array:
	var out: Array = []
	for cell in _cells:
		var e: Dictionary = _cells[cell]
		if e["before_src"] == e["after_src"] and e["before_atlas"] == e["after_atlas"] and e["before_alt"] == e["after_alt"]:
			continue
		out.append({
			"cell": cell,
			"before_src": e["before_src"],
			"before_atlas": e["before_atlas"],
			"before_alt": e["before_alt"],
			"after_src": e["after_src"],
			"after_atlas": e["after_atlas"],
			"after_alt": e["after_alt"],
		})
	return out

## True when changes() would be empty: no records, or every record is a net no-op.
func is_empty() -> bool:
	for cell in _cells:
		var e: Dictionary = _cells[cell]
		if e["before_src"] != e["after_src"] or e["before_atlas"] != e["after_atlas"] or e["before_alt"] != e["after_alt"]:
			return false
	return true

## Resets the recorder for reuse (drops all recorded cells).
func clear() -> void:
	_cells.clear()

## Commits this stroke's net changes as ONE composite UndoRedo action (one commit = one
## undo step). Does NOTHING (creates no action) when there are no net changes, so an empty
## or fully-reverted stroke never pollutes the undo history. `sink` is a
## set_cell(cell, source_id, atlas_coords)-shaped Callable (source_id -1 clears the cell).
##
## THIS IS THE PRIMARY entry point. It commits with execute=false: the caller is expected
## to have ALREADY applied the stroke live to the target during the drag, so committing
## must NOT re-run the do-methods (that would double-apply). undo()/redo() then drive the
## sink normally from history. `sink` takes (cell, source_id, atlas_coords, alternative_tile).
func commit(ur: UndoRedo, action_name: String, sink: Callable) -> void:
	apply_to_undo(ur, action_name, changes(), sink)

## Static UndoRedo bridge over a pre-computed `changes` array (as returned by changes()).
## For a non-empty change set: create_action(action_name), then for EACH change add a
## do-method binding the AFTER state and an undo-method binding the BEFORE state (each
## including alternative_tile, #109), then commit_action(false) ONCE. Returns early (no
## action created) on an empty change set. execute=false because the caller applied the
## stroke live -- see commit() above.
static func apply_to_undo(ur: UndoRedo, action_name: String, changes: Array, sink: Callable) -> void:
	if changes.is_empty():
		return
	ur.create_action(action_name)
	for c in changes:
		var cell: Vector2i = c["cell"]
		ur.add_do_method(sink.bind(cell, c["after_src"], c["after_atlas"], c["after_alt"]))
		ur.add_undo_method(sink.bind(cell, c["before_src"], c["before_atlas"], c["before_alt"]))
	ur.commit_action(false)
