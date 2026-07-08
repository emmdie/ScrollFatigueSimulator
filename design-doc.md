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

- **Built:** `feed/post_card.tscn` + `post_card.gd`, `feed/feed.tscn` + `feed.gd`.
- **Not built yet:** `content_library.gd`, `session_data.gd`, `state_machine.gd`, `external_bridge.gd`, `dwell_tracker.gd`, `prompt_finger.tscn/.gd`, everything under `framing/`, everything under `printing/`, the shaders themselves.
- `feed.gd` was written *against assumed autoload APIs* (`ContentLibrary`, `SessionData`) since those didn't exist yet. **§1a below is the actual contract — implement `content_library.gd` and `session_data.gd` to match it exactly**, or update `feed.gd` if you change the shape.
- `feed.gd` deliberately does **not** read `StateMachine` or drive it. It only exposes `set_scroll_locked(bool)`, `reset()`, and two signals (`nearest_card_changed`, `first_interaction`). Whatever owns dwell detection / framing / the FSM is expected to call into Feed, not the other way around. Don't add a dependency from Feed back to StateMachine — see §2a.
- The `SCROLLING` vs `DISTORTING` states in §3 don't correspond to any branching inside `feed.gd` — Feed always tracks velocity/fatigue/per-card distortion continuously regardless of global state, it just stops doing so when `scrolling_locked` is true. Those two FSM states exist for whoever drives frame-level escalation (phone_frame → picture_frame), not for Feed itself.
- `post_card.gd` needed a fix: the original draft declared `_distort_material` but never assigned it, so `set_distortion()` was a silent no-op. Fixed by adding a `CanvasGroup` (`distort_group`) wrapping the card's contents in `post_card.tscn`, with the `ShaderMaterial` created in `_ready()` and assigned to that group — this also gives "text distorts along with the image" for free, since the CanvasGroup flattens its subtree to one texture before the shader runs. **`shaders/image_distort.gdshader` does not exist yet** — `post_card.gd` will error on `_ready()` until it's created; it needs a `distortion` (0.0–1.0) shader parameter.

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
│   ├── state_machine.gd       # global FSM: IDLE, SCROLLING, DISTORTING, FOCUSING, PRINTING, REVERTING
│   ├── session_data.gd        # tracks current post, scroll velocity, dwell timer, fatigue/distortion level
│   ├── content_library.gd     # loads + validates manifest.json, hands out ArtworkData; sole owner of content paths
│   └── external_bridge.gd     # OS.create_process()/Thread wrappers for printer + API helper scripts
│
├── main/
│   ├── main.tscn              # root: FrameHost + PrintingOverlay layers; listens to StateMachine
│   └── main.gd
│
├── feed/                      # everything that lives INSIDE the SubViewport
│   ├── feed.tscn              # ✅ built. Feed (Control) > CardContainer (Control) + PromptFinger (last child)
│   ├── feed.gd                # ✅ built. Recycled pool of pool_size post_cards, drag/momentum scroll,
│   │                          #   fatigue accumulation, per-card distortion, nearest-card signal. See §1a.
│   ├── post_card.tscn         # ✅ built. Root Control > BackgroundColor, DistortGroup (CanvasGroup) > VBoxContainer
│   │                          #   (CaptionBox w/ Artistlabel+ArtworkLabel, separator ColorRect, ArtworkRect)
│   ├── post_card.gd           # ✅ built. setup(artist,title,texture), set_distortion(0..1) via distort_group's material
│   ├── dwell_tracker.gd       # ⬜ not built. Plain Node child of feed.tscn; NOT told about post changes by polling —
│   │                          #   listen to Feed.nearest_card_changed(post_card, artwork_data) instead. On sustained
│   │                          #   stillness past dwell_threshold, call feed.set_scroll_locked(true) and signal
│   │                          #   whoever owns focus_frame/StateMachine to transition to FOCUSING.
│   ├── prompt_finger.tscn     # ⬜ not built. Idle swipe animation. Feed calls prompt_finger.dismiss() on first input
│   │                          #   and prompt_finger.reset() on Feed.reset() — implement both methods.
│   └── prompt_finger.gd
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
│   ├── printing_overlay.tscn  # progress bar/animation while API + printer run (two-phase bar, see §3 FSM notes)
│   ├── printing_overlay.gd
│   ├── result_card.tscn       # optional on-screen preview of the printed text
│   ├── result_card.gd
│   └── horoscope_client.gd    # no scene; builds prompt from ArtworkData tags, calls external_bridge, parses JSON reply
│
├── shaders/                   # shaders are shared visual assets, referenced by feed/ and framing/
│   ├── image_distort.gdshader # ⬜ not built — REQUIRED for post_card.gd to run. Must expose a float
│   │                          #   shader_parameter named "distortion" (0..1). Applied to post_card's
│   │                          #   DistortGroup (a CanvasGroup), so it runs on the flattened image+text texture.
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
    ├── horoscope_api.py       # calls you.com API, prints JSON {"text": "..."} to stdout
    └── print_job.py           # wraps thermal-pocket-printer repo, takes text (+ optional dithered image) via CLI args
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
- `tags` are the horoscope seed: `horoscope_client.gd` feeds `title`, `artist`, `date`, `tags` into the prompt. Curating tags is how you tune the printout's tone per artwork — no code change needed.
- `content_library.gd` validates the manifest on startup (missing files, duplicate ids, empty tags) and logs problems instead of crashing; a broken entry is skipped, the exhibit keeps running.
- Optional fields can be added later (e.g. `credit`, `palette_hint`) without breaking older code — parse defensively, ignore unknown keys.

