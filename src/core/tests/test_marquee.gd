extends GdTest
## Pure-geometry tests for Marquee (#81): the drag-rectangle multi-select hit-test.
## No TileSet / Node deps required.
## Run: godot --headless --script res://src/core/tests/test_marquee.gd
##
## The guarantees under test: a unit whose `pos` is inside the rect on the active
## tier is returned and one outside is excluded; membership is top-left-INCLUSIVE /
## bottom-right-EXCLUSIVE (Godot `Rect2.has_point` semantics, locked in below); an
## empty / zero-size rect selects nothing; a unit on a different tier is excluded
## even when geometrically inside; the result is sorted ascending and duplicate-free
## regardless of snapshot order; and a rect covering everything returns every id on
## the active tier.


func _run() -> void:
	_test_basic_membership()
	_test_inclusive_top_left_edge()
	_test_exclusive_bottom_right_edge()
	_test_empty_rect()
	_test_zero_size_rect()
	_test_negative_size_rect()
	_test_tier_filtering()
	_test_sorted_and_dedup()
	_test_covering_rect_returns_all_on_tier()


# --- helpers ---

## Exact equality of two typed int arrays with an expected/got diagnostic.
func _ids_eq(a: Array[int], b: Array[int], msg: String) -> void:
	_ok(a == b, "%s: expected %s got %s" % [msg, b, a])


# --- tests ---

## A unit inside the rect is returned; one outside is excluded.
func _test_basic_membership() -> void:
	var entries: Array = [
		{"id": 1, "pos": Vector2(5, 5), "tier": 0},
		{"id": 2, "pos": Vector2(50, 50), "tier": 0},
	]
	var rect := Rect2(0, 0, 10, 10)
	_ids_eq(Marquee.ids_in_rect(entries, rect, 0), [1] as Array[int], "inside kept, outside dropped")


## Top-left corner is INCLUSIVE: a unit exactly on `rect.position` is inside.
func _test_inclusive_top_left_edge() -> void:
	var entries: Array = [
		{"id": 7, "pos": Vector2(0, 0), "tier": 0},
	]
	var rect := Rect2(0, 0, 10, 10)
	_ids_eq(Marquee.ids_in_rect(entries, rect, 0), [7] as Array[int], "top-left corner inclusive")


## Bottom-right edge is EXCLUSIVE: a unit exactly on `position + size` is outside.
func _test_exclusive_bottom_right_edge() -> void:
	var entries: Array = [
		{"id": 8, "pos": Vector2(10, 10), "tier": 0},
	]
	var rect := Rect2(0, 0, 10, 10)
	_ids_eq(Marquee.ids_in_rect(entries, rect, 0), [] as Array[int], "bottom-right corner exclusive")


## An empty rect (zero size at origin) selects nothing.
func _test_empty_rect() -> void:
	var entries: Array = [
		{"id": 1, "pos": Vector2(0, 0), "tier": 0},
	]
	_ids_eq(Marquee.ids_in_rect(entries, Rect2(), 0), [] as Array[int], "empty rect -> []")


## A zero-size rect at a real position still selects nothing (degenerate drag).
func _test_zero_size_rect() -> void:
	var entries: Array = [
		{"id": 1, "pos": Vector2(5, 5), "tier": 0},
	]
	_ids_eq(Marquee.ids_in_rect(entries, Rect2(5, 5, 0, 0), 0), [] as Array[int], "zero-size rect -> []")


## A negative-size component (defensive: un-normalized input) is treated as empty.
func _test_negative_size_rect() -> void:
	var entries: Array = [
		{"id": 1, "pos": Vector2(5, 5), "tier": 0},
	]
	_ids_eq(Marquee.ids_in_rect(entries, Rect2(10, 10, -8, -8), 0), [] as Array[int], "negative-size rect -> []")


## A unit inside the rect but on a different tier is excluded.
func _test_tier_filtering() -> void:
	var entries: Array = [
		{"id": 1, "pos": Vector2(5, 5), "tier": 0},
		{"id": 2, "pos": Vector2(6, 6), "tier": 1},
	]
	var rect := Rect2(0, 0, 10, 10)
	_ids_eq(Marquee.ids_in_rect(entries, rect, 0), [1] as Array[int], "other-tier unit excluded")


## Snapshot fed out of id order comes back sorted ascending and de-duplicated.
func _test_sorted_and_dedup() -> void:
	var entries: Array = [
		{"id": 9, "pos": Vector2(1, 1), "tier": 0},
		{"id": 2, "pos": Vector2(2, 2), "tier": 0},
		{"id": 5, "pos": Vector2(3, 3), "tier": 0},
		{"id": 2, "pos": Vector2(4, 4), "tier": 0},
	]
	var rect := Rect2(0, 0, 10, 10)
	_ids_eq(Marquee.ids_in_rect(entries, rect, 0), [2, 5, 9] as Array[int], "sorted ascending, no dupes")


## A rect covering all units returns every id on the active tier (and nothing off it).
func _test_covering_rect_returns_all_on_tier() -> void:
	var entries: Array = [
		{"id": 3, "pos": Vector2(1, 1), "tier": 0},
		{"id": 1, "pos": Vector2(2, 2), "tier": 0},
		{"id": 4, "pos": Vector2(3, 3), "tier": 1},
		{"id": 2, "pos": Vector2(4, 4), "tier": 0},
	]
	var rect := Rect2(0, 0, 1000, 1000)
	_ids_eq(Marquee.ids_in_rect(entries, rect, 0), [1, 2, 3] as Array[int], "covering rect -> all tier-0 ids")
