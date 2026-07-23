extends GdTest
## Pure-math tests for EntityPlacement (#107): the entity depth-sorting contract
## on elevated terrain. No TileSet / Node deps required.
## Run: godot --headless --script res://src/core/tests/test_entity_placement.gd
##
## The central guarantee under test is that an entity's sort anchor
## (`ground_position`) is INDEPENDENT of its tier, so a unit on a raised tier
## sorts at exactly the footprint depth of that tier's floor tile and interleaves
## with the terrain correctly. Elevation lives only in `visual_offset`, a draw
## raise that never touches the sort anchor.


func _run() -> void:
	_test_ground_position_delegates()
	_test_ground_position_tier_independent()
	_test_tier_zero_neutral()
	_test_visual_offset_single_source()
	_test_visual_position_composition()


# --- helpers ---

## Approximate Vector2 equality via distance (iso math returns floats).
func _v_approx(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.001


# --- tests ---

## The sort anchor is just the unlifted diamond center — it delegates to IsoCoord
## with no extra offset, so an entity sorts exactly like the floor tile it stands on.
func _test_ground_position_delegates() -> void:
	for x in range(-3, 4):
		for y in range(-3, 4):
			var cell := Vector2i(x, y)
			_ok(_v_approx(EntityPlacement.ground_position(cell), IsoCoord.cart_to_iso(cell)),
				"ground_position(%s) == cart_to_iso" % cell)

## THE interleaving guarantee: `ground_position` takes no tier and never bakes in
## the lift, so an entity's sort depth is its footprint depth on every tier — the
## sort anchor for cell C is byte-identical whether the unit is on tier 0, 1 or 2.
func _test_ground_position_tier_independent() -> void:
	for x in range(-3, 4):
		for y in range(-3, 4):
			var cell := Vector2i(x, y)
			var anchor := EntityPlacement.ground_position(cell)
			_ok(is_equal_approx(anchor.y, IsoCoord.cart_to_iso(cell).y),
				"sort anchor of %s is footprint depth, tier-independent" % cell)

## Tier 0 (ground) is a pure no-op: no visual raise, so flat single-tier maps
## behave exactly as if EntityPlacement were not involved.
func _test_tier_zero_neutral() -> void:
	_ok(EntityPlacement.visual_offset(0) == Vector2.ZERO, "visual_offset(0) is ZERO")

## The visual raise is sourced from MapConstants, never re-derived: it is exactly
## elevation_offset(tier) (== Vector2(0, -ELEVATION_STEP_PX * tier)).
func _test_visual_offset_single_source() -> void:
	for tier in range(0, 4):
		_ok(EntityPlacement.visual_offset(tier) == MapConstants.elevation_offset(tier),
			"visual_offset(%d) == MapConstants.elevation_offset(%d)" % [tier, tier])
		_ok(is_equal_approx(EntityPlacement.visual_offset(tier).y, float(-MapConstants.ELEVATION_STEP_PX * tier)),
			"visual_offset(%d).y == -ELEVATION_STEP_PX * %d" % [tier, tier])

## visual_position composes the sort anchor and the raise: it is where the art's
## anchor lands on screen, footprint + lift. Crucially its Y differs from the sort
## anchor by exactly the lift, proving the raise is a draw offset kept OUT of
## `ground_position` (the sort key).
func _test_visual_position_composition() -> void:
	for x in range(-3, 4):
		for y in range(-3, 4):
			var cell := Vector2i(x, y)
			for tier in range(0, 4):
				var vp := EntityPlacement.visual_position(cell, tier)
				var expected := EntityPlacement.ground_position(cell) + EntityPlacement.visual_offset(tier)
				_ok(_v_approx(vp, expected),
					"visual_position(%s,%d) == ground + visual_offset" % [cell, tier])
				var lift := vp.y - EntityPlacement.ground_position(cell).y
				_ok(is_equal_approx(lift, float(-MapConstants.ELEVATION_STEP_PX * tier)),
					"visual_position raises art by the lift only, sort anchor untouched (%s,%d)" % [cell, tier])
