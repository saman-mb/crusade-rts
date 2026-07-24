extends GdTest
## Tests for DoodadScatter (#234): the deterministic decor-placement core. Same
## contract as the terrain variation -- determinism (a reload reproduces the field)
## plus in-range type/variant and a density that tracks the requested rate.


func _run() -> void:
	_test_determinism()
	_test_density()
	_test_fields_in_range()
	_test_zero_density()
	_test_full_density()


func _cells(w: int, h: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(h):
		for x in range(w):
			out.append(Vector2i(x, y))
	return out


## Same cells + same density reproduce the identical scatter (cell, type, variant,
## offset), so a deterministic re-derive on reload is stable.
func _test_determinism() -> void:
	var cells := _cells(24, 24)
	var a := DoodadScatter.scatter(cells, 150)
	var b := DoodadScatter.scatter(cells, 150)
	var same := a.size() == b.size()
	if same:
		for i in range(a.size()):
			if a[i]["cell"] != b[i]["cell"] or a[i]["type"] != b[i]["type"] \
					or a[i]["variant"] != b[i]["variant"] or a[i]["offset"] != b[i]["offset"]:
				same = false
	_ok(same, "DoodadScatter not deterministic")


## Over a large field the placed count is near the requested per-mille rate.
func _test_density() -> void:
	var cells := _cells(80, 80)   # 6400 cells
	var placed := DoodadScatter.scatter(cells, 120).size()
	var rate := float(placed) / float(cells.size())
	_ok(absf(rate - 0.12) < 0.03, "density %.3f off target 0.12" % rate)


## Every entry carries an in-range type + variant and a bounded sub-cell offset.
func _test_fields_in_range() -> void:
	var ok := true
	for d in DoodadScatter.scatter(_cells(40, 40), 300):
		var t: int = d["type"]
		var v: int = d["variant"]
		var off: Vector2 = d["offset"]
		if t < 0 or t >= DoodadCatalog.TYPE_COUNT:
			ok = false
		if v < 0 or v >= DoodadCatalog.VARIANTS:
			ok = false
		if absf(off.x) > MapConstants.TILE_SIZE.x or absf(off.y) > MapConstants.TILE_SIZE.y:
			ok = false
	_ok(ok, "a doodad had an out-of-range type/variant or an oversized offset")


## Zero density places nothing; full density (1000) places on every cell.
func _test_zero_density() -> void:
	_i_eq(DoodadScatter.scatter(_cells(20, 20), 0).size(), 0, "density 0 placed something")


func _test_full_density() -> void:
	var cells := _cells(20, 20)
	_i_eq(DoodadScatter.scatter(cells, 1000).size(), cells.size(), "density 1000 missed cells")
