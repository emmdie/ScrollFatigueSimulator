class_name FocusFrame
extends FrameBase
## Same pattern as phone_frame/picture_frame: feed_slot_path lives on FrameBase
## and is set per-instance in the editor. FocusFrame adds one thing the other
## frames don't need: it owns the FOCUSING -> PRINTING edge, firing once its
## own crossfade-in finishes (per §3, this call belongs here, not in dwell_tracker).

@export var progress_bar: ProgressBar # chrome only for now; printing_overlay drives it later


func enter(duration: float) -> void:
	progress_bar.value = 0.0
	modulate = Color(1, 1, 1, 0)
	var tw := create_tween()
	tw.tween_property(self, "modulate", Color(1, 1, 1, 1), duration)
	tw.finished.connect(_on_enter_complete)


func exit(duration: float) -> Tween:
	var tw := create_tween()
	tw.tween_property(self, "modulate", Color(1, 1, 1, 0), duration)
	return tw


func _on_enter_complete() -> void:
	StateMachine.request_printing()
