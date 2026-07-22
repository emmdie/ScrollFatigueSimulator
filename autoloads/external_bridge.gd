# OS.create_process()/Thread wrappers for printer + API helper scripts
extends Node

## Emitted exactly once per request_horoscope() call. was_fallback is true
## if the API call failed/timed out and a pre-written line was used instead
## (design-doc.md §5, §6 — PRINTING must never dead-end).
signal horoscope_ready(text: String, was_fallback: bool)
## Emitted exactly once per request_print() call. success is false if the
## physical printer failed/timed out (a "the printer is dreaming, ask staff"
## state should be shown, per design-doc.md §5).
signal print_finished(success: bool)

const HOROSCOPE_TIMEOUT_SEC := 12.0
const PRINT_TIMEOUT_SEC := 60.0
const FALLBACK_HOROSCOPES := [
	"The stars are cloudy tonight, but you already know what you love.",
	"Some things resist easy prophecy. Trust your first instinct instead.",
	"An old sign says: look longer, feel more, explain less.",
	"Your fortune is unwritten today. Consider that a compliment.",
]

var _external_dir: String = ""
var _horoscope_thread: Thread = null
var _print_thread: Thread = null


func _ready() -> void:
	_resolve_external_dir()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
## Runs horoscope_api.py (--title/--artist/--date/--tags) in a background
## thread so a stalled you.com call never freezes the exhibit (design-doc §5).
func request_horoscope(artwork_data: Dictionary) -> void:
	if _horoscope_thread != null:
		if _horoscope_thread.is_alive():
			push_warning("ExternalBridge: horoscope request already in flight, ignoring")
			return
		_horoscope_thread.wait_to_finish()
		_horoscope_thread = null

	var tags = artwork_data.get("tags", [])
	var tags_str := ",".join(tags) if typeof(tags) == TYPE_ARRAY else str(tags)

	var args := PackedStringArray(
		[
			"--title",
			str(artwork_data.get("title", "")),
			"--artist",
			str(artwork_data.get("artist", "")),
			"--date",
			str(artwork_data.get("date", "")),
			"--tags",
			tags_str,
		],
	)

	var result := { "done": false, "text": "", "success": false }
	var mutex := Mutex.new()

	_horoscope_thread = Thread.new()
	_horoscope_thread.start(_run_horoscope_script.bind(args, result, mutex))

	_await_with_timeout(
		result,
		mutex,
		HOROSCOPE_TIMEOUT_SEC,
		func(r):
			if r["success"]:
				horoscope_ready.emit(r["text"], false)
			else:
				horoscope_ready.emit(_pick_fallback_horoscope(), true)
	)


## Runs print_job.py with the horoscope text (+ optional image path) in a
## background thread. image_path may be "" for a text-only printout.
func request_print(text: String, image_path: String = "") -> void:
	if _print_thread != null:
		if _print_thread.is_alive():
			push_warning("ExternalBridge: print request already in flight, ignoring")
			return
		_print_thread.wait_to_finish()
		_print_thread = null

	var args := PackedStringArray(["--text", text])
	if image_path != "":
		args.append("--image")
		args.append(image_path)

	var result := { "done": false, "success": false, "output": "" }
	var mutex := Mutex.new()

	_print_thread = Thread.new()
	_print_thread.start(_run_print_script.bind(args, result, mutex))

	var on_settled := func(r: Dictionary) -> void:
		if not r["success"] and r["output"] != "":
			push_warning("ExternalBridge: print job output:\n%s" % r["output"])
		print_finished.emit(r["success"])

	_await_with_timeout(result, mutex, PRINT_TIMEOUT_SEC, on_settled)


# ---------------------------------------------------------------------------
# Thread bodies — run off the main thread. Only touch the shared result/mutex,
# never scene/node state, then hop back via call_deferred.
# ---------------------------------------------------------------------------
func _run_horoscope_script(args: PackedStringArray, result: Dictionary, mutex: Mutex) -> void:
	var script_path := _external_dir.path_join("horoscope_api.py")
	var output: Array = []
	var exit_code := _execute_script(script_path, args, output)

	mutex.lock()
	if exit_code == 0 and not output.is_empty():
		var parsed := _parse_json_text(_last_json_line(output[0]))
		if parsed.has("text"):
			result["text"] = str(parsed["text"])
			result["success"] = true
	result["done"] = true
	mutex.unlock()


## OS.execute merges stderr into one blob; take the last line that is a
## JSON object so warnings ahead of it don't poison the parse.
func _last_json_line(blob: String) -> String:
	var lines := blob.split("\n", false)
	for i in range(lines.size() - 1, -1, -1):
		var line := lines[i].strip_edges()
		if line.begins_with("{") and line.ends_with("}"):
			return line
	return blob


func _run_print_script(args: PackedStringArray, result: Dictionary, mutex: Mutex) -> void:
	var script_path := _external_dir.path_join("print_job.py")
	var output: Array = []
	var exit_code := _execute_script(script_path, args, output)

	mutex.lock()
	result["success"] = (exit_code == 0)
	result["output"] = output[0] if not output.is_empty() else ""
	result["done"] = true
	mutex.unlock()


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------
## PyInstaller-built executables (the export target, design-doc §5) are
## called directly; a bare .py is only expected in dev/editor runs and
## requires a python3 interpreter on that machine — never assumed on the kiosk.
func _execute_script(script_path: String, args: PackedStringArray, output: Array) -> int:
	if not FileAccess.file_exists(script_path):
		push_warning("ExternalBridge: script not found at '%s'" % script_path)
		return -1

	if script_path.get_extension() == "py":
		var full_args := PackedStringArray([script_path])
		for a in args:
			full_args.append(a)
		return OS.execute("python3", full_args, output, true)
	else:
		return OS.execute(script_path, args, output, true)


## Polls `result` on a timer instead of blocking. If timeout_sec elapses
## first, we stop waiting and let the caller fall back — the script keeps
## running in its thread and is joined lazily the next time a request of the
## same kind starts (see the is_alive()/wait_to_finish() guards above).
func _await_with_timeout(result: Dictionary, mutex: Mutex, timeout_sec: float, on_settled: Callable) -> void:
	var elapsed := 0.0
	var poll_interval := 0.05
	while true:
		await get_tree().create_timer(poll_interval).timeout
		elapsed += poll_interval

		mutex.lock()
		var done: bool = result["done"]
		mutex.unlock()

		if done:
			on_settled.call(result)
			return

		if elapsed >= timeout_sec:
			on_settled.call(result)
			return


func _parse_json_text(text: String) -> Dictionary:
	var json := JSON.new()
	var err := json.parse(text)
	if err != OK or typeof(json.data) != TYPE_DICTIONARY:
		return { }
	return json.data


func _pick_fallback_horoscope() -> String:
	return FALLBACK_HOROSCOPES[randi() % FALLBACK_HOROSCOPES.size()]


## Mirrors ContentLibrary's executable-adjacent-first pattern (design-doc §5):
## bundled scripts live next to the exported executable, never inside the
## .pck, and are resolved relative to OS.get_executable_path() — with a
## res://external fallback so this still runs from the editor.
func _resolve_external_dir() -> void:
	var exe_adjacent := OS.get_executable_path().get_base_dir().path_join("external")
	if DirAccess.dir_exists_absolute(exe_adjacent):
		_external_dir = exe_adjacent
		print("ExternalBridge: using executable-adjacent scripts at '%s'" % exe_adjacent)
	else:
		_external_dir = ProjectSettings.globalize_path("res://external")
		print("ExternalBridge: falling back to dev scripts at '%s'" % _external_dir)
