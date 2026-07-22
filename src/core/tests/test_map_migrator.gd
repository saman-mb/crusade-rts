extends SceneTree
## Pure-logic tests for MapMigrator (sequential migrate-UP chain to CURRENT_SCHEMA).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Uses MapSchema.* for every key/version -- no string literals, no magic ints.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_missing_version_is_v0()
	_test_v0_wraps_legacy_cells()
	_test_v1_coord_flatten()
	_test_already_flat_stays_flat()
	_test_idempotent_on_current()
	_test_already_v2_passthrough()
	_test_monotonic()
	_test_future_version_preserved()
	_test_preserves_existing_keys()
	_test_non_mutation()

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

## Recursive deep equality for Dictionary/Array/scalar Variants.
func _dict_eq(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if typeof(a) == TYPE_DICTIONARY:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k):
				return false
			if not _dict_eq(a[k], b[k]):
				return false
		return true
	if typeof(a) == TYPE_ARRAY:
		return _arr_eq(a, b)
	return a == b

## Recursive deep equality for Arrays (defers to _dict_eq per element).
func _arr_eq(a: Variant, b: Variant) -> bool:
	if typeof(a) != TYPE_ARRAY or typeof(b) != TYPE_ARRAY:
		return false
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if not _dict_eq(a[i], b[i]):
			return false
	return true

# --- tests ---

## A document with no schema_version is treated as v0 and produced at CURRENT_SCHEMA
## with a layers array.
func _test_missing_version_is_v0() -> void:
	var r := MapMigrator.migrate({})
	_i_eq(int(r[MapSchema.KEY_SCHEMA_VERSION]), MapSchema.CURRENT_SCHEMA, "missing version -> CURRENT_SCHEMA")
	_ok(typeof(r[MapSchema.KEY_LAYERS]) == TYPE_ARRAY, "missing version gains layers Array")

## v0 legacy top-level cells get wrapped into one terrain layer; the old top-level
## cells key is removed.
func _test_v0_wraps_legacy_cells() -> void:
	var cell := {MapSchema.KEY_CELL_POS: [1, 2], MapSchema.KEY_CELL_ATLAS: [3, 4]}
	var r := MapMigrator.migrate({MapSchema.KEY_SCHEMA_VERSION: 0, MapSchema.KEY_CELLS: [cell]})
	var layers: Array = r[MapSchema.KEY_LAYERS]
	_i_eq(layers.size(), 1, "v0 wrap -> one layer")
	_ok(layers[0][MapSchema.KEY_LAYER_NAME] == "terrain", "v0 wrap layer name terrain")
	_i_eq(int(layers[0][MapSchema.KEY_LAYER_ELEVATION]), 0, "v0 wrap layer elevation 0")
	_i_eq((layers[0][MapSchema.KEY_CELLS] as Array).size(), 1, "v0 wrap keeps the cell")
	_ok(not r.has(MapSchema.KEY_CELLS), "v0 wrap drops top-level cells key")

## v1 cells with dict-encoded coords flatten to [x, y]; the layer gains elevation 0.
func _test_v1_coord_flatten() -> void:
	var cell := {
		MapSchema.KEY_CELL_POS: {"x": 1, "y": 2},
		MapSchema.KEY_CELL_ATLAS: {"x": 3, "y": 4},
	}
	var layer := {MapSchema.KEY_LAYER_NAME: "t", MapSchema.KEY_CELLS: [cell]}
	var r := MapMigrator.migrate({MapSchema.KEY_SCHEMA_VERSION: 1, MapSchema.KEY_LAYERS: [layer]})
	var out_cell: Dictionary = r[MapSchema.KEY_LAYERS][0][MapSchema.KEY_CELLS][0]
	_ok(_arr_eq(out_cell[MapSchema.KEY_CELL_POS], [1, 2]), "v1 flatten pos -> [1,2]")
	_ok(_arr_eq(out_cell[MapSchema.KEY_CELL_ATLAS], [3, 4]), "v1 flatten atlas -> [3,4]")
	_i_eq(int(r[MapSchema.KEY_LAYERS][0][MapSchema.KEY_LAYER_ELEVATION]), 0, "v1 layer gains elevation 0")

## An already-flat v1 coord array passes through unchanged.
func _test_already_flat_stays_flat() -> void:
	var cell := {MapSchema.KEY_CELL_POS: [5, 6], MapSchema.KEY_CELL_ATLAS: [7, 8]}
	var layer := {MapSchema.KEY_LAYER_NAME: "t", MapSchema.KEY_CELLS: [cell]}
	var r := MapMigrator.migrate({MapSchema.KEY_SCHEMA_VERSION: 1, MapSchema.KEY_LAYERS: [layer]})
	var out_cell: Dictionary = r[MapSchema.KEY_LAYERS][0][MapSchema.KEY_CELLS][0]
	_ok(_arr_eq(out_cell[MapSchema.KEY_CELL_POS], [5, 6]), "already-flat pos stays [5,6]")

