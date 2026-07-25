extends Node2D
## Renders the README showcase screenshots (wide / cliff / hero) from the REAL
## project: instances map_system.tscn (so mega-tile terrain, cliffs, doodads and
## trees all run), sets the golden-hour rig, then layers the screenshot-only
## atmosphere pass: campfires with smoke + fireflies, a sun-glint band on the
## lake, shore mist, and a full-screen golden grade (split-tone S-curve, warm
## sun sweep, cool depth multiply, vignette). Run head-ful:
##   godot --path . --rendering-driver vulkan res://tools/render_showcase.tscn
## Writes res://_probe_{wide,cliff,hero}.png. The grade/glow/mist are photo
## styling; terrain lighting, cliffs, doodads and trees are real engine output.
const LIGHT_TEX := "res://assets/lights/point_light.png"
const FIRE_TEX := "res://assets/doodads/campfire.png"

const GRADE_CODE := "shader_type canvas_item;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
void fragment(){
	vec2 uv = SCREEN_UV;
	vec3 c = texture(screen_tex, uv).rgb;
	// S-curve + split-tone: warm highlights, cool shadows (lead-artist grade).
	float lum = dot(c, vec3(0.299,0.587,0.114));
	// Local contrast (unsharp on luma, ~28px radius): SC1's hard value read.
	vec2 px = vec2(0.0146, 0.026);
	float l2 = dot(texture(screen_tex, uv + vec2(px.x, 0.0)).rgb, vec3(0.299,0.587,0.114));
	float l3 = dot(texture(screen_tex, uv - vec2(px.x, 0.0)).rgb, vec3(0.299,0.587,0.114));
	float l4 = dot(texture(screen_tex, uv + vec2(0.0, px.y)).rgb, vec3(0.299,0.587,0.114));
	float l5 = dot(texture(screen_tex, uv - vec2(0.0, px.y)).rgb, vec3(0.299,0.587,0.114));
	float lavg = (l2 + l3 + l4 + l5) * 0.25;
	c *= 1.0 + clamp(lum - lavg, -0.15, 0.15) * 0.15 / max(lum, 0.05);
	vec3 hi = vec3(0.99,0.95,0.87); vec3 lo = vec3(0.50,0.55,0.73);
	c *= mix(lo, hi, smoothstep(0.10,0.86,lum));
	c = mix(vec3(lum), c, 0.97);
	c = clamp(c * 1.11 - 0.025, 0.0, 2.0);
	// Warm sun sweep from upper-left, gone by ~55% across the frame.
	float sweep = clamp(1.0 - (uv.x*0.9 + uv.y*0.95), 0.0, 1.0);
	c += vec3(1.0,0.87,0.64)*sweep*0.045;
	// Cool depth multiply from lower-right.
	float depth = clamp((uv.x*0.6 + uv.y*0.75) - 0.55, 0.0, 1.0);
	c *= mix(vec3(1.0), vec3(0.275,0.322,0.478), depth*0.11);
	// Wide cool vignette.
	float d = length(uv-vec2(0.5));
	c = mix(c, c*vec3(0.62,0.66,0.82), smoothstep(0.5,1.05,d)*0.26);
	COLOR = vec4(c,1.0);
}"

const BG_CODE := "shader_type canvas_item;
void fragment(){
	vec3 top = vec3(0.54,0.455,0.376); vec3 bot = vec3(0.275,0.235,0.204);
	COLOR = vec4(mix(top,bot,UV.y),1.0);
}"

var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20260728
	_full_rect_shader(BG_CODE, -100)
	var scene: PackedScene = load("res://src/nodes/map_system.tscn")
	var map: MapSystem = scene.instantiate()
	add_child(map)
	for _i in range(50):
		await get_tree().process_frame
	_golden_hour(map)
	var fires := [Vector2i(26, 16), Vector2i(14, 21)]
	_set_firelight(map, fires)
	for c in fires:
		_add_campfire(map, c)
	_add_glint(map, Vector2i(6, 7))
	_add_mist(map)
	_full_rect_shader(GRADE_CODE, 100)
	_frame_camera(map, Vector2i(16, 14), 0.6)
	await _settle(); _capture("res://_probe_wide.png")
	_frame_camera(map, Vector2i(23, 13), 1.1)
	await _settle(); _capture("res://_probe_cliff.png")
	_frame_camera(map, Vector2i(24, 15), 1.2)
	await _settle(); _capture("res://_probe_hero.png")
	get_tree().quit()


func _settle() -> void:
	for _i in range(8):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


func _capture(path: String) -> void:
	get_viewport().get_texture().get_image().save_png(path)
	print("[shot] %s" % path)


func _full_rect_shader(code: String, layer_idx: int) -> void:
	var cl := CanvasLayer.new()
	cl.layer = layer_idx
	add_child(cl)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sh := Shader.new()
	sh.code = code
	var mat := ShaderMaterial.new()
	mat.shader = sh
	rect.material = mat
	cl.add_child(rect)


func _golden_hour(map: MapSystem) -> void:
	var dn: CanvasModulate = map.get_node_or_null("DayNight") as CanvasModulate
	if dn != null:
		dn.set_process(false)
		dn.color = Color(0.98, 0.96, 0.91)
	var sun: DirectionalLight2D = map.get_node_or_null("Sun") as DirectionalLight2D
	if sun != null:
		sun.set("tint_from_day_night", false)
		sun.set_process(false)
		sun.color = Color(1.0, 0.85, 0.63)
		sun.energy = 0.72


