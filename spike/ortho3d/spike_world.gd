extends Node
## SPIKE — Option B: Godot 3D engine + ORTHOGRAPHIC camera + a PIXEL-ART render
## pipeline, as an alternative to the shipped pure-2D (Node2D/TileMapLayer) engine.
##
## The whole scene is built in code from this one script (no hand-authored .tscn
## graph to drift), mirroring how tools/render_showcase.gd builds the 2D showcase.
## What it proves, in one frame:
##   * PIXEL ART for free — the 3D world renders into a low-res SubViewport (384x216)
##     that is upscaled NEAREST to the window, so everything reads as crisp pixels.
##   * DEPTH SORTING for free — unit A stands on the plateau BEHIND the tower and is
##     occluded by the hardware Z-buffer. No y-sort script, no z_index math.
##   * REAL VERTICALITY — two terrain tiers joined by a real ramp; the unit's height
##     is just its Y, not faked elevation bookkeeping.
##   * 3D PICKING — click-select via a camera ray + physics query; click-move via a
##     ray against the ground collider.
##
## Assets are Godot primitives standing in for future Blender / Quaternius / Kenney
## CC0 models — the point is the PIPELINE, not the art. Spike code, not production.
##
## Run interactively:  godot --path . res://spike/ortho3d/ortho3d_spike.tscn
## Auto-screenshot:     ... res://spike/ortho3d/ortho3d_spike.tscn -- --shoot
##   (writes res://_spike_b.png after SHOT_FRAME frames, then quits)

const VIEW_W := 384
const VIEW_H := 216
const GROUND_LAYER := 1          # collision bit for the ground (click-to-move rays)
const UNITS_LAYER := 2           # matches unit.gd; click-to-select rays use this
const SHOT_FRAME := 100          # frame at which --shoot captures and quits

var _auto_shoot := false
var _frame := 0
var _subvp: SubViewport
var _cam: Camera3D
var _units: Array = []
var _unit_a                      # the walker (scripted in interactive mode)
var _walk := []                  # waypoints for unit A's interactive stroll
var _walk_i := 0


func _ready() -> void:
	_auto_shoot = OS.get_cmdline_args().has("--shoot") or OS.get_cmdline_user_args().has("--shoot")
	_build_pixel_pipeline()
	_build_environment()
	_build_camera()
	_build_terrain()
	_build_building()
	_build_doodads()
	_build_units()
	set_process(true)


## Root -> SubViewportContainer (NEAREST upscale) -> SubViewport (low-res 3D world).
## This IS the pixel-art look: render small, blow it up with no interpolation.
func _build_pixel_pipeline() -> void:
	var container := SubViewportContainer.new()
	container.stretch = true                                   # scale the low-res VP to fill
	# stretch_shrink = N makes the SubViewport render at container_size / N and then
	# blow it back up. THIS is what makes it low-res: at a 1920-wide window, /5 renders
	# the 3D world at ~384px wide, upscaled NEAREST -> chunky pixels. (Without this,
	# stretch renders the viewport at full window res and there is no pixel-art look.)
	container.stretch_shrink = 5
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # crisp pixels, no blur
	add_child(container)
	_subvp = SubViewport.new()
	_subvp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_subvp.msaa_3d = Viewport.MSAA_DISABLED                    # aliasing is the aesthetic
	_subvp.own_world_3d = true
	container.add_child(_subvp)


func _build_environment() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.53, 0.62, 0.78)             # cool sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.72)
	env.ambient_light_energy = 0.55                           # lift shadows out of pure black
	we.environment = env
	_subvp.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -132.0, 0.0)        # warm NW key, rakes the tiers
	sun.light_color = Color(1.0, 0.94, 0.82)
	sun.light_energy = 1.25
	sun.shadow_enabled = true                                 # REAL 3D shadows, not painted
	_subvp.add_child(sun)


func _build_camera() -> void:
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL           # the RTS "no perspective" look
	_cam.size = 12.5                                           # ortho view height in world units (tighter -> bigger pixels)
	_cam.position = Vector3(16.0, 15.0, 16.0)                 # classic +x+y+z iso octant
	_subvp.add_child(_cam)
	_cam.look_at(Vector3(-1.0, 1.2, -1.0), Vector3.UP)        # frame the plateau/tower


