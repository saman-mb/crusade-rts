class_name Marquee
extends RefCounted
## Pure marquee (drag-rectangle) hit-test for multi-select (#81).
##
## Marquee answers exactly one question: given a snapshot of the live units and a
## selection rectangle, which unit ids fall inside that rectangle on the active
## tier? It is a plain RefCounted with NO Node deps — the controller does all of
## the screen<->world conversion and hands this core unit positions and a rect in
## the SAME coordinate space, so the whole thing is space-agnostic geometry that
## runs headlessly.
##
## The one static entry point (`ids_in_rect`) mirrors `Selection.unit_at`'s
## "pure geometry over a snapshot array" shape, and it returns ids SORTED ascending
## to match `Selection.selected_ids()`'s ordering guarantee: every consumer sees one
## stable canonical order regardless of snapshot order.

## Which unit ids lie inside `rect` on `tier`? `entries` is a snapshot Array of
## `{ "id": int, "pos": Vector2, "tier": int }` dictionaries — one per live unit.
## Returns those ids whose `pos` is inside `rect` AND whose entry `tier` equals the
## requested `tier`, SORTED ascending and de-duplicated, as a typed `Array[int]`.
##
## Membership uses Godot's `Rect2.has_point`, which is inclusive of the top-left
## edge and EXCLUSIVE of the bottom-right edge: a point is in iff
## `pos.x >= rect.position.x and pos.x < rect.position.x + rect.size.x` (and the
## same for y). The caller passes a NORMALIZED rect (non-negative size); as a guard,
## any rect with a zero or negative size component is treated as empty and yields
## `[]` (an empty drag selects nothing).
##
## Static and Node-free: geometry over a plain array, needs no Marquee instance and
## never touches the scene tree.
static func ids_in_rect(entries: Array, rect: Rect2, tier: int) -> Array[int]:
	var out: Array[int] = []
	# A zero/negative-area rect selects nothing (empty drag or degenerate input).
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return out
	var seen: Dictionary = {}
	for entry: Dictionary in entries:
		var etier: int = entry["tier"]
		if etier != tier:
			continue
		var pos: Vector2 = entry["pos"]
		if not rect.has_point(pos):
			continue
		var id: int = entry["id"]
		if seen.has(id):
			continue
		seen[id] = true
		out.append(id)
	out.sort()
	return out
