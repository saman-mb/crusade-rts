class_name CliffRenderer
extends RefCounted
## Renders cliff walls under raised elevation tiers (#235, Tier 4) so a plateau reads
## as solid height instead of floating diamonds. For every raised-tier cell whose
## front (SE / SW, camera-facing) neighbour is absent, it drops a shaded wall band
## from that edge to the tier below, plus a sun-catching lip along the top. Ramp
## cells are skipped so the ramp reads as a walkable break in the wall.
##
## Operates on live nodes (adds Polygon2D/Line2D children to the MapSystem, which is
## Y-sorted), like DoodadPlacer -- re-derivable + idempotent (clears the prior group,
## rebuilds). Geometry comes from IsoCoord/EntityPlacement + MapConstants; nothing is
## hardcoded. Exercised via render, not headless CI.

const CLIFF_GROUP := "crusade_cliff"
## Wall gradient: warm earthen rock, top lit -> base dark (lead-artist palette).
## Front faces point away from the top-left sun, so the wall is dim overall -- that
## contrast against the lit plateau grass is what makes the height read.
const FACE_TOP := Color(0.541, 0.455, 0.322)     # ~#8A7452 warm rock
const FACE_BOTTOM := Color(0.243, 0.200, 0.141)  # ~#3E3324 dark earth base
## Thin grass overhang catching the sun along the top edge -- warm-green, subtle.
const LIP_COLOR := Color(0.722, 0.784, 0.478)    # ~#B8C87A
const LIP_WIDTH := 1.5
## Dark ambient-occlusion contact line where the wall base meets the ground.
const AO_COLOR := Color(0.09, 0.07, 0.05, 0.85)
const AO_WIDTH := 2.0
## Ground cast shadow at the cliff base: a SOFT radial sprite (squashed to the iso
## ground plane), parented to sort with the front-ground tile so it is not occluded.
## Soft edges avoid the hard-diamond look a polygon gives. Sun from NW -> offset SE.
const SHADOW_TEX := "res://assets/lights/point_light.png"
const SHADOW_COLOR := Color(0.10, 0.11, 0.17, 0.5)   # ~#1A1C2B
## The SW (left-front) face catches a touch more of a NW sun than the SE face; a
## small split gives the corner depth.
const SW_BRIGHTEN := 1.18
const SE_DARKEN := 0.82

## Shared unshaded material: the cliff faces point AWAY from the directional sun, so
## they must ignore its 2D light (a flat Polygon2D otherwise catches full sun and
## washes pale). Unshaded items still darken with the day/night CanvasModulate, so
## the authored dark-rock gradient stays correct across the lighting cycle.
static var _unshaded: CanvasItemMaterial

static func _unshaded_material() -> CanvasItemMaterial:
	if _unshaded == null:
		_unshaded = CanvasItemMaterial.new()
		_unshaded.light_mode = CanvasItemMaterial.LIGHT_MODE_UNSHADED
	return _unshaded


## Rebuilds every cliff wall for the map. Safe no-op on a null map system.
static func populate(map_system: MapSystem) -> void:
	if map_system == null:
		return
	_clear(map_system)
	var step := float(MapConstants.ELEVATION_STEP_PX)
	for tier in range(1, map_system.tier_count()):
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
			if se_open:
				_add_face(map_system, cell, tier, step, true)
			if sw_open:
				_add_face(map_system, cell, tier, step, false)


## Frees cliffs from a previous populate (reload path) via the shared group.
static func _clear(map_system: MapSystem) -> void:
	var tree := map_system.get_tree()
	if tree == null:
		return
	for n in tree.get_nodes_in_group(CLIFF_GROUP):
		n.queue_free()


## Builds one wall band (+ its lip) for the SE or SW front edge of `cell` on `tier`.
## Vertices are relative to the cell footprint C = ground_position(cell), so the node
## origin sits at C and Y-sorts exactly like that cell's floor tile.
static func _add_face(map_system: MapSystem, cell: Vector2i, tier: int, step: float, is_se: bool) -> void:
	var lift := step * float(tier)
	var half := MapConstants.TILE_SIZE.x / 2.0        # 64
	var quarter := MapConstants.TILE_SIZE.y / 2.0      # 32
	# Front-surface vertices of the raised diamond, relative to the footprint C.
	var bottom_top := Vector2(0.0, quarter - lift)
	var right_top := Vector2(half, -lift)
	var left_top := Vector2(-half, -lift)
	var down := Vector2(0.0, step)

	var top_a: Vector2
	var top_b: Vector2
	if is_se:
		top_a = right_top
		top_b = bottom_top
	else:
		top_a = bottom_top
		top_b = left_top
	var quad := PackedVector2Array([top_a, top_b, top_b + down, top_a + down])

	var top_c := FACE_TOP * (SE_DARKEN if is_se else SW_BRIGHTEN)
	var bot_c := FACE_BOTTOM * (SE_DARKEN if is_se else SW_BRIGHTEN)
	top_c.a = 1.0
	bot_c.a = 1.0

	var mat := _unshaded_material()
	var origin := EntityPlacement.ground_position(cell)

	var poly := Polygon2D.new()
	poly.polygon = quad
	poly.vertex_colors = PackedColorArray([top_c, top_c, bot_c, bot_c])
	poly.position = origin
	poly.material = mat
	poly.add_to_group(CLIFF_GROUP)
	map_system.add_child(poly)

	# Sun-catching lip along the top edge (subtle).
	var lip := Line2D.new()
	lip.points = PackedVector2Array([top_a, top_b])
	lip.width = LIP_WIDTH
	lip.default_color = LIP_COLOR
	lip.position = origin
	lip.material = mat
	lip.add_to_group(CLIFF_GROUP)
	map_system.add_child(lip)

	# Dark contact line where the wall base meets the ground -- grounds the wall.
	var ao := Line2D.new()
	ao.points = PackedVector2Array([top_a + down, top_b + down])
	ao.width = AO_WIDTH
	ao.default_color = AO_COLOR
	ao.position = origin
	ao.material = mat
	ao.add_to_group(CLIFF_GROUP)
	map_system.add_child(ao)

	# Ground cast shadow on the tile IN FRONT of this face -- a SOFT radial sprite
	# squashed onto the iso ground plane. Parenting it at the front cell's footprint
	# makes it sort WITH that ground tile (drawn over it), not occluded like anything
	# at the plateau depth. Offset SE (sun from NW).
	var front_cell := cell + (Vector2i(1, 0) if is_se else Vector2i(0, 1))
	var tex := load(SHADOW_TEX) as Texture2D
	if tex != null:
		var shadow := Sprite2D.new()
		shadow.texture = tex
		shadow.modulate = SHADOW_COLOR
		var s := (MapConstants.TILE_SIZE.x * 1.15) / float(tex.get_width())
		shadow.scale = Vector2(s, s * 0.5)
		shadow.position = EntityPlacement.ground_position(front_cell) + Vector2(6.0, 4.0)
		shadow.add_to_group(CLIFF_GROUP)
		map_system.add_child(shadow)
