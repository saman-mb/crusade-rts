extends GdTest
## Pure-set tests for Selection (#77): the replace / additive / toggle / clear
## lifecycle, the sorted-on-read determinism guarantee, and the static `unit_at`
## hit-test. No TileSet / Node deps required.
## Run: godot --headless --script res://src/core/tests/test_selection.gd
##
## The guarantees under test: a fresh Selection is empty; `select_only` replaces
## whatever was there with a single id; `add` accumulates; `toggle` flips a single
## id in or out; `clear` empties; `selected_ids()` is always sorted ascending
## regardless of insertion order; and `unit_at` returns the first (cell,tier)-match
## by array order, or -1 when nothing matches.


func _run() -> void:
	_test_fresh_is_empty()
	_test_select_only()
	_test_select_only_replaces()
	_test_add_is_additive()
	_test_toggle_removes_and_readds()
	_test_toggle_absent_adds()
	_test_clear()
	_test_is_selected_unknown()
	_test_selected_ids_sorted()
	_test_unit_at()


# --- helpers ---

## Exact equality of two typed int arrays with an expected/got diagnostic.
func _ids_eq(a: Array[int], b: Array[int], msg: String) -> void:
	_ok(a == b, "%s: expected %s got %s" % [msg, b, a])


# --- tests ---

## A freshly-constructed Selection holds nothing: empty and no ids.
func _test_fresh_is_empty() -> void:
	var s := Selection.new()
	_ok(s.is_empty(), "fresh Selection is_empty")
	_ids_eq(s.selected_ids(), [] as Array[int], "fresh selected_ids empty")


## `select_only(5)` picks exactly unit 5.
func _test_select_only() -> void:
	var s := Selection.new()
	s.select_only(5)
	_ok(s.is_selected(5), "select_only(5) selects 5")
	_ok(not s.is_empty(), "select_only leaves non-empty")
	_ids_eq(s.selected_ids(), [5] as Array[int], "select_only(5) ids == [5]")


## `select_only` REPLACES: selecting 7 after 5 leaves only 7.
func _test_select_only_replaces() -> void:
	var s := Selection.new()
	s.select_only(5)
	s.select_only(7)
	_ok(not s.is_selected(5), "select_only(7) deselects 5")
	_ok(s.is_selected(7), "select_only(7) selects 7")
	_ids_eq(s.selected_ids(), [7] as Array[int], "select_only replace ids == [7]")


## `add` is additive: adding 9 after select_only(7) yields both, sorted.
func _test_add_is_additive() -> void:
	var s := Selection.new()
	s.select_only(7)
	s.add(9)
	_ids_eq(s.selected_ids(), [7, 9] as Array[int], "add(9) ids == [7,9]")
	_ok(s.is_selected(7) and s.is_selected(9), "both 7 and 9 selected")


## `toggle` on a present id removes it; toggling again re-adds it.
func _test_toggle_removes_and_readds() -> void:
	var s := Selection.new()
	s.select_only(7)
	s.add(9)
	s.toggle(7)
	_ids_eq(s.selected_ids(), [9] as Array[int], "toggle(7) present removes -> [9]")
	s.toggle(7)
	_ids_eq(s.selected_ids(), [7, 9] as Array[int], "toggle(7) again re-adds -> [7,9]")


## `toggle` on an absent id adds it.
func _test_toggle_absent_adds() -> void:
	var s := Selection.new()
	s.toggle(3)
	_ok(s.is_selected(3), "toggle(3) absent adds 3")
	_ids_eq(s.selected_ids(), [3] as Array[int], "toggle absent ids == [3]")


## `clear` empties the whole selection.
func _test_clear() -> void:
	var s := Selection.new()
	s.add(1)
	s.add(2)
	s.clear()
	_ok(s.is_empty(), "clear -> is_empty")
	_ids_eq(s.selected_ids(), [] as Array[int], "clear -> ids == []")


## Querying an id that was never selected is false.
func _test_is_selected_unknown() -> void:
	var s := Selection.new()
	_ok(not s.is_selected(999), "is_selected(999) false")


## Determinism: ids added out of order come back sorted ascending.
func _test_selected_ids_sorted() -> void:
	var s := Selection.new()
	s.add(9)
	s.add(2)
	s.add(5)
	_ids_eq(s.selected_ids(), [2, 5, 9] as Array[int], "selected_ids sorted ascending")


## The static hit-test: exact (cell,tier) match returns the id; a tier or cell
## miss returns -1; and stacked entries return the FIRST by array order.
func _test_unit_at() -> void:
	var entries: Array = [
		{"id": 1, "cell": Vector2i(3, 1), "tier": 0},
		{"id": 2, "cell": Vector2i(5, 2), "tier": 1},
	]
	_i_eq(Selection.unit_at(entries, Vector2i(5, 2), 1), 2, "unit_at exact match -> 2")
	_i_eq(Selection.unit_at(entries, Vector2i(5, 2), 0), -1, "unit_at tier mismatch -> -1")
	_i_eq(Selection.unit_at(entries, Vector2i(9, 9), 0), -1, "unit_at cell miss -> -1")

	var stacked: Array = [
		{"id": 8, "cell": Vector2i(4, 4), "tier": 2},
		{"id": 3, "cell": Vector2i(4, 4), "tier": 2},
	]
	_i_eq(Selection.unit_at(stacked, Vector2i(4, 4), 2), 8, "unit_at stacked returns first index")
