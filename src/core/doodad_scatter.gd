class_name DoodadScatter
extends RefCounted
## Deterministic decor placement over candidate cells (#234, Tier 3). Pure integer
## logic: given the grass cells and a density, returns the doodads to spawn --
## { cell, type, variant, offset } -- chosen from an integer hash of each cell, so
## the layout is identical every run and survives reload WITHOUT persisting
## anything (re-derived on load, exactly like TerrainVariation). No Node deps.
##
## The look (which sprite region, base anchor) is DoodadCatalog; the runtime
## placement (Sprite2D under the tier's entity container) is DoodadPlacer; this
## only decides WHERE a doodad goes and WHICH one.

## Doodads for `cells` at `density_per_mille` (0..1000 = chance per candidate cell).
## Each entry: { "cell": Vector2i, "type": int, "variant": int, "offset": Vector2 }
## where offset is a deterministic sub-cell jitter so doodads are not dead-centre.
static func scatter(cells: Array[Vector2i], density_per_mille: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cell in cells:
		if _hash(cell.x, cell.y, 1) % 1000 >= density_per_mille:
			continue
		var type_row := DoodadCatalog.weighted_type(_hash(cell.x, cell.y, 2))
		var variant := _hash(cell.x, cell.y, 3) % DoodadCatalog.VARIANTS
		var jx := _hash(cell.x, cell.y, 4) % 1000
		var jy := _hash(cell.x, cell.y, 5) % 1000
		var offset := Vector2(
			(jx / 1000.0 - 0.5) * MapConstants.TILE_SIZE.x * 0.42,
			(jy / 1000.0 - 0.5) * MapConstants.TILE_SIZE.y * 0.42)
		out.append({"cell": cell, "type": type_row, "variant": variant, "offset": offset})
	return out

## Clustered scatter for TREES (#234 art pass): like scatter(), but gated by a
## low-frequency "grove" mask so trees appear in clumps of a few with open
## meadow between (never even-spaced -- lead-artist placement rule). `salt`
## separates the tree stream from the doodad stream. Entry shape:
## { "cell": Vector2i, "variant": int, "offset": Vector2 }.
static func scatter_clustered(cells: Array[Vector2i], density_per_mille: int, variants: int, salt: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cell in cells:
		# Grove gate: cells share a gate value over 4x4 blocks (arithmetic >> 2
		# floor-divides negatives correctly), so passing blocks form clumps.
		var gate := _hash(cell.x >> 2, cell.y >> 2, salt) % 1000
		if gate >= 320:
			continue
		if _hash(cell.x, cell.y, salt + 1) % 1000 >= density_per_mille:
			continue
		var variant := _hash(cell.x, cell.y, salt + 2) % variants
		var jx := _hash(cell.x, cell.y, salt + 3) % 1000
		var jy := _hash(cell.x, cell.y, salt + 4) % 1000
		var offset := Vector2(
			(jx / 1000.0 - 0.5) * MapConstants.TILE_SIZE.x * 0.5,
			(jy / 1000.0 - 0.5) * MapConstants.TILE_SIZE.y * 0.5)
		out.append({"cell": cell, "variant": variant, "offset": offset})
	return out

## Non-negative 31-bit hash of a cell + a salt (so the placement decision, type,
## variant and the two jitter axes each draw from an independent stream). Masks to
## 31 bits after the first combine so later shifts stay logical for negative cells.
static func _hash(x: int, y: int, salt: int) -> int:
	var h := (x * 73856093) ^ (y * 19349663) ^ (salt * 83492791)
	h = h & 0x7fffffff
	h = (h * 2654435761) & 0x7fffffff
	h = (h ^ (h >> 13)) & 0x7fffffff
	return h
