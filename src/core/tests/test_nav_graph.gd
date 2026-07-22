extends SceneTree
## Pure-logic tests for NavGraph -- the multi-tier nav facade (per-tier grids +
## ramp portal graph). Headless: AStar2D/AStarGrid2D are RefCounted, no servers.
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Guards the stitching contract: flat within a tier, hop tiers ONLY over ramps,
## [] when no route, and { cell, tier } waypoints that begin at from and end at to.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_same_tier_grid_path()
	_test_cross_tier_via_ramp()
	_test_no_ramp_no_cross()
	_test_ramp_is_only_bridge()
	_test_unreachable_within_tier()
	_test_tier_grid_matches_query()
	_test_rebuild_tier()
	_test_guards()

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

## Walkability Callable that treats any cell in `blocked` as a hole/cliff (false).
func _rule(blocked: Dictionary) -> Callable:
	return func(cell: Vector2i) -> bool:
		return not blocked.has(cell)

## Everything-walkable Callable.
func _open() -> Callable:
	return func(_cell: Vector2i) -> bool:
		return true

## True if `path` contains a { cell, tier } waypoint matching exactly.
func _wp_has(path: Array, cell: Vector2i, tier: int) -> bool:
	for wp: Dictionary in path:
		var c: Vector2i = wp["cell"]
		var t: int = wp["tier"]
		if c == cell and t == tier:
			return true
	return false

## True if any waypoint in `path` sits on `tier`.
func _has_tier(path: Array, tier: int) -> bool:
	for wp: Dictionary in path:
		var t: int = wp["tier"]
		if t == tier:
			return true
	return false

## True if EVERY waypoint in `path` sits on `tier`.
func _all_tier(path: Array, tier: int) -> bool:
	for wp: Dictionary in path:
		var t: int = wp["tier"]
		if t != tier:
			return false
	return true

## First waypoint's cell (assumes non-empty).
func _first_cell(path: Array) -> Vector2i:
	var wp: Dictionary = path[0]
	return wp["cell"]

## Last waypoint's cell (assumes non-empty).
func _last_cell(path: Array) -> Vector2i:
	var wp: Dictionary = path[path.size() - 1]
	return wp["cell"]

# --- tests ---

## 1: two cells on tier 0 in an all-walkable 2-tier map -> waypoints all tier 0,
## first == from, last == to.
func _test_same_tier_grid_path() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var nav := NavGraph.new(2, region, [_open(), _open()], [])
	var path: Array = nav.find_path(Vector2i(0, 0), 0, Vector2i(5, 5), 0)
	_ok(not path.is_empty(), "same-tier: path non-empty")
	_ok(_all_tier(path, 0), "same-tier: every waypoint on tier 0")
	_v_eq(_first_cell(path), Vector2i(0, 0), "same-tier: first cell == from")
	_v_eq(_last_cell(path), Vector2i(5, 5), "same-tier: last cell == to")

## 2: tier 0 and tier 1 both all-walkable but otherwise disconnected; ONE ramp
## links (2,2)@t0 to (3,2)@t1. Cross-tier path is non-empty, spans both tiers,
## and passes through BOTH ramp endpoint cells.
func _test_cross_tier_via_ramp() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var ramp := NavRamp.new(Vector2i(2, 2), 0, Vector2i(3, 2), 1)
	var nav := NavGraph.new(2, region, [_open(), _open()], [ramp])
	var path: Array = nav.find_path(Vector2i(0, 0), 0, Vector2i(5, 5), 1)
	_ok(not path.is_empty(), "cross-tier: path non-empty")
	_ok(_has_tier(path, 0), "cross-tier: path visits tier 0")
	_ok(_has_tier(path, 1), "cross-tier: path visits tier 1")
	_ok(_wp_has(path, Vector2i(2, 2), 0), "cross-tier: path contains ramp low endpoint (2,2)@t0")
	_ok(_wp_has(path, Vector2i(3, 2), 1), "cross-tier: path contains ramp high endpoint (3,2)@t1")
	_v_eq(_first_cell(path), Vector2i(0, 0), "cross-tier: first cell == from")
	_v_eq(_last_cell(path), Vector2i(5, 5), "cross-tier: last cell == to")

## 3: same open two-tier setup but NO ramps -> cross-tier find_path returns [].
func _test_no_ramp_no_cross() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var nav := NavGraph.new(2, region, [_open(), _open()], [])
	var path: Array = nav.find_path(Vector2i(0, 0), 0, Vector2i(5, 5), 1)
	_ok(path.is_empty(), "no ramp: cross-tier path is []")