## Migrating an already-current document is a no-op: a second pass equals the first.
func _test_idempotent_on_current() -> void:
	var cell := {MapSchema.KEY_CELL_POS: {"x": 1, "y": 2}, MapSchema.KEY_CELL_ATLAS: {"x": 3, "y": 4}}
	var once := MapMigrator.migrate({MapSchema.KEY_SCHEMA_VERSION: 0, MapSchema.KEY_CELLS: [cell]})
	var twice := MapMigrator.migrate(once)
	_i_eq(int(twice[MapSchema.KEY_SCHEMA_VERSION]), int(once[MapSchema.KEY_SCHEMA_VERSION]), "idempotent version stable")
	_ok(_dict_eq(once, twice), "idempotent doc unchanged on re-migrate")

## An already-v2 document keeps its version, layer name, and elevation.
func _test_already_v2_passthrough() -> void:
	var layer := {MapSchema.KEY_LAYER_NAME: "g", MapSchema.KEY_LAYER_ELEVATION: 1, MapSchema.KEY_CELLS: []}
	var r := MapMigrator.migrate({MapSchema.KEY_SCHEMA_VERSION: 2, MapSchema.KEY_LAYERS: [layer]})
	_i_eq(int(r[MapSchema.KEY_SCHEMA_VERSION]), 2, "v2 version stays 2")
	_ok(r[MapSchema.KEY_LAYERS][0][MapSchema.KEY_LAYER_NAME] == "g", "v2 layer name preserved")
	_i_eq(int(r[MapSchema.KEY_LAYERS][0][MapSchema.KEY_LAYER_ELEVATION]), 1, "v2 layer elevation preserved")

## Every input version 0/1/2 produces exactly CURRENT_SCHEMA (never less than input).
func _test_monotonic() -> void:
	for v in [0, 1, 2]:
		var layer := {MapSchema.KEY_LAYER_NAME: "t", MapSchema.KEY_CELLS: []}
		var r := MapMigrator.migrate({MapSchema.KEY_SCHEMA_VERSION: v, MapSchema.KEY_LAYERS: [layer]})
		_i_eq(int(r[MapSchema.KEY_SCHEMA_VERSION]), MapSchema.CURRENT_SCHEMA, "monotonic v%d -> CURRENT_SCHEMA" % v)

## A FUTURE version (> CURRENT_SCHEMA) is returned untouched with its version
## preserved -- NOT silently downgraded to CURRENT_SCHEMA -- so the loader can
## refuse it rather than mis-parsing a newer shape. (#39)
func _test_future_version_preserved() -> void:
	var future := MapSchema.CURRENT_SCHEMA + 1
	# Use a v1-style dict coord that the v1->v2 step WOULD flatten, to prove no
	# transform ran: it must survive unchanged.
	var layer := {MapSchema.KEY_LAYER_NAME: "future", MapSchema.KEY_CELLS: [
		{MapSchema.KEY_CELL_POS: {"x": 7, "y": 9}},
	]}
	var r := MapMigrator.migrate({MapSchema.KEY_SCHEMA_VERSION: future, MapSchema.KEY_LAYERS: [layer]})
	_i_eq(int(r[MapSchema.KEY_SCHEMA_VERSION]), future, "future version preserved (not downgraded)")
	var pos: Variant = r[MapSchema.KEY_LAYERS][0][MapSchema.KEY_CELLS][0][MapSchema.KEY_CELL_POS]
	_ok(typeof(pos) == TYPE_DICTIONARY, "future doc left untransformed (dict coord not flattened)")

## An unrelated extra root key survives the migration.
func _test_preserves_existing_keys() -> void:
	var layer := {MapSchema.KEY_LAYER_NAME: "t", MapSchema.KEY_CELLS: []}
	var r := MapMigrator.migrate({
		MapSchema.KEY_SCHEMA_VERSION: 1,
		MapSchema.KEY_LAYERS: [layer],
		"generated_by": "x",
	})
	_ok(r.has("generated_by"), "extra root key preserved")
	_ok(r["generated_by"] == "x", "extra root key value preserved")

## The caller's document is deep-copied: migrating a v0 doc never adds layers to it.
func _test_non_mutation() -> void:
	var doc := {MapSchema.KEY_SCHEMA_VERSION: 0, MapSchema.KEY_CELLS: []}
	var _r := MapMigrator.migrate(doc)
	_ok(not doc.has(MapSchema.KEY_LAYERS), "input doc not mutated (no layers added)")
	_ok(doc.has(MapSchema.KEY_CELLS), "input doc still has original cells key")
