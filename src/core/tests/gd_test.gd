class_name GdTest
extends SceneTree
## Shared base for the headless SceneTree test suites (#25).
##
## Centralizes the pass/fail counters, the core `_ok` assertion, the common
## self-asserting typed comparisons, and — the reason this exists — the
## "PASS n / FAIL m" summary print plus the exit-code convention. CI's crash
## detector treats a missing summary as a failure (#24); putting the summary +
## quit here means no suite can forget to emit it, and the contract is enforced
## in exactly one place instead of being copy-pasted into every file.
##
## A suite extends GdTest and overrides `_run()` with its assertions; the base
## drives `_initialize()` -> `_run()` -> summary -> quit. Type-specific helpers
## whose signatures genuinely diverge across suites (e.g. approximate-float
## Vector2 vs exact Vector2i comparison, Array comparison, predicate-returning
## variants) stay local to the suites that need them — GDScript has no
## overloading, so those cannot share one name here.

var _pass: int = 0
var _fail: int = 0


func _initialize() -> void:
	_run()
	# The one and only place the summary + exit code are produced (#24).
	print("PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


## Override with the suite's assertions. Base is intentionally empty.
func _run() -> void:
	pass


## Core assertion every other check funnels through: counts a pass, or counts a
## fail and prints the `FAIL: ` line CI greps for.
func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % msg)


## Integer equality with an expected/got diagnostic.
func _i_eq(a: int, b: int, msg: String) -> void:
	_ok(a == b, "%s: expected %d got %d" % [msg, b, a])


## Exact Vector2i equality with an expected/got diagnostic.
func _v_eq(a: Vector2i, b: Vector2i, msg: String) -> void:
	_ok(a == b, "%s: expected %s got %s" % [msg, b, a])


## String equality with an expected/got diagnostic.
func _s_eq(a: String, b: String, msg: String) -> void:
	_ok(a == b, "%s: expected %s got %s" % [msg, b, a])


## String inequality with a diagnostic.
func _s_neq(a: String, b: String, msg: String) -> void:
	_ok(a != b, "%s: both equal %s" % [msg, a])
