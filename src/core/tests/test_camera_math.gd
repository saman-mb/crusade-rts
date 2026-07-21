extends SceneTree
## Pure-math tests for CameraMath (no Camera2D / Node deps required).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Proves frame-rate-independent smoothing, zoom-invariant panning, edge-pan
## ramps, zoom clamping/anchoring, and target clamping against map bounds.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_smoothing_weight()
	_test_frame_rate_invariance()
	_test_keyboard_pan_zoom_invariance()
	_test_zoom_step_and_clamp()
	_test_clamp_target_position()
	_test_edge_pan_ramp()
	_test_zoom_anchor_correction()

	print("PASS %d / FAIL %d" % [_pass, _fail])
	if _fail > 0:
		OS.set_exit_code(1)
	quit()

# --- helpers ---

## Increments counters; prints only on failure so passing runs stay quiet.
func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % msg)

## Approximate Vector2 equality via distance.
func _v_eq(a: Vector2, b: Vector2) -> bool:
	return a.distance_to(b) < 0.001

## Approximate float equality.
func _f_eq(a: float, b: float) -> bool:
	return abs(a - b) < 0.001

# --- tests ---

## smoothing_weight is a normalized [0,1] blend factor: 0 at delta 0, rising
## monotonically toward (but never past) 1 as decay*delta grows.
func _test_smoothing_weight() -> void:
	var decays: Array[float] = [1.0, 4.0, 8.0, 14.0, 20.0]
	var deltas: Array[float] = [0.0, 0.001, 0.016, 0.1, 1.0]

	for decay in decays:
		# Every sampled weight must sit in the closed unit interval.
		for delta in deltas:
			var w := CameraMath.smoothing_weight(decay, delta)
			_check(w >= 0.0 and w <= 1.0, "smoothing_weight(%s,%s)=%s in [0,1]" % [decay, delta, w])

		# delta == 0 means "no time passed" => no movement.
		_check(_f_eq(CameraMath.smoothing_weight(decay, 0.0), 0.0), "smoothing_weight(%s,0)=0" % decay)

		# Monotonic non-decreasing in delta for fixed decay.
		var prev := -1.0
		for delta in deltas:
			var w := CameraMath.smoothing_weight(decay, delta)
			_check(w >= prev - 0.000001, "smoothing_weight monotonic in delta (decay %s, delta %s)" % [decay, delta])
			prev = w

	# Large decay*delta => within (0,1], approaching 1.
	var big := CameraMath.smoothing_weight(20.0, 1.0)
	_check(big > 0.99 and big <= 1.0, "large decay*delta weight approaches 1 (got %s)" % big)

## THE MARQUEE PROPERTY: exponential decay composes, so 30fps and 144fps land
## in the same place. Decaying current->target over N sub-steps of T/N yields the
## same result regardless of N (1 == 8 == 64), all matching one step of T.
func _test_frame_rate_invariance() -> void:
	var a := Vector2(0.0, 0.0)
	var b := Vector2(100.0, 40.0)
	var t := 0.1
	var subdivisions: Array[int] = [1, 8, 64]

	for decay in [8.0, 14.0, 15.0]:
		# One full step of T is our reference.
		var one_shot := CameraMath.decay_vec2(a, b, decay, t)

		for n in subdivisions:
			var v := a
			for i in range(n):
				v = CameraMath.decay_vec2(v, b, decay, t / float(n))
			_check(_v_eq(one_shot, v), "decay invariance decay=%s N=%s (one_shot %s vs %s)" % [decay, n, one_shot, v])

