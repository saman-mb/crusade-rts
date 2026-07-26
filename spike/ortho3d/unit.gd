extends Node3D
## SPIKE — Option B (ortho-3D + pixel-art). One low-poly RTS unit assembled
## entirely from Godot primitive meshes: a stand-in for a future Blender /
## Quaternius / Kenney CC0 model. Building it from primitives proves the whole
## pipeline (real 3D mesh -> depth-sorted, lit, shadow-casting, pickable) with
## ZERO downloads or licensing. This is spike code, not production code.
##
## Owns: a team-coloured mesh, a flat ground selection ring, a picking collider
## on the UNITS physics layer, and dead-simple move-toward-target locomotion for
## interactive click-to-move. Unit A's scripted walk is driven externally by the
## world script (which sets global_position directly) until the player clicks.

const UNITS_LAYER := 2          # collision layer bit used for click-picking units
const MOVE_SPEED := 3.5         # world units / second (interactive click-to-move)
const ARRIVE_EPS := 0.05        # stop when this close to the move target

var team_color: Color = Color(0.85, 0.22, 0.20)
var _move_target: Vector3 = Vector3.ZERO
var _moving := false
var _ring: MeshInstance3D
var _selected := false


func configure(color: Color) -> void:
	team_color = color


func _ready() -> void:
	_build_body()
	_build_selection_ring()
	_build_picker()
	_move_target = global_position


func is_selected() -> bool:
	return _selected


func set_selected(value: bool) -> void:
	_selected = value
	if _ring != null:
		_ring.visible = value


## Interactive click-to-move: locomotion runs in _process toward this target.
func set_move_target(target: Vector3) -> void:
	_move_target = target
	_moving = true


func _process(delta: float) -> void:
	if not _moving:
		return
	var to_target := _move_target - global_position
	var dist := to_target.length()
	if dist <= ARRIVE_EPS:
		_moving = false
		return
	var step := MOVE_SPEED * delta
	if step >= dist:
		global_position = _move_target
		_moving = false
	else:
		global_position += to_target / dist * step


func _build_body() -> void:
	var body_mat := _solid_material(team_color)
	var dark_mat := _solid_material(Color(0.12, 0.12, 0.14))
	var skin_mat := _solid_material(Color(0.86, 0.68, 0.52))

	# Torso — a capsule reads as a stylised low-poly trooper body.
	var torso := MeshInstance3D.new()
	var torso_mesh := CapsuleMesh.new()
	torso_mesh.radius = 0.26
	torso_mesh.height = 1.0
	torso.mesh = torso_mesh
	torso.material_override = body_mat
	torso.position = Vector3(0.0, 0.5, 0.0)
	add_child(torso)

	# Shoulders — a wide box gives a readable military silhouette from iso.
	var shoulders := MeshInstance3D.new()
	var shoulder_mesh := BoxMesh.new()
	shoulder_mesh.size = Vector3(0.72, 0.24, 0.40)
	shoulders.mesh = shoulder_mesh
	shoulders.material_override = body_mat
	shoulders.position = Vector3(0.0, 0.9, 0.0)
	add_child(shoulders)

	# Head — a small sphere in a skin tone.
	var head := MeshInstance3D.new()
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.17
	head_mesh.height = 0.34
	head.mesh = head_mesh
	head.material_override = skin_mat
	head.position = Vector3(0.0, 1.2, 0.0)
	add_child(head)

	# Gun — a thin box cantilevered forward (-Z is the unit's facing).
	var gun := MeshInstance3D.new()
	var gun_mesh := BoxMesh.new()
	gun_mesh.size = Vector3(0.10, 0.10, 0.62)
	gun.mesh = gun_mesh
	gun.material_override = dark_mat
	gun.position = Vector3(0.30, 0.85, -0.18)
	add_child(gun)


func _build_selection_ring() -> void:
	_ring = MeshInstance3D.new()
	var ring_mesh := TorusMesh.new()
	# TorusMesh's rotational axis is +Y by default, so it lies flat in the XZ
	# plane — exactly what we want for a ground selection ring, no rotation.
	ring_mesh.inner_radius = 0.36
	ring_mesh.outer_radius = 0.50
	ring_mesh.rings = 8
	ring_mesh.ring_segments = 24
	_ring.mesh = ring_mesh
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(1.0, 0.95, 0.35)
	ring_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_ring.material_override = ring_mat
	_ring.position = Vector3(0.0, 0.04, 0.0)
	_ring.visible = false
	add_child(_ring)


func _build_picker() -> void:
	# StaticBody on the UNITS layer so the world's ray query (collision_mask =
	# UNITS_LAYER) hits units for selection; mask 0 so it never blocks anything.
	var body := StaticBody3D.new()
	body.collision_layer = UNITS_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.34
	capsule.height = 1.4
	shape.shape = capsule
	shape.position = Vector3(0.0, 0.7, 0.0)
	body.add_child(shape)
	add_child(body)


func _solid_material(color: Color) -> StandardMaterial3D:
	# Lit material (so the DirectionalLight3D shades it and it casts shadows) with
	# NEAREST filtering to stay on-model with the pixel-art pipeline.
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return mat
