class_name Feed
# scroll container of post_card instances (fixed portrait resolution, e.g. 1080x1920)
#
# Assumed autoload APIs (adjust names below if your real autoloads differ):
#   ContentLibrary.get_artwork_count() -> int
#   ContentLibrary.get_artwork(order_index: int) -> Dictionary  # {id, title, artist, tags, ...}
#   ContentLibrary.load_texture(artwork_data: Dictionary) -> Texture2D
#   ContentLibrary.get_shuffled_order() -> Array[int]           # optional, used by reset()
#   SessionData.fatigue: float                                  # written here, read elsewhere
#
# Per design doc §2: "No special 'zoomed' feed state exists inside the feed
# itself; the feed only knows scrolling locked yes/no." Feed never talks to
# StateMachine directly — frame_host/dwell_tracker call set_scroll_locked().
extends Control

## Emitted whenever a different post becomes the one nearest the center of the
## viewport. dwell_tracker.gd (a sibling child in feed.tscn) listens to this
## to run its per-post dwell timer.
signal nearest_card_changed(post_card: Control, artwork_data: Dictionary)
## Emitted once, the first time the user provides scroll input.
signal first_interaction

@export_group("Scene References")
@export var post_card_scene: PackedScene
@export var card_container: Control
@export var prompt_finger: Control
@export_group("Layout")
@export var pool_size: int = 6
@export var item_height: float = 1000.0
@export var item_spacing: float = 40.0
@export_group("Scrolling Feel")
@export var momentum_damping: float = 3.5 # exponential velocity falloff; higher = stops faster
@export var drag_to_velocity_scale: float = 1.0
@export var max_velocity: float = 6000.0
@export_group("Fatigue")
@export var fatigue_rise_per_velocity: float = 0.00035 # fatigue gained per (px/sec), per second
@export var fatigue_decay_rate: float = 0.12 # fatigue lost per second while idle
@export var max_fatigue: float = 1.0
@export var per_card_jitter: float = 0.12 # randomizes distortion slightly per card so it isn't uniform

var scrolling_locked: bool = false
var _slots: Array = [] # each: { node: Control, logical_index: int, jitter: float }
var _scroll_offset: float = 0.0
var _velocity: float = 0.0
var _dragging: bool = false
var _active_touch_index: int = -1
var _has_interacted: bool = false
var _fatigue: float = 0.0
var _nearest_slot_index: int = -1
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_pool()


func _process(delta: float) -> void:
	if not scrolling_locked and not _dragging:
		_scroll_offset += _velocity * delta
		var friction := absf(_velocity) * momentum_damping * delta + 40.0 * delta
		_velocity = move_toward(_velocity, 0.0, friction)

	_layout_slots()
	_recycle_slots()
	_update_fatigue(delta)
	_apply_distortion()
	_update_nearest_slot()


func _gui_input(event: InputEvent) -> void:
	if scrolling_locked:
		return

	if event is InputEventScreenTouch:
		if event.pressed:
			_start_drag(event.index)
		elif event.index == _active_touch_index:
			_end_drag()
	elif event is InputEventScreenDrag:
		if event.index == _active_touch_index:
			_apply_drag_delta(event.relative.y)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_start_drag(-1)
		else:
			_end_drag()
	elif event is InputEventMouseMotion and _dragging and _active_touch_index == -1:
		_apply_drag_delta(event.relative.y)


## Called by frame_host/dwell_tracker — the only thing outside Feed is allowed
## to tell it about. Locks out drag input and momentum during FOCUSING/PRINTING.
func set_scroll_locked(locked: bool) -> void:
	scrolling_locked = locked
	if locked:
		_dragging = false
		_active_touch_index = -1
		_velocity = 0.0


## Called on REVERTING: clears scroll/fatigue state and re-shuffles content.
func reset() -> void:
	_scroll_offset = 0.0
	_velocity = 0.0
	_fatigue = 0.0
	_dragging = false
	_active_touch_index = -1
	_has_interacted = false
	_nearest_slot_index = -1
	SessionData.fatigue = 0.0
	_build_pool()
	if prompt_finger and prompt_finger.has_method("reset"):
		prompt_finger.reset()


