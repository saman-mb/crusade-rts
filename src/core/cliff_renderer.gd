class_name CliffRenderer
extends RefCounted
## Renders cliff walls under raised elevation tiers (#235) so a plateau reads as
## solid height. For every raised-tier cell whose front (SE / SW, camera-facing)
## neighbour is absent, it places a rocky face SPRITE (art from CliffCatalog /
## tools/gen_cliffs.py -- gradient rock, strata, cracks, sunlit lip, overhanging
## tufts, irregular silhouette), a boulder cap on outward corners, and ONE
## CONTINUOUS soft cast-shadow strip along the wall base (per-cell quads that
## share edge vertices, so the shadow reads as a single feathered band rather
## than stamped blobs). Ramp cells are skipped so a ramp reads as a walkable
## break in the wall.
##
## Operates on live nodes (children of the Y-sorted MapSystem), like
## DoodadPlacer -- re-derivable + idempotent (clears the prior group, rebuilds).
## Exercised via render, not headless CI.

const CLIFF_GROUP := "crusade_cliff"
## Cast shadow: sun from NW -> the wall shades the ground toward SE. Near edge
## sits at the wall base (dark), far edge is offset and fully transparent.
const SHADOW_NEAR := Color(0.118, 0.137, 0.204, 0.55)   # ~#1E2334
const SHADOW_FAR := Color(0.118, 0.137, 0.204, 0.0)
const SHADOW_OFFSET := Vector2(16.0, 10.0)

## Shared unshaded material: the cliff faces point AWAY from the directional sun,
## so they must ignore its 2D light (they'd wash pale otherwise). Unshaded items
## still darken with the day/night CanvasModulate, so the authored rock gradient
## stays correct across the lighting cycle.
static var _unshaded: CanvasItemMaterial

static func _unshaded_material() -> CanvasItemMaterial:
	if _unshaded == null:
		_unshaded = CanvasItemMaterial.new()
		_unshaded.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	return _unshaded


## Rebuilds every cliff wall for the map. Safe no-op on a null map system or a
## missing art sheet.
static func populate(map_system: MapSystem) -> void:
	if map_system == null:
		return
	var sheet := load(CliffCatalog.SHEET_PATH) as Texture2D
	if sheet == null:
		return
	_clear(map_system)
	# Wall map per tier: cell -> [se_open, sw_open], ramps excluded. Needed up
	# front so stacked walls (tier t and t-1 sharing a cell+side) can merge into
	# ONE tall face instead of two 32px bands split by a fake ledge line.
	var walls: Array[Dictionary] = []
	walls.resize(map_system.tier_count())
	for tier in range(1, map_system.tier_count()):
		walls[tier] = {}
		var layer: TileMapLayer = map_system.get_elevation_layer(tier)
		if layer == null:
			continue
		var used: Dictionary = {}
		var cells: Array[Vector2i] = layer.get_used_cells()
		for c in cells:
			used[c] = true
		for cell in cells:
			if TileSetConstants.coord_ramp(layer.get_cell_atlas_coords(cell)):
				continue  # ramp = walkable opening, no wall
			var se_open := not used.has(cell + Vector2i(1, 0))
			var sw_open := not used.has(cell + Vector2i(0, 1))
			if se_open or sw_open:
				walls[tier][cell] = [se_open, sw_open]
	for tier in range(1, map_system.tier_count()):
		for cell in walls[tier]:
			var flags: Array = walls[tier][cell]
			var above: Array = walls[tier + 1].get(cell, [false, false]) if tier + 1 < walls.size() else [false, false]
			var below: Array = walls[tier - 1].get(cell, [false, false]) if tier >= 2 else [false, false]
			for side in range(2):
				if not flags[side]:
					continue
				var is_se := side == 0
				if bool(above[side]):
					continue  # the tier above draws the merged tall face
				var tall := bool(below[side])
				_add_face(map_system, sheet, cell, tier, is_se, tall)
			if bool(flags[0]) and bool(flags[1]) and not (bool(above[0]) and bool(above[1])):
				_add_corner_cap(map_system, sheet, cell, tier)


## Frees cliffs from a previous populate (reload path) via the shared group.
static func _clear(map_system: MapSystem) -> void:
	var tree := map_system.get_tree()
	if tree == null:
		return
	for n in tree.get_nodes_in_group(CLIFF_GROUP):
		n.queue_free()


## One face sprite + its continuous shadow quad for the SE or SW edge of `cell`.
## `tall` = a merged two-tier face (the tier below shares this wall cell+side).
static func _add_face(map_system: MapSystem, sheet: Texture2D, cell: Vector2i, tier: int, is_se: bool, tall: bool = false) -> void:
	var origin := EntityPlacement.ground_position(cell)
	var lift := float(MapConstants.ELEVATION_STEP_PX * tier)
	var half := MapConstants.TILE_SIZE.x / 2.0        # 64
	var quarter := MapConstants.TILE_SIZE.y / 2.0      # 32

	var sprite := Sprite2D.new()
	var tex := AtlasTexture.new()
	tex.atlas = sheet
	tex.region = CliffCatalog.face_region(cell, is_se, tall)
	sprite.texture = tex
	sprite.centered = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sprite.position = origin
	sprite.offset = CliffCatalog.face_offset(tier, is_se)
	sprite.material = _unshaded_material()
	sprite.add_to_group(CLIFF_GROUP)
	map_system.add_child(sprite)

	# Continuous shadow: one quad from this face's BASE edge, extruded toward SE.
	# Adjacent wall cells' quads share their edge endpoints exactly (both derive
	# from the same diamond vertices), so the band is seamless along the chain.
	var step := float(MapConstants.ELEVATION_STEP_PX) * (2.0 if tall else 1.0)
	var base_a: Vector2
	var base_b: Vector2
	if is_se:
		base_a = Vector2(half, -lift + step)
		base_b = Vector2(0.0, quarter - lift + step)
	else:
		base_a = Vector2(0.0, quarter - lift + step)
		base_b = Vector2(-half, -lift + step)
	var shadow := Polygon2D.new()
	shadow.polygon = PackedVector2Array([
		base_a, base_b, base_b + SHADOW_OFFSET, base_a + SHADOW_OFFSET])
	shadow.vertex_colors = PackedColorArray([SHADOW_NEAR, SHADOW_NEAR, SHADOW_FAR, SHADOW_FAR])
	shadow.position = origin
	shadow.material = _unshaded_material()
	shadow.add_to_group(CLIFF_GROUP)
	map_system.add_child(shadow)


## Boulder cluster hiding the sharp prism point of an outward (SE+SW) corner.
static func _add_corner_cap(map_system: MapSystem, sheet: Texture2D, cell: Vector2i, tier: int) -> void:
	var lift := float(MapConstants.ELEVATION_STEP_PX * tier)
	var quarter := MapConstants.TILE_SIZE.y / 2.0
	var cap := Sprite2D.new()
	var tex := AtlasTexture.new()
	tex.atlas = sheet
	tex.region = CliffCatalog.CORNER_RECT
	cap.texture = tex
	cap.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# Centre the cluster on the bottom vertex of the raised diamond, resting a
	# touch below so it straddles the wall base.
	cap.position = EntityPlacement.ground_position(cell) + \
		Vector2(0.0, quarter - lift + float(MapConstants.ELEVATION_STEP_PX) * 0.55)
	cap.material = _unshaded_material()
	cap.add_to_group(CLIFF_GROUP)
	map_system.add_child(cap)
