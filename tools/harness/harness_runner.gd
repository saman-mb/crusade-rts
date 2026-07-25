extends RefCounted
## Reusable case registry + PASS/FAIL bookkeeping for headed integration
## harnesses. A harness scene builds a `HarnessRunner`, hands it an ordered
## Array of test cases, and gets: sequential execution, a screenshot after
## each case, a PASS/FAIL line per case, a final summary line, and a process
## exit code -- all without re-implementing any of it.
##
## Node-free: takes the SceneTree + Viewport it drives as constructor params.
##
## A case is a Dictionary: {"name": String, "fn": Callable}. `fn` is a
## zero-arg Callable (typically `Callable(self, "_case_something")`) that may
## be a coroutine (uses `await` internally) and must return either:
##   - a bool (true == pass), or
##   - a Dictionary {"ok": bool, "detail": String} for a richer PASS/FAIL line.
## See tools/harness/README.md for a worked example.

var _tree: SceneTree
var _viewport: Viewport
var _shots_dir: String
var pass_count := 0
var fail_count := 0


func _init(tree: SceneTree, viewport: Viewport, shots_dir: String) -> void:
	_tree = tree
	_viewport = viewport
	_shots_dir = shots_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shots_dir))


## Runs every case in order: calls `fn`, records + prints PASS/FAIL, saves a
## numbered screenshot named after the case, then -- once all cases are done --
## prints the summary line and quits the process with 0 (all passed) or 1.
func run(cases: Array) -> void:
	var index := 0
	for case in cases:
		index += 1
		var result = await (case["fn"] as Callable).call()
		_report(case["name"], result)
		await _shot("%02d_%s" % [index, case["name"]])
	_finish()


func _report(test_name: String, result) -> void:
	var ok: bool
	var detail: String = ""
	if result is Dictionary:
		ok = result.get("ok", false)
		detail = result.get("detail", "")
	else:
		ok = bool(result)
	if ok:
		pass_count += 1
		print("PASS: %s%s" % [test_name, ("  (%s)" % detail) if detail != "" else ""])
	else:
		fail_count += 1
		print("FAIL: %s%s" % [test_name, (" - " + detail) if detail != "" else ""])


func _shot(shot_name: String) -> void:
	await _tree.process_frame
	var img := _viewport.get_texture().get_image()
	img.save_png("%s/%s.png" % [_shots_dir, shot_name])


func _finish() -> void:
	print("HARNESS SUMMARY: %d passed, %d failed" % [pass_count, fail_count])
	_tree.quit(0 if fail_count == 0 else 1)
