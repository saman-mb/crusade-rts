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

## Builds the full terrain TileSet from an atlas texture: one atlas source, a
## tile at each distinct non-sentinel LOOKUP coord, and the animated water tile.
static func build_terrain_tileset(texture: Texture2D) -> TileSet:
	var ts := TileSet.new()
	configure_isometric(ts)

	var src := TileSetAtlasSource.new()
	src.texture = texture
	src.texture_region_size = TileSetConstants.REGION_SIZE
	ts.add_source(src)

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

	# Water lives at its own row (WATER_ANIM_COORDS) so it never collides with a
	# LOOKUP coord; create it separately and wire up its animation.
	var water := TileSetConstants.WATER_ANIM_COORDS
	if not seen.has(water):
		src.create_tile(water)
		src.get_tile_data(water, 0).texture_origin = TileSetConstants.TEXTURE_ORIGIN
	configure_water_animation(src, water)

	return ts

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
