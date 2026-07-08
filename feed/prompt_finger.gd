extends CenterContainer
## Idle "swipe here" prompt. Loops an up/down swipe motion on the finger
## texture; fades out on dismiss() (first user interaction) and fades back
## in on reset() (called by feed.gd, see design-doc.md §1/§2a).

@export var finger: TextureRect
@export var swipe_distance: float = 120.0
@export var swipe_duration: float = 0.6
@export var pause_duration: float = 0.25
@export var fade_duration: float = 0.35

var _base_position: Vector2
var _loop_tween: Tween
var _fade_tween: Tween


func _ready() -> void:
	_base_position = finger.position
	_start_swipe_loop()


## Called by feed.gd on first user interaction.
func dismiss() -> void:
	if _loop_tween:
		_loop_tween.kill()
	if _fade_tween:
		_fade_tween.kill()
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 0.0, fade_duration)
	_fade_tween.tween_callback(hide)


## Called by feed.gd on reset() (REVERTING).
func reset() -> void:
	show()
	finger.position = _base_position
	if _fade_tween:
		_fade_tween.kill()
	modulate.a = 0.0
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 1.0, fade_duration)
	_start_swipe_loop()


func _start_swipe_loop() -> void:
	if _loop_tween:
		_loop_tween.kill()
	_loop_tween = create_tween()
	_loop_tween.set_loops()
	_loop_tween.tween_property(finger, "position:y", _base_position.y + swipe_distance, swipe_duration) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_loop_tween.tween_interval(pause_duration)
	_loop_tween.tween_property(finger, "position:y", _base_position.y, swipe_duration) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_loop_tween.tween_interval(pause_duration)
