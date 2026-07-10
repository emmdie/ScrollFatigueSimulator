class_name PrintingOverlay
extends Node
## Drives focus_frame's chrome-only progress_bar through two phases
## (0-50 horoscope, 50-100 print) while in StateMachine.PRINTING, then calls
## StateMachine.request_revert(). request_printing() is NOT called here —
## focus_frame.gd already owns that edge (design doc §3a).

@export var focus_frame: FocusFrame ## assign in main.tscn: FrameHost's FocusFrame instance
@export var horoscope_phase_estimate_sec: float = 10.0 ## creep target, stays under ExternalBridge's 12s timeout
@export var print_phase_estimate_sec: float = 17.0 ## creep target, stays under ExternalBridge's 20s timeout
@export var result_display_delay_sec: float = 0.6 ## how long the full bar holds before reverting

var _creep_tween: Tween


func _ready() -> void:
	StateMachine.state_changed.connect(_on_state_changed)
	ExternalBridge.horoscope_ready.connect(_on_horoscope_ready)
	ExternalBridge.print_finished.connect(_on_print_finished)


func _on_state_changed(_previous: StateMachine.STATE, current: StateMachine.STATE) -> void:
	if current == StateMachine.STATE.PRINTING:
		_start_printing_sequence()


func _start_printing_sequence() -> void:
	_set_progress(0.0)
	HoroscopeClient.request(SessionData.current_artwork)
	_creep_to(47.0, horoscope_phase_estimate_sec)


func _on_horoscope_ready(text: String, _was_fallback: bool) -> void:
	SessionData.last_horoscope_text = text
	_set_progress(50.0)
	var image_path: String = SessionData.current_artwork.get("_resolved_path", "")
	ExternalBridge.request_print(text, image_path)
	_creep_to(97.0, print_phase_estimate_sec)


func _on_print_finished(_success: bool) -> void:
	_set_progress(100.0)
	await get_tree().create_timer(result_display_delay_sec).timeout
	StateMachine.request_revert()


func _set_progress(value: float) -> void:
	if _creep_tween:
		_creep_tween.kill()
	if focus_frame and focus_frame.progress_bar:
		focus_frame.progress_bar.value = value


func _creep_to(target: float, duration: float) -> void:
	if not (focus_frame and focus_frame.progress_bar):
		return
	if _creep_tween:
		_creep_tween.kill()
	_creep_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_creep_tween.tween_property(focus_frame.progress_bar, "value", target, duration)
