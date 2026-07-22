extends GdTest
## Pure-logic tests for DualGrid (integer cell space; reads TileSetConstants.LOOKUP).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Bit convention under test: TL=1, TR=2, BL=4, BR=8.


func _run() -> void:
	_test_corner_mask()
	_test_mask_bijection()
	_test_logical_corners_of_display()
	_test_inverse_property()
	_test_changed_display_cells_negative()
	_test_atlas_coord_out_of_range()
	_test_tile_for_display_pond()


# --- tests ---

## Hand-picked corner_mask combos exercise each bit and a mixed case.
func _test_corner_mask() -> void:
	_i_eq(DualGrid.corner_mask(false, false, false, false), 0, "corner_mask FFFF")
	_i_eq(DualGrid.corner_mask(true, false, false, false), 1, "corner_mask TFFF (TL=1)")
	_i_eq(DualGrid.corner_mask(false, true, false, false), 2, "corner_mask FTFF (TR=2)")
	_i_eq(DualGrid.corner_mask(false, false, true, false), 4, "corner_mask FFTF (BL=4)")
	_i_eq(DualGrid.corner_mask(false, false, false, true), 8, "corner_mask FFFT (BR=8)")
	_i_eq(DualGrid.corner_mask(true, true, true, true), 15, "corner_mask TTTT")
	_i_eq(DualGrid.corner_mask(true, false, true, false), 5, "corner_mask TFTF (TL|BL=5)")

## Mask 0 -> SENTINEL; masks 1..15 map to 15 distinct, non-sentinel atlas coords.
func _test_mask_bijection() -> void:
	_v_eq(DualGrid.atlas_coord_for_mask(0), DualGrid.SENTINEL, "atlas_coord_for_mask(0) sentinel")

	var seen: Array[Vector2i] = []
	for mask in range(1, 16):
		var coord := DualGrid.atlas_coord_for_mask(mask)
		_ok(coord != DualGrid.SENTINEL, "mask %d coord not sentinel" % mask)
		_ok(not seen.has(coord), "mask %d coord %s distinct" % [mask, coord])
		seen.append(coord)
	_i_eq(seen.size(), 15, "15 non-empty masks collected")

	# Full fill maps to a valid non-sentinel coord.
	_ok(DualGrid.atlas_coord_for_mask(15) != DualGrid.SENTINEL, "mask 15 non-sentinel")

## Display cell (3,5) straddles the four documented logical corners.
func _test_logical_corners_of_display() -> void:
	var corners := DualGrid.logical_corners_of_display(Vector2i(3, 5))
	var want: Array[Vector2i] = [Vector2i(2, 4), Vector2i(3, 4), Vector2i(2, 5), Vector2i(3, 5)]
	_ok(corners == want, "logical_corners_of_display(3,5): expected %s got %s" % [want, corners])

## changed_display_cells is the exact inverse of logical_corners_of_display:
## every dirtied display cell lists the flipped logical cell among its corners.
func _test_inverse_property() -> void:
	var l := Vector2i(2, 2)
	var changed := DualGrid.changed_display_cells(l)
	var want: Array[Vector2i] = [Vector2i(2, 2), Vector2i(3, 2), Vector2i(2, 3), Vector2i(3, 3)]
	_ok(changed == want, "changed_display_cells(2,2): expected %s got %s" % [want, changed])

	for d in changed:
		var corners := DualGrid.logical_corners_of_display(d)
		_ok(corners.has(l), "L %s in corners of display %s (got %s)" % [l, d, corners])

## The inverse property must also hold at NEGATIVE logical coordinates -- the
## previous case only exercised (2,2), so a signed/unsigned or positive-only
## assumption in the +1 quad would slip through. (#31)
func _test_changed_display_cells_negative() -> void:
	var l := Vector2i(-3, -2)
	var changed := DualGrid.changed_display_cells(l)
	var want: Array[Vector2i] = [Vector2i(-3, -2), Vector2i(-2, -2), Vector2i(-3, -1), Vector2i(-2, -1)]
	_ok(changed == want, "changed_display_cells(-3,-2): expected %s got %s" % [want, changed])
	for d in changed:
		_ok(DualGrid.logical_corners_of_display(d).has(l), "L %s in corners of display %s" % [l, d])

## atlas_coord_for_mask guards its LOOKUP index: masks outside 0..15 are
## unreachable via corner_mask (a 4-bit build) so the guard is otherwise never
## exercised -- assert it returns SENTINEL rather than indexing out of bounds. (#31)
func _test_atlas_coord_out_of_range() -> void:
	for bad in [-1, -8, 16, 17, 100, -100]:
		_v_eq(DualGrid.atlas_coord_for_mask(bad), DualGrid.SENTINEL,
			"atlas_coord_for_mask(%d) out-of-range -> SENTINEL" % bad)
	# In-range boundaries stay meaningful: 0 is the empty sentinel, 15 is real art.
	_v_eq(DualGrid.atlas_coord_for_mask(0), DualGrid.SENTINEL, "mask 0 -> SENTINEL (empty)")
	_ok(DualGrid.atlas_coord_for_mask(15) != DualGrid.SENTINEL, "mask 15 -> real coord")

## Round-trip against a "pond" predicate (filled for cells in 0..2 on both axes).
func _test_tile_for_display_pond() -> void:
	var is_filled := func(c: Vector2i) -> bool:
		return c.x >= 0 and c.x <= 2 and c.y >= 0 and c.y <= 2

	# Interior display cell (2,2): corners (1,1),(2,1),(1,2),(2,2) all filled -> mask 15.
	var interior := DualGrid.tile_for_display(Vector2i(2, 2), is_filled)
	_v_eq(interior, DualGrid.atlas_coord_for_mask(15), "interior display (2,2) -> mask 15")

	# Display cell (10,10): all four corners empty -> mask 0 -> SENTINEL.
	var outside := DualGrid.tile_for_display(Vector2i(10, 10), is_filled)
	_v_eq(outside, DualGrid.SENTINEL, "outside display (10,10) -> sentinel")

	# Edge display cell (0,0): corners (-1,-1),(0,-1),(-1,0),(0,0); only BR (0,0)
	# is filled -> mask 8 (partial: non-0, non-15).
	var edge := DualGrid.tile_for_display(Vector2i(0, 0), is_filled)
	_v_eq(edge, DualGrid.atlas_coord_for_mask(8), "edge display (0,0) -> mask 8")
	_ok(edge != DualGrid.SENTINEL, "edge display (0,0) not sentinel")
	_ok(edge != DualGrid.atlas_coord_for_mask(15), "edge display (0,0) not full-fill")
