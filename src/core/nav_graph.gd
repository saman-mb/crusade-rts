class_name NavGraph
extends RefCounted
## Top-level navigation facade for a multi-tier (multi-elevation) map. Unifies one
## NavTierGrid per elevation tier with a NavPortalGraph whose nodes are ramp
## endpoints -- the ONLY cross-tier connections (cliffs are hard walls). Callers
## ask for a route with find_path() and get back ordered { cell, tier } waypoints
## that walk flat ground within a tier and hop tiers ONLY over ramps.
##
## This unit owns the STITCHING: it picks the best (entry endpoint -> portal path
## -> exit endpoint) pair, then splices the intra-tier grid segments and the ramp
## hops into one continuous waypoint list. It composes the peer classes only via
## their public interfaces and never reaches into their internals.
##
## Headless & pure: NavTierGrid/NavPortalGraph wrap RefCounted AStar objects and
## the walkability rules are plain Callables, so the whole graph is testable with
## no live TileMapLayer and no servers.

var region: Rect2i    ## Read-only copy of the ctor region (cell bounds, shared by all tiers).
var tier_count: int   ## Number of elevation tiers; valid tier indices are [0, tier_count).

var _grids: Array = []            ## Array[NavTierGrid] indexed by tier.
var _portals: NavPortalGraph      ## Ramp-endpoint portal graph over _grids.
var _ramps: Array = []            ## Array[NavRamp] kept for rebuild_tier.

## Builds one NavTierGrid per tier from `walkable_queries` (an Array of
## Callable(Vector2i)->bool, one per tier), then builds the portal graph from
## those grids and `ramps` (an Array of NavRamp). All grids are query-ready and
## the portal graph is wired the moment _init returns.
func _init(p_tier_count: int, p_region: Rect2i, walkable_queries: Array, ramps: Array) -> void:
	tier_count = p_tier_count
	region = p_region
	_ramps = ramps
	_grids = []
	for t in range(tier_count):
		var q: Callable = walkable_queries[t]
		_grids.append(NavTierGrid.new(region, q))
	_portals = NavPortalGraph.new(region, _grids, _ramps)

## The NavTierGrid for `tier`, or null when `tier` is out of range.
func tier_grid(tier: int) -> NavTierGrid:
	if tier < 0 or tier >= _grids.size():
		return null
	return _grids[tier]

## Ordered waypoints from (from_cell, from_tier) to (to_cell, to_tier) as an Array
## of { "cell": Vector2i, "tier": int }. Returns [] when there is no route.
##
## Strategy: guard endpoints; try a direct same-tier grid path; otherwise (or when
## a same-tier goal is only reachable by a ramp detour) route through the portal
## graph and stitch the segments together.
func find_path(from_cell: Vector2i, from_tier: int, to_cell: Vector2i, to_tier: int) -> Array:
	# 1. Guard: tiers in range and both endpoints stand on walkable ground.
	if from_tier < 0 or from_tier >= tier_count:
		return []
	if to_tier < 0 or to_tier >= tier_count:
		return []
	var from_grid: NavTierGrid = _grids[from_tier]
	var to_grid: NavTierGrid = _grids[to_tier]
	if not from_grid.is_walkable(from_cell):
		return []
	if not to_grid.is_walkable(to_cell):
		return []

	# 2. Same tier: a direct grid path wins. If none, FALL THROUGH to portals --
	#    a split tier can still be reconnected by an up-and-over ramp detour.
	if from_tier == to_tier:
		var direct: Array[Vector2i] = from_grid.path_within(from_cell, to_cell)
		if not direct.is_empty():
			return _map_cells(direct, from_tier)

	# 3. Cross-tier (or split same-tier) via the ramp portal graph.
	return _route_via_portals(from_cell, from_tier, to_cell, to_tier)

