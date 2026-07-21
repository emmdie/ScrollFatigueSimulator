# Scroll Fatigue — Design Doc

Godot software for an artistic vision of "scroll fatigue" — engagement with each post drops as the user scrolls past more of them. **Frames symbolize how much attention each post receives**: painting frame = full attention (base), tablet = less, phone = least.

1. **Approaching**: a social-media-style feed of artworks inside the painting frame. A finger icon prompts the first swipe.
2. **Distortion**: continued swiping subtly distorts each image; fatigue escalates the framing down the attention ladder (painting → tablet → phone). Stopping lets fatigue decay and the frames walk back up.
3. **Focusing/Printing**: only after interacting, then holding still long enough for the framing to return all the way to the painting, does the dwelled image enter the focus frame — a visible progress bar fills while a nonsensical horoscope-style statement (AI API, you.com) is generated and printed on a thermal pocket printer via external scripts.
4. **Reverting**: back to the initial state for the next visitor.

## Status

- **Built:** full loop IDLE → SCROLLING → DISTORTING → FOCUSING → PRINTING → REVERTING → IDLE, all feed/framing/printing scenes, all autoloads.
- **Mocked:** `external/horoscope_api.py`, `external/print_job.py` — match the §5 CLI contract; swap for the real you.com API and printer hardware with no Godot-side changes.
- **Not built:** `printing/result_card`, `text_distort`/`feed_distort` shaders.
- **Open:** exhibit hardening, kiosk-hardware verification (paths, touch input).

## 0. Structural Conventions

- Scene-adjacent scripts (`feed.tscn` + `feed.gd`); folders by feature (`feed/`, `framing/`, `printing/`, `content/`), not node type.
- snake_case filenames, PascalCase node names.
- Content is data: artworks + metadata live behind `content/manifest.json`, accessed only via `ContentLibrary`.
- Node references are `@export` variables assigned in the editor — no `$NodeName` fetching at runtime.
- The feed renders once into a fixed-resolution `SubViewport`; every framing context is a different presentation of that one texture (§2).

## 1. Project Structure

```
res://
├── autoload/
│   ├── state_machine.gd    # FSM (§3). Auto-escalates SCROLLING→DISTORTING off fatigue;
│   │                       #   every other edge is a request_*/notify_* method.
│   ├── session_data.gd     # fatigue, scroll_velocity, has_interacted, current_artwork,
│   │                       #   dwell_elapsed, last_horoscope_text, reset().
│   ├── content_library.gd  # manifest load/validate, shuffled run order, texture cache (§4).
│   └── external_bridge.gd  # threaded OS.execute() wrappers, timeouts + fallbacks (§5).
├── main/
│   ├── main.tscn / main.gd # conductor (§3a): state→framing incl. escalation ladder (§3b),
│                           #   first_interaction→FSM, REVERTING cleanup.
├── feed/                   # everything INSIDE the SubViewport
│   ├── feed.tscn / .gd     # recycled card pool, drag/momentum, fatigue + velocity publishing,
│   │                       #   fatigue→shader mapping, nearest-card signal, snap-to-top.
│   ├── post_card.tscn/.gd  # setup(artist,title,texture), set_distortion() via duplicated
│   │                       #   per-instance ShaderMaterial on ArtworkRect.
│   ├── dwell_tracker.gd    # gated dwell → request_focus(); node in frame_host.tscn (§3a).
│   └── prompt_finger.*     # looping swipe tween; dismiss()/reset().
├── framing/
│   ├── frame_host.tscn/.gd # FeedClip (clip) > SubViewportContainer > SubViewport > Feed +
│   │                       #   DecorationLayer + DwellTracker. Tweens clip to FeedSlot rects,
│   │                       #   cover-fit top-anchored, dip-free crossfades (§2). @export feed.
│   ├── frame_base.gd       # feed_slot_path, get_feed_global_rect(), enter()/exit().
│   └── frames/             # picture_frame (base), tablet_frame, phone_frame, focus_frame.
├── printing/
│   ├── printing_overlay.*  # drives focus_frame's progress bar (0–50 horoscope, 50–100 print),
│   │                       #   calls request_revert() when print_finished lands.
│   ├── horoscope_client.gd # stateless ArtworkData → ExternalBridge.request_horoscope().
│   └── result_card.*       # ⬜ optional on-screen preview of the printed text
├── shaders/
│   ├── image_distort.gdshader  # "distortion" param; usable range ≈ 0.02 (subtle) – 0.15 (heavy)
│   ├── text_distort.gdshader   # ⬜
│   └── feed_distort.gdshader   # ⬜
├── content/                # dev copy; executable-adjacent content/ overrides at runtime (§4)
└── external/               # shipped next to the exported executable, not in the .pck (§5)
    ├── horoscope_api.py    # ⚠️ mocked
    └── print_job.py        # ⚠️ mocked
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

- `id` is the stable key; `file` is relative to the manifest's folder; `tags` seed the horoscope prompt.
- `content_library.gd` validates on startup (missing files, duplicate ids, empty tags), skips broken entries, logs instead of crashing. Unknown keys pass through into ArtworkData.

## 1a. Autoload Contract

```gdscript
# ContentLibrary
func get_artwork_count() -> int
func get_artwork(order_index: int) -> Dictionary   # indexes the shuffled run order
func load_texture(artwork_data: Dictionary) -> Texture2D  # cached by id
func reshuffle_order() -> void                     # called by state_machine on REVERTING

