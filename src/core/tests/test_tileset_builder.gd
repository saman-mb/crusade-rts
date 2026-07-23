extends GdTest
## Runtime tests for TileSetBuilder against a live, in-memory TileSet.
## Requires a Godot 4.4 runtime; authored + statically checked now, executed in
## CI: godot --headless --script <this file>. Config-correctness is proven
## against an ImageTexture built in memory so it never depends on asset import;
## a separate, clearly-labeled block verifies the committed atlas PNG on disk
## (which CI imports before running this test).


func _run() -> void:
	# Build against an in-memory texture: geometry/animation correctness must not
	# hinge on the on-disk asset being imported.
	var img := Image.create(TileSetConstants.ATLAS_PX.x, TileSetConstants.ATLAS_PX.y, false, Image.FORMAT_RGBA8)
	var tex := ImageTexture.create_from_image(img)
	var ts := TileSetBuilder.build_terrain_tileset(tex)

	_test_geometry(ts)
	var src := _test_source(ts)
	if src != null:
		_test_tiles(src)
		_test_water_animation(src)
	_test_animation_bounds_independent()
	_test_committed_asset()
	_test_make_atlas_texture(tex)
	_test_no_normal_is_plain_texture(tex)
	_test_normal_map_wired_into_source(tex)
	_test_committed_normal_asset()


# --- helpers ---

func _v_match(a: Vector2i, b: Vector2i) -> bool:
	return a == b

func _i_match(a: int, b: int) -> bool:
	return a == b

## Approximate float equality for per-frame durations.
func _f_eq(a: float, b: float) -> bool:
	return absf(a - b) < 1e-4

# --- tests ---

## Isometric geometry mirrors the map's single source of truth.
func _test_geometry(ts: TileSet) -> void:
	_ok(ts.tile_shape == TileSet.TILE_SHAPE_ISOMETRIC, "tile_shape not ISOMETRIC")
	_ok(ts.tile_layout == TileSet.TILE_LAYOUT_DIAMOND_DOWN, "tile_layout not DIAMOND_DOWN")
	_ok(_v_match(ts.tile_size, Vector2i(128, 64)), "tile_size %s != (128,64)" % ts.tile_size)

## Exactly one atlas source, with the contracted region size. Returns it (or null).
func _test_source(ts: TileSet) -> TileSetAtlasSource:
	_ok(_i_match(ts.get_source_count(), 1), "source count %d != 1" % ts.get_source_count())
	if ts.get_source_count() < 1:
		return null
	var src := ts.get_source(ts.get_source_id(0)) as TileSetAtlasSource
	_ok(src != null, "source 0 is not a TileSetAtlasSource")
	if src != null:
		_ok(_v_match(src.texture_region_size, TileSetConstants.REGION_SIZE),
			"texture_region_size %s != %s" % [src.texture_region_size, TileSetConstants.REGION_SIZE])
	return src

## Every distinct non-sentinel LOOKUP coord exists with its texture_origin set,
## and the water tile likewise exists and is configured.
func _test_tiles(src: TileSetAtlasSource) -> void:
	var seen: Dictionary = {}
	for coord in TileSetConstants.LOOKUP:
		if coord == Vector2i(-1, -1) or seen.has(coord):
			continue
		seen[coord] = true
		var data := src.get_tile_data(coord, 0)
		_ok(data != null, "no tile created at LOOKUP coord %s" % coord)
		if data != null:
			_ok(_v_match(data.texture_origin, TileSetConstants.TEXTURE_ORIGIN),
				"texture_origin at %s is %s != %s" % [coord, data.texture_origin, TileSetConstants.TEXTURE_ORIGIN])

	var water := TileSetConstants.WATER_ANIM_COORDS
	var wdata := src.get_tile_data(water, 0)
	_ok(wdata != null, "no water tile at %s" % water)
	if wdata != null:
		_ok(_v_match(wdata.texture_origin, TileSetConstants.TEXTURE_ORIGIN),
			"water texture_origin %s != %s" % [wdata.texture_origin, TileSetConstants.TEXTURE_ORIGIN])

## Water tile carries the full multi-frame animation config.
func _test_water_animation(src: TileSetAtlasSource) -> void:
	var water := TileSetConstants.WATER_ANIM_COORDS
	_ok(_i_match(src.get_tile_animation_frames_count(water), TileSetConstants.WATER_FRAMES),
		"water frames_count %d != %d" % [src.get_tile_animation_frames_count(water), TileSetConstants.WATER_FRAMES])
	_ok(_i_match(src.get_tile_animation_columns(water), TileSetConstants.WATER_COLUMNS),
		"water columns %d != %d" % [src.get_tile_animation_columns(water), TileSetConstants.WATER_COLUMNS])
	for i in TileSetConstants.WATER_FRAMES:
		var dur := src.get_tile_animation_frame_duration(water, i)
		_ok(_f_eq(dur, TileSetConstants.WATER_FRAME_DURATION),
			"water frame %d duration %f != %f" % [i, dur, TileSetConstants.WATER_FRAME_DURATION])
	_ok(src.get_tile_animation_mode(water) == TileSetAtlasSource.TILE_ANIMATION_MODE_RANDOM_START_TIMES,
		"water animation mode is not RANDOM_START_TIMES")

