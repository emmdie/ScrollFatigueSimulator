# Scroll Fatigue — Design Doc

I want to create a godot based software for showcasing an artistic vision of scroll fatigue, so having a lower engagement with each individual post/element as the user scrolls by a lot of them.
The flow from a user experience point of view is:
1. Approaching the main screen
- There should be a feed reminiscent of a social media site. It might feature a "prompt" in the form of a finger icon moving
- The user can start swiping through the posts, mainly artworks
2. Distortion
- As the user continues to swipe, there should be a subtle distorting effect starting to take place for each individual picture passing by. Images have a title and author, those too should get distorted.
- This "distortion" might also occur on the feed level: shrinking the feed and embedding it into different frames (a phone in a hand, a picture frame) to add distractions and de-emphasize the individual images by making them smaller.
- If the user continues to stay on a single image for longer, the changes revert. The feed grows back until only the current image is in focus
3. Printing
- To make the onlooker have an even stronger connection to the individual image they ended up on, they will recieve a statement about them and a small printout about them.
- This is done using a small pocket printer and the following github repo: https://github.com/ChiaraCannolee/thermal-pocket-printer
- The report about them should feature a few nonsensical horoscope style phrases. e.g. someone landed on Klimt's "Kiss", it might say something about true love and them being a romantic with a taste for kitch, tack and all things gold.
- This should be realized via an API call to an AI model, probably you.com
- These last features should be called as external scripts from within the Godot exported software.
- There should be visible changes (Maybe even a progress bar/frame) so noone leaves because they think the zoom in is done before they recieve their print
4. Reverting
- Once the printout is done, the software should revert to the initial state for the next person

## Implementation Status (read second, right after §0)

- **Built:**
  - `feed/post_card.tscn` + `post_card.gd`, `feed/feed.tscn` + `feed.gd`
  - `autoload/content_library.gd` — implements the §1a contract: manifest loading/validation, executable-adjacent content path resolution, shuffled run order, cached texture loading.
  - `autoload/session_data.gd` — `fatigue` plus supporting session fields (`current_artwork`, `dwell_elapsed`, `has_interacted`, `last_horoscope_text`) and `reset()`.
  - `autoload/state_machine.gd` — the FSM itself, auto-escalating `SCROLLING → DISTORTING` off fatigue, with `request_*`/`notify_*` entry points for the not-yet-built systems that drive the rest of the flow.
  - `autoload/external_bridge.gd` — threaded, timeout-guarded wrappers around `horoscope_api.py`/`print_job.py` with fallback behavior.
  - `feed/prompt_finger.tscn` + `prompt_finger.gd` — looping up/down swipe tween on the finger `TextureRect`, plus `dismiss()`/`reset()` fade out/in. Wired into `feed.tscn` and called by `feed.gd` per §2a.
- **Not built yet:** `dwell_tracker.gd`, everything under `framing/`, everything under `printing/`, the shaders themselves, and `main.tscn`/`main.gd`.
- **Nothing currently calls into the four autoloads' event-driven entry points.** `StateMachine.notify_first_interaction()`, `.request_focus()`, `.cancel_focus()`, `.request_printing()`, `.request_revert()`, `.request_idle()`, and `ExternalBridge.request_horoscope()`/`.request_print()` all exist and are ready, but no scene wires Feed's signals or dwell/print completion into them yet. That wiring is `main.gd`'s and `dwell_tracker.gd`'s job — see §3 and §5.
- `feed.gd` was written *against assumed autoload APIs* (`ContentLibrary`, `SessionData`); `content_library.gd` and `session_data.gd` now implement that contract exactly (§1a), so `feed.tscn` should run as-is once `shaders/image_distort.gdshader` exists (see below); `prompt_finger.tscn/.gd` is now built.
- `feed.gd` deliberately does **not** read `StateMachine` or drive it. It only exposes `set_scroll_locked(bool)`, `reset()`, and two signals (`nearest_card_changed`, `first_interaction`). Whatever owns dwell detection / framing / the FSM is expected to call into Feed, not the other way around. Don't add a dependency from Feed back to StateMachine — see §2a.
- The `SCROLLING` vs `DISTORTING` states in §3 don't correspond to any branching inside `feed.gd` — Feed always tracks velocity/fatigue/per-card distortion continuously regardless of global state, it just stops doing so when `scrolling_locked` is true. Those two FSM states exist for whoever drives frame-level escalation (phone_frame → picture_frame), not for Feed itself.
- `post_card.tscn` has no `CanvasGroup`. `ArtworkRect` (a `TextureRect`) carries a `ShaderMaterial` using `res://shaders/image_distort.gdshader` directly, assigned in the editor. `post_card.gd`'s `_ready()` reads `artwork.material` and caches it; `set_distortion()` sets the shader's `distortion` (0.0–1.0) parameter on it. Only the artwork image distorts; `Artistlabel`/`ArtworkLabel` are unaffected.