## Panning must feel the same at every zoom: world_delta * zoom (the on-screen
## displacement) is identical across zooms, and a diagonal never travels farther
## than a cardinal for the same-magnitude input.
func _test_keyboard_pan_zoom_invariance() -> void:
	var pan_speed := 800.0
	var delta := 0.016
	var d_near := CameraMath.keyboard_pan_delta(Vector2(1.0, 0.0), pan_speed, 0.5, delta)
	var d_far := CameraMath.keyboard_pan_delta(Vector2(1.0, 0.0), pan_speed, 2.5, delta)

	# On-screen displacement = world_delta * zoom must match across zooms.
	_check(_f_eq(d_near.x * 0.5, d_far.x * 2.5), "pan on-screen dx zoom-invariant (%s vs %s)" % [d_near.x * 0.5, d_far.x * 2.5])
	_check(_f_eq(d_near.y * 0.5, d_far.y * 2.5), "pan on-screen dy zoom-invariant (%s vs %s)" % [d_near.y * 0.5, d_far.y * 2.5])

	# Diagonal (unit-length) world delta must not exceed a cardinal unit input.
	var straight := CameraMath.keyboard_pan_delta(Vector2(1.0, 0.0), pan_speed, 1.0, delta).length()
	var diagonal := CameraMath.keyboard_pan_delta(Vector2(1.0, 1.0).normalized(), pan_speed, 1.0, delta).length()
	_check(diagonal <= straight + 0.001, "diagonal pan <= cardinal pan (%s <= %s)" % [diagonal, straight])

## Zoom steps accumulate but never escape [zoom_min, zoom_max]; a step past a
## bound clamps exactly to that bound.
func _test_zoom_step_and_clamp() -> void:
	var zmin := 0.5
	var zmax := 2.5
	var step := 2.0   # zoom_step is multiplicative (>1): *step zooms in, /step zooms out

	# Ratchet up 20 times: never exceeds max.
	var z := 1.0
	for i in range(20):
		z = CameraMath.step_zoom(z, 1, step, zmin, zmax)
		_check(z <= zmax + 0.000001, "step_zoom up stays <= max (iter %s got %s)" % [i, z])
	_check(_f_eq(z, zmax), "step_zoom up saturates to max (got %s)" % z)

	# Ratchet down 20 times: never below min.
	z = 1.0
	for i in range(20):
		z = CameraMath.step_zoom(z, -1, step, zmin, zmax)
		_check(z >= zmin - 0.000001, "step_zoom down stays >= min (iter %s got %s)" % [i, z])
	_check(_f_eq(z, zmin), "step_zoom down saturates to min (got %s)" % z)

	# One step from just inside a bound clamps exactly onto the bound.
	_check(_f_eq(CameraMath.step_zoom(2.4, 1, step, zmin, zmax), zmax), "step_zoom past max clamps to max")
	_check(_f_eq(CameraMath.step_zoom(0.6, -1, step, zmin, zmax), zmin), "step_zoom past min clamps to min")

	# clamp_zoom is a plain clamp.
	_check(_f_eq(CameraMath.clamp_zoom(3.0, zmin, zmax), zmax), "clamp_zoom(3.0)=2.5")
	_check(_f_eq(CameraMath.clamp_zoom(0.1, zmin, zmax), zmin), "clamp_zoom(0.1)=0.5")
	_check(_f_eq(CameraMath.clamp_zoom(1.25, zmin, zmax), 1.25), "clamp_zoom in-range unchanged")

## The camera target stays inside the map bounds inset by half the on-screen view
## (viewport/2/zoom). When the view is larger than the map, target locks to center.
func _test_clamp_target_position() -> void:
	var bounds := Rect2(0.0, 0.0, 4000.0, 3000.0)
	var viewport := Vector2(1920.0, 1080.0)
	var zoom := 1.0
	# Half-view at zoom 1.0: 960 x 540. Inset box: x in [960,3040], y in [540,2460].
	var min_x := 960.0
	var max_x := 3040.0
	var min_y := 540.0
	var max_y := 2460.0

	# Far outside the top-left corner: both axes clamp to the near inset edges.
	var corner := CameraMath.clamp_target_position(Vector2(-5000.0, -5000.0), bounds, viewport, zoom)
	_check(_v_eq(corner, Vector2(min_x, min_y)), "corner clamps to (%s,%s) got %s" % [min_x, min_y, corner])

	# Far outside the bottom-right corner: clamps to the far inset edges.
	var corner2 := CameraMath.clamp_target_position(Vector2(99999.0, 99999.0), bounds, viewport, zoom)
	_check(_v_eq(corner2, Vector2(max_x, max_y)), "far corner clamps to (%s,%s) got %s" % [max_x, max_y, corner2])

	# A point already inside the inset box is untouched.
	var inside := Vector2(2000.0, 1500.0)
	var kept := CameraMath.clamp_target_position(inside, bounds, viewport, zoom)
	_check(_v_eq(kept, inside), "interior target unchanged got %s" % kept)

	# Degenerate bounds smaller than the view: no valid inset => lock to midpoint.
	var tiny := Rect2(0.0, 0.0, 100.0, 100.0)
	var mid := CameraMath.clamp_target_position(Vector2(9999.0, -9999.0), tiny, viewport, zoom)
	_check(_v_eq(mid, Vector2(50.0, 50.0)), "degenerate bounds -> midpoint (50,50) got %s" % mid)

