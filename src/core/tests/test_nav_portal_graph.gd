extends SceneTree
## Integration tests for NavPortalGraph over real NavTierGrids. Verifies: ramp
## endpoints become AStar2D points; ramps are the ONLY cross-tier edges (with the
## climb weight applied to the high endpoint); same-tier endpoints connect only
## when the tier grid reports reachability; endpoint_info / endpoints_on_tier /
## portal positions are correct. Runner: godot --headless --script <this file>.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_portal_graph()
	_test_split_tier_non_reachable()
	_test_shared_high_endpoint_weight()

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

## Walkable Callable: every cell is walkable, so intra-tier reachable is always true.
func _all_walkable(_cell: Vector2i) -> bool:
	return true

## Walkability Callable rejecting a full vertical wall at x==3 (splits a 6-wide
## tier into disjoint left/right halves).
func _wall_at_x3(cell: Vector2i) -> bool:
	return cell.x != 3

# --- tests ---

func _test_portal_graph() -> void:
	var region := Rect2i(0, 0, 5, 5)
	var walk := Callable(self, "_all_walkable")
	var grid0 := NavTierGrid.new(region, walk)
	var grid1 := NavTierGrid.new(region, walk)
	var tier_grids: Array = [grid0, grid1]

	# Two ramps: each links a tier-0 cell up to a tier-1 cell.
	var ramp_a := NavRamp.new(Vector2i(0, 0), 0, Vector2i(0, 1), 1, 2.0)
	var ramp_b := NavRamp.new(Vector2i(4, 4), 0, Vector2i(4, 3), 1, 1.5)
	var ramps: Array = [ramp_a, ramp_b]

	var graph := NavPortalGraph.new(region, tier_grids, ramps)
	var a: AStar2D = graph.astar()

	# Precompute endpoint ids (tier-major, row-major over 5x5 -> area 25).
	var id_a_low: int = NavRamp.endpoint_id(Vector2i(0, 0), 0, region)   # 0
	var id_a_high: int = NavRamp.endpoint_id(Vector2i(0, 1), 1, region)  # 30
	var id_b_low: int = NavRamp.endpoint_id(Vector2i(4, 4), 0, region)   # 24
	var id_b_high: int = NavRamp.endpoint_id(Vector2i(4, 3), 1, region)  # 44

	# Every ramp endpoint is present, via both has_endpoint and astar().has_point.
	_ok(graph.has_endpoint(Vector2i(0, 0), 0), "has_endpoint a.low")
	_ok(graph.has_endpoint(Vector2i(0, 1), 1), "has_endpoint a.high")
	_ok(graph.has_endpoint(Vector2i(4, 4), 0), "has_endpoint b.low")
	_ok(graph.has_endpoint(Vector2i(4, 3), 1), "has_endpoint b.high")
	_ok(a.has_point(id_a_low), "astar has a.low")
	_ok(a.has_point(id_a_high), "astar has a.high")
	_ok(a.has_point(id_b_low), "astar has b.low")
	_ok(a.has_point(id_b_high), "astar has b.high")

	# A non-endpoint cell is absent.
	_ok(not graph.has_endpoint(Vector2i(2, 2), 0), "non-endpoint cell absent")

	# Cross-tier ramp edge produces a non-empty id-path low -> high.
	var ids: PackedInt64Array = a.get_id_path(id_a_low, id_a_high)
	_ok(ids.size() > 0, "cross-tier ramp path a.low -> a.high non-empty")

	# endpoint_info returns the right cell/tier; absent id -> {}.
	var info_low: Dictionary = graph.endpoint_info(id_a_low)
	var low_cell: Vector2i = info_low["cell"]
	var low_tier: int = info_low["tier"]
	_v_eq(low_cell, Vector2i(0, 0), "endpoint_info a.low cell")
	_i_eq(low_tier, 0, "endpoint_info a.low tier")
	var info_high: Dictionary = graph.endpoint_info(id_b_high)
	var high_cell: Vector2i = info_high["cell"]
	var high_tier: int = info_high["tier"]
	_v_eq(high_cell, Vector2i(4, 3), "endpoint_info b.high cell")
	_i_eq(high_tier, 1, "endpoint_info b.high tier")
	_ok(graph.endpoint_info(999999).is_empty(), "endpoint_info absent -> {}")

	# endpoints_on_tier returns exactly the ids on each tier (order-insensitive).
	var on0: Array[int] = graph.endpoints_on_tier(0)
	_i_eq(on0.size(), 2, "two endpoints on tier 0")
	_ok(on0.has(id_a_low) and on0.has(id_b_low), "tier 0 ids are the two lows")
	var on1: Array[int] = graph.endpoints_on_tier(1)
	_i_eq(on1.size(), 2, "two endpoints on tier 1")
	_ok(on1.has(id_a_high) and on1.has(id_b_high), "tier 1 ids are the two highs")
	_i_eq(graph.endpoints_on_tier(2).size(), 0, "no endpoints on empty tier 2")

	# Same-tier endpoints ARE connected (grid says reachable).
	_ok(a.are_points_connected(id_a_low, id_b_low), "tier-0 lows connected (reachable)")
	_ok(a.are_points_connected(id_a_high, id_b_high), "tier-1 highs connected (reachable)")

	# Cross-tier connections exist ONLY along the ramp pairs.
	_ok(a.are_points_connected(id_a_low, id_a_high), "ramp a connects its pair")
	_ok(a.are_points_connected(id_b_low, id_b_high), "ramp b connects its pair")
	_ok(not a.are_points_connected(id_a_low, id_b_high), "no cross-tier edge outside ramp a/b pair")
	_ok(not a.are_points_connected(id_b_low, id_a_high), "no cross-tier edge outside ramp b/a pair")

	# Climb weight applied to the HIGH endpoint (units prefer flat ground).
	_ok(is_equal_approx(a.get_point_weight_scale(id_a_high), 2.0), "ramp a high endpoint weight 2.0")
	_ok(is_equal_approx(a.get_point_weight_scale(id_b_high), 1.5), "ramp b high endpoint weight 1.5")

	# Portal position is pure iso math (matches NavRamp.endpoint_world_pos).
	var pos: Vector2 = a.get_point_position(id_a_high)
	_v2_eq(pos, NavRamp.endpoint_world_pos(Vector2i(0, 1), 1), "portal pos == endpoint_world_pos")