## 0. Structural Conventions (read first, future agents)

- **Scene-adjacent scripts, no `scripts/` folder.** Every `.tscn` has a sibling `.gd` of the same name in the same folder (`feed.tscn` + `feed.gd`). A script that has no scene (pure logic, e.g. `horoscope_client.gd`) lives in the folder of the domain that owns it, not in a shared dumping ground.
- **Folders are organized by feature/domain** (`feed/`, `framing/`, `printing/`, `content/`), not by node type. If you add a new feature, add a new folder; don't scatter its files.
- **snake_case filenames** throughout (Godot 4 style guide). Node names inside scenes stay PascalCase.
- **Content is data, not code.** Artwork and its metadata live in `content/` behind a JSON manifest and are only ever accessed through the `ContentLibrary` autoload. Nothing else in the project may hardcode a path to an image or an artwork's title. Adding/removing artworks must never require touching a scene or script.
- **The feed is rendered once, framed many times.** The feed lives in a fixed-resolution `SubViewport`; every "context" (bare fullscreen, phone-in-hand, picture frame, focus view) is just a different presentation of that one viewport texture. See §2 for the rationale (container-based framing instead of a camera rig).

## 1. Project Structure

```
res://
├── autoload/
│   ├── state_machine.gd       # ✅ built. Global FSM: IDLE, SCROLLING, DISTORTING, FOCUSING, PRINTING, REVERTING.
│   │                          #   Auto-escalates SCROLLING->DISTORTING off SessionData.fatigue; every other edge
│   │                          #   is a request_*/notify_* method for other systems to call. See §3.
│   ├── session_data.gd        # ✅ built. fatigue, scroll_velocity, has_interacted, current_artwork, dwell_elapsed,
│   │                          #   last_horoscope_text, reset(). See §1a.
│   ├── content_library.gd     # ✅ built. Loads + validates manifest.json, hands out ArtworkData, owns the shuffled
│   │                          #   run order and texture cache; sole owner of content paths. See §1a, §4.
│   └── external_bridge.gd     # ✅ built. Threaded OS.execute() wrappers for horoscope_api.py / print_job.py with
│   │                          #   timeouts + fallbacks. See §5.
│
├── main/
│   ├── main.tscn              # ⬜ not built. root: FrameHost + PrintingOverlay layers; listens to StateMachine
│   └── main.gd                # ⬜ not built. This is where Feed's signals get forwarded into StateMachine
│                               #   (see Implementation Status above) — nothing does that yet.
│
├── feed/                      # everything that lives INSIDE the SubViewport
│   ├── feed.tscn               # ✅ built. Feed (Control) > CardContainer (Control) + PromptFinger (last child)
│   ├── feed.gd                 # ✅ built. Recycled pool of pool_size post_cards, drag/momentum scroll,
│   │                           #   fatigue accumulation, per-card distortion, nearest-card signal. See §1a.
│   ├── post_card.tscn          # ✅ built. Root Control > BackgroundColor, VBoxContainer (CaptionBox w/
│   │                           #   Artistlabel+ArtworkLabel, separator ColorRect, ArtworkRect); ArtworkRect
│   │                           #   carries the ShaderMaterial (res://shaders/image_distort.gdshader).
│   ├── post_card.gd            # ✅ built. setup(artist,title,texture), set_distortion(0..1) via the
│   │                           #   ShaderMaterial pre-assigned to ArtworkRect.
│   ├── dwell_tracker.gd        # ⬜ not built. Plain Node child of feed.tscn; NOT told about post changes by polling —
│   │                           #   listen to Feed.nearest_card_changed(post_card, artwork_data) instead. On sustained
│   │                           #   stillness past dwell_threshold, call feed.set_scroll_locked(true) and
│   │                           #   StateMachine.request_focus(). On cancellation, StateMachine.cancel_focus().
│   ├── prompt_finger.tscn      # ✅ built. CenterContainer > Control > TextureRect (finger).
│   └── prompt_finger.gd        # ✅ built. Looping up/down position tween on the finger TextureRect (set_loops);
│                               #   dismiss() kills the loop, fades modulate.a to 0, hides. reset() shows, resets
│                               #   position/alpha, fades back in, restarts the loop.
│
├── framing/                   # everything that presents the SubViewport in a context
│   ├── frame_host.tscn        # owns the SubViewport (with feed.tscn inside) + a SubViewportContainer;
│   │                          #   tweens the container's rect/scale and crossfades frame decorations.
│   │                          #   Replaces the old camera_rig.gd — there is no camera.
│   ├── frame_host.gd
│   └── frames/
│       ├── frame_base.gd      # abstract: exposes target rect/scale for the feed container + enter/exit tweens
│       ├── phone_frame.tscn   # hand + phone bezel decoration; feed container shrinks into the phone screen rect
│       ├── phone_frame.gd
│       ├── picture_frame.tscn # ornate gallery frame decoration; alternative/escalated framing context
│       ├── picture_frame.gd
│       ├── focus_frame.tscn   # minimal chrome; feed container scaled/offset so the dwelled post fills the screen,
│       │                      #   plus the progress bar frame signalling the upcoming print
│       └── focus_frame.gd
│
├── printing/
│   ├── printing_overlay.tscn  # progress bar/animation while API + printer run (two-phase bar, see §3 FSM notes).
│   │                          #   Drives StateMachine.request_printing()/request_revert() once ExternalBridge's
│   │                          #   horoscope_ready/print_finished signals both land.
│   ├── printing_overlay.gd
│   ├── result_card.tscn       # optional on-screen preview of the printed text
│   ├── result_card.gd
│   └── horoscope_client.gd    # no scene; builds the ArtworkData -> ExternalBridge.request_horoscope() call,
│                               #   listens for horoscope_ready, stores text into SessionData.last_horoscope_text
│
├── shaders/                   # shaders are shared visual assets, referenced by feed/ and framing/
│   ├── image_distort.gdshader # ✅ built. Exposes a float shader_parameter named "distortion" (0..1).
│   │                          #   Assigned directly to post_card's ArtworkRect (TextureRect); only the
│   │                          #   image distorts, caption text does not.
│   ├── text_distort.gdshader  # applied to a viewport-rendered text texture or via RichTextEffect
│   └── feed_distort.gdshader  # optional: applied to the SubViewport texture itself for whole-feed effects
│
├── content/                   # dev-time copy; at runtime an executable-adjacent content/ folder overrides this (see §4)
│   ├── manifest.json
│   └── artworks/
│       ├── klimt_the_kiss.jpg
│       ├── vermeer_pearl_earring.jpg
│       └── ...
│
└── external/                  # dev-time copy; shipped NEXT TO the exported executable, not inside the .pck (see §5)
    ├── horoscope_api.py       # ⬜ not built. Must accept --title --artist --date --tags and print JSON
    │                          #   {"text": "..."} to stdout — external_bridge.gd already calls it exactly this way.
    └── print_job.py           # ⬜ not built. Must accept --text (+ optional --image <path>), exit 0 on success —
                                #   external_bridge.gd already calls it exactly this way.
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

- `id` is the stable key used in logs and session data; never key anything off the filename or array index.
- `file` is relative to the manifest's own folder, so the whole `content/` directory is relocatable.
- `tags` are the horoscope seed: `horoscope_client.gd` feeds `title`, `artist`, `date`, `tags` into the prompt (and `external_bridge.gd` already joins `tags` into a single comma-separated `--tags` argument). Curating tags is how you tune the printout's tone per artwork — no code change needed.
- `content_library.gd` validates the manifest on startup (missing files, duplicate ids, empty tags) and logs problems instead of crashing; a broken entry is skipped, the exhibit keeps running.
- Optional fields (e.g. `credit`, `palette_hint`) pass through into `ArtworkData` untouched even though nothing consumes them yet — `content_library.gd` copies any unrecognized manifest keys forward rather than dropping them.

## 1a. Autoload Contract Between `feed.gd` and `content_library.gd` / `session_data.gd` (as implemented)

`feed.gd` calls these directly (no null/has-method guards), and both autoloads now implement this shape exactly:

```gdscript
# ContentLibrary (autoload)
func get_artwork_count() -> int
func get_artwork(order_index: int) -> Dictionary   # {id, title, artist, date, tags, _resolved_path, ...}
func load_texture(artwork_data: Dictionary) -> Texture2D
func reshuffle_order() -> void                     # not part of feed.gd's contract, but called by state_machine.gd
                                                     # on entering REVERTING
