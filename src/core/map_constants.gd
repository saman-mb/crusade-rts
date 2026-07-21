class_name MapConstants
extends RefCounted
## Single source of truth for isometric tile geometry & elevation offsets.
## Both the map scene's per-layer transforms and any runtime entities on
## elevated tiles must derive their vertical offset from ELEVATION_STEP_PX.

const TILE_SIZE := Vector2i(128, 64)   ## true 2:1 HD isometric diamond
const ELEVATION_STEP_PX := 32          ## = TILE_SIZE.y / 2

## Vertical pixel offset for a given integer elevation level (0, 1, 2, ...).
static func elevation_offset(level: int) -> Vector2:
	return Vector2(0, -ELEVATION_STEP_PX * level)
