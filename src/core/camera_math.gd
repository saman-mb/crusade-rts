class_name CameraMath
extends RefCounted
## Pure camera math — frame-rate-independent exponential decay (1 - exp(-k*delta)).
## No Node/Camera2D dependencies whatsoever, so every function is unit-testable
## headless. Callers (the camera controller Node) feed in plain numbers/vectors
## and apply the results; all smoothing, panning, zooming, and clamping geometry
## lives here as static, side-effect-free functions.

## Frame-rate-independent smoothing weight in [0, 1].
## As delta grows the weight approaches 1 (snappier); this is THE anti-jitter
## term that makes exponential decay behave identically at any frame rate.
static func smoothing_weight(decay: float, delta: float) -> float:
	return clampf(1.0 - exp(-decay * delta), 0.0, 1.0)

## Exponentially decay a Vector2 toward a target using the frame-rate weight.
static func decay_vec2(current: Vector2, target: Vector2, decay: float, delta: float) -> Vector2:
	return current.lerp(target, smoothing_weight(decay, delta))

## Exponentially decay a float toward a target using the frame-rate weight.
static func decay_float(current: float, target: float, decay: float, delta: float) -> float:
	return lerpf(current, target, smoothing_weight(decay, delta))

## World-space pan delta from a (caller-normalized) input vector.
## Divides by zoom so the on-screen pan speed is zoom-invariant.
static func keyboard_pan_delta(input_vector: Vector2, pan_speed: float, zoom: float, delta: float) -> Vector2:
	var z := zoom if zoom > 0.0 else 1.0
	return input_vector * pan_speed * delta / z

## Edge-pan velocity based on mouse proximity to each viewport border.
## Each axis ramps linearly from 0 at the inner zone boundary to edge_speed at
## the very edge. Left/up are negative, right/down positive; interior is 0.
static func edge_pan_velocity(mouse_pos: Vector2, viewport_size: Vector2, edge_fraction: float, edge_speed: float) -> Vector2:
	var zone := viewport_size * edge_fraction
	var vx := 0.0
	if zone.x > 0.0:
		if mouse_pos.x < zone.x:
			var ramp := clampf((zone.x - mouse_pos.x) / zone.x, 0.0, 1.0)
			vx = -edge_speed * ramp
		elif mouse_pos.x > viewport_size.x - zone.x:
			var ramp := clampf((mouse_pos.x - (viewport_size.x - zone.x)) / zone.x, 0.0, 1.0)
			vx = edge_speed * ramp
	var vy := 0.0
	if zone.y > 0.0:
		if mouse_pos.y < zone.y:
			var ramp := clampf((zone.y - mouse_pos.y) / zone.y, 0.0, 1.0)
			vy = -edge_speed * ramp
		elif mouse_pos.y > viewport_size.y - zone.y:
			var ramp := clampf((mouse_pos.y - (viewport_size.y - zone.y)) / zone.y, 0.0, 1.0)
			vy = edge_speed * ramp
	return Vector2(vx, vy)

## Advance the zoom target by one multiplicative step (in or out) and clamp it.
static func step_zoom(current_target: float, direction: int, step: float, zoom_min: float, zoom_max: float) -> float:
	var z := current_target * step if direction > 0 else current_target / step
	return clamp_zoom(z, zoom_min, zoom_max)

## Clamp a zoom value to the configured range.
static func clamp_zoom(target_zoom: float, zoom_min: float, zoom_max: float) -> float:
	return clampf(target_zoom, zoom_min, zoom_max)

## Clamp a camera target position so the visible view stays within bounds.
## The view half-extent shrinks as zoom increases; if the bounds are smaller
## than the view on an axis, that axis is centered on the bounds midpoint.
static func clamp_target_position(target: Vector2, bounds: Rect2, viewport_size: Vector2, zoom: float) -> Vector2:
	var z := zoom if zoom > 0.0 else 1.0
	var inset := viewport_size * 0.5 / z
	var min_c := bounds.position + inset
	var max_c := bounds.position + bounds.size - inset
	var out_x := 0.0
	if min_c.x > max_c.x:
		out_x = bounds.position.x + bounds.size.x * 0.5
	else:
		out_x = clampf(target.x, min_c.x, max_c.x)
	var out_y := 0.0
	if min_c.y > max_c.y:
		out_y = bounds.position.y + bounds.size.y * 0.5
	else:
		out_y = clampf(target.y, min_c.y, max_c.y)
	return Vector2(out_x, out_y)

## World-space AABB enclosing a rectangular block of painted isometric cells,
## grown by `pad_cells` on every side so panning keeps editing headroom. This is
## what feeds RtsCamera.world_bounds (#17): the map has no fixed extent, so bounds
## are derived from the actual used cells.
##
## The diamond CENTER of a cell is `cart_to_iso` (which faithfully mirrors
## TileMapLayer.map_to_local); each tile's diamond spans +/- half a tile from its
## center, so the enclosing box is found from the four extreme corner cells.
## Returns an empty Rect2 (the "unbounded" sentinel RtsCamera checks) when the
## cell region has no area, e.g. a blank map.
static func world_bounds_for_cells(used_cells: Rect2i, tile_size: Vector2i, pad_cells: int) -> Rect2:
	if used_cells.size.x <= 0 or used_cells.size.y <= 0:
		return Rect2()
	var pad := maxi(pad_cells, 0)
	var min_cx := used_cells.position.x - pad
	var min_cy := used_cells.position.y - pad
	var max_cx := used_cells.position.x + used_cells.size.x - 1 + pad
	var max_cy := used_cells.position.y + used_cells.size.y - 1 + pad
	var w := tile_size.x / 2.0
	var h := tile_size.y / 2.0
	# Extremes: min-x at (min_cx,max_cy) left vertex, max-x at (max_cx,min_cy) right
	# vertex, min-y at (min_cx,min_cy) top vertex, max-y at (max_cx,max_cy) bottom.
	var x_min := (min_cx - max_cy) * w
	var x_max := (max_cx - min_cy) * w + 2.0 * w
	var y_min := (min_cx + min_cy) * h
	var y_max := (max_cx + max_cy) * h + 2.0 * h
	return Rect2(x_min, y_min, x_max - x_min, y_max - y_min)
