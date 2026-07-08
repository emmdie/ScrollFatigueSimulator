# tracks current post, scroll velocity, dwell timer, fatigue/distortion level
extends Node

## Written every frame by feed.gd (design-doc.md §1a, §2a). Other systems
## (frame_host escalation, state_machine's SCROLLING->DISTORTING check,
## focus_frame) read this — nobody else should recompute it.
var fatigue: float = 0.0
## Scroll speed as tracked internally by feed.gd, published here for any
## system that wants to react to raw scroll behavior (design-doc.md §6:
## "fast flicking should build fatigue faster than slow deliberate scrolling").
var scroll_velocity: float = 0.0
## True the first time the user drags/touches the feed. Whoever wires up
## Feed.first_interaction (Feed itself never calls this, see §2a) should set
## it via notify_first_interaction() so the prompt finger fades permanently
## instead of re-appearing (design-doc.md §3).
var has_interacted: bool = false
## The artwork nearest the viewport center right now, kept in sync with
## Feed.nearest_card_changed. dwell_tracker, focus_frame, and
## horoscope_client all read this to know who's currently being focused on.
var current_artwork: Dictionary = { }
## Seconds the current artwork has been continuously dwelled on. Written by
## dwell_tracker.gd; read by focus_frame for its progress-bar chrome.
var dwell_elapsed: float = 0.0
## Result text from horoscope_client, cached here once PRINTING has it so
## printing_overlay/result_card don't need to re-fetch or pass it around.
var last_horoscope_text: String = ""


func set_current_artwork(artwork_data: Dictionary) -> void:
	current_artwork = artwork_data
	dwell_elapsed = 0.0


func notify_first_interaction() -> void:
	has_interacted = true


## Called by state_machine.gd on entering REVERTING (design-doc.md §3, §6).
## Leftover state bleeding from one visitor into the next is an easy bug in
## exhibit software that runs for days unattended — clear everything.
func reset() -> void:
	fatigue = 0.0
	scroll_velocity = 0.0
	has_interacted = false
	current_artwork = { }
	dwell_elapsed = 0.0
	last_horoscope_text = ""
