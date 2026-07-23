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

## MapSystem instance — held UNTYPED (no class_name; duck-typed API).
var _map_system

## Pure cores driving this node.
var _state: UnitState
var _follower: PathFollower


## Spawn the unit into `{cell, tier}` on `p_map_system`: build the cores, give the
## sprite its placeholder texture, reparent under the tier's entity container, and
## place the node origin at the footprint with the sprite raised onto the tier.
func setup(p_map_system, cell: Vector2i, tier: int) -> void:
	_map_system = p_map_system
	_state = UnitState.new(cell, tier)
	_follower = PathFollower.new()

	var sprite: Sprite2D = $Sprite2D
	sprite.texture = _build_placeholder_texture()

	_reparent_to_tier(tier)

	position = _state.ground_position()
	sprite.position = _state.art_offset()


## Hand the follower a fresh waypoint list to walk (Array of Vector2 world points).
func issue_path(waypoints: Array) -> void:
	_follower.set_path(waypoints)


## The unit's current discrete cell — the spawner uses this as the `from` cell when
## it asks the nav layer for a path.
func current_cell() -> Vector2i:
	return _state.cell


## The unit's current elevation tier.
func current_tier() -> int:
	return _state.tier


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
