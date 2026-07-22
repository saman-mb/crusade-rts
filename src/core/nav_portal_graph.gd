class_name NavPortalGraph
extends RefCounted
## Cross-tier portal graph over a multi-tier map. Nodes are ramp endpoints ONLY
## -- no arbitrary cell is a node. Cross-tier edges come ONLY from ramps (cliffs
## are hard walls; there is NO other way to change tier). Intra-tier edges link
## two endpoints on the same tier only when that tier's NavTierGrid says one is
## reachable from the other. Endpoint positions are PURE iso math (IsoCoord +
## MapConstants) with no live TileMapLayer -- the graph is headless and testable.

var region: Rect2i  ## Read-only copy of the ctor region (used for endpoint ids).

var _astar: AStar2D                ## The one built graph; ids from NavRamp.endpoint_id.
var _info: Dictionary = {}         ## id -> { "cell": Vector2i, "tier": int }.

## Builds the graph. `tier_grids` is an Array of NavTierGrid indexed by tier;
## `ramps` is an Array of NavRamp. Adds each ramp's two endpoints, wires the
## cross-tier ramp edge (scaling the HIGH endpoint's weight to make climbing
## cost `weight`x so units prefer flat ground), then wires every same-tier
## endpoint pair the tier grid reports as mutually reachable.
func _init(p_region: Rect2i, tier_grids: Array, ramps: Array) -> void:
	region = p_region
	_astar = AStar2D.new()

	# 1. Ramp endpoints + the ONLY cross-tier edges.
	for ramp: NavRamp in ramps:
		var low_id: int = NavRamp.endpoint_id(ramp.low_cell, ramp.low_tier, region)
		if not _astar.has_point(low_id):
			_astar.add_point(low_id, NavRamp.endpoint_world_pos(ramp.low_cell, ramp.low_tier))
			_info[low_id] = { "cell": ramp.low_cell, "tier": ramp.low_tier }
		var high_id: int = NavRamp.endpoint_id(ramp.high_cell, ramp.high_tier, region)
		var added_high: bool = false
		if not _astar.has_point(high_id):
			_astar.add_point(high_id, NavRamp.endpoint_world_pos(ramp.high_cell, ramp.high_tier))
			_info[high_id] = { "cell": ramp.high_cell, "tier": ramp.high_tier }
			added_high = true
		_astar.connect_points(low_id, high_id, true)
		# Climb cost: prefer flat ground. Only set on freshly added, valid weight.
		if added_high and ramp.weight >= 0.0:
			_astar.set_point_weight_scale(high_id, ramp.weight)

	# 2. Intra-tier edges: every unordered same-tier pair the grid can route.
	var ids: Array = _info.keys()
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			var a: int = ids[i]
			var b: int = ids[j]
			var ta: int = _info[a]["tier"]
			var tb: int = _info[b]["tier"]
			if ta != tb:
				continue
			if ta < 0 or ta >= tier_grids.size():
				continue
			var grid: NavTierGrid = tier_grids[ta]
			var ca: Vector2i = _info[a]["cell"]
			var cb: Vector2i = _info[b]["cell"]
			if grid.reachable(ca, cb):
				_astar.connect_points(a, b, true)

## True iff a ramp endpoint exists at (cell, tier).
func has_endpoint(cell: Vector2i, tier: int) -> bool:
	return _astar.has_point(NavRamp.endpoint_id(cell, tier, region))

## AStar2D point ids of every endpoint present on `tier`.
func endpoints_on_tier(tier: int) -> Array[int]:
	var out: Array[int] = []
	for id: int in _info.keys():
		if _info[id]["tier"] == tier:
			out.append(id)
	return out

## { "cell": Vector2i, "tier": int } for `id`, or {} if no such endpoint.
func endpoint_info(id: int) -> Dictionary:
	return _info.get(id, {})

## The built AStar2D, for id-path / connectivity queries.
func astar() -> AStar2D:
	return _astar
