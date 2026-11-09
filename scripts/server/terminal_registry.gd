class_name TerminalRegistry
extends RefCounted

## Durable record of matches that reached a terminal state (completed or
## cancelled), kept until every credential for them has expired so a
## still-valid token can never recreate or rejoin a finished match, even
## across a runtime restart.
##
## Stored as one JSON file, {"entries": {match_id: {state, reason,
## retain_until}}}, rewritten atomically (temp file + rename) on each change.
## Entries whose retain_until (unix seconds) has passed are pruned on load and
## on every record().

var path := ""
var _entries := {}

func open(file_path: String, now_unix: int) -> void:
	path = file_path
	_entries = {}
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY and typeof(parsed.get("entries")) == TYPE_DICTIONARY:
			for id in parsed.entries:
				var e = parsed.entries[id]
				if typeof(e) == TYPE_DICTIONARY and e.has("state") and e.has("retain_until"):
					_entries[str(id)] = {"state": str(e.state), "reason": str(e.get("reason", "")), "retain_until": int(e.retain_until)}
		else:
			MatchRuntime.log_event("terminal_registry_unreadable", {"path": path})
	prune(now_unix)

func size() -> int:
	return _entries.size()

## {} when the match isn't terminal; otherwise {state, reason, retain_until}.
func lookup(match_id: String) -> Dictionary:
	return _entries.get(match_id, {})

func record(match_id: String, state: String, reason: String, retain_until: int, now_unix: int) -> void:
	_entries[match_id] = {"state": state, "reason": reason, "retain_until": retain_until}
	_prune_entries(now_unix)
	_save()

func prune(now_unix: int) -> void:
	if _prune_entries(now_unix):
		_save()

func _prune_entries(now_unix: int) -> bool:
	var expired := []
	for id in _entries:
		if int(_entries[id].retain_until) <= now_unix:
			expired.append(id)
	for id in expired:
		_entries.erase(id)
	return not expired.is_empty()

func _save() -> void:
	if path == "":
		return
	if write_atomic(path, JSON.stringify({"entries": _entries})) != OK:
		MatchRuntime.log_event("terminal_registry_write_failed", {"path": path})

## Writes `text` to `file_path` via a temp file and a rename, so readers (and a
## restart after a crash) see either the old or the new content, never a torn file.
static func write_atomic(file_path: String, text: String) -> Error:
	var tmp := file_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.flush()
	f.close()
	return DirAccess.rename_absolute(tmp, file_path)
