# Integration harness

Throwaway dev tool. Runs the real game, headed, and injects synthetic
mouse+keyboard input through the ACTUAL input pipeline (`Input.warp_mouse` +
`Input.parse_input_event`) so it exercises real `_unhandled_input` code paths,
not mocks. Built to catch interactive-control bugs (map editor paint/erase/
undo/etc.) that only show up when input actually flows through the engine.

Not part of the shipped game -- nothing here ships in a build.

## Run it

```bash
./tools/run_harness.sh
```

Requires a real display (`DISPLAY=:0` by default) -- there's no xvfb here, and
the harness screenshots the actual rendered framebuffer, so it must run
headed. Output is teed to `tools/shots/last_run.log`; exit code matches
Godot's (0 = all cases passed).

To point at a different Godot binary or scene manually:

```bash
GODOT_BIN=/path/to/godot ./tools/run_harness.sh
# or, directly:
godot --path . res://tools/input_harness.tscn
```

## Layout

- `tools/harness/input_driver.gd` (`InputDriver`) -- reusable synthetic-input
  primitives: `warp_to_cell`, `move_to`, `click`, `drag`, `mouse_button`,
  `mouse_motion`, `tap_key`, `key_event`, `world_to_screen`. All the
  warp-then-await-a-frame plumbing lives here once. Node-free -- construct it
  with `InputDriver.new(get_tree(), get_viewport())`.
- `tools/harness/harness_runner.gd` (`HarnessRunner`) -- runs an ordered array
  of named test cases, prints `PASS`/`FAIL` per case, screenshots each case to
  `tools/shots/NN_name.png`, prints the `HARNESS SUMMARY` line, and exits with
  the right code. Also Node-free.
- `tools/input_harness.tscn` + `tools/input_harness.gd` -- the concrete suite
  for the map editor. This is the file to copy/extend when testing a
  different interaction.
- `tools/shots/` -- screenshot + log output. Gitignored; not source.

## Adding a new test case

A case is just a method that returns `true`/`false` (or a richer
`{"ok": bool, "detail": String}`) and an entry in the `cases` array. Example
-- asserting a hotkey toggles something:

```gdscript
# in tools/input_harness.gd

func _case_toggle_grid() -> Dictionary:
    var before: bool = _editor.show_grid
    await _driver.tap_key(KEY_G, false, true)  # Shift+G, say
    var after: bool = _editor.show_grid
    return {"ok": after != before, "detail": "before=%s after=%s" % [before, after]}
```

```gdscript
# add one line to the cases array in _run():
{"name": "toggle_grid", "fn": Callable(self, "_case_toggle_grid")},
```

That's it -- the runner picks it up, screenshots it, and folds it into the
summary. For a click at a specific map cell, use the local `_click_cell(cell,
level, button)` helper already defined in `input_harness.gd`; for a drag, use
`_driver.drag(button, layer, level, from_cell, to_cell)`.

## Testing a different interaction/scene entirely

Don't bolt more unrelated cases onto `input_harness.gd`. Instead: make a new
scene + script (e.g. `tools/other_thing_harness.tscn`/`.gd`) that sets up
whatever scene you're driving, builds an `InputDriver` and a `HarnessRunner`
the same way, and defines its own `_case_*` methods. Both library scripts are
global classes (`class_name`), so nothing needs preloading -- just reference
`InputDriver` / `HarnessRunner` directly.

## Known constraints

- Headed only -- no xvfb in this environment; screenshots need a real GPU
  surface.
- The RTS camera eases toward its target every frame; the harness freezes it
  (`camera.set_process(false)`) once it's settled near the map bounds so a
  precomputed screen position can't drift between a mouse warp and the
  synthetic button event fired a frame or two later. Any new harness driving
  a camera-panned scene will likely want the same trick.
- A prior harness run's F6 save leaves a real user map on disk
  (`user://maps/dev_map.json`), and `MapPersistence` deliberately does not
  auto-load a saved user map on startup -- only the first-run showcase, and
  only when no user map exists yet. `input_harness.gd` deletes that file
  (plus `.bak`/`.tmp`) at the start of every run so each run starts from the
  same first-run-showcase state.
