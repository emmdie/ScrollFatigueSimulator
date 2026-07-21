extends Control
## Top-level conductor. Translates StateMachine states into FrameHost framing,
## injects Feed.first_interaction into the FSM, and owns scene-level cleanup on
## REVERTING. Per-edge logic (dwell -> FOCUSING, focus -> PRINTING, print ->
## REVERTING) lives in its own node; main.gd only orchestrates framing and the
## IDLE / REVERTING bookends.

@export var frame_host: FrameHost
@export_group("Frames")
## Framing at escalation level 0: IDLE, SCROLLING, low-fatigue DISTORTING, and
## after REVERTING. Set to phone_frame.tscn so the exhibit opens inside the
## phone. Leave empty for bare fullscreen.
@export var base_frame_scene: PackedScene
## Ordered mildest -> strongest, entered as fatigue climbs. Level 0 is
## base_frame_scene; level i is escalation_frames[i-1]. focus_frame is entered
## via the FOCUSING state, never by fatigue — do NOT add it here.
@export var escalation_frames: Array[PackedScene] = []
## Fatigue at which escalation_frames[i] appears. Same length, ascending.
@export var escalation_thresholds: Array[float] = [0.35]
@export var focus_frame_scene: PackedScene
@export_group("Escalation feel")
## Fatigue must fall this far BELOW a level's threshold before stepping back
## down — stopping right after a frame appeared won't immediately undo it.
@export var de_escalation_hysteresis: float = 0.15
## Minimum seconds any framing level is held before it may change again.
@export var min_frame_hold: float = 2.5
@export_group("Revert")
@export var revert_settle_time: float = 0.6

var _level: int = 0 # 0 = base frame, i = escalation_frames[i-1]
var _level_age: float = 0.0
var _shown_scene: PackedScene = null # skip re-showing the frame already on screen

# Feed lives inside frame_host's SubViewport; frame_host exposes it as @export var feed.
@onready var _feed: Control = frame_host.feed


func _ready() -> void:
	set_process(false) # only polls fatigue while DISTORTING
	if escalation_frames.size() != escalation_thresholds.size():
		push_warning("main.gd: escalation_frames and escalation_thresholds lengths differ; extra entries ignored")
	StateMachine.state_changed.connect(_on_state_changed)
	_feed.first_interaction.connect(StateMachine.notify_first_interaction)
	_set_level(0)


func _process(delta: float) -> void:
	_apply_distort_framing(delta)


func _on_state_changed(_previous: int, current: int) -> void:
	set_process(current == StateMachine.STATE.DISTORTING)
	match current:
		StateMachine.STATE.IDLE:
			_set_level(0)
		StateMachine.STATE.DISTORTING:
			# Re-apply the current level's framing: covers cancel-back from
			# FOCUSING, where the focus frame must yield to the escalation
			# level we were at. No-op if that frame is already showing.
			_set_level(_level)
		StateMachine.STATE.FOCUSING:
			_apply_framing(focus_frame_scene)
		StateMachine.STATE.REVERTING:
			_revert()
		# SCROLLING: base framing carries over; prompt finger self-dismisses in feed.gd
		# PRINTING:  focus_frame + printing_overlay own this edge


func _apply_distort_framing(delta: float) -> void:
	_level_age += delta
	if _level_age < min_frame_hold:
		return
	var fatigue = SessionData.fatigue
	var max_level := mini(escalation_frames.size(), escalation_thresholds.size())
	if _level < max_level and fatigue >= escalation_thresholds[_level]:
		_set_level(_level + 1)
	elif _level > 0 and fatigue < escalation_thresholds[_level - 1] - de_escalation_hysteresis:
		_set_level(_level - 1)


func _set_level(level: int) -> void:
	_level = level
	_level_age = 0.0
	if level == 0:
		_apply_framing(base_frame_scene)
	else:
		_apply_framing(escalation_frames[level - 1])


## Central framing switch — dedupes so re-entering a state doesn't re-crossfade
## the frame that's already on screen. null = bare fullscreen.
func _apply_framing(scene: PackedScene) -> void:
	if scene == _shown_scene:
		return
	_shown_scene = scene
	if scene:
		frame_host.show_frame(scene)
	else:
		frame_host.to_bare_fullscreen()


func _revert() -> void:
	# StateMachine._on_enter() runs SessionData.reset() + ContentLibrary.reshuffle_order()
	# before emitting state_changed, so Feed.reset() rebuilds from the fresh shuffle.
	_feed.reset()
	_set_level(0)
	await get_tree().create_timer(revert_settle_time).timeout
	StateMachine.request_idle()
