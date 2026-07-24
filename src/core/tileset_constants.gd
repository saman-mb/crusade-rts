class_name TileSetConstants
extends RefCounted
## Single source of truth for the terrain atlas layout. Read read-only by the
## tileset builder, the dual-grid autotiler, and the water animation driver.
## REGION_SIZE mirrors MapConstants.TILE_SIZE -- the single source of truth for
## tile geometry itself stays MapConstants; this module only describes how the
## real CC0 terrain atlas at assets/tilesets/terrain_atlas.png (see CREDITS.md) is
## carved into regions.

const REGION_SIZE := Vector2i(128, 64)          ## == MapConstants.TILE_SIZE; HD 2:1 diamond
const ATLAS_PX := Vector2i(512, 1408)           ## 4 cols x 22 rows of 128x64 regions
const DUALGRID_ORIGIN := Vector2i(0, 0)         ## atlas coord of the 4x4 dual-grid block's top-left cell

## Committed atlas assets. ATLAS_PATH is the diffuse art; NORMAL_ATLAS_PATH is the
## L1-generated tangent-space normal map (#82) paired with it via a CanvasTexture
## so Light2D shades the diamonds with relief (#84). Single source of truth for
## both paths -- map_editor and the dev-menu catalog load from here.
const ATLAS_PATH := "res://assets/tilesets/terrain_atlas.png"
const NORMAL_ATLAS_PATH := "res://assets/tilesets/terrain_atlas_n.png"

const WATER_ANIM_COORDS := Vector2i(0, 4)       ## atlas coord (col,row) of the animated water base tile (row 4)

## Per-tile walkability, exposed to the runtime as a TYPE_BOOL TileSet custom-data
## layer the builder populates. WALKABLE_LAYER is the layer name (single source of
## truth for both the builder and any reader). Ground is walkable by default;
## NON_WALKABLE_COORDS is an allowlist-of-exceptions -- only water carves a hole
## today, but cliffs/props append here as they arrive without touching the builder.
const WALKABLE_LAYER := "walkable"
const NON_WALKABLE_COORDS: Array[Vector2i] = [WATER_ANIM_COORDS]

## True when a tile at `coord` is walkable: not in the exceptions allowlist and
## not one of the positional water windows (which are water just like the legacy
## animated tile, so they carve the same nav hole).
static func coord_walkable(coord: Vector2i) -> bool:
	return not (NON_WALKABLE_COORDS.has(coord) or is_water_window_coord(coord))

## Per-tile ramp flag, exposed as a second TYPE_BOOL TileSet custom-data layer the
## builder populates. A ramp tile marks a low<->high tier transition; NavMapBuilder
## derives NavRamps from painted ramp tiles (#78). Painted on the HIGH tier at the
## transition cell; the ramp tile is itself walkable (a unit stands on it).
const RAMP_LAYER := "ramp"
const RAMP_COORDS: Array[Vector2i] = [Vector2i(0, 5)]   ## atlas coord(s) of the ramp tile(s), row 5

## True when a tile at `coord` is a ramp tile.
static func coord_ramp(coord: Vector2i) -> bool:
	return RAMP_COORDS.has(coord)

const WATER_FRAMES := 4
const WATER_COLUMNS := 4
const WATER_FRAME_DURATION := 0.2               ## seconds/frame (~5fps)
const WATER_SEPARATION := Vector2i(0, 0)

## Per-tile TileData.texture_origin. Godot even-dimension half-offset quirk
## (godotengine/godot#65963): a tile group with even pixel dimensions is
## auto-offset by half a tile, so art authored centered on the cell origin
## needs no correction -- for a flat diamond that exactly fills the region and
## is centered on the cell origin this is (0, 0). For TALLER art (props whose
## art rect extends above the diamond) shift y by -REGION_SIZE.y/2 to re-anchor
## the visual base onto the diamond.
const TEXTURE_ORIGIN := Vector2i(0, 0)

## Dual-grid corner-mask -> atlas-coord table. index = corner mask (0..15),
## value = atlas coord. Bit order: TL=1, TR=2, BL=4, BR=8. Canonical mapping
## coord = Vector2i(mask & 3, mask >> 2) for mask 1..15; LOOKUP[0] is the empty
## sentinel Vector2i(-1, -1) because physical cell (0,0) is left blank.
static var LOOKUP: Array[Vector2i] = _build_lookup()

static func _build_lookup() -> Array[Vector2i]:
	var table: Array[Vector2i] = []
	table.resize(16)
	table[0] = Vector2i(-1, -1)
	for mask in range(1, 16):
		table[mask] = Vector2i(mask & 3, mask >> 2)
	return table

## --- Per-cell tile variation (#232) ---------------------------------------
## The fully-surrounded grass tile (corner mask 15 -> LOOKUP[15] == Vector2i(3,3))
## is the interior tile stamped into every solid-grass cell, so it is the one that
## reads as a repeating grid. It gets N alternative_tiles (built by TileSetBuilder)
## that flip/tint the SAME atlas region -- zero extra art -- and TerrainVariation
## assigns one per cell via VariationPicker so neighbours stop looking identical.
const INTERIOR_GRASS_MASK := 15
## Number of grass variants INCLUDING the base tile (index 0) == the four flip
## orientations. Alternatives 1..3 are built on the interior grass coord. Variation
## is FLIP-ONLY on purpose: a per-tile flat colour tint would make every diamond a
## uniformly-shaded patch, and the brightness step at each tile edge re-traces the
## grid. The smooth, seamless colour variation instead comes from the low-frequency
## world-space noise in the terrain tint shader (#233), which has no tile boundary.
const GRASS_VARIANTS := 4

