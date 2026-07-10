class_name FrameBase
extends Control
## Base class for framing/frames/*.tscn (phone_frame, picture_frame, focus_frame).
## A frame only declares where the feed rect should go (FeedSlot) and how its
## own decoration enters/exits. frame_host.gd owns the actual SubViewportContainer
## tween and the crossfade between frames. See design-doc.md §2 / §2a.

## Child Control marking the target rect for the feed container, in this
## frame's own local coordinate space. The node itself has no visuals.
@export var feed_slot_path: NodePath = ^"FeedSlot"

var feed_slot: Control


func _ready() -> void:
	feed_slot = get_node_or_null(feed_slot_path)
	if feed_slot == null:
		push_error("%s: feed_slot_path '%s' not found" % [name, feed_slot_path])
	modulate.a = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Global-space rect the feed container should be tweened to while this frame is active.
func get_feed_global_rect() -> Rect2:
	return feed_slot.get_global_rect()


## Called by frame_host right after this frame is added to DecorationLayer.
## Override for frame-specific enter behavior (e.g. focus_frame's progress bar).
func enter(duration: float) -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, duration)


## Called by frame_host before this frame is freed. Returns the tween so the
## caller can free the node once it finishes.
func exit(duration: float) -> Tween:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, duration)
	return tw
