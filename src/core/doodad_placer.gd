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
## Trees: sparse and CLUSTERED (grove-gated in DoodadScatter.scatter_clustered),
## so the map reads as meadow with copses, not an even orchard.
const TREE_DENSITY_PER_MILLE := 170
const TREE_SALT := 977

## Clears any previously-placed doodads, then scatters fresh ones over every tier's
## interior-grass cells. Safe no-op if the map system or the atlas is unavailable.
static func populate(map_system: MapSystem) -> void:
	if map_system == null:
		return
	var atlas := load(DoodadCatalog.ATLAS_PATH) as Texture2D
	if atlas == null:
		return
	_clear(map_system)
	for tier in map_system.tier_count():
		var layer: TileMapLayer = map_system.get_elevation_layer(tier)
		var parent: Node2D = map_system.entity_parent_for_tier(tier)
		if layer == null or parent == null:
			continue
		var grass: Array[Vector2i] = []
		for cell in layer.get_used_cells():
			# is_grass_coord matches the painted interior tile AND the positional
			# windows the variation pass remaps to -- the placer runs after it.
			if TileSetConstants.is_grass_coord(layer.get_cell_atlas_coords(cell)):
				grass.append(cell)
		for d in DoodadScatter.scatter(grass, DENSITY_PER_MILLE):
			parent.add_child(_make_sprite(atlas, d, tier))
		var trees := load(TreeCatalog.SHEET_PATH) as Texture2D
		if trees != null:
			for t in DoodadScatter.scatter_clustered(grass, TREE_DENSITY_PER_MILLE, TreeCatalog.VARIANTS, TREE_SALT):
				parent.add_child(_make_tree(trees, t, tier))


## Frees doodads from a previous populate (the reload path) via the shared group.
static func _clear(map_system: MapSystem) -> void:
	var tree := map_system.get_tree()
	if tree == null:
		return
	for n in tree.get_nodes_in_group(DOODAD_GROUP):
		n.queue_free()


## Builds one tree Sprite2D: trunk base at the cell footprint (+ jitter) so it
## Y-sorts like a unit; long SE shadow is baked into the art, so anything SE of
## the tree sorts later and correctly draws over the shadow.
static func _make_tree(sheet: Texture2D, d: Dictionary, tier: int) -> Sprite2D:
	var s := Sprite2D.new()
	var tex := AtlasTexture.new()
	tex.atlas = sheet
	var variant: int = d["variant"]
	tex.region = TreeCatalog.region(variant)
	s.texture = tex
	s.centered = false
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var cell: Vector2i = d["cell"]
	var offset: Vector2 = d["offset"]
	s.position = EntityPlacement.ground_position(cell) + offset
	s.offset = TreeCatalog.art_offset(tier)
	# Per-instance jitter (lead artist): slight value/hue modulate + scale mix so
	# overlapping crowns in a grove separate instead of blending into one mass.
	var vjit := 0.94 + 0.12 * float(VariationPicker.pick(cell, 7)) / 6.0
	var hjit := float(VariationPicker.pick(cell + Vector2i(37, 91), 5)) / 4.0
	s.modulate = Color(vjit * (0.97 + 0.05 * hjit), vjit, vjit * (1.03 - 0.05 * hjit))
	var sjit := 0.88 + 0.24 * float(VariationPicker.pick(cell + Vector2i(11, 3), 9)) / 8.0
	s.scale = Vector2(sjit, sjit)
	s.add_to_group(DOODAD_GROUP)
	return s


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
