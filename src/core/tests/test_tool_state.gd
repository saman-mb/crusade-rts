extends GdTest
## Pure-logic tests for ToolState (no Node deps; drives only the state machine + static keymap).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Guards the undo rule (EYEDROPPER is non-mutating) and the keycode collision guards.


func _run() -> void:
	_test_initial()
	_test_select()
	_test_invalid_select()
	_test_is_mutating()
	_test_creates_stroke()
	_test_label()
	_test_from_keycode()


# --- tests ---

## A fresh ToolState starts on PAINT.
func _test_initial() -> void:
	var ts := ToolState.new()
	_i_eq(ts.tool, ToolState.Tool.PAINT, "initial tool is PAINT")

## select() sets the active tool; every tool round-trips.
func _test_select() -> void:
	var ts := ToolState.new()
	ts.select(ToolState.Tool.EYEDROPPER)
	_i_eq(ts.tool, ToolState.Tool.EYEDROPPER, "select(EYEDROPPER) -> EYEDROPPER")
	ts.select(ToolState.Tool.BUCKET)
	_i_eq(ts.tool, ToolState.Tool.BUCKET, "select(BUCKET) -> BUCKET")
	ts.select(ToolState.Tool.PAINT)
	_i_eq(ts.tool, ToolState.Tool.PAINT, "select(PAINT) -> PAINT")

## Out-of-range select() is a no-op; the tool stays at its prior value.
func _test_invalid_select() -> void:
	var ts := ToolState.new()
	ts.select(ToolState.Tool.BUCKET)
	ts.select(99)
	_i_eq(ts.tool, ToolState.Tool.BUCKET, "select(99) ignored -> stays BUCKET")
	ts.select(-1)
	_i_eq(ts.tool, ToolState.Tool.BUCKET, "select(-1) ignored -> stays BUCKET")

## is_mutating(): true for PAINT and BUCKET (they create undo entries), FALSE for EYEDROPPER.
func _test_is_mutating() -> void:
	var ts := ToolState.new()
	ts.select(ToolState.Tool.PAINT)
	_ok(ts.is_mutating() == true, "PAINT is_mutating -> true")
	ts.select(ToolState.Tool.BUCKET)
	_ok(ts.is_mutating() == true, "BUCKET is_mutating -> true")
	ts.select(ToolState.Tool.EYEDROPPER)
	_ok(ts.is_mutating() == false, "EYEDROPPER is_mutating -> false (no undo entry)")

## creates_stroke(): true ONLY for PAINT (drag accumulation); BUCKET one-shot and EYEDROPPER false.
func _test_creates_stroke() -> void:
	var ts := ToolState.new()
	ts.select(ToolState.Tool.PAINT)
	_ok(ts.creates_stroke() == true, "PAINT creates_stroke -> true")
	ts.select(ToolState.Tool.BUCKET)
	_ok(ts.creates_stroke() == false, "BUCKET creates_stroke -> false (one-shot fill)")
	ts.select(ToolState.Tool.EYEDROPPER)
	_ok(ts.creates_stroke() == false, "EYEDROPPER creates_stroke -> false")

## label(): distinct, non-empty human strings per tool.
func _test_label() -> void:
	var ts := ToolState.new()
	ts.select(ToolState.Tool.PAINT)
	_ok(ts.label() == "Paint", "PAINT label -> 'Paint'")
	ts.select(ToolState.Tool.EYEDROPPER)
	_ok(ts.label() == "Eyedropper", "EYEDROPPER label -> 'Eyedropper'")
	ts.select(ToolState.Tool.BUCKET)
	_ok(ts.label() == "Bucket Fill", "BUCKET label -> 'Bucket Fill'")

## from_keycode(): B/I/G map to tools; unmapped and existing-binding keys return -1.
func _test_from_keycode() -> void:
	_i_eq(ToolState.from_keycode(KEY_B), ToolState.Tool.PAINT, "KEY_B -> PAINT")
	_i_eq(ToolState.from_keycode(KEY_I), ToolState.Tool.EYEDROPPER, "KEY_I -> EYEDROPPER")
	_i_eq(ToolState.from_keycode(KEY_G), ToolState.Tool.BUCKET, "KEY_G -> BUCKET")
	_i_eq(ToolState.from_keycode(KEY_Q), -1, "KEY_Q unmapped -> -1")
	# Collision guards: existing editor bindings must NOT map to a tool.
	_i_eq(ToolState.from_keycode(KEY_BRACKETLEFT), -1, "KEY_BRACKETLEFT (editor) -> -1")
	_i_eq(ToolState.from_keycode(KEY_1), -1, "KEY_1 (layer switch) -> -1")
	_i_eq(ToolState.from_keycode(KEY_W), -1, "KEY_W (camera) -> -1")
