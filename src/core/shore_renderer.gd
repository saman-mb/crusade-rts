class_name ShoreRenderer
extends RefCounted
## Shoreline transition bands (SC1 convergence item 5): for every water cell edge
## that borders grass, lays a three-band strip -- wet grass, mud, waterline
## highlight -- straddling the boundary, burying the raw tile "staircase" the
## grass<->water adjacency otherwise shows. Runtime Polygon2D quads with vertex
## alpha fades (per-cell quads share edge vertices, so bands run continuous along
## the shore like the cliff shadow strip). Re-derivable + idempotent.

const SHORE_GROUP := "crusade_shore"
const WET_GRASS := Color(0.333, 0.376, 0.188, 0.75)    # ~#556030
const MUD := Color(0.565, 0.478, 0.306, 0.9)           # ~#907a4e
const WATERLINE := Color(0.788, 0.722, 0.471, 0.5)     # ~#c9b878

static var _unshaded: CanvasItemMaterial

static func _mat() -> CanvasItemMaterial:
	if _unshaded == null:
		_unshaded = CanvasItemMaterial.new()
		_unshaded.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	return _unshaded


## Rebuilds every shore band. Call after the terrain-variation pass.
static func populate(map_system: MapSystem) -> void:
	if map_system == null:
		return
	_clear(map_system)
	for tier in map_system.tier_count():
		var layer: TileMapLayer = map_system.get_elevation_layer(tier)
		if layer == null:
			continue
		for cell in layer.get_used_cells():
			if not TileSetConstants.is_water_coord(layer.get_cell_atlas_coords(cell)):
				continue
			for n in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
				var ncoord: Vector2i = cell + n
				if layer.get_cell_source_id(ncoord) == -1:
					continue
				if TileSetConstants.is_water_coord(layer.get_cell_atlas_coords(ncoord)):
					continue
				_add_band(map_system, cell, tier, n)


static func _clear(map_system: MapSystem) -> void:
	var tree := map_system.get_tree()
	if tree == null:
		return
	for nd in tree.get_nodes_in_group(SHORE_GROUP):
		nd.queue_free()


## One three-band quad set along the water cell's edge facing neighbour dir `n`.
## Edge endpoints (rel. diamond centre): SE n=(1,0): (64,0)-(0,32); SW n=(0,1):
## (0,32)-(-64,0); NW n=(-1,0): (-64,0)-(0,-32); NE n=(0,-1): (0,-32)-(64,0).
static func _add_band(map_system: MapSystem, cell: Vector2i, tier: int, n: Vector2i) -> void:
	var half := MapConstants.TILE_SIZE.x / 2.0
	var quarter := MapConstants.TILE_SIZE.y / 2.0
	var a: Vector2
	var b: Vector2
	if n == Vector2i(1, 0):
		a = Vector2(half, 0)
		b = Vector2(0, quarter)
	elif n == Vector2i(0, 1):
		a = Vector2(0, quarter)
		b = Vector2(-half, 0)
	elif n == Vector2i(-1, 0):
		a = Vector2(-half, 0)
		b = Vector2(0, -quarter)
	else:
		a = Vector2(0, -quarter)
		b = Vector2(half, 0)
	# Outward normal (toward the grass side), scaled per band.
	var out := Vector2(n.x - n.y, (n.x + n.y) * 0.5).normalized()
	var origin := EntityPlacement.ground_position(cell) - Vector2(0, MapConstants.ELEVATION_STEP_PX * tier)
	_quad(map_system, origin, a, b, out, -4.0, 3.0, WATERLINE, WATERLINE)
	_quad(map_system, origin, a, b, out, 3.0, 11.0, MUD, Color(MUD.r, MUD.g, MUD.b, 0.0))
	_quad(map_system, origin, a, b, out, 8.0, 22.0, WET_GRASS, Color(WET_GRASS.r, WET_GRASS.g, WET_GRASS.b, 0.0))


static func _quad(map_system: MapSystem, origin: Vector2, a: Vector2, b: Vector2, out: Vector2, d0: float, d1: float, c0: Color, c1: Color) -> void:
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([a + out * d0, b + out * d0, b + out * d1, a + out * d1])
	poly.vertex_colors = PackedColorArray([c0, c0, c1, c1])
	poly.position = origin
	poly.material = _mat()
	poly.add_to_group(SHORE_GROUP)
	map_system.add_child(poly)