## Rebuilds tier `tier` from a fresh walkability Callable, then refreshes ONLY
## that tier's portal edges (#59) -- cross-tier ramp edges and other tiers'
## intra-tier edges are structural w.r.t. this grid and stay untouched, so an
## in-editor terrain edit re-solves just the tier that changed instead of the
## whole NavPortalGraph.
func rebuild_tier(tier: int, walkable: Callable) -> void:
	if tier < 0 or tier >= _grids.size():
		return
	_grids[tier] = NavTierGrid.new(region, walkable)
	_portals.refresh_tier_edges(tier, _grids)

# --- private stitching helpers ---

## Finds the minimum-cost (entry endpoint, exit endpoint) pair whose portal path
## connects them, then stitches it into waypoints. [] when no pair routes.
func _route_via_portals(from_cell: Vector2i, from_tier: int, to_cell: Vector2i, to_tier: int) -> Array:
	var from_grid: NavTierGrid = _grids[from_tier]
	var to_grid: NavTierGrid = _grids[to_tier]
	var graph: AStar2D = _portals.astar()

	# Entry endpoints: on from_tier and reachable from from_cell within that tier.
	var entries: Array[int] = []
	for eid: int in _portals.endpoints_on_tier(from_tier):
		var einfo: Dictionary = _portals.endpoint_info(eid)
		var ecell: Vector2i = einfo["cell"]
		if from_grid.reachable(from_cell, ecell):
			entries.append(eid)

	# Exit endpoints: on to_tier and able to reach to_cell within that tier.
	var exits: Array[int] = []
	for xid: int in _portals.endpoints_on_tier(to_tier):
		var xinfo: Dictionary = _portals.endpoint_info(xid)
		var xcell: Vector2i = xinfo["cell"]
		if to_grid.reachable(xcell, to_cell):
			exits.append(xid)

	if entries.is_empty() or exits.is_empty():
		return []

	# Pick the cheapest connectable pair. Cost is the FAITHFUL traversal cost (#61):
	# entry/exit grid-segment lengths plus the true cost of the portal id-path
	# (intra-tier segment lengths between portals + each ramp hop's climb weight),
	# so selection prefers genuinely shorter routes rather than just fewer hops.
	var best_cost: float = -1.0
	var best_ids: PackedInt64Array = PackedInt64Array()
	for entry: int in entries:
		var entry_info: Dictionary = _portals.endpoint_info(entry)
		var entry_cell: Vector2i = entry_info["cell"]
		var seg_in: Array[Vector2i] = from_grid.path_within(from_cell, entry_cell)
		if seg_in.is_empty():
			continue
		for exit_id: int in exits:
			var ids: PackedInt64Array = graph.get_id_path(entry, exit_id)
			if ids.is_empty():
				continue
			var exit_info: Dictionary = _portals.endpoint_info(exit_id)
			var exit_cell: Vector2i = exit_info["cell"]
			var seg_out: Array[Vector2i] = to_grid.path_within(exit_cell, to_cell)
			if seg_out.is_empty():
				continue
			var cost: float = _seg_cost(seg_in) + _portal_path_cost(ids) + _seg_cost(seg_out)
			if best_cost < 0.0 or cost < best_cost:
				best_cost = cost
				best_ids = ids

	if best_ids.is_empty():
		return []
	return _stitch(from_cell, from_tier, best_ids, to_cell, to_tier)

## Traversal cost of an intra-tier grid segment: number of STEPS (edges), i.e.
## cells minus one, so a same-cell/empty segment costs 0.
func _seg_cost(seg: Array[Vector2i]) -> float:
	return float(maxi(seg.size() - 1, 0))

## True traversal cost of a portal id-path: sums the intra-tier grid-segment
## step counts between consecutive same-tier endpoints and each ramp hop's climb
## weight (the high endpoint's weight_scale, as applied by NavPortalGraph). This
## makes _route_via_portals compare pairs by real distance + climb effort, not a
## hop count that ignored the ground covered between portals. (#61)
func _portal_path_cost(ids: PackedInt64Array) -> float:
	var graph: AStar2D = _portals.astar()
	var total: float = 0.0
	for k in range(ids.size() - 1):
		var a_info: Dictionary = _portals.endpoint_info(ids[k])
		var b_info: Dictionary = _portals.endpoint_info(ids[k + 1])
		var a_tier: int = a_info["tier"]
		var b_tier: int = b_info["tier"]
		if a_tier == b_tier:
			var grid: NavTierGrid = _grids[a_tier]
			var seg: Array[Vector2i] = grid.path_within(a_info["cell"], b_info["cell"])
			total += _seg_cost(seg)
		else:
			# Ramp hop: charge the climb weight of the higher endpoint (>= 1 step).
			var high_id: int = ids[k] if a_tier > b_tier else ids[k + 1]
			total += maxf(graph.get_point_weight_scale(high_id), 1.0)
	return total

