class_name FrameHost
extends Control
## Owns the feed SubViewport + the SubViewportContainer that displays it, and
## swaps FrameBase decoration scenes (phone_frame, picture_frame, focus_frame)
## around that container. Feed itself never resizes - only this container does.
## See design-doc.md §2 / §7 step 4 (framing spike).

@export var transition_duration := 0.6
## Spike flag. SubViewportContainer is expected to forward scaled/offset input
## on its own (stretch = true handles the coordinate remap internally). Flip
## this on only if manual testing (see class comment below) shows drag/touch
## events failing to reach Feed once the container is shrunk/offset.
@export var use_manual_input_forwarding := false
@export var phone_frame_scene: PackedScene
@export var feed_container: SubViewportContainer
@export var sub_viewport: SubViewport
@export var feed: Control
@export var decoration_layer: Control

var current_frame: FrameBase
var _rect_tween: Tween


func _ready() -> void:
	feed_container.stretch = true
	to_bare_fullscreen(0.0)


## --- Manual input forwarding fallback (§2 risk item) ---
## Isolated here per design-doc.md: nothing else in the project should need to
## know this exists. Only activates if use_manual_input_forwarding is true.
func _unhandled_input(event: InputEvent) -> void:
	if not use_manual_input_forwarding:
		return
	var vp_event := _remap_to_viewport(event)
	if vp_event == null:
		return
	sub_viewport.push_input(vp_event)
	get_viewport().set_input_as_handled()


## Target = full FrameHost rect, no decoration. Used for the bare-feed framing
## (IDLE / SCROLLING / early DISTORTING).
func to_bare_fullscreen(duration := transition_duration) -> void:
	_clear_current_frame(duration)
	_tween_container_to(get_global_rect(), duration)


## Swap in a new FrameBase scene (phone_frame.tscn, picture_frame.tscn, focus_frame.tscn).
func show_frame(frame_scene: PackedScene, duration := transition_duration) -> void:
	_clear_current_frame(duration)
	var frame: FrameBase = frame_scene.instantiate()
	decoration_layer.add_child(frame)
	current_frame = frame
	# Let layout settle for one frame so FeedSlot's global rect is valid before reading it.
	await get_tree().process_frame
	frame.enter(duration)
	_tween_container_to(frame.get_feed_global_rect(), duration)


func _clear_current_frame(duration: float) -> void:
	if current_frame == null:
		return
	var old := current_frame
	current_frame = null
	var tw := old.exit(duration)
	tw.finished.connect(old.queue_free)


func _tween_container_to(target_rect: Rect2, duration: float) -> void:
	if _rect_tween:
		_rect_tween.kill()
	var local_pos := target_rect.position - global_position
	if duration <= 0.0:
		feed_container.position = local_pos
		feed_container.size = target_rect.size
		return
	_rect_tween = create_tween().set_parallel(true).set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	_rect_tween.tween_property(feed_container, "position", local_pos, duration)
	_rect_tween.tween_property(feed_container, "size", target_rect.size, duration)


func _remap_to_viewport(event: InputEvent) -> InputEvent:
	var scale_factor: Vector2 = Vector2(sub_viewport.size) / feed_container.size
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		var e = event.duplicate()
		e.position = (event.position - feed_container.global_position) * scale_factor
		return e
	if event is InputEventScreenDrag or event is InputEventMouseMotion:
		var e = event.duplicate()
		e.position = (event.position - feed_container.global_position) * scale_factor
		if "relative" in e:
			e.relative = event.relative * scale_factor
		return e
	return null
