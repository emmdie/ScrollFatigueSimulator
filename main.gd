extends Control
## Top-level conductor. Translates StateMachine states into FrameHost framing,
## injects Feed.first_interaction into the FSM, and owns scene-level cleanup on
## REVERTING. All per-edge logic (dwell -> FOCUSING, focus -> PRINTING, print ->
## REVERTING) is owned by its own node; main.gd only orchestrates framing and the
## IDLE / REVERTING bookends.

enum FrameLevel { BARE, PHONE, PICTURE }

@export var frame_host: FrameHost
@export_group("Frames")
@export var phone_frame_scene: PackedScene
@export var picture_frame_scene: PackedScene # optional: leave null until picture_frame exists
@export var focus_frame_scene: PackedScene
@export_group("Fatigue -> frame escalation (DISTORTING)")
@export_range(0.0, 1.0) var phone_frame_fatigue: float = 0.35
@export_range(0.0, 1.0) var picture_frame_fatigue: float = 0.70
@export_group("Revert")
@export var revert_settle_time: float = 0.6

var _distort_level: int = -1 # last FrameLevel applied during DISTORTING; -1 = unset

# Feed lives inside frame_host's SubViewport; frame_host exposes it as @export var feed.
@onready var _feed: Control = frame_host.feed


func _ready() -> void:
	set_process(false) # only polls fatigue while DISTORTING
	StateMachine.state_changed.connect(_on_state_changed)
	_feed.first_interaction.connect(StateMachine.notify_first_interaction)
	frame_host.to_bare_fullscreen()


func _process(_delta: float) -> void:
	_apply_distort_framing(SessionData.fatigue)


func _on_state_changed(_previous: int, current: int) -> void:
	set_process(current == StateMachine.STATE.DISTORTING)
	match current:
		StateMachine.STATE.IDLE:
			frame_host.to_bare_fullscreen()
		StateMachine.STATE.DISTORTING:
			_distort_level = -1 # force re-eval on entry AND on cancel-back from FOCUSING
		StateMachine.STATE.FOCUSING:
			frame_host.show_frame(focus_frame_scene)
		StateMachine.STATE.REVERTING:
			_revert()
		# SCROLLING: bare framing carries over; prompt finger self-dismisses in feed.gd
		# PRINTING:  focus_frame + printing_overlay own this edge


func _apply_distort_framing(fatigue: float) -> void:
	var level := FrameLevel.BARE
	if picture_frame_scene != null and fatigue >= picture_frame_fatigue:
		level = FrameLevel.PICTURE
	elif fatigue >= phone_frame_fatigue:
		level = FrameLevel.PHONE
	if level == _distort_level:
		return
	_distort_level = level
	match level:
		FrameLevel.BARE:
			frame_host.to_bare_fullscreen()
		FrameLevel.PHONE:
			frame_host.show_frame(phone_frame_scene)
		FrameLevel.PICTURE:
			frame_host.show_frame(picture_frame_scene)


func _revert() -> void:
	# StateMachine._on_enter() runs SessionData.reset() + ContentLibrary.reshuffle_order()
	# before emitting state_changed, so Feed.reset() rebuilds from the fresh shuffle.
	_feed.reset()
	frame_host.to_bare_fullscreen()
	await get_tree().create_timer(revert_settle_time).timeout
	StateMachine.request_idle()
