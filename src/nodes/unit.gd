extends Node2D
## The Unit node: a moving game entity on the stacked isometric elevation terrain
## (#75/#76). A plain `Node2D` root with a `Sprite2D` child, driven by two pure
## cores built by siblings: `UnitState` (src/core/unit_state.gd) holds the
## discrete slot + continuous position, and `PathFollower` (src/core/path_follower.gd)
## walks a waypoint list. This node is the thin runtime glue that binds those cores
## to the scene tree and to `MapSystem`'s per-tier entity containers.
##
## PLACEMENT CONTRACT (docs/ENTITY_SORTING.md, EntityPlacement): the Unit's NODE
## ORIGIN sits at the unlifted footprint (`state.ground_position()`) so it sorts by
## footprint depth exactly like that tier's floor tile; the SPRITE CHILD is raised
## by `state.art_offset()` (= `EntityPlacement.visual_offset(tier)`) so the drawn
## body stands ON the tier without moving the sort anchor. origin sorts, art draws.
## The unit is parented under `map_system.entity_parent_for_tier(tier)`, a plain
## Y-sorted container; a tier change is a clean reparent + art-offset update.
##
## CI-parse-only (src/nodes/*): every var is explicitly typed (no `:=` inferred from
## a Variant), and `_map_system` is kept UNTYPED because MapSystem carries no
## `class_name` and is duck-typed, exactly as map_editor.gd / entity_sort_harness.gd.

## Placeholder sprite geometry, in pixels. A small bright rectangle built in code so
## the node has no committed art dependency (the real sprite lands with #33 art).
const PLACEHOLDER_SIZE := Vector2i(20, 36)
const PLACEHOLDER_COLOR := Color(1.0, 0.0, 1.0)  ## bright magenta

## Selection-ring geometry, built in code (no committed art). A placeholder
## yellow-green so it reads as a highlight until final art lands (#33).
const RING_COLOR := Color(0.7, 1.0, 0.2)  ## bright yellow-green
const RING_WIDTH := 3.0

## MapSystem instance — held UNTYPED (no class_name; duck-typed API).
var _map_system

## Pure cores driving this node.
var _state: UnitState
var _follower: PathFollower

## World-space selection ring at the footprint (node origin). Built + added as the
## FIRST child in `setup()` so it draws UNDER the raised Sprite2D; default hidden.
var _ring: Line2D


## Spawn the unit into `{cell, tier}` on `p_map_system`: build the cores, give the
## sprite its placeholder texture, reparent under the tier's entity container, and
## place the node origin at the footprint with the sprite raised onto the tier.
func setup(p_map_system, cell: Vector2i, tier: int) -> void:
	_map_system = p_map_system
	_state = UnitState.new(cell, tier)
	_follower = PathFollower.new()

	var sprite: Sprite2D = $Sprite2D
	sprite.texture = _build_placeholder_texture()

	_build_selection_ring()

	_reparent_to_tier(tier)

	position = _state.ground_position()
	sprite.position = _state.art_offset()


## Hand the follower a fresh waypoint list to walk — the Array of { cell, tier }
## dictionaries that NavGraph.find_path returns (empty Array = no route → no-op).
func issue_path(waypoints: Array) -> void:
	_follower.set_path(waypoints)


## The unit's current discrete cell — the spawner uses this as the `from` cell when
## it asks the nav layer for a path.
func current_cell() -> Vector2i:
	return _state.cell


## The unit's current elevation tier.
func current_tier() -> int:
	return _state.tier


## Toggles the world-space selection ring at the unit's footprint. Pure view — no
## UnitState change; the ring sits at the node origin (footprint) so it never
## perturbs the origin's sort key (docs/ENTITY_SORTING.md).
func set_selected(p_selected: bool) -> void:
	# Null-safe: the ring is built in setup(), so a call before setup is a no-op
	# rather than a crash.
	if _ring == null:
		return
	_ring.visible = p_selected


func _process(delta: float) -> void:
	if not _follower.has_path():
		return

	var r: Dictionary = _follower.advance(_state.world_pos, delta)
	var rpos: Vector2 = r["pos"]
	var rcell: Vector2i = r["cell"]
	var rtier: int = r["tier"]

	_state.world_pos = rpos

	if rtier != _state.tier:
		# Tier handoff: raise the art onto the new tier now, and move the node into
		# the new tier's container. The reparent is DEFERRED — detaching/re-attaching
		# self synchronously inside _process is unsafe tree mutation; the containers
		# all sit at the origin in one Y-sort space, so a one-idle-frame delay is
		# invisible (the node's origin/position is unchanged in the meantime).
		var sprite: Sprite2D = $Sprite2D
		sprite.position = EntityPlacement.visual_offset(rtier)
		_reparent_to_tier.call_deferred(rtier)

	_state.tier = rtier
	_state.cell = rcell
	position = _state.ground_position()


## Reparent this unit under `entity_parent_for_tier(tier)`. Null-safe: if MapSystem
## hands back no container for the tier, keep the current parent (never detach into
## limbo). Idempotent (no-op when already under the right container), so it is safe
## to `call_deferred` from `_process` on a tier handoff. Used directly (not deferred)
## from `setup`, where the node is not yet inside the tree.
func _reparent_to_tier(tier: int) -> void:
	var new_parent: Node2D = _map_system.entity_parent_for_tier(tier)
	if new_parent == null:
		return
	var old_parent: Node = get_parent()
	if old_parent == new_parent:
		return
	if old_parent != null:
		old_parent.remove_child(self)
	new_parent.add_child(self)


## Build the placeholder sprite texture in code (a solid bright rectangle) so the
## node depends on no committed art asset.
func _build_placeholder_texture() -> ImageTexture:
	var image: Image = Image.create(PLACEHOLDER_SIZE.x, PLACEHOLDER_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(PLACEHOLDER_COLOR)
	return ImageTexture.create_from_image(image)


## Build the selection ring in code (no committed art): a closed Line2D tracing the
## footprint iso diamond around the node origin (0,0), so it draws on the ground
## plane at the footprint — NOT raised by the art offset. Added as the FIRST child
## so the raised Sprite2D draws over it; cached in `_ring`; hidden by default.
func _build_selection_ring() -> void:
	var half_x: float = MapConstants.TILE_SIZE.x / 2.0
	var half_y: float = MapConstants.TILE_SIZE.y / 2.0
	_ring = Line2D.new()
	_ring.name = "SelectionRing"
	_ring.position = Vector2.ZERO
	_ring.points = PackedVector2Array([
		Vector2(0.0, -half_y),  # top
		Vector2(half_x, 0.0),   # right
		Vector2(0.0, half_y),   # bottom
		Vector2(-half_x, 0.0),  # left
	])
	_ring.closed = true
	_ring.width = RING_WIDTH
	_ring.default_color = RING_COLOR
	_ring.visible = false
	add_child(_ring)
	move_child(_ring, 0)
