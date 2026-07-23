extends GdTest
## Pure-behaviour tests for RampQueue (#79): the deterministic single-file ordering
## authority for a 1-wide chokepoint. Run:
##   godot --headless --script res://src/core/tests/test_ramp_queue.gd
##
## These fix the load-bearing invariants with no live scene: the order is deterministic
## (priority ascending, id tie-break -- independent of input array order), AT MOST ONE
## unit is ever admitted onto the choke at a time (the core guarantee against stacking),
## an occupant blocks every waiter until it leaves, waiters get distinct monotonic hold
## slots so they line up, and N units contending resolve to a clean single-file crossing.


func _run() -> void:
	_test_order_is_priority_then_id()
	_test_order_independent_of_input_order()
	_test_single_admission_when_choke_free()
	_test_occupant_blocks_all_waiters()
	_test_slots_distinct_and_monotonic()
	_test_hold_distance_spacing()
	_test_n_unit_single_file_crossing()
	_test_empty_and_degenerate()


# --- helpers ---

## A contender record. `priority` lower == nearer the front (nearer the choke).
func _c(id: int, cell: Vector2i, priority: float) -> Dictionary:
	return { "id": id, "cell": cell, "priority": priority }


## Count how many of `ids` the resolution admits (may_enter true). The core invariant
## caps this at 1.
func _admitted_count(resolution: Dictionary, ids: Array) -> int:
	var n: int = 0
	for id: int in ids:
		if RampQueue.may_enter(resolution, id):
			n += 1
	return n


# --- tests ---

## order() sorts by priority ascending, breaking ties by ascending id.
func _test_order_is_priority_then_id() -> void:
	var away := Vector2i(0, 0)
	var contenders: Array = [
		_c(7, away, 3.0),
		_c(2, away, 1.0),
		_c(5, away, 2.0),
		_c(9, away, 1.0),   # ties id 2 on priority 1.0 -> id 2 first
	]
	var got: PackedInt32Array = RampQueue.order(contenders)
	var expected := PackedInt32Array([2, 9, 5, 7])
	_ok(got == expected, "order is priority-asc, id-asc on ties: got %s" % [got])


## order() ignores the input array order -- feeding the same set shuffled yields the
## identical sequence (determinism).
func _test_order_independent_of_input_order() -> void:
	var away := Vector2i(0, 0)
	var a: Array = [_c(1, away, 5.0), _c(2, away, 4.0), _c(3, away, 6.0)]
	var b: Array = [_c(3, away, 6.0), _c(1, away, 5.0), _c(2, away, 4.0)]
	_ok(RampQueue.order(a) == RampQueue.order(b), "order is independent of input array order")


## With the choke FREE (nobody on it), exactly ONE unit -- the front of the queue -- is
## admitted; every other waiter is held.
func _test_single_admission_when_choke_free() -> void:
	var choke := Vector2i(5, 5)
	var up := Vector2i(3, 5)   # everyone upstream, none on the choke
	var contenders: Array = [
		_c(10, up, 30.0),
		_c(11, up, 10.0),   # front (lowest priority)
		_c(12, up, 20.0),
	]
	var res: Dictionary = RampQueue.resolve(contenders, choke)
	_ok(int(res["occupant"]) == RampQueue.NONE, "choke free -> no occupant")
	_ok(int(res["next"]) == 11, "front waiter is next")
	_ok(RampQueue.may_enter(res, 11), "front waiter admitted when choke free")
	_ok(not RampQueue.may_enter(res, 12), "second waiter held")
	_ok(not RampQueue.may_enter(res, 10), "back waiter held")
	_ok(_admitted_count(res, [10, 11, 12]) == 1, "exactly one unit admitted onto a free choke")


## An occupant on the choke blocks EVERY waiter (nobody else may enter until it clears),
## and the occupant itself is always admitted (to cross off).
func _test_occupant_blocks_all_waiters() -> void:
	var choke := Vector2i(5, 5)
	var up := Vector2i(3, 5)
	var contenders: Array = [
		_c(20, choke, 0.0),   # on the ramp
		_c(21, up, 10.0),
		_c(22, up, 20.0),
	]
	var res: Dictionary = RampQueue.resolve(contenders, choke)
	_ok(int(res["occupant"]) == 20, "unit on the choke is the occupant")
	_ok(RampQueue.may_enter(res, 20), "occupant may proceed (cross off the ramp)")
	_ok(not RampQueue.may_enter(res, 21), "front waiter blocked while occupied")
	_ok(not RampQueue.may_enter(res, 22), "back waiter blocked while occupied")
	_ok(_admitted_count(res, [20, 21, 22]) == 1, "at most one admitted while occupied")


