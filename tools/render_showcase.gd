extends Node2D
## Renders the README showcase screenshots (wide / cliff / hero) from the REAL
## project: instances map_system.tscn (so terrain variation, cliffs and doodads run),
## sets a golden-hour rig, adds faked campfire light sources, and applies a full-screen
## golden grade + warm-horizon background. Run head-ful:
##   godot --path . --rendering-driver vulkan res://tools/render_showcase.tscn
## Writes res://_probe_{wide,cliff,hero}.png. Screenshot-composition tool only: the
## grade + campfire glow are photo styling; the terrain lighting + cliffs are real
## engine features (terrain_tint.gdshader / cliff_renderer.gd).
const LIGHT_TEX := "res://assets/lights/point_light.png"
const FIRE_TEX := "res://assets/doodads/campfire.png"

const GRADE_CODE := "shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
void fragment(){
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	float lum = dot(c, vec3(0.299,0.587,0.114));
	vec3 hi = vec3(1.0,0.906,0.76); vec3 lo = vec3(0.50,0.56,0.72);
	c *= mix(lo, hi, smoothstep(0.12,0.88,lum));
	c = mix(vec3(lum), c, 1.12);
	vec2 uv = SCREEN_UV;
	float sweep = clamp(1.0 - (uv.x*0.5 + uv.y*0.55), 0.0, 1.0);
	c += vec3(1.0,0.77,0.42)*sweep*0.12;
	float d = length(uv-vec2(0.5));
	c *= mix(1.0,0.72,smoothstep(0.42,1.0,d));
	COLOR = vec4(c,1.0);
}"

const BG_CODE := "shader_type canvas_item;
void fragment(){
	vec3 top = vec3(0.91,0.78,0.60); vec3 bot = vec3(0.42,0.30,0.22);
	COLOR = vec4(mix(top,bot,UV.y),1.0);
}"

func _ready() -> void:
	_full_rect_shader(BG_CODE, -100)
	var scene: PackedScene = load("res://src/nodes/map_system.tscn")
	var map: MapSystem = scene.instantiate()
	add_child(map)
	for _i in range(50):
		await get_tree().process_frame
	_golden_hour(map)
	_add_campfire(map, Vector2i(26, 16))
	_add_campfire(map, Vector2i(15, 21))
	_full_rect_shader(GRADE_CODE, 100)
	# wide establishing (whole world)
	_frame_camera(map, Vector2i(16, 14), 0.6)
	await _settle(); _capture("res://_probe_wide.png")
	# verticality / cliff
	_frame_camera(map, Vector2i(24, 13), 1.15)
	await _settle(); _capture("res://_probe_cliff.png")
	# hero
	_frame_camera(map, Vector2i(24, 15), 1.5)
	await _settle(); _capture("res://_probe_hero.png")
	get_tree().quit()


func _settle() -> void:
	for _i in range(8): await get_tree().process_frame
	await RenderingServer.frame_post_draw

func _capture(path: String) -> void:
	get_viewport().get_texture().get_image().save_png(path); print("[shot] %s" % path)

func _full_rect_shader(code: String, layer_idx: int) -> void:
	var cl := CanvasLayer.new(); cl.layer = layer_idx; add_child(cl)
	var rect := ColorRect.new(); rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sh := Shader.new(); sh.code = code
	var mat := ShaderMaterial.new(); mat.shader = sh
	rect.material = mat; cl.add_child(rect)

func _golden_hour(map: MapSystem) -> void:
	var dn: CanvasModulate = map.get_node_or_null("DayNight") as CanvasModulate
	if dn != null:
		dn.set_process(false); dn.color = Color(0.90, 0.86, 0.78)
	var sun: DirectionalLight2D = map.get_node_or_null("Sun") as DirectionalLight2D
	if sun != null:
		sun.set("tint_from_day_night", false); sun.set_process(false)
		sun.color = Color(1.0, 0.85, 0.63); sun.energy = 0.55

func _glow(tex: Texture2D, col: Color, size_px: float, alpha: float, squash: float) -> Sprite2D:
	var s := Sprite2D.new(); s.texture = tex
	s.modulate = Color(col.r, col.g, col.b, alpha)
	var m := CanvasItemMaterial.new(); m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	s.material = m
	var sc := size_px / 256.0; s.scale = Vector2(sc, sc * squash)
	return s

func _add_campfire(map: MapSystem, cell: Vector2i) -> void:
	var pos := IsoCoord.cart_to_iso(cell)
	# soft warm glow pool (additive, squashed to ground), warmer + softer than before
	var ltex := load(LIGHT_TEX) as Texture2D
	if ltex != null:
		var outer := _glow(ltex, Color(1.0,0.52,0.18), 300.0, 0.30, 0.5); outer.position = pos; map.add_child(outer)
		var inner := _glow(ltex, Color(1.0,0.66,0.28), 120.0, 0.55, 0.5); inner.position = pos; map.add_child(inner)
	# the fire object itself (source), sits on the ground
	var ftex := load(FIRE_TEX) as Texture2D
	if ftex != null:
		var fire := Sprite2D.new(); fire.texture = ftex; fire.position = pos
		map.add_child(fire)
		var core := _glow(ltex, Color(1.0,0.54,0.22), 44.0, 0.9, 0.8); core.position = pos + Vector2(0,-8); map.add_child(core)

func _frame_camera(map: MapSystem, cell: Vector2i, z: float) -> void:
	var cam: Camera2D = map.get_node_or_null("Camera") as Camera2D
	if cam == null: return
	var layer: TileMapLayer = map.get_elevation_layer(0)
	var world: Vector2 = layer.map_to_local(cell) if layer != null else Vector2.ZERO
	cam.world_bounds = Rect2(); cam.target_position = world; cam.target_zoom = z
	cam.position = world; cam.zoom = Vector2(z, z)
