class_name TileSetConstants
extends RefCounted
## Single source of truth for the terrain atlas layout. Read read-only by the
## tileset builder, the dual-grid autotiler, and the water animation driver.
## REGION_SIZE mirrors MapConstants.TILE_SIZE -- the single source of truth for
## tile geometry itself stays MapConstants; this module only describes how the
## placeholder atlas at assets/tilesets/terrain_atlas.png is carved into regions.

const REGION_SIZE := Vector2i(128, 64)          ## == MapConstants.TILE_SIZE; HD 2:1 diamond
const ATLAS_PX := Vector2i(512, 320)            ## 4 cols x 5 rows of 128x64 regions
const DUALGRID_ORIGIN := Vector2i(0, 0)         ## atlas coord of the 4x4 dual-grid block's top-left cell

## Committed atlas assets. ATLAS_PATH is the diffuse art; NORMAL_ATLAS_PATH is the
## L1-generated tangent-space normal map (#82) paired with it via a CanvasTexture
## so Light2D shades the diamonds with relief (#84). Single source of truth for
## both paths -- map_editor and the dev-menu catalog load from here.
const ATLAS_PATH := "res://assets/tilesets/terrain_atlas.png"
const NORMAL_ATLAS_PATH := "res://assets/tilesets/terrain_atlas_n.png"

const WATER_ANIM_COORDS := Vector2i(0, 4)       ## atlas coord (col,row) of the animated water base tile (row 4)
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
