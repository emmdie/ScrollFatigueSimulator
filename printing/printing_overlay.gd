class_name PrintingOverlay
extends Node
## PRINTING flow: fill focus_frame's progress bar to 100%, THEN request the
## horoscope; the result is printed to console (result_card comes later).
## No thermal print job and no auto-revert for now — flip auto_revert on to
## restore the REVERTING loop. request_printing() stays owned by focus_frame.

@export var focus_frame: FocusFrame ## assign in main.tscn: FrameHost's FocusFrame instance
@export var bar_fill_duration_sec: float = 3.0 ## how long the bar takes to fill before the request fires
## Off: exhibit stays on the filled bar after the horoscope (current wish).
## On: reverts to IDLE revert_delay_sec after the horoscope arrives.
@export var auto_revert: bool = false
@export var revert_delay_sec: float = 4.0

var _fill_tween: Tween


func _ready() -> void:
	StateMachine.state_changed.connect(_on_state_changed)
	ExternalBridge.horoscope_ready.connect(_on_horoscope_ready)


func _on_state_changed(_previous: int, current: int) -> void:
	if current == StateMachine.STATE.PRINTING:
		_start_fill()


func _start_fill() -> void:
	if not (focus_frame and focus_frame.progress_bar):
		push_warning("PrintingOverlay: focus_frame/progress_bar not assigned")
		_on_bar_filled()
		return
	if _fill_tween:
		_fill_tween.kill()
	focus_frame.progress_bar.value = 0.0
	_fill_tween = create_tween().set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	_fill_tween.tween_property(focus_frame.progress_bar, "value", 100.0, bar_fill_duration_sec)
	_fill_tween.finished.connect(_on_bar_filled)


func _on_bar_filled() -> void:
	HoroscopeClient.request(SessionData.current_artwork)


func _on_horoscope_ready(text: String, was_fallback: bool) -> void:
	if StateMachine.state != StateMachine.STATE.PRINTING:
		return
	SessionData.last_horoscope_text = text
	var suffix := " (fallback)" if was_fallback else ""
	print("PrintingOverlay: horoscope%s: %s" % [suffix, text])
	if auto_revert:
		await get_tree().create_timer(revert_delay_sec).timeout
		StateMachine.request_revert()
