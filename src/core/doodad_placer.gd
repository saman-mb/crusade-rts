class_name DoodadPlacer
extends RefCounted
## Runtime pass (#234, Tier 3) that spawns scattered doodad Sprite2Ds over the map's
## solid-grass cells, parented under each tier's Y-sorted entity container so they
## sort exactly like units (origin at the footprint, art lifted onto the tier).
##
## Re-derivable + idempotent: it frees the prior doodads (node group DOODAD_GROUP)
## and re-scatters deterministically (DoodadScatter), so a reload reproduces the
## same field and nothing needs persisting. Mirrors TerrainVariation's role, but
## for decor sprites rather than tile alternatives. Operates on live nodes, so it
## lives with the runtime cores (like NavMapBuilder) and is exercised via render,
## not headless CI.

const DOODAD_GROUP := "crusade_doodad"
const DENSITY_PER_MILLE := 110   ## ~11% of grass cells carry a doodad

## Clears any previously-placed doodads, then scatters fresh ones over every tier's
## interior-grass cells. Safe no-op if the map system or the atlas is unavailable.
static func populate(map_system: MapSystem) -> void:
	if map_system == null:
		return
	var atlas := load(DoodadCatalog.ATLAS_PATH) as Texture2D
	if atlas == null:
		return
	_clear(map_system)
	var interior := TileSetConstants.interior_grass_coord()
	for tier in map_system.tier_count():
		var layer: TileMapLayer = map_system.get_elevation_layer(tier)
		var parent: Node2D = map_system.entity_parent_for_tier(tier)
		if layer == null or parent == null:
			continue
		var grass: Array[Vector2i] = []
		for cell in layer.get_used_cells():
			if layer.get_cell_atlas_coords(cell) == interior:
				grass.append(cell)
		for d in DoodadScatter.scatter(grass, DENSITY_PER_MILLE):
			parent.add_child(_make_sprite(atlas, d, tier))


## Frees doodads from a previous populate (the reload path) via the shared group.
static func _clear(map_system: MapSystem) -> void:
	var tree := map_system.get_tree()
	if tree == null:
		return
	for n in tree.get_nodes_in_group(DOODAD_GROUP):
		n.queue_free()


## Builds one doodad Sprite2D: an AtlasTexture region from the catalog, origin at
## the cell footprint (+ jitter) so it Y-sorts like a unit, art base anchored and
## lifted onto `tier` via DoodadCatalog.art_offset.
static func _make_sprite(atlas: Texture2D, d: Dictionary, tier: int) -> Sprite2D:
	var s := Sprite2D.new()
	var tex := AtlasTexture.new()
	tex.atlas = atlas
	var type_row: int = d["type"]
	var variant: int = d["variant"]
	tex.region = DoodadCatalog.region(type_row, variant)
	s.texture = tex
	s.centered = false
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var cell: Vector2i = d["cell"]
	var offset: Vector2 = d["offset"]
	s.position = EntityPlacement.ground_position(cell) + offset
	s.offset = DoodadCatalog.art_offset(tier)
	s.add_to_group(DOODAD_GROUP)
	return s
