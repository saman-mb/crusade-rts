class_name ToolState
extends RefCounted
## Pure state machine for the map editor's active tool. No Node/scene deps; ALL
## tool selection, mutation, and keymap logic lives here so it is fully headless-testable.
## Maps 1:1 onto undo batching: is_mutating() == false for EYEDROPPER is exactly why
## the runtime skips UndoRedo for it (eyedropper reads, it never creates an undo entry).

## Editor tool: PAINT writes tiles, EYEDROPPER samples a tile (read-only), BUCKET flood-fills.
enum Tool { PAINT, EYEDROPPER, BUCKET }

var tool: int = Tool.PAINT  ## The active tool. Starts on PAINT.

## Sets the active tool. Out-of-range values are IGNORED (guarded by a range check):
## the tool is left unchanged rather than clamped, so a stray keycode/index is a no-op.
func select(t: int) -> void:
	if t < Tool.PAINT or t > Tool.BUCKET:
		return
	tool = t

## True when the active tool changes tiles and therefore produces an undo entry:
## PAINT and BUCKET mutate; EYEDROPPER is read-only and creates NO undo entry.
## This predicate is the ONLY place the "eyedropper creates no undo entry" rule is encoded.
func is_mutating() -> bool:
	return tool == Tool.PAINT or tool == Tool.BUCKET

## True only for PAINT, which accumulates a press->drag->release stroke into ONE undo action.
## BUCKET also produces exactly one undo action (see is_mutating()), but it is a one-shot fill,
## not a drag-stroke accumulation, so creates_stroke() is FALSE for it. EYEDROPPER is false.
## Semantics: is_mutating() answers "produces an undo action"; creates_stroke() distinguishes
## a multi-cell drag accumulation (PAINT) from a single-shot action (BUCKET).
func creates_stroke() -> bool:
	return tool == Tool.PAINT

## Human-readable label for HUD/debug. Distinct non-empty string per tool.
func label() -> String:
	match tool:
		Tool.PAINT:
			return "Paint"
		Tool.EYEDROPPER:
			return "Eyedropper"
		Tool.BUCKET:
			return "Bucket Fill"
	return ""

## Pure key -> Tool mapping. Returns a Tool value or -1 if unmapped.
## Mapping: B -> PAINT (brush), I -> EYEDROPPER, G -> BUCKET (fill).
## Chosen to AVOID existing editor bindings: W/A/S/D (camera), [ / ] (KEY_BRACKETLEFT/RIGHT,
## elevation-tier cycle), 1/2/3 (layer switch), and , / . (the dev day/night scrub, moved
## onto those keys in #100) all return -1 here.
static func from_keycode(keycode: int) -> int:
	match keycode:
		KEY_B:
			return Tool.PAINT
		KEY_I:
			return Tool.EYEDROPPER
		KEY_G:
			return Tool.BUCKET
	return -1
