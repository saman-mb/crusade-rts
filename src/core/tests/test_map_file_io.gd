extends SceneTree
## Filesystem tests for MapFileIO (atomic save, backup, round-trip, mtime).
## Self-contained SceneTree runner: godot --headless --script <this file>.
## Writes under user:// which is always writable in headless CI; a unique BASE
## keeps the fixtures from clobbering anything else.

const BASE := "user://test_map_file_io"
const MISSING := "user://definitely_missing_xyz.json"
const NESTED := "user://tmio_sub/deep/file.json"

var _pass: int = 0
var _fail: int = 0

func _initialize() -> void:
	var path := BASE + ".json"
	_clean(path)

	_test_round_trip(path)
	_test_atomic(path)
	_test_backup(path)
	_test_missing()
	_test_mtime(path)
	_test_nested()

	_cleanup(path)

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

## Exact String equality check with message.
func _s_eq(a: String, b: String, msg: String) -> void:
	_ok(a == b, "%s: expected %s got %s" % [msg, b, a])

## Removes a file if it exists (best-effort; ignores the result).
func _rm(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)

## Clears the three sibling files that a save may leave behind.
func _clean(path: String) -> void:
	_rm(path)
	_rm(path + ".tmp")
	_rm(path + ".bak")

# --- tests ---

## save_text returns true and load_text reads back the exact bytes.
func _test_round_trip(path: String) -> void:
	var payload := "hello {\"a\":1}"
	_ok(MapFileIO.save_text(path, payload), "save_text round-trip returns true")
	_ok(MapFileIO.file_exists(path), "file_exists true after save")
	var r := MapFileIO.load_text(path)
	_ok(r["ok"], "load_text ok after save")
	_s_eq(r["text"], payload, "load_text round-trip content")

## The temp file is renamed away, never left on disk after a successful save.
func _test_atomic(path: String) -> void:
	_ok(MapFileIO.file_exists(path + ".tmp") == false, "no .tmp left after save")

## Overwriting snapshots the prior content into .bak while the real file updates.
func _test_backup(path: String) -> void:
	_ok(MapFileIO.save_text(path, "second version"), "save_text overwrite returns true")
	_s_eq(MapFileIO.load_text(path)["text"], "second version", "overwrite updates real file")
	_s_eq(MapFileIO.load_text(path + ".bak")["text"], "hello {\"a\":1}", "prior content preserved in .bak")

## Missing file loads report ok == false.
func _test_missing() -> void:
	var r := MapFileIO.load_text(MISSING)
	_ok(r["ok"] == false, "load_text missing file ok==false")
	_s_eq(r["text"], "", "load_text missing file empty text")

## modified_time is positive for a real file and 0 for a missing one.
func _test_mtime(path: String) -> void:
	_ok(MapFileIO.modified_time(path) > 0, "modified_time existing > 0")
	_i_eq(MapFileIO.modified_time(MISSING), 0, "modified_time missing == 0")

## save_text creates the parent directory tree when it does not exist.
func _test_nested() -> void:
	_ok(MapFileIO.save_text(NESTED, "x"), "save_text nested dir returns true")
	var r := MapFileIO.load_text(NESTED)
	_ok(r["ok"], "load_text nested ok")
	_s_eq(r["text"], "x", "load_text nested content")

# --- cleanup ---

## Removes every fixture this suite created (best-effort; failures never fail).
func _cleanup(path: String) -> void:
	_clean(path)
	_rm(NESTED)
	if DirAccess.dir_exists_absolute("user://tmio_sub/deep"):
		DirAccess.remove_absolute("user://tmio_sub/deep")
	if DirAccess.dir_exists_absolute("user://tmio_sub"):
		DirAccess.remove_absolute("user://tmio_sub")