```
```gdscript
# SessionData (autoload)
var fatigue: float   # Feed writes this every frame; other systems (frame_host escalation, state_machine's
                      # SCROLLING->DISTORTING check) read it, not recompute it
```

Implementation notes:
- `get_artwork(order_index)` indexes into `content_library.gd`'s **internal shuffled run order**, not the manifest's own array position or `id` string — Feed's `order_index` (already wrapped into `0..count-1` via `((logical_index % count) + count) % count`) is treated as an index into "whoever's currently up" for this visitor's run, not into the manifest itself.
- `reshuffle_order()` regenerates that run order and is called once, by `state_machine.gd`, on entering `REVERTING`. Feed's `reset()` re-queries `get_artwork_count()`/`get_artwork()` from scratch afterwards, so `content_library.gd` doesn't need to push any notification — Feed just needs to be told to rebuild, which is its own `reset()` (§2a), called separately by whatever drives REVERTING's scene-side cleanup.
- `load_texture()` caches by `id` in-memory (`Image.load()` → `ImageTexture.create_from_image()`), so repeated laps through the run order don't redecode the same file.
- `session_data.gd` additionally tracks `current_artwork`, `dwell_elapsed`, `has_interacted`, and `last_horoscope_text` for `dwell_tracker`/`focus_frame`/`printing_overlay` to use once built — these aren't part of Feed's contract, just co-located session state per the file's original purpose ("tracks current post, scroll velocity, dwell timer, fatigue/distortion level").

## 2. Framing: container-based, not camera-based

**Decision: drop the Camera2D zoom rig. Render the feed into a fixed-resolution `SubViewport` and present it through a `SubViewportContainer` whose rect/scale is tweened by `frame_host.gd`. Frames are decoration scenes swapped around that container.**

Why this beats the camera approach for this piece:

- **It literally is the concept.** The artwork feed never changes — only the container it sits in does. "The same art, given different amounts of attention depending on how it's framed" maps 1:1 onto "the same viewport texture, displayed at different sizes inside different chrome." A camera zoom fakes this; a container swap *is* this. That makes the code easier to reason about for future agents and the metaphor visible in the scene tree.
- **Compositing was going to force a viewport anyway.** Embedding the feed into a phone screen held by a hand requires the feed as a texture inside another scene. Once a SubViewport exists, a camera on top of it is a redundant second mechanism; one system (container transforms) should own all framing transitions.
- **Frames become trivially interchangeable.** `phone_frame`, `picture_frame`, `focus_frame` all inherit `frame_base.gd` and only declare "where does the feed rect go, what decoration surrounds it, how do I enter/exit." Adding a new context (a museum wall, a tiny thumbnail grid) is one new scene, zero changes to feed logic.
- **Stable rendering + clean shader hook.** The feed always renders at its native resolution, so text stays crisp and per-card shaders behave identically at every framing level. Feed-level distortion gets a natural single insertion point: a shader on the SubViewport texture (`feed_distort.gdshader`), independent from per-card distortion — the two tunable curves from the original design fall out of the architecture for free.
- **UI-native transitions.** Tweens on `position`/`scale`/`size` of Controls, crossfades on decoration `modulate` — no camera math, no world/screen coordinate juggling, interruptible mid-tween by killing/replacing a single Tween.

Implementation notes / risks (validate these in an early spike, step 4 of the build order):

- Keep the SubViewport at a **fixed resolution** and scale the *container*, never resize the viewport — resizing would reflow the feed layout instead of shrinking the "screen".
- `SubViewportContainer` forwards input and transforms event coordinates, but **verify touch/drag forwarding while the container is scaled and offset** (the phone-frame state). If it misbehaves, fall back to a `TextureRect` + manual `SubViewport.push_input()` with the inverse transform — isolate that in `frame_host.gd` so nothing else cares.
- Focus mode is the same mechanism in reverse: tween the container's scale up and offset it so the dwelled post's rect fills the display, while `focus_frame` fades in its progress-bar chrome. No special "zoomed" feed state exists inside the feed itself; the feed only knows "scrolling locked yes/no".
- During PhoneFrame the visitor still swipes on the physical (kiosk) screen; the shrunken feed must remain the touch target. Make the decoration mouse-filter `IGNORE` so it never eats input.

## 2a. Feed's Public API (as built)

Everything outside `feed/` should talk to Feed only through this surface:

```gdscript
# Called by dwell_tracker.gd (on dwell) and by frame_host.gd (during PRINTING).
# Also cancels any in-progress drag when set to true.
func set_scroll_locked(locked: bool) -> void