## Split-tier NEGATIVE coverage (#62): two endpoints on the SAME tier separated by
## a wall are NOT connected -- the "connect only when reachable" branch's false
## side (the earlier test only exercised the reachable=true side). tier 0 is split
## at x==3; ramp A's low is on the left, ramp B's low is on the right, so the two
## tier-0 lows must NOT be joined, while the open tier-1 highs still are.
func _test_split_tier_non_reachable() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var split := Callable(self, "_wall_at_x3")
	var open := Callable(self, "_all_walkable")
	var grid0 := NavTierGrid.new(region, split)   # tier 0 split by the wall
	var grid1 := NavTierGrid.new(region, open)    # tier 1 fully open
	var tier_grids: Array = [grid0, grid1]

	var ramp_l := NavRamp.new(Vector2i(1, 0), 0, Vector2i(1, 1), 1)  # low on LEFT half
	var ramp_r := NavRamp.new(Vector2i(5, 0), 0, Vector2i(5, 1), 1)  # low on RIGHT half
	var graph := NavPortalGraph.new(region, tier_grids, [ramp_l, ramp_r])
	var a: AStar2D = graph.astar()

	var id_l_low: int = NavRamp.endpoint_id(Vector2i(1, 0), 0, region)
	var id_r_low: int = NavRamp.endpoint_id(Vector2i(5, 0), 0, region)
	var id_l_high: int = NavRamp.endpoint_id(Vector2i(1, 1), 1, region)
	var id_r_high: int = NavRamp.endpoint_id(Vector2i(5, 1), 1, region)

	_ok(not a.are_points_connected(id_l_low, id_r_low),
		"split tier: tier-0 lows across the wall are NOT connected")
	_ok(a.are_points_connected(id_l_high, id_r_high),
		"split tier: tier-1 highs (open) remain connected")
	# Each ramp still bridges its own pair.
	_ok(a.are_points_connected(id_l_low, id_l_high), "split tier: left ramp still bridges")
	_ok(a.are_points_connected(id_r_low, id_r_high), "split tier: right ramp still bridges")

## Shared-high-endpoint climb weight (#60): two ramps whose HIGH endpoint is the
## same (cell, tier) but with different weights -> the endpoint takes the MAX
## weight (steepest wins), never silently first-ramp-wins.
func _test_shared_high_endpoint_weight() -> void:
	var region := Rect2i(0, 0, 6, 6)
	var open := Callable(self, "_all_walkable")
	var tier_grids: Array = [NavTierGrid.new(region, open), NavTierGrid.new(region, open)]

	# Both ramps climb to the SAME high cell (2,1)@t1 from different lows.
	var gentle := NavRamp.new(Vector2i(1, 0), 0, Vector2i(2, 1), 1, 1.5)
	var steep := NavRamp.new(Vector2i(3, 0), 0, Vector2i(2, 1), 1, 4.0)
	var graph := NavPortalGraph.new(region, tier_grids, [gentle, steep])
	var a: AStar2D = graph.astar()

	var id_high: int = NavRamp.endpoint_id(Vector2i(2, 1), 1, region)
	_ok(is_equal_approx(a.get_point_weight_scale(id_high), 4.0),
		"shared high endpoint takes MAX climb weight (4.0), not first-ramp 1.5")
	# Order independence: the max holds regardless of ramp order.
	var graph2 := NavPortalGraph.new(region, tier_grids, [steep, gentle])
	_ok(is_equal_approx(graph2.astar().get_point_weight_scale(id_high), 4.0),
		"shared high endpoint MAX weight is order-independent")
