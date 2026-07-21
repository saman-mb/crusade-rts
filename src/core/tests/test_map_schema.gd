extends SceneTree
## Pure-logic tests for MapSchema (the map-file schema contract constants).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Guards the invariants downstream tooling relies on: version/limit values,
## tile-size derivation from MapConstants, and non-empty DISTINCT key names.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_version_and_limits()
	_test_tile_size_derives()
	_test_keys_non_empty()
	_test_keys_distinct()
	_test_required_root_keys()
	_test_tile_shape_name()

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

## String inequality (distinctness) check with message.
func _s_neq(a: String, b: String, msg: String) -> void:
	_ok(a != b, "%s: both equal %s" % [msg, a])

# --- tests ---

## Version and limit constants hold their contract values.
func _test_version_and_limits() -> void:
	_i_eq(MapSchema.CURRENT_SCHEMA, 2, "CURRENT_SCHEMA is 2")
	_i_eq(MapSchema.MAX_COORD, 4096, "MAX_COORD is 4096")

## Tile size is derived from MapConstants, never hardcoded -- proves no drift.
func _test_tile_size_derives() -> void:
	_v_eq(MapSchema.expected_tile_size(), MapConstants.TILE_SIZE, "tile size derives from MapConstants")

## Every serialized key name (and the tile shape name) is a non-empty String.
func _test_keys_non_empty() -> void:
	_ok(MapSchema.KEY_SCHEMA_VERSION.length() > 0, "KEY_SCHEMA_VERSION non-empty")
	_ok(MapSchema.KEY_LAYERS.length() > 0, "KEY_LAYERS non-empty")
	_ok(MapSchema.KEY_LAYER_NAME.length() > 0, "KEY_LAYER_NAME non-empty")
	_ok(MapSchema.KEY_LAYER_ELEVATION.length() > 0, "KEY_LAYER_ELEVATION non-empty")
	_ok(MapSchema.KEY_CELLS.length() > 0, "KEY_CELLS non-empty")
	_ok(MapSchema.KEY_CELL_POS.length() > 0, "KEY_CELL_POS non-empty")
	_ok(MapSchema.KEY_CELL_SOURCE.length() > 0, "KEY_CELL_SOURCE non-empty")
	_ok(MapSchema.KEY_CELL_ATLAS.length() > 0, "KEY_CELL_ATLAS non-empty")
	_ok(MapSchema.TILE_SHAPE_NAME.length() > 0, "TILE_SHAPE_NAME non-empty")

## No two key constants collide -- a duplicate would silently corrupt
## serialization by overwriting a sibling field.
func _test_keys_distinct() -> void:
	var keys: Array[String] = [
		MapSchema.KEY_SCHEMA_VERSION,
		MapSchema.KEY_LAYERS,
		MapSchema.KEY_LAYER_NAME,
		MapSchema.KEY_LAYER_ELEVATION,
		MapSchema.KEY_CELLS,
		MapSchema.KEY_CELL_POS,
		MapSchema.KEY_CELL_SOURCE,
		MapSchema.KEY_CELL_ATLAS,
	]

	# Pairwise distinctness for precise failure messages.
	for i in range(keys.size()):
		for j in range(i + 1, keys.size()):
			_s_neq(keys[i], keys[j], "keys[%d] vs keys[%d] distinct" % [i, j])

	# Dedupe via Dictionary; deduped count must equal the total count.
	var seen: Dictionary = {}
	for k in keys:
		seen[k] = true
	_i_eq(seen.size(), keys.size(), "all key names distinct (deduped count == total)")

## REQUIRED_ROOT_KEYS is exactly {schema_version, layers}.
func _test_required_root_keys() -> void:
	_i_eq(MapSchema.REQUIRED_ROOT_KEYS.size(), 2, "REQUIRED_ROOT_KEYS size 2")
	_ok(MapSchema.REQUIRED_ROOT_KEYS.has(MapSchema.KEY_SCHEMA_VERSION), "REQUIRED_ROOT_KEYS has schema_version")
	_ok(MapSchema.REQUIRED_ROOT_KEYS.has(MapSchema.KEY_LAYERS), "REQUIRED_ROOT_KEYS has layers")

## Tile shape metadata name is the documented isometric literal.
func _test_tile_shape_name() -> void:
	_ok(MapSchema.TILE_SHAPE_NAME == "isometric", "TILE_SHAPE_NAME is isometric")
