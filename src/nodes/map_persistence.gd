extends Node2D
## Dev-loop save/reload for maps: F6 saves the current layers to JSON (atomic),
## F5 reloads from disk, so an externally-edited or editor-painted map updates
## instantly in a running debug build.
##
## Godot does not hot-reload data files (only scripts/scenes), so this implements
## that manually against the A/B/C cores (MapSerializer / MapFileIO / MapLoader).
## Debug-build only: the input handling and optional mtime polling early-out
## unless `OS.is_debug_build()`, so this stays inert in shipped builds.
##
## This is a RUNTIME node (not `@tool`), so none of this executes during a
## headless `--import` in CI.

@export_group("Map Persistence")
## The MapSystem whose elevation stack + objects overlay are saved/loaded.
@export var map_system_path: NodePath
## The target map file.
@export var current_map_path: String = "user://maps/dev_map.json"
## When true, poll the file's mtime and reload on change.
@export var auto_reload: bool = false
## Seconds between mtime polls.
@export var auto_reload_interval: float = 1.0

## The resolved MapSystem node. Typed via class_name (#105): its
## `get_elevation_layer()` / `elevation_layers` / `objects_layer` API resolves
## statically on the MapSystem type.
var _map_system: MapSystem
## Live TileSet the MapEditor built, shared across the elevation layers.
var _tile_set: TileSet
## Last-seen modified time of `current_map_path`, for auto-reload polling.
var _last_mtime: int = 0
## Accumulated seconds since the last mtime poll.
var _poll_accum: float = 0.0


func _ready() -> void:
	# Defer binding by one step: our sibling MapSystem fills its @onready
	# `elevation_layers` (and the MapEditor builds the shared TileSet) only when
	# their `_ready` runs. A deferred call runs after the whole tree has finished
	# readying, so the layers and tileset are populated when we query them.
	_setup.call_deferred()


func _setup() -> void:
	_map_system = get_node_or_null(map_system_path) as MapSystem
	if _map_system == null:
		push_warning("map_persistence: map_system_path unresolved; persistence is inert.")
		return
	# Grab the live TileSet the editor built so reloads resolve tiles identically.
	var l0 := _map_system.get_elevation_layer(0) as TileMapLayer
	if l0 != null:
		_tile_set = l0.tile_set
	# Record the current mtime but do NOT auto-load on start: the editor owns the
	# initial paint; reload is explicit (F5 or auto_reload polling).
	_last_mtime = MapFileIO.modified_time(current_map_path)


## Returns the MapSystem's elevation layers, or an empty typed array when unbound.
func _layers() -> Array[TileMapLayer]:
	if _map_system != null:
		return _map_system.elevation_layers
	var empty: Array[TileMapLayer] = []
	return empty


## The MapSystem's Objects overlay layer, or null when unbound. Typed via
## class_name (#105): the `objects_layer` property resolves on the MapSystem type.
func _objects() -> TileMapLayer:
	if _map_system == null:
		return null
	return _map_system.objects_layer


func _unhandled_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if event.is_action_pressed("dev_reload_map"):
		_reload()
	elif event.is_action_pressed("dev_save_map"):
		_save()


## Reloads the map file from disk into the live elevation layers.
func _reload() -> void:
	if _map_system == null:
		return
	# Re-read the layer-0 TileSet FRESH each reload (#102) rather than trusting the value
	# cached in _setup(): the DevMenu can swap the live TileSet after boot (a stale cache
	# would validate against the wrong set), and it may still have been null when _setup()
	# ran (a null cache would kill reload for the whole session). Reading here fixes both,
	# plus the node-ordering dependency, in one place.
	var l0 := _map_system.get_elevation_layer(0) as TileMapLayer
	if l0 != null:
		_tile_set = l0.tile_set
	# Without a bound TileSet the validator would drop every cell AFTER the loader
	# has already cleared the layers -- a reload in that window would blank the map.
	# Skip only when the TileSet is GENUINELY still unbound at reload time (honest warning).
	if _tile_set == null:
		push_warning("reload: TileSet not bound yet; skipping to avoid clearing the map.")
		return
	var r := MapFileIO.load_text(current_map_path)
	if not r["ok"]:
		push_warning("reload: %s not found" % current_map_path)
		return
	var res := MapLoader.load_map(r["text"], _layers(), _objects(), _tile_set)
	print("[MapPersistence] reloaded %s (ok=%s, %d diagnostics)" % [current_map_path, res["ok"], (res["diagnostics"] as Array).size()])
	# The freshly-loaded extent replaces whatever was painted. Announce it through the
	# MapSystem hub (#95): the camera clamp is now a map_changed SUBSCRIBER, so this no
	# longer pokes refresh_camera_bounds() by name (#17 bounds still refresh, via the
	# signal). Only emit on a successful load -- a refused load (e.g. out-of-range
	# elevation, #106) leaves the layers untouched, so there is nothing to announce.
	if res["ok"]:
		_map_system.emit_map_changed_all()
	_last_mtime = MapFileIO.modified_time(current_map_path)


## Serializes the live elevation stack + objects overlay to JSON, atomically. (#43)
func _save() -> void:
	if _map_system == null:
		return
	var doc := MapSerializer.serialize_map(_layers(), _objects())
	var ok := MapFileIO.save_text(current_map_path, MapSerializer.to_json(doc))
	print("[MapPersistence] saved %s (ok=%s)" % [current_map_path, ok])
	_last_mtime = MapFileIO.modified_time(current_map_path)


func _process(delta: float) -> void:
	if auto_reload and OS.is_debug_build() and _map_system != null:
		_poll_accum += delta
		if _poll_accum >= auto_reload_interval:
			_poll_accum = 0.0
			var m := MapFileIO.modified_time(current_map_path)
			if m > _last_mtime:
				_reload()