## 1a. Autoload Contract Required by `feed.gd` (implement to match, or edit feed.gd)

`feed.gd` is already written and calls these directly (no null/has-method guards), so `content_library.gd` and `session_data.gd` must match this shape or the feed will error at runtime:

```gdscript
# ContentLibrary (autoload)
func get_artwork_count() -> int
func get_artwork(order_index: int) -> Dictionary   # {id, title, artist, tags, ...} — NOT keyed by manifest "file"/id string,
                                                     # Feed always passes a plain 0..count-1 index (see note below)
func load_texture(artwork_data: Dictionary) -> Texture2D
```
```gdscript
# SessionData (autoload)
var fatigue: float   # Feed writes this every frame; other systems (frame_host escalation) should read it, not recompute it
```

Notes for whoever builds `content_library.gd`:
- Feed maps its own infinite `logical_index` (can be negative, unbounded) to a manifest entry via `((logical_index % count) + count) % count`, then calls `get_artwork(order_index)`. This assumes `get_artwork` takes a **plain array-style index into your current shuffle order**, not the manifest's `id` string. If you'd rather key by `id`, either add a separate `get_shuffled_order() -> Array[int]` that Feed can consult, or change `_artwork_for_logical_index()` in `feed.gd` to go through it — flagging so the two aren't built to mismatching assumptions.
- `reset()` on Feed rebuilds its whole pool from scratch (calls `get_artwork_count`/`get_artwork` again), so re-shuffling inside `content_library.gd` on REVERTING is enough — Feed doesn't need to be told the order changed, it'll just re-query it.

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

## 4. Content Loading

