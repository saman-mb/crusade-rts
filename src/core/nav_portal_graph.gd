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
	# INVARIANT (#60): a high endpoint shared by several ramps takes the MAX of
	# their climb weights -- a shared top costs as much as its steepest ramp, so
	# a cheap ramp can never silently under-price a point another ramp climbs
	# steeply. Weights are accumulated here and applied once after the loop.
	var high_weights: Dictionary = {}   # high_id -> float (max climb weight seen)
	for ramp: NavRamp in ramps:
		var low_id: int = NavRamp.endpoint_id(ramp.low_cell, ramp.low_tier, region)
		if not _astar.has_point(low_id):
			_astar.add_point(low_id, NavRamp.endpoint_world_pos(ramp.low_cell, ramp.low_tier))
			_info[low_id] = { "cell": ramp.low_cell, "tier": ramp.low_tier }
		var high_id: int = NavRamp.endpoint_id(ramp.high_cell, ramp.high_tier, region)
		if not _astar.has_point(high_id):
			_astar.add_point(high_id, NavRamp.endpoint_world_pos(ramp.high_cell, ramp.high_tier))
			_info[high_id] = { "cell": ramp.high_cell, "tier": ramp.high_tier }
		_astar.connect_points(low_id, high_id, true)
		# Climb cost: prefer flat ground. Track the max across ramps sharing a high.
		if ramp.weight >= 0.0:
			if not high_weights.has(high_id) or ramp.weight > high_weights[high_id]:
				high_weights[high_id] = ramp.weight
	for hid: int in high_weights:
		_astar.set_point_weight_scale(hid, high_weights[hid])

	# 2. Intra-tier edges: every unordered same-tier pair the grid can route.
	for t in range(tier_grids.size()):
		_wire_tier_edges(t, tier_grids)

## Wires (or re-wires) tier `t`'s intra-tier edges: connects every unordered pair
## of endpoints on `t` that the tier grid reports mutually reachable.
##
## Reachability within a tier is an equivalence relation (the grid is undirected),
## so endpoints partition into reachable components and each component is a clique.
## We exploit that with union-find (#63): a pair already in the same component is
## known-reachable and is connected WITHOUT another A* query; only cross-component
## pairs pay for a reachable() call, and a successful one merges the components.
## Net: at most one A* per edge that grows a component, instead of one per pair.
## Semantics are unchanged -- every mutually-reachable pair still gets its edge.
func _wire_tier_edges(t: int, tier_grids: Array) -> void:
	if t < 0 or t >= tier_grids.size():
		return
	var grid: NavTierGrid = tier_grids[t]
	var ids: Array[int] = endpoints_on_tier(t)
	var parent: Dictionary = {}
	for id: int in ids:
		parent[id] = id
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			var a: int = ids[i]
			var b: int = ids[j]
			var connected: bool = _find(parent, a) == _find(parent, b)
			if not connected:
				connected = grid.reachable(_info[a]["cell"], _info[b]["cell"])
				if connected:
					parent[_find(parent, a)] = _find(parent, b)
			if connected:
				_astar.connect_points(a, b, true)

## Union-find root of `x` with path compression (see _wire_tier_edges).
func _find(parent: Dictionary, x: int) -> int:
	var root: int = x
	while parent[root] != root:
		root = parent[root]
	while parent[x] != root:
		var nxt: int = parent[x]
		parent[x] = root
		x = nxt
	return root

## Re-derives ONLY tier `t`'s intra-tier edges from the (rebuilt) tier grid,
## leaving cross-tier ramp edges and every other tier's edges untouched (#59).
## Cross-tier ramp edges are structural -- they exist independent of any grid --
## so a terrain edit on one tier can only change that tier's intra-tier
## connectivity. Two endpoints both on `t` can only be joined by an intra-tier
## edge, so dropping all connected same-tier pairs before re-wiring is safe.
func refresh_tier_edges(t: int, tier_grids: Array) -> void:
	var ids: Array[int] = endpoints_on_tier(t)
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			if _astar.are_points_connected(ids[i], ids[j]):
				_astar.disconnect_points(ids[i], ids[j])
	_wire_tier_edges(t, tier_grids)

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
