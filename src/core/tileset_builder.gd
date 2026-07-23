class_name TileSetBuilder
extends RefCounted
## Headless builder for the terrain TileSet. Assembles an isometric
## DIAMOND_DOWN TileSet backed by a single atlas source, one tile per distinct
## dual-grid lookup coord, plus the animated water tile. All geometry &
## atlas metadata come from MapConstants / TileSetConstants (single sources of
## truth); nothing is hardcoded here. Pure/headless -- no Node dependencies, so
## it is fully constructible against an in-memory ImageTexture with no GPU.

## Applies the shared isometric geometry to a TileSet (shape, layout, tile size).
static func configure_isometric(ts: TileSet) -> void:
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_DOWN
	ts.tile_size = MapConstants.TILE_SIZE

## Pairs a diffuse atlas with an optional normal map into the texture the atlas
## source draws with. When `normal` is supplied, returns a CanvasTexture that
## carries both, so a Light2D shades each diamond with the normal-map relief (L3,
## #84); when it is null, returns the diffuse texture unchanged (unlit path, and
## keeps every existing single-arg caller behaving exactly as before). Pure and
## headless -- CanvasTexture is a CPU-side Resource, no GPU needed.
static func make_atlas_texture(diffuse: Texture2D, normal: Texture2D = null) -> Texture2D:
	if normal == null:
		return diffuse
	var ct := CanvasTexture.new()
	ct.diffuse_texture = diffuse
	ct.normal_texture = normal
	return ct

## Builds the full terrain TileSet from an atlas texture: one atlas source, a
## tile at each distinct non-sentinel LOOKUP coord, and the animated water tile.
## An optional `normal` map is paired with the diffuse via a CanvasTexture so the
## terrain catches directional light (#84).
static func build_terrain_tileset(texture: Texture2D, normal: Texture2D = null) -> TileSet:
	var ts := TileSet.new()
	configure_isometric(ts)

	var src := TileSetAtlasSource.new()
	src.texture = make_atlas_texture(texture, normal)
	src.texture_region_size = TileSetConstants.REGION_SIZE
	ts.add_source(src)

	# Register the per-tile walkability layer once, before any tile exists, so
	# every get_tile_data(...).set_custom_data(WALKABLE_LAYER, ...) below resolves.
	ts.add_custom_data_layer()
	var idx: int = ts.get_custom_data_layers_count() - 1
	ts.set_custom_data_layer_name(idx, TileSetConstants.WALKABLE_LAYER)
	ts.set_custom_data_layer_type(idx, TYPE_BOOL)

	# Register a second per-tile "ramp" layer (#78) the same way, before any tile
	# exists, so every set_custom_data(RAMP_LAYER, ...) below resolves. Marks a
	# tier-transition tile the NavMapBuilder turns into a NavRamp.
	ts.add_custom_data_layer()
	var ramp_idx: int = ts.get_custom_data_layers_count() - 1
	ts.set_custom_data_layer_name(ramp_idx, TileSetConstants.RAMP_LAYER)
	ts.set_custom_data_layer_type(ramp_idx, TYPE_BOOL)

	# De-duplicate coords: LOOKUP repeats atlas coords across its 16 entries and
	# create_tile() must never be called twice for the same coord.
	var seen: Dictionary = {}
	for coord in TileSetConstants.LOOKUP:
		if coord == Vector2i(-1, -1):
			continue
		if seen.has(coord):
			continue
		seen[coord] = true
		src.create_tile(coord)
		src.get_tile_data(coord, 0).texture_origin = TileSetConstants.TEXTURE_ORIGIN
		src.get_tile_data(coord, 0).set_custom_data(TileSetConstants.WALKABLE_LAYER, TileSetConstants.coord_walkable(coord))
		src.get_tile_data(coord, 0).set_custom_data(TileSetConstants.RAMP_LAYER, TileSetConstants.coord_ramp(coord))

	# Water lives at its own row (WATER_ANIM_COORDS) so it never collides with a
	# LOOKUP coord; create it separately and wire up its animation.
	var water := TileSetConstants.WATER_ANIM_COORDS
	if not seen.has(water):
		src.create_tile(water)
		src.get_tile_data(water, 0).texture_origin = TileSetConstants.TEXTURE_ORIGIN
	# Water is non-walkable; set it unconditionally so it holds even if the water
	# coord had already been created as a LOOKUP tile above.
	src.get_tile_data(water, 0).set_custom_data(TileSetConstants.WALKABLE_LAYER, TileSetConstants.coord_walkable(water))
	src.get_tile_data(water, 0).set_custom_data(TileSetConstants.RAMP_LAYER, TileSetConstants.coord_ramp(water))
	configure_water_animation(src, water)

	# Ramp tiles (#78) live on their own row (RAMP_COORDS) so they never collide
	# with a LOOKUP or water coord; create each separately, mirroring the water
	# block, and mark it BOTH walkable (a unit stands on it) and a ramp. The
	# seen-guard is defensive: RAMP_COORDS does not overlap the LOOKUP/water rows
	# today (row 5), but a future collision must not double-create the tile.
	for ramp in TileSetConstants.RAMP_COORDS:
		if not seen.has(ramp):
			seen[ramp] = true
			src.create_tile(ramp)
			src.get_tile_data(ramp, 0).texture_origin = TileSetConstants.TEXTURE_ORIGIN
		src.get_tile_data(ramp, 0).set_custom_data(TileSetConstants.WALKABLE_LAYER, TileSetConstants.coord_walkable(ramp))
		src.get_tile_data(ramp, 0).set_custom_data(TileSetConstants.RAMP_LAYER, TileSetConstants.coord_ramp(ramp))

	return ts

## Loads the committed diffuse + normal atlases from their canonical paths and
## builds the terrain TileSet from them. One place so every call site (the editor
## boot and the dev-menu catalog) gets the normal map wired identically. Returns
## null if the diffuse atlas is missing; a missing normal degrades to the unlit
## texture rather than failing.
static func build_default_terrain_tileset() -> TileSet:
	var diffuse := load(TileSetConstants.ATLAS_PATH) as Texture2D
	if diffuse == null:
		return null
	var normal := load(TileSetConstants.NORMAL_ATLAS_PATH) as Texture2D
	return build_terrain_tileset(diffuse, normal)


## Configures the multi-frame water animation on an existing atlas tile: frame
## count, column layout, per-frame durations, separation, and randomized start
## times so neighbouring water tiles do not visibly ripple in lockstep.
static func configure_water_animation(src: TileSetAtlasSource, coords: Vector2i) -> void:
	src.set_tile_animation_frames_count(coords, TileSetConstants.WATER_FRAMES)
	src.set_tile_animation_columns(coords, TileSetConstants.WATER_COLUMNS)
	src.set_tile_animation_separation(coords, TileSetConstants.WATER_SEPARATION)
	for i in TileSetConstants.WATER_FRAMES:
		src.set_tile_animation_frame_duration(coords, i, TileSetConstants.WATER_FRAME_DURATION)
	src.set_tile_animation_mode(coords, TileSetAtlasSource.TILE_ANIMATION_MODE_RANDOM_START_TIMES)
