class_name DwellTracker
extends Node
## Watches Feed.nearest_card_changed + SessionData.scroll_velocity and turns
## sustained stillness on one card into StateMachine.request_focus().
##
## Two gates keep focus meaningful:
## 1. FSM state — dwell only accumulates in SCROLLING/DISTORTING, the states in
##    which request_focus() can actually take.
## 2. Fatigue recovery — dwell only accumulates once SessionData.fatigue has
##    decayed below fatigue_focus_threshold. This forces the escalation ladder
##    to walk all the way back down (phone -> tablet -> painting) BEFORE the
##    focus timer even starts: attention must visibly recover first, and a brief
##    pause mid-ladder can never skip straight to FOCUSING/printing.
##
## Assign `feed` in the editor rather than fetching it via $NodeName at runtime.

@export var feed: Control
@export var dwell_threshold: float = 4.0 # seconds of recovered stillness required to focus
@export var forgiveness_window: float = 0.3 # brief motion tolerated before resetting dwell timer
@export var velocity_still_threshold: float = 40.0 # px/s below which the feed counts as "still"
## Dwell only accumulates while SessionData.fatigue is at/below this. Set it to
## main.gd's escalation_thresholds[0] - de_escalation_hysteresis (0.35 - 0.15)
## so "focus is possible" coincides exactly with "the base frame is back".
@export var fatigue_focus_threshold: float = 0.2

var _current_card: Control = null
var _current_artwork: Dictionary = { }
var _dwell_elapsed: float = 0.0
var _motion_elapsed: float = 0.0
var _focus_requested: bool = false


func _ready() -> void:
	assert(feed != null, "DwellTracker.feed must be assigned in the editor")
	feed.nearest_card_changed.connect(_on_nearest_card_changed)
	StateMachine.state_changed.connect(_on_state_changed)


func _process(delta: float) -> void:
	if _current_card == null or _focus_requested:
		return

	if not _is_dwell_state():
		_dwell_elapsed = 0.0
		_motion_elapsed = 0.0
		return

	if SessionData.scroll_velocity <= velocity_still_threshold:
		_motion_elapsed = 0.0
		if SessionData.fatigue > fatigue_focus_threshold:
			# Still de-escalating: stay still, let fatigue decay and the frames
			# step back down; the focus timer starts only once recovered.
			_dwell_elapsed = 0.0
			return
		_dwell_elapsed += delta
		if _dwell_elapsed >= dwell_threshold:
			_trigger_focus()
	else:
		_motion_elapsed += delta
		# only a *sustained* motion beyond the forgiveness window resets progress;
		# a brief pause-then-nudge shouldn't cost the visitor their dwell.
		if _motion_elapsed >= forgiveness_window:
			_dwell_elapsed = 0.0


func _is_dwell_state() -> bool:
	return StateMachine.state == StateMachine.STATE.SCROLLING \
			or StateMachine.state == StateMachine.STATE.DISTORTING


func _on_nearest_card_changed(post_card: Control, artwork_data: Dictionary) -> void:
	if _focus_requested:
		_cancel_focus()
	_current_card = post_card
	_current_artwork = artwork_data
	_dwell_elapsed = 0.0
	_motion_elapsed = 0.0


func _on_state_changed(_previous: int, current: int) -> void:
	if current == StateMachine.STATE.REVERTING:
		# Feed.reset() (main.gd) unlocks scrolling; just clear our own state so
		# the next visitor's dwell starts from zero.
		_focus_requested = false
		_current_artwork = { }
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