# SessionData
var fatigue: float          # Feed writes every frame; others read, never recompute
var scroll_velocity: float  # Feed writes every frame; dwell_tracker's stillness source
```

## 2. Framing: container-based, not camera-based

The feed renders into a fixed `SubViewport` (`size_2d_override` = 1080×1920); `frame_host.gd` tweens **FeedClip** to the active frame's FeedSlot rect and cover-fits the container inside — aspect-preserving, top-anchored, cropping bottom/sides rather than stretching (the snapped card sits at the top). Frames are `FrameBase` decoration scenes swapped in `DecorationLayer`.

- **Dip-free crossfade:** `show_frame()` keeps the outgoing frame fully opaque underneath while the incoming one (a later sibling, drawn on top) fades in; only then does the old one fade out (`duration * 0.5`) and free. Both frames are never half-transparent at once, so the feed never flashes "bare" between escalation steps. Rapid supersessions chain cleanly: each call retires exactly the frame it replaced.
- **Draw order:** FeedClip is a later sibling than DecorationLayer, so the feed draws above all z-index-0 decoration. Any decoration meant to render **over** the feed (phone bezel, focus frame's progress bar) needs `z_index ≥ 1` on that node.
- Gotchas already handled in `frame_host.gd`: `size_2d_override` set at runtime; `get_feed_global_rect()` honors editor `scale` on FeedSlots; `show_frame()` re-checks `current_frame` after its one-frame layout await; decoration nodes are `mouse_filter = IGNORE`; a manual `push_input()` fallback exists behind `use_manual_input_forwarding` (off by default).

## 2a. Feed's Public API

```gdscript
func set_scroll_locked(locked: bool) -> void  # dwell_tracker on focus; cancels in-progress drag
func reset() -> void   # REVERTING: unlocks scrolling, clears scroll/fatigue, rebuilds pool, resets finger
signal nearest_card_changed(post_card: Control, artwork_data: Dictionary)
signal first_interaction
```

- **"Nearest" card = top edge closest to the top of the feed.**
- **Snap-to-top:** after `snap_delay` (1.0s) of near-stillness, Feed tweens the nearest card fully into view.
- **Fatigue → shader mapping** (`_apply_distortion`): `pow(fatigue + jitter, distortion_exponent) * max_shader_distortion` (defaults 1.6 / 0.12). `SessionData.fatigue` stays raw 0..1; only the shader input is compressed into the shader's usable range.

## 3. Core State Machine (`state_machine.gd`)

```
IDLE → SCROLLING → DISTORTING → FOCUSING → PRINTING → REVERTING → IDLE
```

- Single `state_changed(previous: int, current: int)` signal; states in `enum STATE`; current state in `var state: int`.
- Only automatic transition: `SCROLLING → DISTORTING` when `SessionData.fatigue ≥ distorting_fatigue_threshold` (0.25). All other edges are no-op-if-wrong-state calls:
  - `notify_first_interaction()` — IDLE → SCROLLING (main.gd, off `Feed.first_interaction`).
  - `request_focus()` / `cancel_focus()` — dwell_tracker.gd.
  - `request_printing()` — focus_frame.gd, after its fade-in completes.
  - `request_revert()` — printing_overlay.gd, once both ExternalBridge signals land.
  - `request_idle()` — main.gd, after revert visuals finish.
- On entering REVERTING the FSM calls `SessionData.reset()` + `ContentLibrary.reshuffle_order()` **before** emitting `state_changed`, so listeners rebuild from fresh state.

## 3a. Dwell + edge ownership

- `dwell_tracker.gd` (node in frame_host.tscn, `@export var feed`) gates dwell twice:
  1. **FSM state** — only SCROLLING/DISTORTING accumulate (elsewhere `request_focus()` couldn't take).
  2. **Fatigue recovery** — dwell only accumulates once `SessionData.fatigue ≤ fatigue_focus_threshold` (0.2 = `escalation_thresholds[0] - de_escalation_hysteresis`). A pause mid-ladder first plays out the full de-escalation back to the painting; only then does the `dwell_threshold` (4.0s) focus timer run. Focus is therefore always entered *from* the painting frame, never from tablet/phone.
- Below `velocity_still_threshold` dwell accumulates; motion resets it only after `forgiveness_window` (0.3s). On trigger: locks the feed, writes `SessionData.current_artwork`, calls `request_focus()`. A new `nearest_card_changed` while focused cancels back. Resets itself on REVERTING.
- `focus_frame.gd` owns FOCUSING → PRINTING: `enter()` fades in (progress bar at 0), then `request_printing()`.
- `printing_overlay.gd` owns PRINTING → REVERTING and drives focus_frame's progress bar (0–50% horoscope, 50–100% print) with a creep tween that snaps when the real signal lands.
- `main.gd` owns framing + the IDLE/REVERTING bookends. Per state: IDLE → level 0; DISTORTING → re-apply current level (covers cancel-back from FOCUSING); FOCUSING → focus frame; REVERTING → `Feed.reset()` + level 0, then `request_idle()` after `revert_settle_time`. Framing changes are deduped — re-entering a state doesn't re-crossfade the frame already on screen.

## 3b. Frame Escalation Ladder (`main.gd`)

- **Level 0 = `base_frame_scene` = picture_frame** — full attention; the exhibit opens, de-escalates, and reverts into it. Level *i* = `escalation_frames[i-1]`, ordered by *decreasing* attention: `[tablet_frame, phone_frame]` with thresholds `[0.35, 0.7]`.
- `focus_frame` is entered via the FOCUSING state, **never** listed in `escalation_frames` — it has its own `focus_frame_scene` export.
- Escalation is sluggish by design: `min_frame_hold` (2.5s) before any level change; de-escalation requires fatigue to drop `de_escalation_hysteresis` (0.15) below the threshold. With fatigue decaying at 0.12/s, a full phone → painting recovery plus the 4s focus dwell takes roughly 8–10s of stillness.

## 4. Content Loading

- `content_library.gd` looks for `content/` next to the executable, falling back to `res://content/` in-editor. Images load via `Image.load()` → `ImageTexture`, cached by `id`. Curators swap artworks/tags by editing folder + JSON — no re-export.
- Feed order is a shuffled index list, regenerated on every REVERTING; a small pool of `post_card` instances is recycled.

## 5. External Script Integration (`external_bridge.gd`)

Only place that spawns processes; Godot never blocks on network/serial I/O.

- `horoscope_api.py`: `--title --artist --date --tags` (comma-joined) → stdout JSON `{"text": "..."}`.
- `print_job.py`: `--text [--image <path>]`, exit `0` on success.
- Each request runs `OS.execute()` on a dedicated `Thread`, polled via mutex-guarded dict every 0.05s. Timeouts: 12s horoscope / 20s print. On failure/timeout: horoscope → `horoscope_ready(fallback_line, was_fallback=true)`; print → `print_finished(false)`. PRINTING never dead-ends.
- One request of each kind in flight at a time; `.py` runs via `python3` (dev), anything else (PyInstaller build, the export target) runs directly. Path resolution mirrors `content_library.gd` (executable-adjacent `external/`, else `res://external`).

## 6. Remaining Work

- Real you.com API + thermal-printer calls in `external/` (drop-in per §5 contract).
- `result_card` on-screen preview; `text_distort`/`feed_distort` shaders.
- Distortion reading as "fatigue" not "glitch" — tune `distortion_exponent`/`max_shader_distortion` + shader look on real hardware.
- Kiosk verification: executable-adjacent paths, touch input through the shrunk container.