- On startup `content_library.gd` looks for a `content/` folder **next to the executable** (`OS.get_executable_path().get_base_dir()`); if absent (i.e. running from the editor) it falls back to `res://content/`.
- External images load at runtime via `Image.load_from_file()` → `ImageTexture` (the res:// import pipeline doesn't apply to executable-adjacent files, and that's fine — decode once at startup or lazily with a small cache).
- Consequence for the exhibit: curators can swap artworks or edit horoscope tags by editing a folder and a JSON file, **no re-export of the Godot project needed**.
- Feed order is a shuffled index list over `content_library`'s artworks, re-shuffled every REVERTING; the feed recycles a small pool of post_card instances rather than instancing one per artwork.

## 5. External Script Integration

Godot itself should never block on network/serial I/O. `external_bridge.gd` is the only place that spawns processes; it uses `OS.execute()` in blocking mode from a background `Thread` (or `OS.create_process()` + polling), communicating via stdout/JSON or temp files:

- `horoscope_api.py`: takes `--title`, `--artist`, `--date`, `--tags` as args (straight out of the manifest entry), calls you.com's API, prints JSON `{ "text": "..." }` to stdout.
- `print_job.py`: wraps the thermal-pocket-printer repo's own CLI/library calls, takes the horoscope text + maybe a cropped/dithered version of the artwork, sends to the printer over serial/Bluetooth.

**Key implementation details**:
- Run both in a Godot `Thread` (or `WorkerThreadPool` task), never on the main thread — a stalled API call or serial handshake would otherwise freeze the whole exhibit. Emit completion back to the main thread via `call_deferred`.
- Every external call gets a timeout and a fallback: pre-written generic horoscope lines if the API fails, a graceful "the printer is dreaming, ask staff" state if printing fails. PRINTING must never dead-end.
- For export: bundle the Python scripts (ideally compiled to standalone executables via PyInstaller so no interpreter is required on the kiosk) in an `external/` folder **next to the exported executable**, resolved relative to `OS.get_executable_path()` — never hardcoded dev paths, never inside the .pck.

## 6. Key Technical Challenges

- **Distortion that reads as "fatigue" not "glitch"**: subtle shader work (slight chromatic aberration, softening, gentle wave warp) that intensifies smoothly rather than an obvious glitch-art effect. Fine-tune curve shape (ease-in, not linear) so early scrolling feels normal.
- **Text distortion**: Godot's Label/RichTextLabel don't warp easily. Options: render text to a Viewport texture and apply the same shader as images, or use per-character transforms via `RichTextEffect`.
- **Input forwarding through a scaled SubViewportContainer**: the one real risk of the container approach; spike it early (build order step 4) and quarantine any workaround inside `frame_host.gd`.
- **Decoupling scroll speed from fatigue**: fast flicking should build fatigue faster than slow deliberate scrolling — track velocity, not just item count, so the piece rewards/punishes behavior meaningfully.
- **Dwell detection UX**: needs a "forgiveness window" — brief pauses (checking a caption) shouldn't fully trigger focus mode; only sustained stillness should.
- **API latency variance**: you.com response time isn't guaranteed — timeout + fallback horoscope text (pre-written generic lines) if the call takes too long or fails, so the installation never dead-ends for a gallery visitor.
- **Exported build + external assets**: both `external/` (scripts) and `content/` (artwork + manifest) live beside the exported executable; verify path resolution on the target machine, not just in the editor.
- **Session reset integrity**: make sure REVERTING fully clears shader uniforms, timers, and thread state — leftover state from one visitor bleeding into the next is an easy bug in exhibit-style software that runs for days unattended.

## 7. Suggested Build Order

1. ~~`content_library` + manifest loading (with executable-adjacent override) + feed showing real artworks, scroll input, prompt finger — no distortion yet.~~ **Partially done**: `feed.gd`/`post_card.tscn` are built and expect the §1a contract, but `content_library.gd` and `prompt_finger.tscn/.gd` themselves still need to be written to match. Do these next — feed.tscn can't run at all without them.
2. Image/text distortion shaders wired to a manually-tweaked debug slider. **Blocked on `shaders/image_distort.gdshader`** — `post_card.gd`'s `_ready()` already calls `load()` on it, so write the shader before testing the card scene at all. The "debug slider" can just be a Range node calling `post_card.set_distortion()` directly for isolated testing, separate from Feed's automatic fatigue-driven mapping.
3. ~~Fatigue accumulation from real scroll input, replacing the debug slider.~~ **Done** — lives inside `feed.gd` (`_update_fatigue`), written directly against real drag/momentum input, not a debug slider. Writes to `SessionData.fatigue` (§1a) — build `session_data.gd` next so this has somewhere to land.
4. **Framing spike**: SubViewport + SubViewportContainer, verify swipe input while scaled/offset, then build frame_host with phone_frame as the first decoration. Feed already exposes `set_scroll_locked()` for this to call during transitions (§2a) — frame_host doesn't need to reach into Feed's internals.
5. Dwell detection + focus_frame transition (container scale-up onto the dwelled post). Build `dwell_tracker.gd` against `Feed.nearest_card_changed` (§2a) rather than polling card positions.
6. External script plumbing via external_bridge (start with a mocked/local fake API and a print-to-log stub instead of the real printer) to validate the async threading model and the two-phase progress bar.
7. Swap in real you.com API and real printer hardware.
8. Reset/revert flow + exhibit hardening (crash recovery, timeouts, logging, path checks on the kiosk machine). Note `Feed.reset()` already exists and does its part (§2a) — this step is about wiring it into `state_machine.gd`'s REVERTING handler alongside the rest.
