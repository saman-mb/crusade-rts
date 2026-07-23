extends GdTest
## Pure-math tests for UnitState (#75): a unit's discrete `{cell, tier}` slot plus
## its continuous `world_pos`, composed entirely from EntityPlacement. No TileSet /
## Node deps required.
## Run: godot --headless --script res://src/core/tests/test_unit_state.gd
##
## The guarantees under test: construction snaps `world_pos` onto the tier-lifted
## `visual_position`; the derived sort anchor `ground_position()` strips that lift
## so it is tier-INDEPENDENT and equals EntityPlacement.ground_position(cell); the
## `ground_position() == world_pos - visual_offset(tier)` split holds even when
## `world_pos` is moved off-center by steering; and `world_pos` lives in the one
## shared lifted space that both EntityPlacement and NavRamp key off.


func _run() -> void:
	_test_construction_snaps_to_visual_position()
	_test_anchor_tier_independent()
	_test_art_offset_single_source()
	_test_off_center_invariant()
	_test_space_agreement_with_nav_ramp()
	_test_place_at_resnaps()


# --- helpers ---

## Approximate Vector2 equality via distance (iso math returns floats).
func _v_approx(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.001


# --- tests ---

## A freshly-constructed unit sits dead-centered on its cell, lifted onto its tier:
## `world_pos` is exactly EntityPlacement.visual_position(cell, tier).
func _test_construction_snaps_to_visual_position() -> void:
	for x in range(-3, 4):
		for y in range(-3, 4):
			var cell := Vector2i(x, y)
			for tier in range(0, 3):
				var u := UnitState.new(cell, tier)
				_ok(_v_approx(u.world_pos, EntityPlacement.visual_position(cell, tier)),
					"world_pos(%s,%d) == visual_position" % [cell, tier])

## THE interleaving guarantee for units: the sort anchor takes no tier. For a fixed
## cell, a unit freshly constructed on tier 0, 1 or 2 has the SAME `ground_position()`,
## and it equals EntityPlacement.ground_position(cell) -- the lift is fully stripped
## back out, so the unit sorts at its footprint depth on every tier.
func _test_anchor_tier_independent() -> void:
	for x in range(-3, 4):
		for y in range(-3, 4):
			var cell := Vector2i(x, y)
			var expected := EntityPlacement.ground_position(cell)
			var anchor0 := UnitState.new(cell, 0).ground_position()
			var anchor1 := UnitState.new(cell, 1).ground_position()
			var anchor2 := UnitState.new(cell, 2).ground_position()
			_ok(_v_approx(anchor0, expected), "ground_position(%s, tier0) == EntityPlacement.ground_position" % cell)
			_ok(_v_approx(anchor1, expected), "ground_position(%s, tier1) == EntityPlacement.ground_position" % cell)
			_ok(_v_approx(anchor2, expected), "ground_position(%s, tier2) == EntityPlacement.ground_position" % cell)
			_ok(_v_approx(anchor0, anchor1) and _v_approx(anchor1, anchor2),
				"ground_position of %s equal across tiers 0/1/2" % cell)

## `art_offset()` is the tier's visual raise, sourced from EntityPlacement (never
## re-derived): exactly EntityPlacement.visual_offset(tier).
func _test_art_offset_single_source() -> void:
	for tier in range(0, 4):
		var u := UnitState.new(Vector2i.ZERO, tier)
		_ok(u.art_offset() == EntityPlacement.visual_offset(tier),
			"art_offset(%d) == EntityPlacement.visual_offset(%d)" % [tier, tier])

## The off-center invariant: after steering moves `world_pos` to an arbitrary point
## that is NO cell center, the sort anchor still equals `world_pos - visual_offset(tier)`
## EXACTLY -- the origin/art split is defined against the live position, not the snap.
func _test_off_center_invariant() -> void:
	for tier in range(0, 3):
		var u := UnitState.new(Vector2i(2, -1), tier)
		u.world_pos = Vector2(137.5, -42.25)
		_ok(u.ground_position() == u.world_pos - EntityPlacement.visual_offset(tier),
			"off-center ground_position == world_pos - visual_offset (tier %d)" % tier)
		_ok(u.ground_position() + u.art_offset() == u.world_pos,
			"ground_position + art_offset reproduces world_pos (tier %d)" % tier)

## `world_pos` lives in the SAME lifted space the nav mesh keys off: for a spread of
## cells x tiers, EntityPlacement.visual_position == NavRamp.endpoint_world_pos. This
## locks unit positions and ramp endpoints to one coordinate space, so a unit snapped
## onto a ramp endpoint lands exactly on it.
func _test_space_agreement_with_nav_ramp() -> void:
	for x in range(-3, 4):
		for y in range(-3, 4):
			var cell := Vector2i(x, y)
			for tier in range(0, 3):
				_ok(_v_approx(EntityPlacement.visual_position(cell, tier), NavRamp.endpoint_world_pos(cell, tier)),
					"visual_position(%s,%d) == NavRamp.endpoint_world_pos" % [cell, tier])

## `place_at` re-snaps all three fields together: cell, tier, and `world_pos` back
## onto the new slot's lifted center, discarding any prior off-center offset.
func _test_place_at_resnaps() -> void:
	var u := UnitState.new(Vector2i(0, 0), 0)
	u.world_pos = Vector2(999.0, 999.0)  # smear it off-center first
	var new_cell := Vector2i(4, -2)
	var new_tier := 2
	u.place_at(new_cell, new_tier)
	_ok(u.cell == new_cell, "place_at updates cell")
	_ok(u.tier == new_tier, "place_at updates tier")
	_ok(_v_approx(u.world_pos, EntityPlacement.visual_position(new_cell, new_tier)),
		"place_at re-snaps world_pos to new visual_position")