func _build_terrain() -> void:
	# Lower ground plane (y=0) with a click collider on the GROUND layer.
	var ground := _box(Vector3(20.0, 0.4, 20.0), Vector3(0.0, -0.2, 0.0),
			_grass_material(), true, GROUND_LAYER)
	ground.name = "Ground"

	# Raised plateau (top at y=2), far corner so its near faces read as cliff walls.
	var plateau := _box(Vector3(6.0, 2.0, 6.0), Vector3(-3.0, 1.0, -3.0),
			_grass_material(), true, GROUND_LAYER)
	plateau.name = "Plateau"
	# Cliff skirt: a slightly larger dark-rock band on the plateau sides so the wall
	# reads as rock, not grass (top stays grass because the grass box sits on top).
	var cliff := _box(Vector3(6.2, 1.9, 6.2), Vector3(-3.0, 0.95, -3.0),
			_rock_material(), false, 0)
	cliff.name = "CliffFace"

	# Ramp: a tilted slab joining the lower ground to the plateau's +z face.
	var ramp := _box(Vector3(2.4, 0.3, 3.4), Vector3(-2.0, 1.0, 1.15),
			_rock_material(), true, GROUND_LAYER)
	ramp.rotation_degrees = Vector3(36.0, 0.0, 0.0)
	ramp.name = "Ramp"


func _build_building() -> void:
	# A tower on the plateau top. Unit A walks BEHIND this (farther -x/-z from the
	# camera) so the depth buffer occludes it — the whole point of the demo.
	var body_mat := _lit(Color(0.74, 0.70, 0.60))
	var roof_mat := _lit(Color(0.45, 0.22, 0.18))
	var tower := _mesh(_box_mesh(Vector3(1.7, 2.4, 1.7)), Vector3(-2.2, 3.2, -2.2), body_mat)
	tower.name = "Tower"
	var roof := PrismMesh.new()
	roof.size = Vector3(1.9, 1.0, 1.9)
	_mesh(roof, Vector3(-2.2, 4.9, -2.2), roof_mat).name = "TowerRoof"
	# Door.
	_mesh(_box_mesh(Vector3(0.5, 0.9, 0.1)), Vector3(-1.35, 2.45, -1.35), _lit(Color(0.2, 0.15, 0.12)))


func _build_doodads() -> void:
	# Tree = trunk cylinder + canopy cone; rock = squashed sphere. Real meshes, lit,
	# shadow-casting, depth-sorted like everything else.
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.12; trunk.bottom_radius = 0.16; trunk.height = 0.9
	_mesh(trunk, Vector3(3.4, 0.45, 2.0), _lit(Color(0.36, 0.26, 0.16)))
	var canopy := SphereMesh.new()
	canopy.radius = 0.7; canopy.height = 1.3
	_mesh(canopy, Vector3(3.4, 1.35, 2.0), _lit(Color(0.24, 0.42, 0.20)))

	var rock := SphereMesh.new()
	rock.radius = 0.45; rock.height = 0.6
	var r := _mesh(rock, Vector3(4.6, 0.22, 0.4), _lit(Color(0.48, 0.47, 0.45)))
	r.scale = Vector3(1.0, 0.6, 1.2)


func _build_units() -> void:
	var UnitScript := load("res://spike/ortho3d/unit.gd")

	# Unit A — the walker. In --shoot it is posed on the plateau BEHIND the tower.
	_unit_a = UnitScript.new()
	_unit_a.configure(Color(0.85, 0.22, 0.20))
	_subvp.add_child(_unit_a)
	_units.append(_unit_a)
	if _auto_shoot:
		_unit_a.global_position = Vector3(-1.2, 2.0, -0.7)    # atop the plateau near the ramp head — high ground, facing camera (verticality vs unit B below)
	else:
		_unit_a.global_position = Vector3(4.5, 0.0, 4.5)
		_walk = [Vector3(1.6, 0.0, 1.6), Vector3(-2.0, 2.0, -0.6),
				Vector3(-3.7, 2.0, -3.7)]                     # ground -> up ramp -> behind tower

	# Unit B — a blue trooper on the lower ground, pre-selected (ring on).
	var b = UnitScript.new()
	b.configure(Color(0.24, 0.42, 0.85))
	_subvp.add_child(b)
	b.global_position = Vector3(2.2, 0.0, -1.0)
	b.set_selected(true)
	_units.append(b)


