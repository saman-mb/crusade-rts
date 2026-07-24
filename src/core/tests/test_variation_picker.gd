extends GdTest
## Tests for VariationPicker (#232): the deterministic per-cell variant chooser.
## Determinism (same cell -> same index) is the load-safety contract; range and a
## rough uniform spread are what make the variation actually break up the grid.


func _run() -> void:
	_test_range()
	_test_determinism()
	_test_count_guard()
	_test_negative_cells()
	_test_distribution()


## Every pick lands in [0, count) for a block of cells.
func _test_range() -> void:
	var count := TileSetConstants.GRASS_VARIANTS
	var in_range := true
	for y in range(-4, 12):
		for x in range(-4, 12):
			var v := VariationPicker.pick(Vector2i(x, y), count)
			if v < 0 or v >= count:
				in_range = false
	_ok(in_range, "pick out of [0, %d)" % count)


## Same cell + same count is stable across calls (survives save/reload unchanged).
func _test_determinism() -> void:
	var same := true
	for i in range(50):
		var cell := Vector2i(i * 3 - 7, 11 - i)
		if VariationPicker.pick(cell, 8) != VariationPicker.pick(cell, 8):
			same = false
	_ok(same, "pick not deterministic for a fixed cell")


## count <= 1 always maps to the base tile (index 0) -- a safe no-op.
func _test_count_guard() -> void:
	_i_eq(VariationPicker.pick(Vector2i(5, 5), 1), 0, "count 1 -> base")
	_i_eq(VariationPicker.pick(Vector2i(5, 5), 0), 0, "count 0 -> base")
	_i_eq(VariationPicker.pick(Vector2i(-3, 9), -2), 0, "negative count -> base")


## Negative cell coords (maps can extend into negative space) stay in range and
## deterministic -- the hash must not sign-extend into a negative index.
func _test_negative_cells() -> void:
	var ok := true
	for y in range(-20, -1):
		for x in range(-20, -1):
			var v := VariationPicker.pick(Vector2i(x, y), 8)
			if v < 0 or v >= 8:
				ok = false
	_ok(ok, "negative cells produced an out-of-range index")


## Across a large block every variant bucket is hit at least once, so variation
## actually spreads rather than collapsing onto one or two indices.
func _test_distribution() -> void:
	var count := TileSetConstants.GRASS_VARIANTS
	var seen := {}
	for y in range(40):
		for x in range(40):
			seen[VariationPicker.pick(Vector2i(x, y), count)] = true
	_i_eq(seen.size(), count, "not every variant index appears over a 40x40 block")
