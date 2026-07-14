extends Control
## Top-level conductor. Translates StateMachine states into FrameHost framing,
## injects Feed.first_interaction into the FSM, and owns scene-level cleanup on
## REVERTING. All per-edge logic (dwell -> FOCUSING, focus -> PRINTING, print ->
## REVERTING) is owned by its own node; main.gd only orchestrates framing and the
## IDLE / REVERTING bookends.

@export var frame_host: FrameHost
@export_group("Frames")
## Ordered mildest -> strongest. During DISTORTING, fatigue walks up this list;
## level 0 is bare fullscreen, level i is escalation_frames[i-1]. focus_frame is
## conceptually the final frame but stays separate — it's entered via the
## FOCUSING state, not fatigue. Add new frames by appending scene + threshold.
@export var escalation_frames: Array[PackedScene] = []
## Fatigue at which escalation_frames[i] appears. Same length, ascending.
@export var escalation_thresholds: Array[float] = [0.35, 0.70]
@export var focus_frame_scene: PackedScene
@export_group("Escalation feel")
## Fatigue must fall this far BELOW a level's threshold before stepping back
## down — stopping right after a frame appeared won't immediately undo it.
@export var de_escalation_hysteresis: float = 0.15
## Minimum seconds any framing level is held before it may change again.
@export var min_frame_hold: float = 2.5
@export_group("Revert")
@export var revert_settle_time: float = 0.6

var _level: int = 0 # 0 = bare, i = escalation_frames[i-1]
var _level_age: float = 0.0

# Feed lives inside frame_host's SubViewport; frame_host exposes it as @export var feed.
@onready var _feed: Control = frame_host.feed


func _ready() -> void:
	set_process(false) # only polls fatigue while DISTORTING
	if escalation_frames.size() != escalation_thresholds.size():
		push_warning("main.gd: escalation_frames and escalation_thresholds lengths differ; extra entries ignored")
	StateMachine.state_changed.connect(_on_state_changed)
	_feed.first_interaction.connect(StateMachine.notify_first_interaction)
	frame_host.to_bare_fullscreen()


func _process(delta: float) -> void:
	_apply_distort_framing(delta)


func _on_state_changed(_previous: int, current: int) -> void:
	set_process(current == StateMachine.STATE.DISTORTING)
	match current:
		StateMachine.STATE.IDLE:
			_set_level(0)
		StateMachine.STATE.DISTORTING:
			# Re-apply the current level's framing: covers both first entry
			# (level 0 -> no-op) and cancel-back from FOCUSING, where the
			# focus frame must yield to whatever escalation level we were at.
			_set_level(_level)
		StateMachine.STATE.FOCUSING:
			frame_host.show_frame(focus_frame_scene)
		StateMachine.STATE.REVERTING:
			_revert()
		# SCROLLING: bare framing carries over; prompt finger self-dismisses in feed.gd
		# PRINTING:  focus_frame + printing_overlay own this edge


func _apply_distort_framing(delta: float) -> void:
	_level_age += delta
	if _level_age < min_frame_hold:
		return
	var fatigue := SessionData.fatigue
	var max_level := mini(escalation_frames.size(), escalation_thresholds.size())
	if _level < max_level and fatigue >= escalation_thresholds[_level]:
		_set_level(_level + 1)
	elif _level > 0 and fatigue < escalation_thresholds[_level - 1] - de_escalation_hysteresis:
		_set_level(_level - 1)


func _set_level(level: int) -> void:
	_level = level
	_level_age = 0.0
	if level == 0:
		frame_host.to_bare_fullscreen()
	else:
		frame_host.show_frame(escalation_frames[level - 1])


func _revert() -> void:
	# StateMachine._on_enter() runs SessionData.reset() + ContentLibrary.reshuffle_order()
	# before emitting state_changed, so Feed.reset() rebuilds from the fresh shuffle.
	_level = 0
	_level_age = 0.0
	_feed.reset()
	frame_host.to_bare_fullscreen()
	await get_tree().create_timer(revert_settle_time).timeout
	StateMachine.request_idle()
