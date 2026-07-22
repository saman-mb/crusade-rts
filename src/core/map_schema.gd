class_name MapSchema
extends RefCounted
## Single source of truth for the map-file schema contract. Every field name,
## version, and limit lives here so the validator (#7 Unit B), the migrator
## (#7 Unit C), and the future serializer (#5) all import from one place.
##
## Encoding is JSON-native: a Vector2i is flattened to a two-element [x, y]
## array, and all JSON numbers decode as float -- so readers cast back with
## int() when they need integer cell/atlas coords. The root object carries a
## schema_version; readers migrate an older document UP to CURRENT_SCHEMA
## before consuming it. Writers only ever emit CURRENT_SCHEMA.

const CURRENT_SCHEMA := 2   ## bump when the on-disk shape changes; writers emit only this.
const MAX_COORD := 4096     ## abs bound on cell x/y -- keeps coords well inside float's safe-int range.

## Root object key names.
const KEY_SCHEMA_VERSION := "schema_version"   ## -> int document schema version
const KEY_LAYERS := "layers"                   ## -> array of layer objects

## Layer object key names.
const KEY_LAYER_NAME := "name"                  ## -> String layer name
const KEY_LAYER_ELEVATION := "elevation"        ## -> int elevation level
const KEY_LAYER_KIND := "kind"                  ## -> String layer kind (additive optional, default LAYER_KIND_TERRAIN; no version bump)

## Layer kinds. Terrain layers are keyed by elevation into the elevation stack;
## the single objects overlay is routed by kind, NOT by elevation (it sits at the
## OBJECTS_ELEVATION sentinel so it can never collide with an elevation slot). (#43)
const LAYER_KIND_TERRAIN := "terrain"           ## elevation-indexed terrain layer (the default)
const LAYER_KIND_OBJECTS := "objects"           ## the object-overlay layer
const LAYER_NAME_OBJECTS := "objects"           ## default name written for the objects layer
const OBJECTS_ELEVATION := -1                   ## sentinel elevation for the objects layer (not a real elevation index)

## Cell object key names (kept terse to shrink on-disk size).
const KEY_CELLS := "cells"          ## -> array of cell objects
const KEY_CELL_POS := "p"           ## -> [x, y]
const KEY_CELL_SOURCE := "s"        ## -> int source id
const KEY_CELL_ATLAS := "a"         ## -> [ax, ay]
const KEY_CELL_ALT := "alt"         ## -> int alternative_tile (additive optional field, default 0; no version bump)

const TILE_SHAPE_NAME := "isometric"   ## written into the doc's tile_shape metadata.

## Metadata / provenance root key names (additive; readers may ignore them).
const KEY_TILE_SHAPE := "tile_shape"                  ## -> String, metadata (== TILE_SHAPE_NAME)
const KEY_TILE_SIZE := "tile_size"                    ## -> [w, h] metadata
const KEY_GENERATED_BY := "generated_by"              ## -> String provenance tag
const GENERATED_BY_NAME := "crusade-rts editor"       ## value written into KEY_GENERATED_BY

## Minimal set of root keys a document must carry to be usable.
const REQUIRED_ROOT_KEYS: Array[String] = [KEY_SCHEMA_VERSION, KEY_LAYERS]

## True when `doc` is a Dictionary carrying every REQUIRED_ROOT_KEYS entry. The
## validator enforces this so the constant is a live contract, not just an
## advertised intent -- a raw doc missing schema_version is rejected rather than
## quietly assumed migrated. (#41)
static func has_required_root_keys(doc: Variant) -> bool:
	if typeof(doc) != TYPE_DICTIONARY:
		return false
	for key: String in REQUIRED_ROOT_KEYS:
		if not (doc as Dictionary).has(key):
			return false
	return true

## Expected tile geometry, derived from MapConstants so map geometry never
## drifts from the single source of truth (do NOT hardcode 128x64 here).
static func expected_tile_size() -> Vector2i:
	return MapConstants.TILE_SIZE
