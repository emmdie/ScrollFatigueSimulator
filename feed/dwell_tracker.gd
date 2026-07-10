class_name DwellTracker
extends Node
## Watches Feed.nearest_card_changed + SessionData.scroll_velocity and turns
## sustained stillness on one card into StateMachine.request_focus().
## Assign `feed` in the editor rather than fetching it via $NodeName at runtime.

@export var feed: Control
@export var dwell_threshold: float = 1.2 # seconds of stillness required to focus
@export var forgiveness_window: float = 0.3 # brief motion tolerated before resetting dwell timer
@export var velocity_still_threshold: float = 40.0 # px/s below which the feed counts as "still"

var _current_card: Control = null
var _current_artwork: Dictionary = { }
var _dwell_elapsed: float = 0.0
var _motion_elapsed: float = 0.0
var _focus_requested: bool = false


func _ready() -> void:
	assert(feed != null, "DwellTracker.feed must be assigned in the editor")
	feed.nearest_card_changed.connect(_on_nearest_card_changed)


func _process(delta: float) -> void:
	if _current_card == null or _focus_requested:
		return

	if SessionData.scroll_velocity <= velocity_still_threshold:
		_motion_elapsed = 0.0
		_dwell_elapsed += delta
		if _dwell_elapsed >= dwell_threshold:
			_trigger_focus()
	else:
		_motion_elapsed += delta
		# only a *sustained* motion beyond the forgiveness window resets progress;
		# a brief pause-then-nudge shouldn't cost the visitor their dwell.
		if _motion_elapsed >= forgiveness_window:
			_dwell_elapsed = 0.0


func _on_nearest_card_changed(post_card: Control, artwork_data: Dictionary) -> void:
	if _focus_requested:
		_cancel_focus()
	_current_card = post_card
	_current_artwork = artwork_data
	_dwell_elapsed = 0.0
	_motion_elapsed = 0.0


func _trigger_focus() -> void:
	_focus_requested = true
	feed.set_scroll_locked(true)
	SessionData.current_artwork = _current_artwork
	SessionData.dwell_elapsed = _dwell_elapsed
	StateMachine.request_focus()


func _cancel_focus() -> void:
	_focus_requested = false
	feed.set_scroll_locked(false)
	StateMachine.cancel_focus()
