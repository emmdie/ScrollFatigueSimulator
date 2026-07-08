# loads + validates manifest.json, hands out ArtworkData; sole owner of content paths
extends Node

const MANIFEST_FILENAME := "manifest.json"
const DEV_CONTENT_PATH := "res://content"

var _content_base_path: String = ""
var _artworks: Array[Dictionary] = [] # validated entries, stable manifest order
var _shuffle_order: Array[int] = [] # indices into _artworks; this is the "current run"
var _texture_cache: Dictionary = { } # id (String) -> Texture2D


func _ready() -> void:
	_resolve_content_base_path()
	_load_manifest()
	reshuffle_order()


# ---------------------------------------------------------------------------
# Public API required by feed.gd (design-doc.md §1a)
# ---------------------------------------------------------------------------
func get_artwork_count() -> int:
	return _artworks.size()


## Feed passes a plain 0..count-1 index (its logical_index already wrapped
## via modulo before calling in) — this indexes into the CURRENT shuffle
## order, not the manifest's own array position or "id".
func get_artwork(order_index: int) -> Dictionary:
	if _shuffle_order.is_empty():
		return { }
	var i: int = ((order_index % _shuffle_order.size()) + _shuffle_order.size()) % _shuffle_order.size()
	return _artworks[_shuffle_order[i]]


func load_texture(artwork_data: Dictionary) -> Texture2D:
	var id: String = artwork_data.get("id", "")
	if id == "":
		push_warning("ContentLibrary: load_texture called with no 'id' in artwork_data")
		return null

	if _texture_cache.has(id):
		return _texture_cache[id]

	var resolved_path: String = artwork_data.get("_resolved_path", "")
	if resolved_path == "":
		push_warning("ContentLibrary: no resolved path for artwork '%s'" % id)
		return null

	var image := Image.new()
	var err := image.load(resolved_path)
	if err != OK:
		push_warning("ContentLibrary: failed to load image '%s' (error %d)" % [resolved_path, err])
		return null

	var texture := ImageTexture.create_from_image(image)
	_texture_cache[id] = texture
	return texture


## Called on REVERTING (design-doc.md §3, §7 step 8). Re-shuffling here is
## enough — Feed.reset() re-queries get_artwork_count()/get_artwork() on its
## own and doesn't need to be told the order changed (design-doc.md §1a).
func reshuffle_order() -> void:
	_shuffle_order.clear()
	for i in range(_artworks.size()):
		_shuffle_order.append(i)
	_shuffle_order.shuffle()


# ---------------------------------------------------------------------------
# Manifest loading + validation (design-doc.md §1, §4)
# ---------------------------------------------------------------------------
func _resolve_content_base_path() -> void:
	var exe_adjacent := OS.get_executable_path().get_base_dir().path_join("content")
	if DirAccess.dir_exists_absolute(exe_adjacent):
		_content_base_path = exe_adjacent
		print("ContentLibrary: using executable-adjacent content at '%s'" % exe_adjacent)
	else:
		_content_base_path = DEV_CONTENT_PATH
		print("ContentLibrary: falling back to '%s' (running from editor)" % DEV_CONTENT_PATH)


func _load_manifest() -> void:
	var manifest_path := _content_base_path.path_join(MANIFEST_FILENAME)
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null:
		push_error("ContentLibrary: could not open manifest at '%s'" % manifest_path)
		return

	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var parse_err := json.parse(text)
	if parse_err != OK:
		push_error("ContentLibrary: failed to parse manifest.json (%s at line %d)" % [json.get_error_message(), json.get_error_line()])
		return

	var data = json.data
	if typeof(data) != TYPE_DICTIONARY or not data.has("artworks") or typeof(data["artworks"]) != TYPE_ARRAY:
		push_error("ContentLibrary: manifest.json missing an 'artworks' array")
		return

	var seen_ids := { }
	for entry in data["artworks"]:
		var artwork := _validate_entry(entry, seen_ids)
		if not artwork.is_empty():
			seen_ids[artwork["id"]] = true
			_artworks.append(artwork)

	if _artworks.is_empty():
		push_error("ContentLibrary: no valid artworks loaded from manifest — exhibit has nothing to show")


## Returns {} for a bad entry (and logs why) instead of crashing, so one
## broken entry doesn't take down the exhibit (design-doc.md §1).
func _validate_entry(entry, seen_ids: Dictionary) -> Dictionary:
	if typeof(entry) != TYPE_DICTIONARY:
		push_warning("ContentLibrary: skipping non-object manifest entry")
		return { }

	var id: String = entry.get("id", "")
	if id == "":
		push_warning("ContentLibrary: skipping entry with empty/missing id")
		return { }
	if seen_ids.has(id):
		push_warning("ContentLibrary: skipping duplicate id '%s'" % id)
		return { }

	var file_rel: String = entry.get("file", "")
	if file_rel == "":
		push_warning("ContentLibrary: skipping '%s' (empty 'file')" % id)
		return { }

	var tags_raw = entry.get("tags", [])
	var tags: Array = tags_raw if typeof(tags_raw) == TYPE_ARRAY else []
	if tags.is_empty():
		push_warning("ContentLibrary: skipping '%s' (empty tags — horoscope needs a seed)" % id)
		return { }

	var resolved_path := _content_base_path.path_join(file_rel)
	if not FileAccess.file_exists(resolved_path):
		push_warning("ContentLibrary: skipping '%s' (missing file '%s')" % [id, resolved_path])
		return { }

	var artwork := {
		"id": id,
		"title": entry.get("title", ""),
		"artist": entry.get("artist", ""),
		"date": entry.get("date", ""),
		"tags": tags,
		"_resolved_path": resolved_path,
	}

	# Forward-compatible: unknown extra fields (credit, palette_hint, ...)
	# pass through untouched, per design-doc.md §1.
	for key in entry.keys():
		if not artwork.has(key):
			artwork[key] = entry[key]

	return artwork