## INDEPENDENT atlas-bounds guard for the water animation strip (#31). Derived
## purely from the geometry constants + arithmetic, NOT from the builder's
## output: _test_water_animation asserts frames_count/columns against the same
## TileSetConstants the builder reads, so bumping WATER_FRAMES/WATER_COLUMNS/
## WATER_ANIM_COORDS past the atlas edge moves both sides together and stays
## green while real art would overflow ATLAS_PX. This check fails in that case.
func _test_animation_bounds_independent() -> void:
	var region := TileSetConstants.REGION_SIZE
	var atlas := TileSetConstants.ATLAS_PX
	_ok(region.x > 0 and region.y > 0, "region size positive")
	# The atlas must carve into whole regions on both axes (no partial row/col).
	_i_eq(atlas.x % region.x, 0, "atlas width is a whole number of regions")
	_i_eq(atlas.y % region.y, 0, "atlas height is a whole number of regions")
	var cols := atlas.x / region.x
	var rows := atlas.y / region.y

	var start := TileSetConstants.WATER_ANIM_COORDS
	var frames := TileSetConstants.WATER_FRAMES
	var acols := TileSetConstants.WATER_COLUMNS
	_ok(frames > 0 and acols > 0, "water frame/column counts positive")
	_ok(start.x >= 0 and start.y >= 0, "water anim origin non-negative")
	# The strip lays `frames` cells across `acols` columns, wrapping downward:
	# first row spans min(frames, acols) columns; total height is ceil(frames/acols).
	var strip_cols := mini(frames, acols)
	var strip_rows := (frames + acols - 1) / acols
	_ok(start.x + strip_cols <= cols, "water strip exceeds atlas columns: %d+%d > %d" % [start.x, strip_cols, cols])
	_ok(start.y + strip_rows <= rows, "water strip exceeds atlas rows: %d+%d > %d" % [start.y, strip_rows, rows])

## Committed-asset check (runs after CI's import step): the atlas PNG exists on
## disk and matches the contracted pixel dimensions. A null load is a FAIL, not
## a crash.
func _test_committed_asset() -> void:
	var disk := load(TileSetConstants.ATLAS_PATH)
	_ok(disk != null, "committed atlas %s failed to load" % TileSetConstants.ATLAS_PATH)
	if disk != null:
		var size := Vector2i(disk.get_size())
		_ok(_v_match(size, TileSetConstants.ATLAS_PX),
			"committed atlas size %s != %s" % [size, TileSetConstants.ATLAS_PX])

## make_atlas_texture: null normal returns the diffuse untouched (unlit path);
## a normal returns a CanvasTexture pairing the two (#84).
func _test_make_atlas_texture(diffuse: Texture2D) -> void:
	var plain := TileSetBuilder.make_atlas_texture(diffuse, null)
	_ok(plain == diffuse, "make_atlas_texture(diffuse, null) should return the diffuse itself")
	var normal := ImageTexture.create_from_image(
		Image.create(TileSetConstants.ATLAS_PX.x, TileSetConstants.ATLAS_PX.y, false, Image.FORMAT_RGB8))
	var paired := TileSetBuilder.make_atlas_texture(diffuse, normal)
	var ct := paired as CanvasTexture
	_ok(ct != null, "make_atlas_texture(diffuse, normal) should return a CanvasTexture")
	if ct != null:
		_ok(ct.diffuse_texture == diffuse, "CanvasTexture.diffuse_texture not the diffuse")
		_ok(ct.normal_texture == normal, "CanvasTexture.normal_texture not the normal")

## Building without a normal leaves the source drawing the plain diffuse (not a
## CanvasTexture), so the existing single-arg callers are unchanged.
func _test_no_normal_is_plain_texture(diffuse: Texture2D) -> void:
	var ts := TileSetBuilder.build_terrain_tileset(diffuse)
	var src := ts.get_source(ts.get_source_id(0)) as TileSetAtlasSource
	_ok(src != null and src.texture == diffuse, "no-normal build should keep the plain diffuse texture")
	_ok(not (src.texture is CanvasTexture), "no-normal build should NOT wrap in a CanvasTexture")

## Building WITH a normal wires a CanvasTexture (diffuse + normal) onto the atlas
## source, so Light2D can shade the tiles with relief.
func _test_normal_map_wired_into_source(diffuse: Texture2D) -> void:
	var normal := ImageTexture.create_from_image(
		Image.create(TileSetConstants.ATLAS_PX.x, TileSetConstants.ATLAS_PX.y, false, Image.FORMAT_RGB8))
	var ts := TileSetBuilder.build_terrain_tileset(diffuse, normal)
	var src := ts.get_source(ts.get_source_id(0)) as TileSetAtlasSource
	_ok(src != null, "normal build produced no atlas source")
	if src == null:
		return
	var ct := src.texture as CanvasTexture
	_ok(ct != null, "atlas source texture is not a CanvasTexture when a normal is supplied")
	if ct != null:
		_ok(ct.diffuse_texture == diffuse, "source CanvasTexture diffuse is not the atlas diffuse")
		_ok(ct.normal_texture == normal, "source CanvasTexture normal is not the supplied normal map")
	# Region size is unchanged: the CanvasTexture is a transparent swap for the diffuse.
	_ok(_v_match(src.texture_region_size, TileSetConstants.REGION_SIZE),
		"region size changed when wrapping in a CanvasTexture")

## Committed normal-atlas check (post-import): the L1 normal PNG exists on disk
## and matches the atlas dimensions, so build_default_terrain_tileset pairs it in.
func _test_committed_normal_asset() -> void:
	var disk := load(TileSetConstants.NORMAL_ATLAS_PATH)
	_ok(disk != null, "committed normal atlas %s failed to load" % TileSetConstants.NORMAL_ATLAS_PATH)
	if disk != null:
		var size := Vector2i(disk.get_size())
		_ok(_v_match(size, TileSetConstants.ATLAS_PX),
			"committed normal atlas size %s != %s" % [size, TileSetConstants.ATLAS_PX])