## Interior (fully-surrounded) grass atlas coord, from the single-source LOOKUP.
static func interior_grass_coord() -> Vector2i:
	return LOOKUP[INTERIOR_GRASS_MASK]

## Variant count for `coord`: >1 only for coords that carry alternative_tiles. The
## runtime picker uses this to know how many alternatives a cell may choose from,
## and skips (returns the base) for every other tile. Water is intentionally left
## at 1 -- it varies via its animation desync (RANDOM_START_TIMES), not flips.
static func variant_count_for(coord: Vector2i) -> int:
	if coord == interior_grass_coord():
		return GRASS_VARIANTS
	return 1

## Per-variant tile transform for the terrain variation system (#232). Index 0 is
## the base tile (identity); indices 1..3 mirror the SAME atlas region through the
## four flip orientations, relocating the tile's signature features so adjacent
## cells stop reading as one repeated stamp (a symmetric diamond stays a diamond
## under either flip). Modulate is left WHITE by design -- see GRASS_VARIANTS: the
## colour variation is a smooth world-space noise in the tint shader, not a per-
## tile step. Returns { "flip_h": bool, "flip_v": bool, "modulate": Color }.
## LEGACY note: the flip alternatives are still BUILT (existing saves reference
## alt 1..3 and the validator drops cells whose alt the source lacks) but the
## variation pass now assigns positional WINDOW tiles instead -- see below.
static func variant_transform(index: int) -> Dictionary:
	return {"flip_h": (index & 1) != 0, "flip_v": (index & 2) != 0, "modulate": Color.WHITE}

## --- Positional mega-tile windows (the real seam killer) --------------------
## A field of ONE repeated tile bitmap always reads as a grid. The atlas instead
## carries 32 grass and 32 water "window" tiles -- 128x64 diamond crops of one
## large SEAMLESS (torus-periodic) mega texture, cut at the exact screen offsets
## of the cells they land on. TerrainVariation assigns each cell the window for
## its position, so the artwork flows continuously across every tile edge.
##
## Indexing (mirrors tools/pack_terrain_atlas.py, the generator): screen-x
## depends only on p = x - y and screen-y only on q = x + y, so the window class
## is (a, b) = (posmod(p, 8), posmod(q, 8)). Two cells share a class iff their
## screen offset is a multiple of (512, 256) -- the mega texture's exact period
## -- making one crop correct everywhere its class appears. p and q always share
## parity, so only the 32 same-parity classes occur; index = a*4 + b/2 (0..31),
## stored as 8 atlas rows of 4. Windows carry NO flip alternatives: a flip would
## break the edge continuity that is the whole point.
const WINDOW_N := 8                       ## window classes per axis (p mod 8, q mod 8)
const GRASS_WINDOW_ROW0 := 6              ## atlas rows 6..13: grass windows
const WATER_WINDOW_ROW0 := 14             ## atlas rows 14..21: water windows (STATIC:
                                          ## desynced anim frames re-created a checkerboard)

## Window index (0..31) for `cell` -- pure positional math, no hashing.
static func window_index(cell: Vector2i) -> int:
	var a := posmod(cell.x - cell.y, WINDOW_N)
	var b := posmod(cell.x + cell.y, WINDOW_N)
	return a * 4 + b / 2

## Atlas coord of the grass window `cell` must display for seamless flow.
static func grass_window_coord(cell: Vector2i) -> Vector2i:
	var idx := window_index(cell)
	return Vector2i(idx % 4, GRASS_WINDOW_ROW0 + idx / 4)

## Atlas coord of the water window `cell` must display for seamless flow.
static func water_window_coord(cell: Vector2i) -> Vector2i:
	var idx := window_index(cell)
	return Vector2i(idx % 4, WATER_WINDOW_ROW0 + idx / 4)

## True when `coord` is one of the 32 grass window tiles.
static func is_grass_window_coord(coord: Vector2i) -> bool:
	return coord.x >= 0 and coord.x < 4 \
		and coord.y >= GRASS_WINDOW_ROW0 and coord.y < GRASS_WINDOW_ROW0 + 8

## True when `coord` is one of the 32 water window tiles.
static func is_water_window_coord(coord: Vector2i) -> bool:
	return coord.x >= 0 and coord.x < 4 \
		and coord.y >= WATER_WINDOW_ROW0 and coord.y < WATER_WINDOW_ROW0 + 8

## True when `coord` renders solid grass: the painted interior tile or any grass
## window. The variation pass, the doodad scatter, and save-normalization all key
## off this ONE predicate instead of assuming "interior grass == one coord".
static func is_grass_coord(coord: Vector2i) -> bool:
	return coord == interior_grass_coord() or is_grass_window_coord(coord)

## True when `coord` renders water: the legacy animated tile or any water window.
static func is_water_coord(coord: Vector2i) -> bool:
	return coord == WATER_ANIM_COORDS or is_water_window_coord(coord)
