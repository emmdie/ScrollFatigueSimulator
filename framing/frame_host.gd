class_name FrameHost
extends Control
## Owns the feed SubViewport + the SubViewportContainer that displays it, and
## swaps FrameBase decoration scenes (phone/tablet/picture/focus frames) around
## that container. Feed itself never resizes - only this container does.
## See design-doc.md §2.

@export var transition_duration := 0.6
## Spike flag. SubViewportContainer is expected to forward scaled/offset input
## on its own (stretch = true handles the coordinate remap internally). Flip
## this on only if manual testing shows drag/touch events failing to reach Feed
## once the container is shrunk/offset.
@export var use_manual_input_forwarding := false
## Fixed internal render resolution of the feed (size_2d_override); the clip/cover
## math below preserves this aspect ratio regardless of FeedSlot shape.
@export var feed_resolution := Vector2i(1080, 1920)
## clip_contents wrapper around feed_container. This is what gets tweened to the
## FeedSlot rect; the container inside is cover-fitted (see _apply_cover).
@export var feed_clip: Control
@export var feed_container: SubViewportContainer
@export var sub_viewport: SubViewport
@export var feed: Control
@export var decoration_layer: Control

var current_frame: FrameBase
var _rect_tween: Tween


func _ready() -> void:
	feed_container.stretch = true
	feed_clip.clip_contents = true
	sub_viewport.size_2d_override = feed_resolution
	sub_viewport.size_2d_override_stretch = true
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


## Target = full FrameHost rect, no decoration. Only used when main.gd has no
## base_frame_scene set; the old frame fades out with nothing replacing it.
func to_bare_fullscreen(duration := transition_duration) -> void:
	var old := current_frame
	current_frame = null
	_retire_frame(old, 0.0, duration)
	_tween_clip_to(get_global_rect(), duration)


## Swap in a new FrameBase scene (any frames/*.tscn). The old frame stays fully
## opaque UNDERNEATH while the new one (a later DecorationLayer sibling, so it
## draws on top) fades in, and only then fades out — the crossfade never dips
## into a "no frame" moment with both decorations half-transparent.
func show_frame(frame_scene: PackedScene, duration := transition_duration) -> void:
	var old := current_frame
	current_frame = null
	var frame: FrameBase = frame_scene.instantiate()
	decoration_layer.add_child(frame)
	current_frame = frame
	_retire_frame(old, duration, duration * 0.5)
	# Let layout settle for one frame so FeedSlot's global rect is valid before reading it.
	await get_tree().process_frame
	if current_frame != frame:
		return # superseded during the await; the superseding call retires this frame
	frame.enter(duration)
	_tween_clip_to(frame.get_feed_global_rect(), duration)


## Fades `old` out after `delay` seconds and frees it. Each show_frame call
## retires exactly the frame it replaced, so rapid supersessions chain cleanly
## (a superseded, never-entered frame just fades from alpha 0 and is freed).
func _retire_frame(old: FrameBase, delay: float, fade_duration: float) -> void:
	if old == null:
		return
	var tw := create_tween()
	if delay > 0.0:
		tw.tween_interval(delay)
	else:
		tw.tween_interval(0.0001) # tween needs at least one step before the callback
	tw.tween_callback(
		func() -> void:
			if not is_instance_valid(old):
				return
			var exit_tw := old.exit(fade_duration)
			exit_tw.finished.connect(old.queue_free)
	)


func _tween_clip_to(target_global_rect: Rect2, duration: float) -> void:
	if _rect_tween:
		_rect_tween.kill()
	var target := Rect2(target_global_rect.position - global_position, target_global_rect.size)
	if duration <= 0.0:
		_set_clip_rect(target)
		return
	var from := Rect2(feed_clip.position, feed_clip.size)
	_rect_tween = create_tween().set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_CUBIC)
	_rect_tween.tween_method(_set_clip_rect, from, target, duration)


func _set_clip_rect(rect: Rect2) -> void:
	feed_clip.position = rect.position
	feed_clip.size = rect.size
	_apply_cover(rect.size)


## Aspect-preserving "cover" fit: the feed always keeps feed_resolution's ratio,
## scaled to fill the clip rect, anchored top / centered horizontally. FeedSlots
## with a different ratio crop the feed's bottom (or sides) instead of
## stretching it — the snapped card sits at the top, so the top edge is sacred.
func _apply_cover(clip_size: Vector2) -> void:
	var feed_size := Vector2(feed_resolution)
	var s := maxf(clip_size.x / feed_size.x, clip_size.y / feed_size.y)
	var cover := feed_size * s
	feed_container.position = Vector2((clip_size.x - cover.x) * 0.5, 0.0)
	feed_container.size = cover


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