func _glow(tex: Texture2D, col: Color, size_px: float, alpha: float, squash: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = tex
	s.modulate = Color(col.r, col.g, col.b, alpha)
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	s.material = m
	var sc := size_px / 256.0
	s.scale = Vector2(sc, sc * squash)
	return s


func _soft(tex: Texture2D, col: Color, w_px: float, h_px: float, alpha: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = tex
	s.modulate = Color(col.r, col.g, col.b, alpha)
	s.scale = Vector2(w_px / 256.0, h_px / 256.0)
	return s


## Drives the terrain shader's firelight uniforms (#252). The warm ground pools are
## computed in the terrain's own world-space fragment pass -- seamless across tiles,
## never a sprite occluded into a diamond -- so they read as light on the ground.
func _set_firelight(map: MapSystem, cells: Array) -> void:
	var layer: TileMapLayer = map.get_elevation_layer(0)
	if layer == null:
		return
	var mat := layer.material as ShaderMaterial
	if mat == null:
		return
	var positions := PackedVector2Array()
	for c in cells:
		positions.append(IsoCoord.cart_to_iso(c))
	mat.set_shader_parameter("fire_pos", positions)
	mat.set_shader_parameter("fire_count", positions.size())
	mat.set_shader_parameter("fire_color", Vector3(1.0, 0.58, 0.24))
	mat.set_shader_parameter("fire_radius", 240.0)
	mat.set_shader_parameter("fire_strength", 1.0)


func _add_campfire(map: MapSystem, cell: Vector2i) -> void:
	var pos := IsoCoord.cart_to_iso(cell)
	var ltex := load(LIGHT_TEX) as Texture2D
	# NOTE: the broad warm pool is now the terrain shader's firelight (see
	# _set_firelight) -- seamless on the ground, no tile clip. Only the tight flame
	# bloom stays a sprite below, sitting on top of the fire.
	var ftex := load(FIRE_TEX) as Texture2D
	if ftex != null:
		var fire := Sprite2D.new()
		fire.texture = ftex
		fire.position = pos
		map.add_child(fire)
		if ltex != null:
			var core := _glow(ltex, Color(1.0, 0.54, 0.22), 44.0, 0.9, 0.8)
			core.position = pos + Vector2(0, -8)
			map.add_child(core)
	if ltex == null:
		return
	# Smoke: soft grey puffs rising with a slight NE drift.
	for i in range(4):
		var t := float(i + 1)
		var puff := _soft(ltex, Color(0.62, 0.60, 0.57), 40.0 + 30.0 * t, 34.0 + 24.0 * t, 0.38 - 0.055 * t)
		puff.position = pos + Vector2(10.0 * t + _rng.randf_range(-4.0, 4.0), -34.0 * t)
		map.add_child(puff)
	# Fireflies: warm motes loosely clustered near the fire.
	for _i in range(11):
		var a := _rng.randf_range(0.0, TAU)
		var dist := _rng.randf_range(28.0, 140.0)
		var fpos := pos + Vector2(cos(a) * dist, sin(a) * dist * 0.5 - 10.0)
		var halo := _glow(ltex, Color(1.0, 0.87, 0.55), 9.0, 0.30, 1.0)
		halo.position = fpos
		map.add_child(halo)
		var mote := _glow(ltex, Color(1.0, 0.91, 0.60), 3.5, 0.85, 1.0)
		mote.position = fpos
		map.add_child(mote)


## Sun-glint band on the lake: additive warm flecks along the NW->SE sun axis.
func _add_glint(map: MapSystem, lake_cell: Vector2i) -> void:
	var ltex := load(LIGHT_TEX) as Texture2D
	if ltex == null:
		return
	var centre := IsoCoord.cart_to_iso(lake_cell)
	var axis := Vector2(2.0, 1.0).normalized()
	for _i in range(52):
		var along := _rng.randf_range(-190.0, 190.0)
		var across := _rng.randf_range(-34.0, 34.0)
		var fpos := centre + axis * along + Vector2(-axis.y, axis.x) * across
		var fleck := _glow(ltex, Color(1.0, 0.90, 0.70), _rng.randf_range(6.0, 18.0), 0.7, 0.32)
		fleck.position = fpos
		map.add_child(fleck)
	# Faint warm sky reflection over the lake's NW half -- ties the water into
	# the golden scene instead of leaving it a cool slate hole.
	var sky := _glow(ltex, Color(0.60, 0.46, 0.31), 560.0, 0.24, 0.42)
	sky.position = centre + Vector2(-70.0, -40.0)
	map.add_child(sky)


## Shore mist: faint cool wisps hugging the lake's SE shore.
func _add_mist(map: MapSystem) -> void:
	var ltex := load(LIGHT_TEX) as Texture2D
	if ltex == null:
		return
	for i in range(4):
		var cell := Vector2i(4 + i * 2, 10)
		var wisp := _soft(ltex, Color(0.78, 0.83, 0.88), _rng.randf_range(320.0, 480.0), _rng.randf_range(46.0, 70.0), 0.11)
		wisp.position = IsoCoord.cart_to_iso(cell) + Vector2(_rng.randf_range(-30.0, 30.0), 8.0)
		map.add_child(wisp)


func _frame_camera(map: MapSystem, cell: Vector2i, z: float) -> void:
	var cam: Camera2D = map.get_node_or_null("Camera") as Camera2D
	if cam == null:
		return
	var layer: TileMapLayer = map.get_elevation_layer(0)
	var world: Vector2 = layer.map_to_local(cell) if layer != null else Vector2.ZERO
	cam.world_bounds = Rect2()
	cam.target_position = world
	cam.target_zoom = z
	cam.position = world
	cam.zoom = Vector2(z, z)
