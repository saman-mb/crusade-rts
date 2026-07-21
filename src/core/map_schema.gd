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

## Cell object key names (kept terse to shrink on-disk size).
const KEY_CELLS := "cells"          ## -> array of cell objects
const KEY_CELL_POS := "p"           ## -> [x, y]
const KEY_CELL_SOURCE := "s"        ## -> int source id
const KEY_CELL_ATLAS := "a"         ## -> [ax, ay]

const TILE_SHAPE_NAME := "isometric"   ## written into the doc's tile_shape metadata.

## Minimal set of root keys a document must carry to be usable.
const REQUIRED_ROOT_KEYS: Array[String] = [KEY_SCHEMA_VERSION, KEY_LAYERS]

## Expected tile geometry, derived from MapConstants so map geometry never
## drifts from the single source of truth (do NOT hardcode 128x64 here).
static func expected_tile_size() -> Vector2i:
	return MapConstants.TILE_SIZE