## Every WAITING unit gets a distinct 0-based slot, front waiter = 0, increasing with
## queue position (so the driver can space them single-file).
func _test_slots_distinct_and_monotonic() -> void:
	var choke := Vector2i(5, 5)
	var up := Vector2i(3, 5)
	var contenders: Array = [
		_c(30, up, 30.0),
		_c(31, up, 10.0),
		_c(32, up, 20.0),
	]
	var res: Dictionary = RampQueue.resolve(contenders, choke)
	var slots: Dictionary = res["slots"]
	# Order is 31 (0), 32 (1), 30 (2).
	_ok(int(slots[31]) == 0, "front waiter is slot 0")
	_ok(int(slots[32]) == 1, "second waiter is slot 1")
	_ok(int(slots[30]) == 2, "back waiter is slot 2")
	_ok(slots.size() == 3, "every waiter has a slot")


## hold_distance grows with slot at the given spacing (single-file line-up).
func _test_hold_distance_spacing() -> void:
	_ok(is_equal_approx(RampQueue.hold_distance(0), 0.0), "slot 0 waits at the choke entrance")
	_ok(is_equal_approx(RampQueue.hold_distance(1), RampQueue.DEFAULT_QUEUE_SPACING_PX), "slot 1 one spacing back")
	_ok(RampQueue.hold_distance(2) > RampQueue.hold_distance(1), "further slots are further back")
	_ok(is_equal_approx(RampQueue.hold_distance(3, 10.0), 30.0), "custom spacing honoured")


## Simulate N units crossing a 1-wide ramp step by step: each 'tick' the admitted unit
## advances onto the choke, then off it; assert that AT NO TICK are two units admitted,
## and that all N cross in strict priority order (single file).
func _test_n_unit_single_file_crossing() -> void:
	var choke := Vector2i(5, 5)
	var up := Vector2i(3, 5)
	var off := Vector2i(7, 5)   # the far side, once crossed

	# Five units queued upstream with distinct priorities (front = lowest).
	var cells: Dictionary = { 40: up, 41: up, 42: up, 43: up, 44: up }
	var prio: Dictionary = { 40: 50.0, 41: 10.0, 42: 40.0, 43: 20.0, 44: 30.0 }
	var expected_order: Array = [41, 43, 44, 42, 40]

	var crossed_order: Array = []
	var ever_double_admit: bool = false
	var occupant: int = RampQueue.NONE

	# Loop-guarded ticks. Each tick: build contenders from the units NOT yet crossed,
	# resolve, admit at most one, and step the admitted unit choke->off.
	var guard: int = 0
	while crossed_order.size() < expected_order.size() and guard < 100:
		guard += 1
		var contenders: Array = []
		for id: int in cells:
			if cells[id] == off:
				continue   # already crossed -- no longer contends
			contenders.append(_c(id, cells[id], float(prio[id])))
		if contenders.is_empty():
			break
		var res: Dictionary = RampQueue.resolve(contenders, choke)

		# Invariant: never more than one admitted among the live contenders.
		var live_ids: Array = []
		for it: Dictionary in contenders:
			live_ids.append(it["id"])
		if _admitted_count(res, live_ids) > 1:
			ever_double_admit = true

		occupant = int(res["occupant"])
		if occupant != RampQueue.NONE:
			# The occupant crosses OFF the ramp this tick.
			cells[occupant] = off
			crossed_order.append(occupant)
		else:
			# Choke free: admit the next waiter ONTO the choke.
			var nxt: int = int(res["next"])
			if nxt != RampQueue.NONE:
				cells[nxt] = choke

	_ok(not ever_double_admit, "never two units admitted onto the choke at once")
	_ok(crossed_order == expected_order, "all units cross single-file in priority order: %s" % [crossed_order])
	_ok(guard < 100, "crossing resolves inside the tick budget (used %d)" % guard)


## Empty and single-contender inputs are safe and sensible.
func _test_empty_and_degenerate() -> void:
	var choke := Vector2i(5, 5)
	var empty: Dictionary = RampQueue.resolve([], choke)
	_ok((empty["order"] as PackedInt32Array).is_empty(), "empty contenders -> empty order")
	_ok(int(empty["occupant"]) == RampQueue.NONE, "empty -> no occupant")
	_ok(int(empty["next"]) == RampQueue.NONE, "empty -> no next")

	# A single unit already on the choke is the occupant and may proceed.
	var solo: Dictionary = RampQueue.resolve([_c(1, choke, 0.0)], choke)
	_ok(int(solo["occupant"]) == 1, "lone unit on choke is the occupant")
	_ok(RampQueue.may_enter(solo, 1), "lone occupant may proceed")
