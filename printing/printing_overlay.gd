class_name PrintingOverlay
extends Node
## PRINTING flow: fill focus_frame's progress bar to 100%, request the
## horoscope, then send text + artwork to the thermal printer via
## ExternalBridge.request_print(). Reverts after the print settles when
## auto_revert is on. Never dead-ends: a horoscope fallback still prints,
## and a printer failure/timeout just logs and continues into REVERTING.

@export var focus_frame: FocusFrame ## assign in main.tscn: FrameHost's FocusFrame instance
@export var bar_fill_duration_sec: float = 3.0 ## bar fill time before the horoscope request fires
## Physical printout via ExternalBridge.request_print(). Off = console only,
## useful when developing without the printer in BLE range.
@export var physical_print: bool = true
## On: revert to IDLE revert_delay_sec after the print (or horoscope, if
## physical_print is off) settles. Off: exhibit stays on the filled bar.
@export var auto_revert: bool = false
@export var revert_delay_sec: float = 4.0

var _fill_tween: Tween


func _ready() -> void:
	StateMachine.state_changed.connect(_on_state_changed)
	ExternalBridge.horoscope_ready.connect(_on_horoscope_ready)
	ExternalBridge.print_finished.connect(_on_print_finished)


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
	if physical_print:
		# Single composed job: print_job.py stacks the dithered artwork above
		# the caption itself (design-doc.md §5).
		var image_path: String = SessionData.current_artwork.get("_resolved_path", "")
		ExternalBridge.request_print(text, image_path)
	else:
		_settle()


func _on_print_finished(success: bool) -> void:
	if StateMachine.state != StateMachine.STATE.PRINTING:
		return
	if not success:
		push_warning("PrintingOverlay: print job failed/timed out — continuing without paper")
	_settle()


func _settle() -> void:
	if not auto_revert:
		return
	await get_tree().create_timer(revert_delay_sec).timeout
	if StateMachine.state == StateMachine.STATE.PRINTING:
		StateMachine.request_revert()