func _build_pool() -> void:
	for child in card_container.get_children():
		child.queue_free()
	_slots.clear()

	for i in pool_size:
		var card: Control = post_card_scene.instantiate()
		card_container.add_child(card)
		_apply_artwork(card, _artwork_for_logical_index(i))
		_slots.append(
			{
				"node": card,
				"logical_index": i,
				"jitter": _rng.randf_range(-per_card_jitter, per_card_jitter),
			},
		)

	_layout_slots()


func _artwork_for_logical_index(logical_index: int) -> Dictionary:
	var count: int = ContentLibrary.get_artwork_count()
	if count == 0:
		return { }
	var order_index: int = ((logical_index % count) + count) % count
	return ContentLibrary.get_artwork(order_index)


func _apply_artwork(card: Control, data: Dictionary) -> void:
	if data.is_empty():
		return
	var texture: Texture2D = ContentLibrary.load_texture(data)
	card.setup(data.get("artist", ""), data.get("title", ""), texture)
	card.set_meta("artwork_data", data)


func _layout_slots() -> void:
	var step := item_height + item_spacing
	for slot in _slots:
		slot.node.position.y = slot.logical_index * step - _scroll_offset


func _recycle_slots() -> void:
	var step := item_height + item_spacing
	var top_bound := -step * 1.5
	var bottom_bound := size.y + step * 0.5

	for slot in _slots:
		var changed := false
		while slot.node.position.y < top_bound:
			slot.logical_index += pool_size
			slot.node.position.y += step * pool_size
			changed = true
		while slot.node.position.y > bottom_bound:
			slot.logical_index -= pool_size
			slot.node.position.y -= step * pool_size
			changed = true
		if changed:
			_apply_artwork(slot.node, _artwork_for_logical_index(slot.logical_index))


func _start_drag(touch_index: int) -> void:
	_dragging = true
	_active_touch_index = touch_index
	_velocity = 0.0
	_notify_first_interaction()


func _apply_drag_delta(dy: float) -> void:
	var delta_offset := -dy * drag_to_velocity_scale
	_scroll_offset += delta_offset
	var dt := get_process_delta_time()
	if dt > 0.0:
		_velocity = clampf(delta_offset / dt, -max_velocity, max_velocity)


func _end_drag() -> void:
	_dragging = false
	_active_touch_index = -1


func _notify_first_interaction() -> void:
	if _has_interacted:
		return
	_has_interacted = true
	first_interaction.emit()
	if prompt_finger and prompt_finger.has_method("dismiss"):
		prompt_finger.dismiss()


func _update_fatigue(delta: float) -> void:
	var speed := absf(_velocity)
	if speed > 10.0:
		_fatigue = clampf(_fatigue + speed * fatigue_rise_per_velocity * delta, 0.0, max_fatigue)
	else:
		_fatigue = clampf(_fatigue - fatigue_decay_rate * delta, 0.0, max_fatigue)

	SessionData.fatigue = _fatigue


func _apply_distortion() -> void:
	for slot in _slots:
		var value: float = clampf(_fatigue + slot.jitter, 0.0, 1.0)
		if slot.node.has_method("set_distortion"):
			slot.node.set_distortion(value)


func _update_nearest_slot() -> void:
	var center := size.y * 0.5
	var best_index := -1
	var best_dist := INF
	for i in _slots.size():
		var slot = _slots[i]
		var card_center: float = slot.node.position.y + item_height * 0.5
		var dist: float = absf(card_center - center)
		if dist < best_dist:
			best_dist = dist
			best_index = i

	if best_index != -1 and best_index != _nearest_slot_index:
		_nearest_slot_index = best_index
		var slot = _slots[best_index]
		var data: Dictionary = slot.node.get_meta("artwork_data", { })
		nearest_card_changed.emit(slot.node, data)
