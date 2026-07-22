extends SceneTree
## Pure-logic tests for NavRamp (no Node deps). Covers endpoint_id determinism &
## collision-freedom within a region, ctor field storage, and the pure-iso world
## position (IsoCoord.cart_to_iso + MapConstants.elevation_offset, y = -32*tier).
## Runner: godot --headless --script <this file>.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_endpoint_id_deterministic()
	_test_endpoint_id_no_collision()
	_test_ctor_stores_fields()
	_test_endpoint_world_pos()

	print("PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- helpers ---

func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % msg)

func _i_eq(a: int, b: int, msg: String) -> void:
	_ok(a == b, "%s: expected %d got %d" % [msg, b, a])

func _v_eq(a: Vector2i, b: Vector2i, msg: String) -> void:
	_ok(a == b, "%s: expected %s got %s" % [msg, b, a])

func _v2_eq(a: Vector2, b: Vector2, msg: String) -> void:
	_ok(a.is_equal_approx(b), "%s: expected %s got %s" % [msg, b, a])

# --- tests ---

## Same (cell, tier, region) inputs must always yield the same id.
func _test_endpoint_id_deterministic() -> void:
	var region := Rect2i(0, 0, 5, 5)
	var id_a: int = NavRamp.endpoint_id(Vector2i(2, 3), 1, region)
	var id_b: int = NavRamp.endpoint_id(Vector2i(2, 3), 1, region)
	_i_eq(id_a, id_b, "endpoint_id deterministic")

	# Explicit formula check: tier*area + row*w + col.
	var expected: int = 1 * (5 * 5) + 3 * 5 + 2
	_i_eq(id_a, expected, "endpoint_id matches tier-major row-major formula")

	# Region with a non-zero origin: offsets are relative to region.position.
	var region2 := Rect2i(10, 20, 5, 5)
	var id_off: int = NavRamp.endpoint_id(Vector2i(12, 23), 0, region2)
	_i_eq(id_off, 0 * 25 + 3 * 5 + 2, "endpoint_id offset-relative to region origin")

## No two distinct (cell, tier) inside a 5x5 region may collide.
func _test_endpoint_id_no_collision() -> void:
	var region := Rect2i(0, 0, 5, 5)
	var seen: Dictionary = {}
	var collision: bool = false
	for tier in range(3):
		for y in range(5):
			for x in range(5):
				var id: int = NavRamp.endpoint_id(Vector2i(x, y), tier, region)
				if seen.has(id):
					collision = true
				seen[id] = true
	_ok(not collision, "no id collision across 3 tiers x 25 cells")
	_i_eq(seen.size(), 3 * 25, "all 75 (cell,tier) ids distinct")

	# Cross-tier: same cell on different tiers must differ.
	var t0: int = NavRamp.endpoint_id(Vector2i(4, 4), 0, region)
	var t1: int = NavRamp.endpoint_id(Vector2i(4, 4), 1, region)
	_ok(t0 != t1, "same cell, different tier -> different id")

## Ctor stores all fields, including weight (and its default).
func _test_ctor_stores_fields() -> void:
	var r := NavRamp.new(Vector2i(1, 2), 0, Vector2i(1, 3), 1, 2.5)
	_v_eq(r.low_cell, Vector2i(1, 2), "ctor low_cell")
	_i_eq(r.low_tier, 0, "ctor low_tier")
	_v_eq(r.high_cell, Vector2i(1, 3), "ctor high_cell")
	_i_eq(r.high_tier, 1, "ctor high_tier")
	_ok(is_equal_approx(r.weight, 2.5), "ctor weight stored")

	var d := NavRamp.new(Vector2i(0, 0), 0, Vector2i(0, 1), 1)
	_ok(is_equal_approx(d.weight, 1.0), "ctor weight default 1.0")

## endpoint_world_pos == cart_to_iso(cell) + elevation_offset(tier); higher tier
## sits higher on screen (smaller y, since elevation_offset(tier).y = -32*tier).
func _test_endpoint_world_pos() -> void:
	var cell := Vector2i(3, 2)
	var expected0: Vector2 = IsoCoord.cart_to_iso(cell) + MapConstants.elevation_offset(0)
	_v2_eq(NavRamp.endpoint_world_pos(cell, 0), expected0, "world_pos tier 0")

	var expected2: Vector2 = IsoCoord.cart_to_iso(cell) + MapConstants.elevation_offset(2)
	_v2_eq(NavRamp.endpoint_world_pos(cell, 2), expected2, "world_pos tier 2")

	# Higher tier -> smaller y (higher on screen).
	var p_low: Vector2 = NavRamp.endpoint_world_pos(cell, 0)
	var p_high: Vector2 = NavRamp.endpoint_world_pos(cell, 3)
	_ok(p_high.y < p_low.y, "higher tier yields smaller y (higher on screen)")
	_ok(is_equal_approx(p_low.y - p_high.y, 32.0 * 3), "y drop is 32 per tier")
	# x is unchanged by elevation.
	_ok(is_equal_approx(p_low.x, p_high.x), "elevation leaves x unchanged")
