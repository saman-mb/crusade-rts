class_name MapFileIO
extends RefCounted
## Schema-agnostic durable file layer for maps: bytes and text only, with no JSON
## or schema knowledge -- callers (MapSerializer et al.) turn documents into text
## and hand the string here. save_text is atomic and crash-safe: it writes to a
## sibling `.tmp` file, snapshots any prior file to `.bak`, then renames the temp
## over the real path, so a crash mid-save can never corrupt the live map.
##
## The read / existence / mtime helpers back the dev reload poll, which watches a
## file's modified time and reloads when it changes on disk.

## Atomically writes `text` to `path`. Ensures the parent dir exists, writes a
## `.tmp` sibling first, snapshots any existing file to `.bak`, then renames the
## temp over the real path. Returns false (and warns) if the temp cannot be
## opened or the final rename fails.
static func save_text(path: String, text: String) -> bool:
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)

	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("MapFileIO.save_text: cannot open %s" % tmp)
		return false
	f.store_string(text)
	f.close()

	if FileAccess.file_exists(path):
		DirAccess.copy_absolute(path, path + ".bak")

	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		push_warning("MapFileIO.save_text: cannot rename %s over %s (err %d)" % [tmp, path, err])
		DirAccess.remove_absolute(tmp)  # don't leave a stale temp behind on failure
		return false
	return true

## Reads the whole file at `path` as text. Returns { "ok": bool, "text": String };
## ok is false with an empty text when the file is missing or cannot be opened.
static func load_text(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "text": ""}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "text": ""}
	var t := f.get_as_text()
	f.close()
	return {"ok": true, "text": t}

## True when a file exists at `path`.
static func file_exists(path: String) -> bool:
	return FileAccess.file_exists(path)

## Unix modified time of `path` in seconds, or 0 when the file does not exist.
## Used by the dev reload poll to detect on-disk edits.
static func modified_time(path: String) -> int:
	if not FileAccess.file_exists(path):
		return 0
	return int(FileAccess.get_modified_time(path))
