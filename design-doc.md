# Scroll Fatigue — Design Doc

Godot software for an artistic vision of "scroll fatigue" — engagement with each post drops as the user scrolls past more of them.

1. **Approaching**: a social-media-style feed of artworks. A finger icon prompts the first swipe.
2. **Distortion**: continued swiping subtly distorts each image (and its title/author) passing by. This can also happen at the feed level — shrinking the feed into different frames (phone in hand, picture frame) to de-emphasize individual images. Staying on one image longer reverts the effect until only that image is in focus.
3. **Printing**: the image the visitor settles on gets a nonsensical horoscope-style statement (e.g. Klimt's "Kiss" → true love, romantic, taste for gold and kitsch), generated via an AI API call (you.com) and sent to a small thermal pocket printer (https://github.com/ChiaraCannolee/thermal-pocket-printer) via external scripts. A visible progress bar covers both steps so no one leaves early.
4. **Reverting**: back to the initial state for the next visitor.

## Implementation Status (read second, right after §0)

- **Built:** `feed/` (post_card, feed, prompt_finger, dwell_tracker), all four `autoload/` singletons (`content_library`, `session_data`, `state_machine`, `external_bridge`), `shaders/image_distort.gdshader`, `framing/` (`frame_base`, `frame_host`, `phone_frame`, `focus_frame`), `printing/printing_overlay`, `printing/horoscope_client`, and `main/` (`main.tscn`, `main.gd`) — see §1 tree for what each does.
- **Mocked:** `external/horoscope_api.py`, `external/print_job.py` — match the §5 CLI contract but return canned/templated results; swap for the real you.com API and printer hardware later (§7 step 7).
- **Not built:** `picture_frame`, `printing/result_card`, `text_distort`/`feed_distort` shaders.
- **`main.gd` is the conductor** (§3a): forwards `Feed.first_interaction` → `StateMachine.notify_first_interaction()`, maps `StateMachine.state_changed` onto `frame_host` framing (incl. fatigue-driven DISTORTING escalation), and owns REVERTING cleanup (`Feed.reset()` + bare framing → `request_idle()`). `dwell_tracker.gd` (FOCUSING edge) and `printing_overlay.gd` (PRINTING edge) stay wired to `StateMachine`/`ExternalBridge` directly; `main.gd` does not duplicate them.
- `feed.gd` never reads or drives `StateMachine` — it only exposes `set_scroll_locked()`, `reset()`, and `nearest_card_changed`/`first_interaction` signals (§2a). Whoever owns dwell/framing/FSM calls into Feed, never the reverse.
- `post_card.tscn`'s `ArtworkRect` carries the distortion `ShaderMaterial` directly (no `CanvasGroup`); captions are unaffected.
- `frame_host.gd` exposes `@export var feed` (the inner SubViewport Feed); `main.gd` reads it as `frame_host.feed`. `DwellTracker` lives inside `frame_host.tscn` beside the Feed so its own `@export feed` resolves without editable children.

## 0. Structural Conventions

- Scene-adjacent scripts (`feed.tscn` + `feed.gd`), no shared `scripts/` folder. Logic-only scripts live in the domain folder that owns them.
- Folders by feature/domain (`feed/`, `framing/`, `printing/`, `content/`), not by node type.
- snake_case filenames, PascalCase node names (Godot 4 style guide).
- Content is data: artwork + metadata live behind `content/manifest.json`, accessed only via `ContentLibrary`. No hardcoded image paths or titles elsewhere.
- The feed renders once, into a fixed-resolution `SubViewport`; every framing context is a different presentation of that one texture (§2).

## 1. Project Structure

```
res://
├── autoload/
│   ├── state_machine.gd       # ✅ FSM: IDLE, SCROLLING, DISTORTING, FOCUSING, PRINTING, REVERTING. Auto-escalates
│   │                          #   SCROLLING->DISTORTING off SessionData.fatigue; every other edge is a
│   │                          #   request_*/notify_* method. See §3.
│   ├── session_data.gd        # ✅ fatigue, scroll_velocity, has_interacted, current_artwork, dwell_elapsed,
│   │                          #   last_horoscope_text, reset(). See §1a.
│   ├── content_library.gd     # ✅ manifest loading/validation, executable-adjacent path resolution, shuffled
│   │                          #   run order, cached texture loading. See §1a, §4.
│   └── external_bridge.gd     # ✅ threaded OS.execute() wrappers for horoscope_api.py/print_job.py, timeouts
│                              #   + fallbacks. See §5.
│
├── main/
│   ├── main.tscn              # ✅ root Control: FrameHost + PrintingOverlay instances. Project main scene.
│   └── main.gd                # ✅ conductor: first_interaction->FSM, state_changed->framing, REVERTING cleanup. §3a.
│
├── feed/                      # everything that lives INSIDE the SubViewport
│   ├── feed.tscn / feed.gd    # ✅ recycled post_card pool, drag/momentum scroll, fatigue accumulation,
│   │                          #   per-card distortion, nearest-card signal. See §1a, §2a.
│   ├── post_card.tscn / .gd   # ✅ setup(artist,title,texture), set_distortion(0..1) via ArtworkRect's
│   │                          #   pre-assigned ShaderMaterial.
│   ├── dwell_tracker.gd       # ✅ @export var feed; polls SessionData.scroll_velocity against
│   │                          #   dwell_threshold with a forgiveness_window, then feed.set_scroll_locked(true)
│   │                          #   + StateMachine.request_focus()/cancel_focus(). Node in frame_host.tscn. See §3a.
│   └── prompt_finger.tscn/.gd # ✅ looping swipe tween; dismiss()/reset() fade out/in. Wired into feed.gd.
│
├── framing/                   # presents the SubViewport in a context
│   ├── frame_host.tscn        # ✅ FrameHost (Control) > FeedContainer (SubViewportContainer > SubViewport >
│   │                          #   Feed instance) + DecorationLayer (Ignore) + DwellTracker. Exposes @export feed.
│   ├── frame_host.gd          # ✅ to_bare_fullscreen()/show_frame(PackedScene) tween FeedContainer to the
│   │                          #   active frame's FeedSlot rect, aspect-fit clamped (see §2), crossfade
│   │                          #   decoration via FrameBase.enter/exit. Manual push_input() fallback wired,
│   │                          #   off by default.
│   ├── frame_base.gd          # ✅ abstract: feed_slot_path, get_feed_global_rect(), enter()/exit().
│   └── frames/
│       ├── phone_frame.tscn/.gd  # ✅ placeholder hand+phone decoration + FeedSlot.
│       ├── picture_frame.tscn/.gd # ⬜ same pattern as phone_frame.
│       └── focus_frame.tscn/.gd   # ✅ FeedSlot = full-bleed rect + progress bar chrome (chrome only,
│                                   #   not yet driven). enter() fades in then calls request_printing()
│                                   #   once complete. See §3a.
│
├── printing/
│   ├── printing_overlay.tscn/.gd  # ✅ no visual of its own — on entering PRINTING, drives focus_frame's
│   │                               #   progress_bar 0->50 (horoscope) then 50->100 (print) via an eased
│   │                               #   creep tween that never reaches the phase boundary until the real
│   │                               #   signal lands, then snaps. Calls StateMachine.request_revert() once
│   │                               #   print_finished arrives. Does NOT call request_printing() — that's
│   │                               #   focus_frame.gd's edge (§3a).
│   ├── result_card.tscn/.gd       # ⬜ optional on-screen preview of the printed text
│   └── horoscope_client.gd        # ✅ stateless: ArtworkData dict -> ExternalBridge.request_horoscope()
│                                   #   call. No signals of its own; printing_overlay listens to
│                                   #   ExternalBridge directly.
│
├── shaders/
│   ├── image_distort.gdshader # ✅ float shader_parameter "distortion" (0..1), on ArtworkRect only.
│   ├── text_distort.gdshader  # ⬜ for Artistlabel/ArtworkLabel if added later
│   └── feed_distort.gdshader  # ⬜ optional whole-feed effect on the SubViewport texture
│
├── content/                   # dev-time copy; executable-adjacent content/ overrides at runtime (§4)
│   ├── manifest.json
│   └── artworks/*.jpg
│
└── external/                  # shipped next to the exported executable, not in the .pck (§5)
    ├── horoscope_api.py       # ⚠️ mocked — matches CLI contract, returns a templated line, no real API call
    └── print_job.py           # ⚠️ mocked — matches CLI contract, logs + sleeps, always exits 0
```

### Content manifest schema (`content/manifest.json`)

```json
{
  "version": 1,
  "artworks": [
    {
      "id": "klimt_the_kiss",
      "file": "artworks/klimt_the_kiss.jpg",
      "title": "The Kiss",
      "artist": "Gustav Klimt",
      "date": "1907–1908",
      "tags": ["gold", "romance", "ornament", "art nouveau", "embrace"]
    }
  ]
}
```

- `id` is the stable key; never key off filename or array index. `file` is relative to the manifest's folder.
- `tags` seed the horoscope prompt — curating them tunes the printout's tone, no code change needed.
- `content_library.gd` validates on startup (missing files, duplicate ids, empty tags), skips broken entries, logs instead of crashing.
- Unrecognized manifest keys pass through into `ArtworkData` untouched.

## 1a. Autoload Contract (`feed.gd` ↔ `content_library.gd` / `session_data.gd`)

```gdscript
# ContentLibrary (autoload)
func get_artwork_count() -> int
func get_artwork(order_index: int) -> Dictionary   # {id, title, artist, date, tags, _resolved_path, ...}
func load_texture(artwork_data: Dictionary) -> Texture2D
func reshuffle_order() -> void                     # called by state_machine.gd on entering REVERTING
```
```gdscript
# SessionData (autoload)
var fatigue: float   # Feed writes every frame; other systems read, don't recompute
```

- `get_artwork(order_index)` indexes `content_library.gd`'s internal shuffled run order, not the manifest array or `id`.
- `load_texture()` caches by `id` in-memory so repeated laps don't redecode.
- `session_data.gd` also tracks `current_artwork`, `dwell_elapsed`, `has_interacted`, `last_horoscope_text` for not-yet-built consumers.

## 2. Framing: container-based, not camera-based

**Decision: render the feed into a fixed-resolution `SubViewport`, present it through a `SubViewportContainer` whose rect is tweened by `frame_host.gd`. Frames are decoration scenes swapped around that container.** This beats a Camera2D zoom rig because the feed literally never changes — only its container does — and it composites cleanly into a phone-screen or picture-frame cutout without a redundant second transform system.

**Resolved implementation gotchas** (all in `frame_host.gd`):
- `SubViewport.size` is driven automatically by its parent `SubViewportContainer` and is read-only in the editor. Use `size_2d_override` (+ `size_2d_override_stretch = true`) to give the feed a fixed internal render resolution independent of however small the container currently is — set both at runtime in `_ready()`, don't rely on the `.tscn`.
- `stretch = true` on the container will distort (non-uniformly squish) the feed whenever the target rect's aspect ratio doesn't match `size_2d_override`'s. `_tween_container_to()` routes every target rect through `_aspect_fit()` first, which fits+letterboxes instead of stretching — applies to bare fullscreen too, not just framed states.
- Built-in `SubViewportContainer` input forwarding (via `stretch = true`) works out of the box; a manual `push_input()` remap exists behind `use_manual_input_forwarding` (off by default) only as a fallback if a given kiosk misbehaves.
- Decoration nodes must be `mouse_filter = IGNORE` so the shrunk feed stays the touch target under PhoneFrame etc.

## 2a. Feed's Public API (as built)

```gdscript
# Called by dwell_tracker.gd (on dwell) and frame_host.gd (during PRINTING). Cancels any in-progress drag when true.
func set_scroll_locked(locked: bool) -> void

# Called on REVERTING: resets scroll/velocity/fatigue, rebuilds the card pool from ContentLibrary, resets prompt_finger.
func reset() -> void

signal nearest_card_changed(post_card: Control, artwork_data: Dictionary)
signal first_interaction
```

`fatigue` isn't exposed on Feed directly — read `SessionData.fatigue` (§1a).

## 3. Core State Machine

```
IDLE → SCROLLING → DISTORTING → (dwell timeout) FOCUSING → PRINTING → REVERTING → IDLE
```

- **IDLE**: prompt finger animates, no distortion, bare fullscreen framing.
- **SCROLLING**: swipe/drag increments `fatigue`; prompt finger fades permanently on first interaction.
- **DISTORTING**: `fatigue` drives (a) per-card shader distortion and (b) frame escalation (bare → phone_frame → picture_frame) — two independently tunable curves.
- **FOCUSING**: single post centered past `dwell_threshold` (with a forgiveness window) tweens fatigue to 0 for that post, then frame_host scales up to focus_frame. Cancels cleanly back to DISTORTING if the visitor scrolls away mid-tween.
- **PRINTING**: focus_frame locks input; printing_overlay shows a two-phase bar (0–50% horoscope API, 50–100% print) since the two durations are unrelated.
- **REVERTING**: reset shader uniforms/timers/thread state, frame_host back to bare, clear SessionData, reshuffle feed, back to IDLE.

### As implemented (`state_machine.gd`)

- Single `state_changed(previous: int, current: int)` signal — no per-state signals. States are `enum STATE { IDLE, SCROLLING, DISTORTING, FOCUSING, PRINTING, REVERTING }` (callers use `StateMachine.STATE.X`); current state is `var state: int`. `_on_enter()` runs **before** `state_changed` is emitted, so REVERTING's `SessionData.reset()`/`reshuffle_order()` are already applied by the time listeners react.
- Only automatic transition: `SCROLLING -> DISTORTING`, gated by `@export var distorting_fatigue_threshold` (default `0.25`) against `SessionData.fatigue`. Every other edge is an explicit no-op-if-wrong-state call:
  - `notify_first_interaction()` — `IDLE -> SCROLLING` + flips `has_interacted`. Wired by `main.gd` off `Feed.first_interaction`.
  - `request_focus()` / `cancel_focus()` — `dwell_tracker.gd`.
  - `request_printing()` — `focus_frame.gd`, once its scale-up tween completes.
  - `request_revert()` — `printing_overlay.gd`, once both `ExternalBridge` signals land.
  - `request_idle()` — `main.gd`, once revert visuals finish.
- On entering `REVERTING`, the FSM calls `SessionData.reset()` + `ContentLibrary.reshuffle_order()` **before** emitting `state_changed`, so the reshuffle is live when `main.gd` rebuilds. Scene-level cleanup (`Feed.reset()`, bare framing) is owned by `main.gd`, which then calls `request_idle()`.

## 3a. Dwell Detection (`dwell_tracker.gd`, as implemented)

- Holds `@export var feed: Control` (assigned in the editor, not fetched via `$NodeName`) and connects to `Feed.nearest_card_changed`.
- Each frame, compares `SessionData.scroll_velocity` to `velocity_still_threshold`: below it, accumulates `_dwell_elapsed`; at/above it, accumulates `_motion_elapsed` and only resets the dwell timer once `_motion_elapsed >= forgiveness_window` — a brief nudge doesn't cost progress, sustained motion does.
- `_dwell_elapsed >= dwell_threshold` → `feed.set_scroll_locked(true)`, writes `SessionData.current_artwork`/`dwell_elapsed`, calls `StateMachine.request_focus()`.
- A new `nearest_card_changed` while focused calls `StateMachine.cancel_focus()` + unlocks the feed before tracking the new card — covers the "scrolled away mid-tween" cancel path.
- Exported knobs: `dwell_threshold` (1.2s default), `forgiveness_window` (0.3s), `velocity_still_threshold` (40 px/s).
- `focus_frame.gd` (extends `FrameBase`, same pattern as `phone_frame`) owns the FOCUSING → PRINTING edge: `enter(duration: float) -> void` (signature from `FrameBase`, driven by `frame_host`'s crossfade timing) fades the frame in, then calls `StateMachine.request_printing()` once the fade completes. `exit(duration: float) -> Tween` returns its tween so `frame_host` can await it before swapping frames. Its `progress_bar` export is chrome only — `printing_overlay.gd` (unbuilt) will drive its value later.
- `main.gd` (`main/`, extends `Control`) owns framing orchestration and the IDLE/REVERTING bookends. In `_ready()` it connects `Feed.first_interaction -> StateMachine.notify_first_interaction` and `StateMachine.state_changed -> _on_state_changed`, then sets bare framing. Per state: IDLE → `to_bare_fullscreen()`; DISTORTING → polls `SessionData.fatigue` in `_process` and escalates bare → `phone_frame` → `picture_frame` at `@export` thresholds (`picture_frame_scene` optional — caps at phone until built); FOCUSING → `show_frame(focus_frame_scene)`; PRINTING → no-op (owned by focus_frame + printing_overlay); REVERTING → `Feed.reset()` + `to_bare_fullscreen()`, then `request_idle()` after `revert_settle_time`. Reads the Feed via `frame_host.feed`. `debug_state_router.gd` is deleted.
- PRINTING resolves on its own: `printing_overlay.gd` drives `focus_frame`'s progress bar and calls `StateMachine.request_revert()` once the (mocked) horoscope + print calls both land.

## 4. Content Loading

- `content_library.gd` looks for `content/` next to the executable (`OS.get_executable_path().get_base_dir()`), falling back to `res://content/` in-editor.
- Images load via `Image.load()` → `ImageTexture.create_from_image()`, cached by `id`.
- Curators can swap artworks/tags by editing a folder + JSON — no re-export needed.
- Feed order is a shuffled index list, regenerated by `reshuffle_order()` on every REVERTING; a small pool of `post_card` instances is recycled rather than instancing one per artwork.

## 5. External Script Integration

`external_bridge.gd` is the only place that spawns processes — Godot itself never blocks on network/serial I/O.

- `horoscope_api.py`: `--title --artist --date --tags` (comma-joined) → stdout JSON `{"text": "..."}`.
- `print_job.py`: `--text [--image <path>]`, wraps the thermal-pocket-printer repo, exit `0` on success.

### As implemented (`external_bridge.gd`)

- Each request runs `OS.execute()` blocking on a dedicated `Thread`; completion is detected by polling a mutex-guarded result dict every 0.05s (simpler to reason about alongside a timeout than push-notification).
- Timeouts: 12s horoscope / 20s print. On timeout, the bridge stops waiting and fires a fallback immediately; the underlying process is joined lazily next time a same-kind request starts.
- Fallbacks: horoscope timeout/failure → `horoscope_ready(text, was_fallback: true)` picks from 4 hardcoded generic lines. Print timeout/failure → `print_finished(success: false)`, no fallback text needed, just a clear failure signal for `printing_overlay.gd`.
- `.py` scripts run via `python3` (dev convenience); anything else (a PyInstaller build, the intended export target) runs directly — decided per-call from the extension.
- Path resolution mirrors `content_library.gd` (executable-adjacent `external/`, else `res://external`).
- Only one horoscope request and one print request in flight at a time; a second call while one is alive is ignored with a warning.
- `request_horoscope(artwork_data: Dictionary)` takes the whole ArtworkData dict and builds the CLI flags itself — callers pass the dict through untouched (it also carries `_resolved_path` for `print_job.py`'s `--image`). `horoscope_client.gd` only validates it.

**Still open**: `horoscope_api.py`/`print_job.py` are mocked (templated text, no real network/serial I/O) — swap for the real you.com API and thermal-pocket-printer calls with no Godot-side changes needed, since `external_bridge.gd` already calls them by the CLI contract above.

## 6. Key Technical Challenges

- **Distortion reading as "fatigue" not "glitch"**: subtle shader work (chromatic aberration, softening, wave warp), ease-in curve. *(Open — shaders not built.)*
- **Text distortion**: Label/RichTextLabel don't warp easily; options are a Viewport-rendered text texture + `text_distort.gdshader`, or per-character `RichTextEffect`. *(Open.)*
- **Exported build + external assets**: path resolution logic done in `content_library.gd`/`external_bridge.gd`; still needs verification on real kiosk hardware.
- **Session reset integrity**: `state_machine.gd` clears `SessionData`/reshuffles on REVERTING; scene-level cleanup (`Feed.reset()`, bare framing) owned by `main.gd`. *(Done.)*

## 7. Suggested Build Order

1. Content loading + feed + prompt finger, no distortion. **Done.**
2. Image distortion shader + debug slider. **Done.**
3. Fatigue accumulation from real scroll input. **Done** — `feed.gd`'s `_update_fatigue` → `SessionData.fatigue`.
4. **Framing spike**: **Done.** `frame_host`/`frame_base`/`phone_frame`/`focus_frame` built (`picture_frame` remains, same pattern); SubViewport sizing and aspect-ratio distortion bugs resolved (§2).
5. Dwell detection + FOCUSING transition: **Done** (§3a) via `dwell_tracker.gd` + `focus_frame.gd`, now driven through `main.gd`.
6. External script plumbing. **Done with mocks** — `external_bridge.gd`, `horoscope_client.gd`, `printing_overlay.gd` all built; `horoscope_api.py`/`print_job.py` mocked per §5 CLI contract.
7. Swap in real you.com API and printer hardware.
8. Reset/revert flow + exhibit hardening. **Full loop wired** via `main.gd` (`Feed.reset()` + bare framing → `request_idle()`). Remaining: exhibit hardening + kiosk-hardware verification (§6).