func _process(_delta: float) -> void:
	# Interactive stroll for unit A (skipped in --shoot, which poses it directly).
	if not _auto_shoot and _walk_i < _walk.size() and _unit_a != null:
		var tgt: Vector3 = _walk[_walk_i]
		var to: Vector3 = tgt - _unit_a.global_position
		if to.length() <= 0.05:
			_walk_i += 1
		else:
			_unit_a.global_position += to.normalized() * min(2.5 * _delta, to.length())

	if not _auto_shoot:
		return
	_frame += 1
	if _frame == SHOT_FRAME:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://_spike_b.png")
		print("[spike] wrote res://_spike_b.png (%dx%d)" % [img.get_width(), img.get_height()])
		get_tree().quit()


## LMB: select the unit under the cursor, else move the selected unit(s) to the
## clicked ground point. Rays are cast in the SubViewport's own World3D.
func _input(event: InputEvent) -> void:
	if _auto_shoot:
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var vp_pos := _to_subviewport(mb.position)
	var from := _cam.project_ray_origin(vp_pos)
	var dir := _cam.project_ray_normal(vp_pos)
	var space := _subvp.find_world_3d().direct_space_state
	# Try units first.
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 200.0, UNITS_LAYER)
	var hit := space.intersect_ray(q)
	if hit:
		for u in _units:
			u.set_selected(u == hit.collider.get_parent())
		return
	# Else move the selected unit to the ground hit.
	q = PhysicsRayQueryParameters3D.create(from, from + dir * 200.0, GROUND_LAYER)
	hit = space.intersect_ray(q)
	if hit:
		for u in _units:
			if u.is_selected():
				u.set_move_target(hit.position)


## Map a window-space mouse position into the stretched SubViewport's pixel space.
func _to_subviewport(win_pos: Vector2) -> Vector2:
	var rect := get_viewport().get_visible_rect().size
	if rect.x <= 0.0 or rect.y <= 0.0:
		return win_pos
	return Vector2(win_pos.x / rect.x * VIEW_W, win_pos.y / rect.y * VIEW_H)


# ---- small builders -------------------------------------------------------------

func _mesh(m: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	_subvp.add_child(mi)
	mi.global_position = pos
	return mi


func _box_mesh(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


## A box with an optional StaticBody collider on `layer` (0 = no collider).
func _box(size: Vector3, pos: Vector3, mat: Material, collide: bool, layer: int) -> Node3D:
	var mi := _mesh(_box_mesh(size), pos, mat)
	if collide:
		var body := StaticBody3D.new()
		body.collision_layer = layer
		body.collision_mask = 0
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		body.add_child(cs)
		mi.add_child(body)
	return mi


func _lit(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.95
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return m


func _grass_material() -> StandardMaterial3D:
	var m := _lit(Color.WHITE)
	m.albedo_texture = _pixel_texture([
		Color(0.30, 0.45, 0.22), Color(0.34, 0.50, 0.24),
		Color(0.28, 0.42, 0.20), Color(0.37, 0.53, 0.26)])
	m.uv1_scale = Vector3(6.0, 6.0, 6.0)
	m.uv1_triplanar = true                                    # tile on all faces without UVs
	return m


func _rock_material() -> StandardMaterial3D:
	var m := _lit(Color.WHITE)
	m.albedo_texture = _pixel_texture([
		Color(0.42, 0.38, 0.33), Color(0.36, 0.32, 0.28),
		Color(0.30, 0.27, 0.24), Color(0.46, 0.42, 0.37)])
	m.uv1_scale = Vector3(4.0, 4.0, 4.0)
	m.uv1_triplanar = true
	return m


## Tiny procedural tiling texture (8x8) from a 4-colour palette -- a nod to the
## pixel-art aesthetic; NEAREST filtering keeps the texels crisp under the ortho cam.
func _pixel_texture(palette: Array) -> ImageTexture:
	var img := Image.create(8, 8, false, Image.FORMAT_RGB8)
	var h := 1
	for y in range(8):
		for x in range(8):
			h = (h * 1103515245 + 12345) & 0x7fffffff
			img.set_pixel(x, y, palette[h % palette.size()])
	return ImageTexture.create_from_image(img)