## Splices one chosen portal id-path into a continuous waypoint list:
##   from_cell -> [grid] -> entry endpoint,
##   then along the ids: same-tier neighbors get their grid segment stitched, a
##   tier CHANGE is a ramp hop (both endpoint cells appended at their tiers),
##   finally exit endpoint -> [grid] -> to_cell. Touching cells are de-duplicated.
## Returns [] if any required intra-tier segment is unexpectedly missing.
func _stitch(from_cell: Vector2i, from_tier: int, ids: PackedInt64Array, to_cell: Vector2i, to_tier: int) -> Array:
	var waypoints: Array = []

	var first_info: Dictionary = _portals.endpoint_info(ids[0])
	var first_cell: Vector2i = first_info["cell"]
	var from_grid: NavTierGrid = _grids[from_tier]
	var seg_in: Array[Vector2i] = from_grid.path_within(from_cell, first_cell)
	if seg_in.is_empty():
		return []
	_append_cells(waypoints, seg_in, from_tier)

	# Walk consecutive endpoint ids along the portal path.
	for k in range(ids.size() - 1):
		var a_info: Dictionary = _portals.endpoint_info(ids[k])
		var b_info: Dictionary = _portals.endpoint_info(ids[k + 1])
		var a_cell: Vector2i = a_info["cell"]
		var b_cell: Vector2i = b_info["cell"]
		var a_tier: int = a_info["tier"]
		var b_tier: int = b_info["tier"]
		if a_tier == b_tier:
			# Same tier: stitch the flat-ground segment between the two cells.
			var grid: NavTierGrid = _grids[a_tier]
			var seg: Array[Vector2i] = grid.path_within(a_cell, b_cell)
			if seg.is_empty():
				return []
			_append_cells(waypoints, seg, a_tier)
		else:
			# Tier change == ramp hop: both endpoint cells at their own tiers.
			_append_wp(waypoints, a_cell, a_tier)
			_append_wp(waypoints, b_cell, b_tier)

	var last_info: Dictionary = _portals.endpoint_info(ids[ids.size() - 1])
	var last_cell: Vector2i = last_info["cell"]
	var to_grid: NavTierGrid = _grids[to_tier]
	var seg_out: Array[Vector2i] = to_grid.path_within(last_cell, to_cell)
	if seg_out.is_empty():
		return []
	_append_cells(waypoints, seg_out, to_tier)

	return waypoints

## Maps a cell path on a single tier to { cell, tier } waypoints (no de-dup needed;
## a grid path has no back-to-back repeats).
func _map_cells(cells: Array[Vector2i], tier: int) -> Array:
	var out: Array = []
	for c: Vector2i in cells:
		out.append({ "cell": c, "tier": tier })
	return out

## Appends every cell of `cells` on `tier`, de-duplicating a touching endpoint.
func _append_cells(waypoints: Array, cells: Array[Vector2i], tier: int) -> void:
	for c: Vector2i in cells:
		_append_wp(waypoints, c, tier)

## Appends one { cell, tier } waypoint unless it exactly repeats the previous one.
func _append_wp(waypoints: Array, cell: Vector2i, tier: int) -> void:
	if not waypoints.is_empty():
		var last: Dictionary = waypoints[waypoints.size() - 1]
		var last_cell: Vector2i = last["cell"]
		var last_tier: int = last["tier"]
		if last_cell == cell and last_tier == tier:
			return
	waypoints.append({ "cell": cell, "tier": tier })
