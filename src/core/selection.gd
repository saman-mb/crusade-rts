class_name Selection
extends RefCounted
## The player's current unit selection set, as a pure ordered-by-id core (#77).
##
## Selection is the single source of truth for "which units are picked" that both
## the click-to-select input path and the order-dispatch path key off. It is a
## plain RefCounted with NO Node deps, so the whole selection lifecycle — replace,
## additive, toggle, clear — is exercised headlessly without a scene tree.
##
## The set is backed by a Dictionary used as a hash set (`id -> true`); membership
## is O(1) and duplicate adds are naturally idempotent. The one invariant callers
## rely on is that `selected_ids()` returns the ids SORTED ascending: input arrives
## in arbitrary click order, but every consumer — test assertions, deterministic
## order dispatch, UI enumeration — sees one stable canonical ordering, so behavior
## never depends on the sequence the units happened to be clicked in.
##
## The hit-test that turns a clicked (cell, tier) into a unit id lives here too as a
## STATIC helper (`unit_at`): it is pure geometry over a snapshot array and needs no
## Selection instance, keeping "what did I click" decoupled from "what is selected".

## The membership set: `id -> true`. Presence of a key means the unit is selected;
## the value is always `true` and carries no meaning. Never iterated for order —
## `selected_ids()` sorts on read.
var _ids: Dictionary = {}


## Replace-select: drop the entire current selection, then select `id` alone. This
## is the plain left-click gesture ("select just this unit"). After this call the
## set contains exactly `{id}`.
func select_only(id: int) -> void:
	clear()
	add(id)


## Additive-select: add `id` to the current selection, leaving existing members in
## place (the shift+left-click gesture). Idempotent — adding an already-selected id
## is a no-op.
func add(id: int) -> void:
	_ids[id] = true


## Toggle `id`: remove it if currently selected, add it if not (shift-style toggle
## on an already-considered unit). Flips exactly this one id, leaving the rest of
## the selection untouched.
func toggle(id: int) -> void:
	if _ids.has(id):
		_ids.erase(id)
	else:
		_ids[id] = true


## Empty the selection entirely. After this call `is_empty()` is true and
## `selected_ids()` is `[]`.
func clear() -> void:
	_ids.clear()


## Whether `id` is currently in the selection.
func is_selected(id: int) -> bool:
	return _ids.has(id)


## The selected unit ids, SORTED ascending, as a typed `Array[int]`. Sorting on
## read is the core's ordering guarantee: consumers get one deterministic sequence
## regardless of click order (see the class doc). Returns a fresh array each call;
## the caller may mutate it freely without disturbing the selection.
func selected_ids() -> Array[int]:
	var out: Array[int] = []
	for id: int in _ids.keys():
		out.append(id)
	out.sort()
	return out


## Whether nothing is selected.
func is_empty() -> bool:
	return _ids.is_empty()


## Pure hit-test: which unit id occupies (`cell`, `tier`)? `entries` is a snapshot
## Array of `{ "id": int, "cell": Vector2i, "tier": int }` dictionaries — one per
## live unit. Returns the FIRST matching id in array order (lowest index), so a
## caller that wants a deterministic winner among stacked units controls it by
## ordering `entries`; returns -1 when no entry matches.
##
## Static and Node-free: this is geometry over a plain array, so it needs no
## Selection instance and never touches the scene tree.
static func unit_at(entries: Array, cell: Vector2i, tier: int) -> int:
	for i in range(entries.size()):
		var e: Dictionary = entries[i]
		var e_cell: Vector2i = e["cell"]
		var e_tier: int = e["tier"]
		if e_cell == cell and e_tier == tier:
			var e_id: int = e["id"]
			return e_id
	return -1
