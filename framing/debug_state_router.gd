class_name DebugStateRouter
extends Node
## STOPGAP ONLY — this is main.gd's job (§3, §7) once main.tscn exists.
## Delete this node/script when main.gd is built; don't merge its logic in.

@export var frame_host: Node # drag FrameHost here
@export var phone_frame_scene: PackedScene
@export var focus_frame_scene: PackedScene


# picture_frame intentionally omitted — not built yet, so DISTORTING only
# ever shows phone_frame regardless of fatigue for now.
func _ready() -> void:
	StateMachine.state_changed.connect(_on_state_changed)
	# Stopgap for main.gd's other job (§3): without this, IDLE never advances
	# and nothing downstream (frame swaps included) ever fires.
	frame_host.feed.first_interaction.connect(_on_first_interaction)


func _on_first_interaction() -> void:
	StateMachine.notify_first_interaction()


func _on_state_changed(_previous: int, current: int) -> void:
	match current:
		StateMachine.STATE.IDLE, StateMachine.STATE.SCROLLING:
			frame_host.to_bare_fullscreen()
		StateMachine.STATE.DISTORTING:
			frame_host.show_frame(phone_frame_scene)
		StateMachine.STATE.FOCUSING:
			frame_host.show_frame(focus_frame_scene)
		StateMachine.STATE.PRINTING:
			pass # stays on focus_frame; printing_overlay isn't built yet
		StateMachine.STATE.REVERTING:
			frame_host.to_bare_fullscreen()