## Edge panning ramps linearly from the zone's inner boundary (0) to the screen
## edge (full speed), on all four sides.
func _test_edge_pan_ramp() -> void:
	var viewport := Vector2(1000.0, 1000.0)
	var edge_fraction := 0.05   # 50px zone on each side.
	var edge_speed := 1000.0
	var tol := 1.0

	# Dead center: no movement.
	var center := CameraMath.edge_pan_velocity(Vector2(500.0, 500.0), viewport, edge_fraction, edge_speed)
	_check(_v_eq(center, Vector2.ZERO), "edge pan center = (0,0) got %s" % center)

	# Left edge (x=0): full negative x velocity.
	var left := CameraMath.edge_pan_velocity(Vector2(0.0, 500.0), viewport, edge_fraction, edge_speed)
	_check(abs(left.x - (-edge_speed)) < tol, "left edge vx ~ -edge_speed got %s" % left.x)
	_check(abs(left.y) < tol, "left edge vy ~ 0 got %s" % left.y)

	# Zone midpoint (x=25): half negative x velocity.
	var half := CameraMath.edge_pan_velocity(Vector2(25.0, 500.0), viewport, edge_fraction, edge_speed)
	_check(abs(half.x - (-0.5 * edge_speed)) < tol, "zone midpoint vx ~ -0.5*edge_speed got %s" % half.x)

	# Inner boundary (x=50): velocity fades to ~0.
	var inner := CameraMath.edge_pan_velocity(Vector2(50.0, 500.0), viewport, edge_fraction, edge_speed)
	_check(abs(inner.x) < tol, "inner boundary vx ~ 0 got %s" % inner.x)

	# Bottom-right corner: full positive velocity on both axes.
	var br := CameraMath.edge_pan_velocity(Vector2(1000.0, 1000.0), viewport, edge_fraction, edge_speed)
	_check(abs(br.x - edge_speed) < tol, "corner vx ~ +edge_speed got %s" % br.x)
	_check(abs(br.y - edge_speed) < tol, "corner vy ~ +edge_speed got %s" % br.y)

## Zoom anchoring keeps the point under the cursor fixed. The correction equals
## the closed form offset*(1/z0 - 1/z1), is zero for no zoom change, and a
## round-trip (in then out) drifts nowhere.
func _test_zoom_anchor_correction() -> void:
	var offset := Vector2(200.0, -120.0)
	var z0 := 1.0
	var z1 := 1.1

	# Matches the closed-form world-space shift.
	var closed := offset * (1.0 / z0 - 1.0 / z1)
	var corr := CameraMath.zoom_anchor_correction(offset, z0, z1)
	_check(_v_eq(corr, closed), "correction matches closed form got %s want %s" % [corr, closed])

	# In-then-out round trip cancels: no cumulative drift.
	var back := CameraMath.zoom_anchor_correction(offset, z1, z0)
	_check(_v_eq(corr + back, Vector2.ZERO), "round-trip correction ~ ZERO got %s" % (corr + back))

	# No zoom change => no correction.
	var none := CameraMath.zoom_anchor_correction(offset, z0, z0)
	_check(_v_eq(none, Vector2.ZERO), "no-op zoom correction = ZERO got %s" % none)
