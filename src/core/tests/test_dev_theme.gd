extends SceneTree
## Headless tests for DevTheme: assert `build()` returns a fully-configured Theme
## with the key style tokens applied (no Node/GPU deps; constructs the Theme in
## memory). Run: godot --headless --script <this file>.

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	_test_build()

	print("PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)

# --- helpers ---

## Increments counters; prints only on failure so passing runs stay quiet.
func _ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: %s" % msg)

## Exact int equality check with message.
func _i_eq(a: int, b: int, msg: String) -> void:
	_ok(a == b, "%s: expected %d got %d" % [msg, b, a])

# --- tests ---

func _test_build() -> void:
	var theme := DevTheme.build()
	_ok(theme != null, "build() returns a Theme")
	_ok(theme is Theme, "build() result is a Theme")

	# Button state styleboxes and the panel are all registered.
	_ok(theme.has_stylebox("normal", "Button"), "Button has 'normal' stylebox")
	_ok(theme.has_stylebox("hover", "Button"), "Button has 'hover' stylebox")
	_ok(theme.has_stylebox("focus", "Button"), "Button has 'focus' stylebox")
	_ok(theme.has_stylebox("panel", "PanelContainer"), "PanelContainer has 'panel' stylebox")

	# Font sizing token.
	_i_eq(theme.get_font_size("font_size", "Button"), 18, "Button font_size == 18")

	# Button normal stylebox geometry.
	var normal := theme.get_stylebox("normal", "Button")
	_ok(normal is StyleBoxFlat, "Button 'normal' is a StyleBoxFlat")
	var flat := normal as StyleBoxFlat
	_i_eq(flat.corner_radius_top_left, 4, "Button normal corner_radius == 4")
	_i_eq(flat.border_width_left, 1, "Button normal border_width == 1")

	# Button font colour is opaque.
	_ok(theme.get_color("font_color", "Button").a > 0.0, "Button font_color alpha > 0")

	# TitleLabel variation carries the accent colour token.
	var title_color := theme.get_color("font_color", "TitleLabel")
	_ok(title_color.is_equal_approx(DevTheme.ACCENT), "TitleLabel font_color == ACCENT token")