## 4: the ramp is the ONLY bridge. Tier 1 is split by a full wall at x=3; the
## ramp's high endpoint sits on the LEFT half. A goal on the left half MUST route
## through the ramp (path contains both endpoint cells); a goal on the RIGHT half
## has no reachable exit endpoint -> [].
func _test_ramp_is_only_bridge() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var wall: Dictionary = {}
	for y in range(0, 6):
		wall[Vector2i(3, y)] = true  # full vertical wall on tier 1
	var ramp := NavRamp.new(Vector2i(1, 1), 0, Vector2i(1, 1), 1)  # high endpoint on left half
	var nav := NavGraph.new(2, region, [_open(), _rule(wall)], [ramp])

	# Left-half goal (0,5): must exist and pass through the sole ramp endpoints.
	var left_path: Array = nav.find_path(Vector2i(0, 0), 0, Vector2i(0, 5), 1)
	_ok(not left_path.is_empty(), "only-bridge: left-half goal reachable")
	_ok(_wp_has(left_path, Vector2i(1, 1), 0), "only-bridge: path uses ramp low (1,1)@t0")
	_ok(_wp_has(left_path, Vector2i(1, 1), 1), "only-bridge: path uses ramp high (1,1)@t1")

	# Right-half goal (5,5): unreachable from the left-side high endpoint -> [].
	var right_path: Array = nav.find_path(Vector2i(0, 0), 0, Vector2i(5, 5), 1)
	_ok(right_path.is_empty(), "only-bridge: right-half goal across wall is []")

## 5: a full wall splits tier 0 with NO ramp detour -> same-tier find_path is [].
func _test_unreachable_within_tier() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var wall: Dictionary = {}
	for y in range(0, 6):
		wall[Vector2i(3, y)] = true
	var nav := NavGraph.new(2, region, [_rule(wall), _open()], [])
	var path: Array = nav.find_path(Vector2i(0, 0), 0, Vector2i(5, 5), 0)
	_ok(path.is_empty(), "split tier, no ramp: same-tier path is []")
	# Sanity: same half is still connected.
	var same_half: Array = nav.find_path(Vector2i(0, 0), 0, Vector2i(2, 5), 0)
	_ok(not same_half.is_empty(), "split tier: within one half still reachable")

## 6: tier_grid(t).is_walkable matches the tier's query; out-of-range -> null.
func _test_tier_grid_matches_query() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var hole: Dictionary = { Vector2i(2, 2): true }
	var nav := NavGraph.new(2, region, [_rule(hole), _open()], [])
	var g0: NavTierGrid = nav.tier_grid(0)
	_ok(g0 != null, "tier_grid(0) non-null")
	_ok(g0.is_walkable(Vector2i(1, 1)) == true, "tier_grid(0): open cell walkable")
	_ok(g0.is_walkable(Vector2i(2, 2)) == false, "tier_grid(0): hole not walkable")
	var g1: NavTierGrid = nav.tier_grid(1)
	_ok(g1 != null and g1.is_walkable(Vector2i(2, 2)) == true, "tier_grid(1): same cell walkable (open tier)")
	_ok(nav.tier_grid(5) == null, "tier_grid out-of-range -> null")
	_ok(nav.tier_grid(-1) == null, "tier_grid negative -> null")

## 7: rebuild_tier swaps in a new walkability rule; a previously-open path breaks.
func _test_rebuild_tier() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var nav := NavGraph.new(2, region, [_open(), _open()], [])
	var before: Array = nav.find_path(Vector2i(0, 0), 0, Vector2i(5, 5), 0)
	_ok(not before.is_empty(), "rebuild: path open before")

	# Carve a full vertical wall into tier 0 via a fresh Callable.
	var wall: Dictionary = {}
	for y in range(0, 6):
		wall[Vector2i(3, y)] = true
	nav.rebuild_tier(0, _rule(wall))
	var after: Array = nav.find_path(Vector2i(0, 0), 0, Vector2i(5, 5), 0)
	_ok(after.is_empty(), "rebuild: path broken after carving wall")
	# The grid handed out reflects the rebuild too.
	var g0: NavTierGrid = nav.tier_grid(0)
	_ok(g0.is_walkable(Vector2i(3, 3)) == false, "rebuild: new wall cell not walkable")

## 8: out-of-range tiers and unwalkable endpoints all return [].
func _test_guards() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var hole: Dictionary = { Vector2i(0, 0): true }
	var nav := NavGraph.new(2, region, [_rule(hole), _open()], [])
	_ok(nav.find_path(Vector2i(1, 1), 5, Vector2i(2, 2), 0).is_empty(), "guard: from_tier out of range -> []")
	_ok(nav.find_path(Vector2i(1, 1), 0, Vector2i(2, 2), 9).is_empty(), "guard: to_tier out of range -> []")
	_ok(nav.find_path(Vector2i(1, 1), -1, Vector2i(2, 2), 0).is_empty(), "guard: negative from_tier -> []")
	_ok(nav.find_path(Vector2i(0, 0), 0, Vector2i(2, 2), 0).is_empty(), "guard: unwalkable from_cell (hole) -> []")
	_ok(nav.find_path(Vector2i(1, 1), 0, Vector2i(0, 0), 0).is_empty(), "guard: unwalkable to_cell (hole) -> []")
