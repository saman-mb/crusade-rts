# Contributing to Crusade

Thanks for hacking on Crusade. This project keeps a tight testing and code-hygiene
contract so the map engine stays headless-testable and CI stays trustworthy. Please
read this before opening a PR.

## Engine

- **Godot 4.4.1** exactly (the version CI installs — see `.github/workflows/ci.yml`
  and `config/features` in `project.godot`). Newer/older point releases may import
  or lint differently.
- No C#/.NET — the project is pure GDScript (`use-dotnet: false` in CI).

## Architecture & the testing contract

The source tree splits into three tiers, and **what CI executes depends on the tier**:

| Directory | Role | What CI does with it |
|-----------|------|----------------------|
| `src/core/` | Pure `RefCounted` libraries — math, serialization, autotiling, steering, nav. No `Node`, no scene, no file IO in the hot path. | **Executed.** Every `src/core/tests/test_*.gd` runs headless and must pass. |
| `src/nodes/`, `src/editor/` | Runtime nodes (map system, editor, camera, persistence, units). Not `@tool`. | **Parsed only.** `--import` proves they *compile*; their `_ready`/input never runs headless. |
| `src/ui/` | In-game UI (dev menu, theme). | Parsed only. |

The design rule that follows from this: **push all decision logic down into a pure
`src/core/` library and unit-test it there.** A runtime node should be a thin wrapper
that wires engine input/tree state to those pure calls. Green CI on a node file proves
it parses, **not** that it behaves — only the pure cores and `test_*.gd` files actually
execute. (See `docs/` for the per-subsystem write-ups.)

Examples of this split already in the tree: `BrushCore` (pure) vs `MapEditor` (node);
`DayNight` (pure) vs `day_night_driver.gd` (node); `Selection`/`Marquee`/`FlowField`
(pure) vs `unit_debug.gd` (node).

### Test convention

- Tests live in `src/core/tests/` and are named `test_*.gd`.
- Each is a standalone script run via `godot --headless --script res://src/core/tests/test_x.gd`.
- Each suite prints a `PASS n / FAIL m` summary line. CI treats a `FAIL: ` assert line,
  a nonzero `FAIL m`, a missing `PASS ` line (crash), **or** a nonzero exit code as failure.
- Shared assert helpers live in `src/core/tests/gd_test.gd`.
- **New pure logic must ship with a `test_*.gd`.** New runtime behavior should be
  refactored so its decisions live in a testable core.

## Running the tests locally

CI (`.github/workflows/ci.yml`) does two things: a fresh import, then a per-test run.
Reproduce it locally from the repo root:

```bash
# 1. Fresh import (regenerates the class cache; --import can exit nonzero on benign
#    messages, hence we don't assert its code).
rm -rf .godot
godot --headless --path . --import

# 2. Run every core test, failing the run if any suite reports FAIL / crashes.
fail=0
for t in src/core/tests/test_*.gd; do
  echo "== $t =="
  out="$(godot --headless --path . --script "res://$t" 2>&1)"; code=$?
  echo "$out"
  echo "$out" | grep -Eq 'FAIL: |FAIL [1-9]' && { echo "FAIL in $t"; fail=1; }
  echo "$out" | grep -q 'PASS ' || { echo "no PASS summary in $t"; fail=1; }
  [ "$code" -ne 0 ] && { echo "$t exited $code"; fail=1; }
done
exit "$fail"
```

Run a single suite while iterating:

```bash
godot --headless --path . --script res://src/core/tests/test_map_validator.gd
```

## Warnings-as-errors

This project treats GDScript warnings as **errors** — a warning fails `--import` and
therefore CI. The one that bites most often:

> **Never `var x := <Variant>`.** Godot cannot infer a concrete type from a `Variant`
> source (a `Dictionary`/`Array` index, a `Callable.call()` result, `JSON.get_data()`,
> a `.get()` with a Variant default). Annotate the type explicitly instead:

```gdscript
var data: Variant = json.get_data()        # explicit Variant
var ok: bool = result["ok"]                 # not  var ok := result["ok"]
var layer: TileMapLayer = layers[i]         # not  var layer := layers[i]
```

Cast when you know the concrete type (`var n := int(cell["s"])`), and prefer reading
Dictionary values into an explicitly-typed local. When in doubt, run the local import
step above — it surfaces the exact warning and line.

## Assets & licensing

Only assets whose licenses permit redistribution are vendored — **CC0 preferred**, or
**CC-BY** with attribution recorded in `CREDITS.md`. The terrain atlas is composited
from CC0 source art by `tools/pack_terrain_atlas.py`; see `CREDITS.md` and
`assets/tilesets/sources/SOURCE.txt`. If you add art, record its provenance the same way.

## Before you open a PR

1. `rm -rf .godot && godot --headless --path . --import` is clean (no warnings/errors).
2. All `src/core/tests/test_*.gd` pass locally.
3. New pure logic has a matching `test_*.gd`.
4. New third-party assets are CC0/CC-BY and credited in `CREDITS.md`.
5. Keep runtime nodes thin; put logic in a pure core.

CI runs the same import + test loop on every PR to `main` and must be green to merge.
