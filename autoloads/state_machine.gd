# global FSM: IDLE, SCROLLING, DISTORTING, FOCUSING, PRINTING, REVERTING
extends Node

signal state_changed(previous: int, current: int)

enum STATE { IDLE, SCROLLING, DISTORTING, FOCUSING, PRINTING, REVERTING }

## Fatigue (SessionData.fatigue) above which SCROLLING escalates into
## DISTORTING. Tune alongside feed.gd's fatigue curve (design-doc.md §3).
@export var distorting_fatigue_threshold: float = 0.25

var state: int = STATE.IDLE


func _process(_delta: float) -> void:
	# The only purely-automatic transition is SCROLLING -> DISTORTING, driven
	# by fatigue climbing past the threshold. Every other transition is
	# event-driven and comes in through the request_*/notify_* methods below,
	# called by dwell_tracker / focus_frame / printing_overlay / main once
	# those are built (design-doc.md §1, §7).
	if state == STATE.SCROLLING and SessionData.fatigue >= distorting_fatigue_threshold:
		_transition_to(STATE.DISTORTING)


# ---------------------------------------------------------------------------
# Driven by whatever forwards Feed's signals (Feed itself never calls
# StateMachine directly — design-doc.md §2a's "don't add a dependency from
# Feed back to StateMachine").
# ---------------------------------------------------------------------------
## Call this from wherever Feed.first_interaction is forwarded.
func notify_first_interaction() -> void:
	SessionData.notify_first_interaction()
	if state == STATE.IDLE:
		_transition_to(STATE.SCROLLING)


# ---------------------------------------------------------------------------
# Driven by dwell_tracker.gd (not built yet, design-doc.md §1)
# ---------------------------------------------------------------------------
## Sustained stillness past dwell_threshold (with the forgiveness window).
func request_focus() -> void:
	if state == STATE.SCROLLING or state == STATE.DISTORTING:
		_transition_to(STATE.FOCUSING)


## Visitor scrolled away before the focus tween completed — cancel smoothly
## back into DISTORTING rather than all the way to SCROLLING (design-doc §3).
func cancel_focus() -> void:
	if state == STATE.FOCUSING:
		_transition_to(STATE.DISTORTING)


# ---------------------------------------------------------------------------
# Driven by focus_frame.gd / printing_overlay.gd (not built yet)
# ---------------------------------------------------------------------------
## Focus tween onto the dwelled post has finished; begin the horoscope +
## print flow.
func request_printing() -> void:
	if state == STATE.FOCUSING:
		_transition_to(STATE.PRINTING)


## Both the horoscope text and the physical printout are done — or have
## gracefully fallen back. PRINTING must never dead-end (design-doc §5, §6).
func request_revert() -> void:
	if state == STATE.PRINTING:
		_transition_to(STATE.REVERTING)


## Revert fade/reset visuals have finished playing out.
func request_idle() -> void:
	if state == STATE.REVERTING:
		_transition_to(STATE.IDLE)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------
func _transition_to(new_state: int) -> void:
	if new_state == state:
		return
	var previous := state
	state = new_state
	_on_enter(new_state)
	state_changed.emit(previous, new_state)


func _on_enter(new_state: int) -> void:
	match new_state:
		STATE.REVERTING:
			# design-doc.md §3/§6: fully clear session state and re-shuffle the
			# running order for the next visitor. Feed.reset() (called by
			# whoever owns REVERTING's scene-side cleanup) re-queries
			# ContentLibrary on its own, so nothing needs to be told the order
			# changed.
			SessionData.reset()
			ContentLibrary.reshuffle_order()
