class_name MapChange
extends RefCounted
## Pure helpers for the `map_changed` signal hub (#95). Isolates the ONE piece of
## non-trivial payload logic -- computing the affected-cell bounding Rect2i -- from
## the Node-side emit sites, so the rect a stroke/bucket announces is unit-testable
## with no TileMapLayer / Node dependency.

## Bounding Rect2i covering every cell in `cells` (each cell contributes a 1x1
## footprint, so the rect is inclusive of the max cell). Empty input -> a zero-size
## Rect2i(); a single cell -> a 1x1 rect at that cell. Never drags in the origin
## (0,0) for a non-empty set the way a naive Rect2i().merge() would.
static func bounds_of_cells(cells: Array) -> Rect2i:
	var seeded := false
	var minc := Vector2i.ZERO
	var maxc := Vector2i.ZERO
	for cell: Vector2i in cells:
		if not seeded:
			minc = cell
			maxc = cell
			seeded = true
			continue
		minc.x = mini(minc.x, cell.x)
		minc.y = mini(minc.y, cell.y)
		maxc.x = maxi(maxc.x, cell.x)
		maxc.y = maxi(maxc.y, cell.y)
	if not seeded:
		return Rect2i()
	return Rect2i(minc, maxc - minc + Vector2i.ONE)

## Bounding Rect2i over the `cell` field of a StrokeRecorder.changes()-shaped array
## (each element a Dictionary carrying a "cell" Vector2i). Convenience wrapper over
## bounds_of_cells for the editor's stroke/bucket emit sites.
static func bounds_of_changes(changes: Array) -> Rect2i:
	var cells: Array[Vector2i] = []
	for c in changes:
		cells.append(c["cell"])
	return bounds_of_cells(cells)
