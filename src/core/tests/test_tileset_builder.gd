extends SceneTree
## Runtime tests for TileSetBuilder against a live, in-memory TileSet.
## Requires a Godot 4.4 runtime; authored + statically checked now, executed in
## CI: godot --headless --script <this file>. Config-correctness is proven
## against an ImageTexture built in memory so it never depends on asset import;
## a separate, clearly-labeled block verifies the committed atlas PNG on disk
## (which CI imports before running this test).

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
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
	_test_committed_asset()

	print("PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- helpers ---

## Increments counters; prints only on failure so passing runs stay quiet.
func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % msg)

func _v_eq(a: Vector2i, b: Vector2i) -> bool:
	return a == b

func _i_eq(a: int, b: int) -> bool:
	return a == b

## Approximate float equality for per-frame durations.
func _f_eq(a: float, b: float) -> bool:
	return absf(a - b) < 1e-4

# --- tests ---

## Isometric geometry mirrors the map's single source of truth.
func _test_geometry(ts: TileSet) -> void:
	_ok(ts.tile_shape == TileSet.TILE_SHAPE_ISOMETRIC, "tile_shape not ISOMETRIC")
	_ok(ts.tile_layout == TileSet.TILE_LAYOUT_DIAMOND_DOWN, "tile_layout not DIAMOND_DOWN")
	_ok(_v_eq(ts.tile_size, Vector2i(128, 64)), "tile_size %s != (128,64)" % ts.tile_size)

## Exactly one atlas source, with the contracted region size. Returns it (or null).
func _test_source(ts: TileSet) -> TileSetAtlasSource:
	_ok(_i_eq(ts.get_source_count(), 1), "source count %d != 1" % ts.get_source_count())
	if ts.get_source_count() < 1:
		return null
	var src := ts.get_source(ts.get_source_id(0)) as TileSetAtlasSource
	_ok(src != null, "source 0 is not a TileSetAtlasSource")
	if src != null:
		_ok(_v_eq(src.texture_region_size, TileSetConstants.REGION_SIZE),
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
			_ok(_v_eq(data.texture_origin, TileSetConstants.TEXTURE_ORIGIN),
				"texture_origin at %s is %s != %s" % [coord, data.texture_origin, TileSetConstants.TEXTURE_ORIGIN])

	var water := TileSetConstants.WATER_ANIM_COORDS
	var wdata := src.get_tile_data(water, 0)
	_ok(wdata != null, "no water tile at %s" % water)
	if wdata != null:
		_ok(_v_eq(wdata.texture_origin, TileSetConstants.TEXTURE_ORIGIN),
			"water texture_origin %s != %s" % [wdata.texture_origin, TileSetConstants.TEXTURE_ORIGIN])

## Water tile carries the full multi-frame animation config.
func _test_water_animation(src: TileSetAtlasSource) -> void:
	var water := TileSetConstants.WATER_ANIM_COORDS
	_ok(_i_eq(src.get_tile_animation_frames_count(water), TileSetConstants.WATER_FRAMES),
		"water frames_count %d != %d" % [src.get_tile_animation_frames_count(water), TileSetConstants.WATER_FRAMES])
	_ok(_i_eq(src.get_tile_animation_columns(water), TileSetConstants.WATER_COLUMNS),
		"water columns %d != %d" % [src.get_tile_animation_columns(water), TileSetConstants.WATER_COLUMNS])
	for i in TileSetConstants.WATER_FRAMES:
		var dur := src.get_tile_animation_frame_duration(water, i)
		_ok(_f_eq(dur, TileSetConstants.WATER_FRAME_DURATION),
			"water frame %d duration %f != %f" % [i, dur, TileSetConstants.WATER_FRAME_DURATION])
	_ok(src.get_tile_animation_mode(water) == TileSetAtlasSource.TILE_ANIMATION_MODE_RANDOM_START_TIMES,
		"water animation mode is not RANDOM_START_TIMES")

## Committed-asset check (runs after CI's import step): the atlas PNG exists on
## disk and matches the contracted pixel dimensions. A null load is a FAIL, not
## a crash.
func _test_committed_asset() -> void:
	var disk := load("res://assets/tilesets/terrain_atlas.png")
	_ok(disk != null, "committed atlas res://assets/tilesets/terrain_atlas.png failed to load")
	if disk != null:
		var size := Vector2i(disk.get_size())
		_ok(_v_eq(size, TileSetConstants.ATLAS_PX),
			"committed atlas size %s != %s" % [size, TileSetConstants.ATLAS_PX])
