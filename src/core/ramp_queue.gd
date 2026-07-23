class_name RampQueue
extends RefCounted
## Deterministic single-file queueing at a 1-wide chokepoint (#79, ramp polish).
##
## A ramp (or any 1-cell-wide corridor) can only hold ONE unit at a time; when a crowd
## funnels toward it the flow-field + separation steering alone will pile several units
## onto the same choke cell (separation just spreads them AROUND the choke, it does not
## grant right-of-way). This pure core is the ordering authority: given the choke cell
## and the set of units contending for it, it decides a DETERMINISTIC single-file order
## and gates who may occupy the choke, so units line up and cross one at a time instead
## of stacking.
##
## MODEL. Each contender is a Dictionary { "id": int, "cell": Vector2i, "priority":
## float }. `priority` is a caller-supplied scalar where LOWER == closer to the front
## of the queue (nearer the choke / further along toward the goal) -- the driver
## typically passes each unit's world distance to the choke, or its flow-field cost.
## Ties break by ascending `id`, so the order is fully deterministic (no dependence on
## input array order or float jitter).
##
## RIGHT-OF-WAY. `resolve` reports the single OCCUPANT currently standing on the choke
## cell (front-most by priority if, defensively, several overlap it), the NEXT waiter
## first in line to enter, and a 0-based queue SLOT for every waiting unit so the
## driver can hold each one `slot * spacing` back and they line up rather than bunch.
## `may_enter` is the per-unit gate the driver calls each frame: it admits the occupant
## (already on the ramp -- keep it moving off) and, ONLY when the choke is free, the
## next waiter -- so AT MOST ONE unit is ever cleared onto the choke cell at a time.
## Everyone else holds; the existing separation steering handles their spacing within
## the slot the queue assigns them.
##
## Pure / headless: static functions only, no Node/scene/field deps -- it works on
## abstract { id, cell, priority } records, so the same logic serves any driver
## regardless of how priority or the choke are derived. Fully unit-tested.

## Default hold spacing (world px) between consecutive queued units -- one body, matched
## to Steering.DEFAULT_SEPARATION_RADIUS so the queue's slot spacing agrees with the
## separation the steering already enforces.
const DEFAULT_QUEUE_SPACING_PX := 28.0

## Sentinel returned when there is no occupant / no next unit.
const NONE := -1


## Front-to-back single-file order of the contender ids: `priority` ascending, `id`
## ascending on ties. Deterministic and independent of the input array order. Empty in
## -> empty out.
static func order(contenders: Array) -> PackedInt32Array:
	var items: Array = contenders.duplicate()
	items.sort_custom(_before)
	var ids := PackedInt32Array()
	for it: Dictionary in items:
		var id: int = it["id"]
		ids.append(id)
	return ids


## Resolves the queue against the choke cell. Returns:
##   "order":    PackedInt32Array -- all contender ids front-to-back (== `order`).
##   "occupant": int -- the id currently ON `choke_cell` (front-most by priority if
##               several overlap it), or NONE (-1) if the choke is free.
##   "next":     int -- the front-most contender NOT the occupant, i.e. first in line
##               to enter, or NONE (-1) if nobody is waiting.
##   "slots":    Dictionary(id -> int) -- a 0-based queue slot for every WAITING unit
##               (every contender except the occupant), front waiter = 0, so the driver
##               can hold each `slot * spacing` back from the choke and they line up.
static func resolve(contenders: Array, choke_cell: Vector2i) -> Dictionary:
	var ordered: PackedInt32Array = order(contenders)

	# Index contenders by id for the cell lookup (occupant test).
	var cell_by_id: Dictionary = {}
	for it: Dictionary in contenders:
		var cid: int = it["id"]
		var ccell: Vector2i = it["cell"]
		cell_by_id[cid] = ccell

	# Occupant = the FIRST id in priority order that sits on the choke cell.
	var occupant: int = NONE
	for id: int in ordered:
		var this_cell: Vector2i = cell_by_id[id]
		if this_cell == choke_cell:
			occupant = id
			break

	# Waiting = every contender except the occupant, kept in priority order. The first
	# waiter is `next`; each waiter gets its rank as a 0-based hold slot.
	var next_id: int = NONE
	var slots: Dictionary = {}
	var slot: int = 0
	for id: int in ordered:
		if id == occupant:
			continue
		if next_id == NONE:
			next_id = id
		slots[id] = slot
		slot += 1

	return {
		"order": ordered,
		"occupant": occupant,
		"next": next_id,
		"slots": slots,
	}


## The per-frame gate: may `unit_id` move onto / through the choke this frame?
## True for the current occupant (it is already on the ramp -- let it cross off), and
## for the `next` waiter ONLY when the choke is free (occupant == NONE). Everyone else
## must hold. Consequence: at most one unit is ever admitted onto the choke at a time.
static func may_enter(resolution: Dictionary, unit_id: int) -> bool:
	var occupant: int = resolution["occupant"]
	if unit_id == occupant:
		return true
	if occupant != NONE:
		return false
	var next_id: int = resolution["next"]
	return unit_id == next_id


## The hold-back distance (world px) for a waiting unit at `slot`: slot 0 waits right at
## the choke entrance, each further slot one `spacing` further back, so queued units
## line up single-file instead of stacking on one upstream cell.
static func hold_distance(slot: int, spacing: float = DEFAULT_QUEUE_SPACING_PX) -> float:
	return float(slot) * spacing


## Sort predicate: priority ascending, id ascending on ties. `a`/`b` are the contender
## Dictionaries; kept private so the deterministic tie-break lives in exactly one place.
static func _before(a: Dictionary, b: Dictionary) -> bool:
	var pa: float = a["priority"]
	var pb: float = b["priority"]
	if pa != pb:
		return pa < pb
	var ia: int = a["id"]
	var ib: int = b["id"]
	return ia < ib
