class_name TileSetConstants
extends RefCounted
## Single source of truth for the terrain atlas layout. Read read-only by the
## tileset builder, the dual-grid autotiler, and the water animation driver.
## REGION_SIZE mirrors MapConstants.TILE_SIZE -- the single source of truth for
## tile geometry itself stays MapConstants; this module only describes how the
## real CC0 terrain atlas at assets/tilesets/terrain_atlas.png (see CREDITS.md) is
## carved into regions.

const REGION_SIZE := Vector2i(128, 64)          ## == MapConstants.TILE_SIZE; HD 2:1 diamond
const ATLAS_PX := Vector2i(512, 384)            ## 4 cols x 6 rows of 128x64 regions (row 5 = ramp tile)
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

## True when a tile at `coord` is walkable (i.e. not in the exceptions allowlist).
static func coord_walkable(coord: Vector2i) -> bool:
	return not NON_WALKABLE_COORDS.has(coord)

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