# Called on REVERTING. Resets scroll position, velocity and fatigue to zero,
# rebuilds the card pool from ContentLibrary (so a re-shuffle takes effect),
# and tells prompt_finger to reset.
func reset() -> void

# Emitted whenever the post nearest the viewport center changes.
# dwell_tracker.gd should listen to this rather than polling Feed's position math.
signal nearest_card_changed(post_card: Control, artwork_data: Dictionary)

# Emitted once, first time the user drags/touches the feed.
signal first_interaction
```

`fatigue` itself isn't exposed as a getter on Feed — read `SessionData.fatigue` instead, since Feed writes there every frame (§1a).

## 3. Core State Machine

```
IDLE → SCROLLING → DISTORTING → (dwell timeout) FOCUSING → PRINTING → REVERTING → IDLE
```

- **IDLE**: prompt finger animates, feed static, no distortion, frame_host in bare fullscreen framing.
- **SCROLLING**: any swipe/drag input increments a `fatigue` float (e.g. +scroll_speed*dt, decays slowly). Prompt finger fades permanently once user has interacted once (SessionData flag).
- **DISTORTING**: `fatigue` maps to (a) per-card shader uniforms on visible post_cards (randomized per-card offsets so it doesn't look uniform), and (b) frame escalation in frame_host: bare feed → phone_frame (shrunken, hand decoration) → optionally picture_frame. Two independently tunable curves: image-level distortion vs. frame-level shrinking/decoration, so "individual images getting worse" is decoupled from "context getting more distracting."
- **FOCUSING** (reversal): triggered when a single post stays centered longer than `dwell_threshold` seconds (with the forgiveness window from dwell_tracker). Tween `fatigue` toward 0 for *that post first*, then frame_host transitions to focus_frame (container scales up until the post fills the screen, decorations fade out). Scrolling away before the tween completes cancels smoothly back into DISTORTING — one Tween per transition, killed and replaced on cancel, no raw lerps scattered in `_process`.
- **PRINTING**: focus_frame locks feed input, printing_overlay shows a two-phase progress bar. horoscope_client builds the prompt from the ArtworkData (title/artist/date/tags), external_bridge runs `horoscope_api.py`, then `print_job.py`. Bar reflects *both* steps (0–50% "waiting on words", 50–100% "printing") since API latency and print time are unrelated durations — don't fake one linear bar over an unknown-length combined process.
- **REVERTING**: fade/reset everything — shader uniforms, timers, thread state, frame_host back to bare framing — clear SessionData, re-shuffle feed order via content_library, back to IDLE.

### As implemented (`state_machine.gd`)

- `state_changed(previous: int, current: int)` is the only signal; there is no per-state signal. Anything reacting to a specific state (`main.gd`, `frame_host.gd`, `printing_overlay.gd`) should switch on `current` inside a single handler rather than each listening for a different event.
- The **only** automatic transition is `SCROLLING -> DISTORTING`, gated by `@export var distorting_fatigue_threshold` (default `0.25`) checked against `SessionData.fatigue` in `_process()`. Every other edge is one of these explicit calls, all no-ops if the state machine isn't in the expected source state (so double-calls from an eager caller are harmless):
  - `notify_first_interaction()` — `IDLE -> SCROLLING`; also flips `SessionData.has_interacted`. **Nothing calls this yet** — it's meant to be wired to `Feed.first_interaction` from `main.gd`, since Feed itself must never depend on StateMachine (§2a).
  - `request_focus()` — `SCROLLING/DISTORTING -> FOCUSING`, for `dwell_tracker.gd`.
  - `cancel_focus()` — `FOCUSING -> DISTORTING`, for `dwell_tracker.gd`/`focus_frame.gd` if the visitor scrolls away mid-tween.
  - `request_printing()` — `FOCUSING -> PRINTING`, for `focus_frame.gd` once its scale-up tween completes.
  - `request_revert()` — `PRINTING -> REVERTING`, for `printing_overlay.gd` once both `ExternalBridge` signals (`horoscope_ready`, `print_finished`) have landed (success or fallback — printing must never dead-end).
  - `request_idle()` — `REVERTING -> IDLE`, for `main.gd` once revert visuals finish.
- On entering `REVERTING`, `state_machine.gd` itself calls `SessionData.reset()` and `ContentLibrary.reshuffle_order()`. It does **not** call `Feed.reset()`, reset shader uniforms, or touch frame_host — those remain the responsibility of whatever scene node owns REVERTING's visual cleanup (per the original design's "fade/reset everything" — the FSM only owns session/content state, not scene state).

## 4. Content Loading

- On startup `content_library.gd` looks for a `content/` folder **next to the executable** (`OS.get_executable_path().get_base_dir()`, checked via `DirAccess.dir_exists_absolute`); if absent (i.e. running from the editor) it falls back to `res://content/`.
- External images load at runtime via `Image.load()` (which handles both absolute filesystem paths and `res://`) → `ImageTexture.create_from_image()`, cached in-memory by artwork `id` so repeated laps through the shuffled order don't redecode the same file.
- Consequence for the exhibit: curators can swap artworks or edit horoscope tags by editing a folder and a JSON file, **no re-export of the Godot project needed**.
- Feed order is a shuffled index list (`content_library.gd`'s `_shuffle_order`) over the validated artwork array, regenerated by `reshuffle_order()` on every REVERTING (called from `state_machine.gd`); the feed recycles a small pool of post_card instances rather than instancing one per artwork.

## 5. External Script Integration

Godot itself should never block on network/serial I/O. `external_bridge.gd` is the only place that spawns processes.

- `horoscope_api.py`: takes `--title`, `--artist`, `--date`, `--tags` (tags pre-joined into one comma-separated string) as args, calls you.com's API, prints JSON `{ "text": "..." }` to stdout.
- `print_job.py`: takes `--text` (+ optional `--image <path>`), wraps the thermal-pocket-printer repo's own CLI/library calls, sends to the printer over serial/Bluetooth, exits `0` on success.

### As implemented (`external_bridge.gd`)

- Each request (`request_horoscope(artwork_data)`, `request_print(text, image_path="")`) starts a dedicated `Thread` running `OS.execute()` in blocking mode (which captures stdout into an `output` array) — the blocking call happens off the main thread, so a stalled API call or serial handshake never freezes the exhibit.
- Completion is detected by **polling a shared, mutex-guarded result dictionary** on a `get_tree().create_timer()` loop every 0.05s, rather than `call_deferred` push-notification — simpler to reason about alongside a timeout, at the cost of a small poll granularity.
- **Timeouts**: `HOROSCOPE_TIMEOUT_SEC = 12.0`, `PRINT_TIMEOUT_SEC = 20.0`. If the timeout elapses before the thread reports `done`, the bridge stops waiting and reports a fallback immediately — the underlying script keeps running in its thread/process in the background and is joined lazily (`wait_to_finish()`) the next time a request of the same kind starts, not right away.
- **Fallbacks**: on horoscope timeout/failure, `horoscope_ready(text, was_fallback: true)` fires with a line picked from a small hardcoded `FALLBACK_HOROSCOPES` array (4 generic lines) instead of dead-ending PRINTING. On print timeout/failure, `print_finished(success: false)` fires so `printing_overlay.gd` can show a "the printer is dreaming, ask staff" state — no fallback text needed there, just a clear failure signal.
- **Interpreter resolution**: if the resolved script path ends in `.py`, it's invoked as `python3 <script> <args>` (dev/editor convenience — never assume a `python3` install on the kiosk); any other extension (i.e. a PyInstaller-built standalone executable, the intended export target) is invoked directly. This is decided per-call from the file extension, not a global flag.
- **Path resolution** mirrors `content_library.gd`: `OS.get_executable_path().get_base_dir() + "/external"` if that directory exists, else `ProjectSettings.globalize_path("res://external")` for editor runs. Never inside the `.pck`.
- Only one horoscope request and one print request can be in flight at a time — a second call while one is still `is_alive()` is ignored with a warning rather than queued.

**Still open**: `horoscope_api.py` and `print_job.py` themselves don't exist yet. `external_bridge.gd` already calls them with the exact argument shapes above, so writing them is now purely a matter of matching that CLI contract — no Godot-side changes should be needed.

## 6. Key Technical Challenges

- **Distortion that reads as "fatigue" not "glitch"**: subtle shader work (slight chromatic aberration, softening, gentle wave warp) that intensifies smoothly rather than an obvious glitch-art effect. Fine-tune curve shape (ease-in, not linear) so early scrolling feels normal. *(Still open — shaders not built.)*
- **Text distortion**: `Artistlabel`/`ArtworkLabel` are not distorted — the `ShaderMaterial` is only on `ArtworkRect`. Godot's Label/RichTextLabel don't warp easily; if text distortion is added later, options are rendering text to a Viewport texture and applying `text_distort.gdshader` (not yet built), or per-character transforms via `RichTextEffect`.
- **Input forwarding through a scaled SubViewportContainer**: the one real risk of the container approach; spike it early (build order step 4) and quarantine any workaround inside `frame_host.gd`. *(Still open — framing/ not built.)*
- **Decoupling scroll speed from fatigue**: fast flicking should build fatigue faster than slow deliberate scrolling — track velocity, not just item count, so the piece rewards/punishes behavior meaningfully. *(Done — lives in `feed.gd`'s `_update_fatigue`.)*
- **Dwell detection UX**: needs a "forgiveness window" — brief pauses (checking a caption) shouldn't fully trigger focus mode; only sustained stillness should. *(Still open — `dwell_tracker.gd` not built.)*
- **API latency variance**: you.com response time isn't guaranteed. *(Done — `external_bridge.gd` enforces a 12s horoscope timeout / 20s print timeout with hardcoded fallback text, so the installation never dead-ends for a gallery visitor.)*
- **Exported build + external assets**: both `external/` (scripts) and `content/` (artwork + manifest) live beside the exported executable; verify path resolution on the target machine, not just in the editor. *(Resolution logic done in both `content_library.gd` and `external_bridge.gd`; still needs verification on real kiosk hardware.)*
- **Session reset integrity**: REVERTING must fully clear shader uniforms, timers, and thread state — leftover state from one visitor bleeding into the next is an easy bug in exhibit-style software that runs for days unattended. *(Partially done — `state_machine.gd` clears `SessionData` and reshuffles `ContentLibrary` on entering REVERTING; `external_bridge.gd`'s in-flight thread guard prevents overlapping requests. Scene-level cleanup — shader uniforms, tweens, `Feed.reset()` — is still unowned since `main.gd`/`framing/` don't exist yet.)*

## 7. Suggested Build Order

1. `content_library` + manifest loading (with executable-adjacent override) + feed showing real artworks, scroll input, prompt finger — no distortion yet. **Done** — `content_library.gd` and `prompt_finger.tscn/.gd` are both built; `feed.tscn` no longer has missing dependencies for this step.
2. Image distortion shader wired to a manually-tweaked debug slider. **Done** — `shaders/image_distort.gdshader` is built and assigned as `ArtworkRect`'s `ShaderMaterial` directly in `post_card.tscn`; `post_card.gd` reads that material in `_ready()`, no `load()` call involved. The "debug slider" can just be a Range node calling `post_card.set_distortion()` directly for isolated testing, separate from Feed's automatic fatigue-driven mapping. Only the artwork image distorts; captions do not.
3. Fatigue accumulation from real scroll input, replacing the debug slider. **Done** — lives inside `feed.gd` (`_update_fatigue`), writing to `SessionData.fatigue`, which **is now built** and ready to receive it.
4. **Framing spike**: SubViewport + SubViewportContainer, verify swipe input while scaled/offset, then build frame_host with phone_frame as the first decoration. Feed already exposes `set_scroll_locked()` for this to call during transitions (§2a) — frame_host doesn't need to reach into Feed's internals.
5. Dwell detection + focus_frame transition (container scale-up onto the dwelled post). Build `dwell_tracker.gd` against `Feed.nearest_card_changed` (§2a), calling `StateMachine.request_focus()`/`cancel_focus()` (§3) rather than polling card positions or reimplementing FSM logic.
6. External script plumbing via external_bridge. **`external_bridge.gd` itself is done** (threading, timeouts, fallbacks, path resolution) — what's left is writing `horoscope_api.py`/`print_job.py` to match the CLI contract in §5, and building `horoscope_client.gd`/`printing_overlay.gd` to call `request_horoscope()`/`request_print()` and drive `StateMachine.request_printing()`/`request_revert()` off the resulting signals. Start with mocked scripts (echo a canned JSON string / exit 0) to validate that wiring before touching the real API or printer hardware.
7. Swap in real you.com API and real printer hardware.
8. Reset/revert flow + exhibit hardening (crash recovery, timeouts, logging, path checks on the kiosk machine). `state_machine.gd`'s REVERTING handling and `Feed.reset()` both already exist (§3, §2a) — this step is about wiring `main.gd` so `Feed.reset()` and any scene-level shader/tween cleanup actually run alongside `StateMachine`'s session-data reset, plus `main.gd` calling `StateMachine.request_idle()` once that cleanup finishes.
