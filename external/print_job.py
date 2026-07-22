#!/usr/bin/env python3
"""Thermal print job — Fichero 3561 (Art. 3561) via TiMini-Print.

CLI contract (design doc §5, unchanged): --text [--image <path>] -> exit 0 on
success, nothing required on stdout. All diagnostics go to stderr.

Composes caption + artwork into ONE 384 px 1-bit PNG and hands TiMini a single
job: every invocation pays ~10 s of BLE connect/GATT discovery, and two
sequential jobs (~33 s) risk a dropped link.

TiMini CLI resolution order:
  1. $TIMINI_CLI  — path to a release binary, or a .py (run with its venv python)
  2. a TiMini-Print-Command-Line-* release binary next to this script (kiosk)
  3. sibling dev checkout ../TiMini-Print/timiniprint_command_line.py,
     using its venv/bin/python when present

Pillow is needed for composition. If the invoking python3 lacks it, the script
re-execs itself under the TiMini venv python (which ships Pillow). If that
also fails, it degrades to a text-only job so PRINTING never dead-ends.

Extra dev flag: --dry-run [--out preview.png] composes without printing.
"""
import argparse
import os
import subprocess
import sys
import tempfile

BT_ADDR = os.environ.get("TIMINI_BT_ADDR", "60:6E:41:63:09:0D")
MODEL_KEY = os.environ.get("TIMINI_MODEL", "luck_a2")  # internal key, NOT "PPA2"
PRINT_WIDTH = 384          # 56 mm @ 203 dpi
MAX_ART_HEIGHT = 400       # caps BLE transfer time (transfer scales with height)
MARGIN = 8
TEXT_SIZE = 26
LINE_SPACING = 6
JOB_TIMEOUT_SEC = 55       # stays under ExternalBridge's 60 s

EXTERNAL_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(EXTERNAL_DIR)
SIBLING_TIMINI = os.path.join(os.path.dirname(PROJECT_ROOT), "TiMini-Print")

# 8x8 Bayer matrix — ordered dithering reads cleaner on cheap thermal paper
# than Floyd-Steinberg, which muds up dark regions.
BAYER8 = [
    [0, 32, 8, 40, 2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21],
]


def log(message: str) -> None:
    print("[print_job] %s" % message, file=sys.stderr)


def _venv_python(directory: str) -> str:
    for venv in ("venv", ".venv"):
        path = os.path.join(directory, venv, "bin", "python3")
        if os.path.isfile(path):
            return path
        path = os.path.join(directory, venv, "bin", "python")
        if os.path.isfile(path):
            return path
    return ""


def _normalize_godot_path(path: str) -> str:
    """Godot hands over a res:// path when running from the editor; map it
    onto the project root so PIL can open it. Exported builds pass absolute
    executable-adjacent paths and never hit this."""
    if path.startswith("res://"):
        mapped = os.path.join(PROJECT_ROOT, path[len("res://"):])
        log("mapped Godot path '%s' -> '%s'" % (path, mapped))
        return mapped
    return path


def resolve_timini_cmd() -> list:
    """argv prefix for invoking the TiMini CLI, or [] if not found."""
    cli = os.environ.get("TIMINI_CLI", "")
    if cli:
        if cli.endswith(".py"):
            py = _venv_python(os.path.dirname(cli)) or sys.executable
            return [py, cli]
        return [cli]
    try:
        for name in sorted(os.listdir(EXTERNAL_DIR)):
            if name.startswith("TiMini-Print-Command-Line"):
                return [os.path.join(EXTERNAL_DIR, name)]
    except OSError:
        pass
    script = os.path.join(SIBLING_TIMINI, "timiniprint_command_line.py")
    if os.path.isfile(script):
        py = _venv_python(SIBLING_TIMINI) or sys.executable
        return [py, script]
    return []


def ensure_pillow() -> bool:
    """True if PIL importable; may re-exec under the TiMini venv python."""
    try:
        import PIL  # noqa: F401
        return True
    except ImportError:
        pass
    if os.environ.get("PRINT_JOB_REEXECED") == "1":
        return False
    py = _venv_python(SIBLING_TIMINI)
    if py and os.path.realpath(py) != os.path.realpath(sys.executable):
        os.environ["PRINT_JOB_REEXECED"] = "1"
        os.execv(py, [py, os.path.abspath(__file__)] + sys.argv[1:])
    return False


# ---------------------------------------------------------------------------
# Composition (requires Pillow)
# ---------------------------------------------------------------------------
def _ordered_dither(gray):
    from PIL import Image, ImageChops
    tile = Image.new("L", (8, 8))
    tile.putdata([min(255, int((v + 0.5) * 4)) for row in BAYER8 for v in row])
    thresholds = Image.new("L", gray.size)
    for y in range(0, gray.size[1], 8):
        for x in range(0, gray.size[0], 8):
            thresholds.paste(tile, (x, y))
    # subtract clamps at 0, so only pixels with gray > threshold survive
    return ImageChops.subtract(gray, thresholds).point(lambda p: 255 if p > 0 else 0)


def _load_font(size: int):
    from PIL import ImageFont
    for path in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    ):
        if os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
    return ImageFont.load_default()


def _wrap(draw, text: str, font, max_width: int) -> list:
    lines = []
    for paragraph in text.split("\n"):
        words = paragraph.split()
        if not words:
            lines.append("")
            continue
        line = words[0]
        for word in words[1:]:
            candidate = line + " " + word
            if draw.textlength(candidate, font=font) <= max_width:
                line = candidate
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def compose(text: str, image_path: str, out_path: str) -> None:
    from PIL import Image, ImageDraw, ImageOps

    art = None
    if image_path:
        try:
            art = ImageOps.exif_transpose(Image.open(image_path)).convert("L")
            art.thumbnail((PRINT_WIDTH, MAX_ART_HEIGHT))
            art = ImageOps.autocontrast(art, cutoff=1)
            art = _ordered_dither(art)
        except OSError as exc:
            log("could not open artwork '%s': %s — text only" % (image_path, exc))
            art = None

    font = _load_font(TEXT_SIZE)
    probe = ImageDraw.Draw(Image.new("L", (PRINT_WIDTH, 8), 255))
    lines = _wrap(probe, text, font, PRINT_WIDTH - 2 * MARGIN) if text.strip() else []
    try:
        line_height = font.getbbox("Ag")[3] + LINE_SPACING
    except AttributeError:  # bitmap fallback font
        line_height = TEXT_SIZE + LINE_SPACING

    height = MARGIN
    if art:
        height += art.height + (MARGIN if lines else 0)
    height += len(lines) * line_height + MARGIN

    canvas = Image.new("L", (PRINT_WIDTH, height), 255)
    y = MARGIN
    if art:
        canvas.paste(art, ((PRINT_WIDTH - art.width) // 2, y))
        y += art.height + (MARGIN if lines else 0)
    draw = ImageDraw.Draw(canvas)
    for line in lines:
        draw.text((MARGIN, y), line, font=font, fill=0)  # text: hard B/W, no dither
        y += line_height
    canvas.convert("1").save(out_path)


# ---------------------------------------------------------------------------
# Printing
# ---------------------------------------------------------------------------
def run_timini(job_args: list) -> int:
    cmd = resolve_timini_cmd()
    if not cmd:
        log(
            "TiMini CLI not found — set $TIMINI_CLI, drop a "
            "TiMini-Print-Command-Line-* release binary into external/, or "
            "clone TiMini-Print next to the project folder"
        )
        return 1
    full = cmd + ["--bluetooth", BT_ADDR, "--printer-model", MODEL_KEY] + job_args
    env = dict(os.environ, TIMINIPRINT_NO_UPDATE_CHECK="1")
    log("exec: %s" % " ".join(full))
    try:
        proc = subprocess.run(
            full,
            env=env,
            timeout=JOB_TIMEOUT_SEC,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except subprocess.TimeoutExpired:
        log("TiMini timed out after %d s" % JOB_TIMEOUT_SEC)
        return 1
    except OSError as exc:
        log("failed to exec TiMini: %s" % exc)
        return 1
    if proc.stdout:
        sys.stderr.write(proc.stdout)
    if proc.returncode != 0:
        log("TiMini exited with code %d" % proc.returncode)
    return proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", default="")
    parser.add_argument("--image", default="")
    parser.add_argument("--dry-run", action="store_true", help="compose only, don't print")
    parser.add_argument("--out", default="", help="output path for --dry-run preview")
    args = parser.parse_args()

    if not args.text and not args.image:
        log("nothing to print (--text and --image both empty)")
        return 1
    image_path = _normalize_godot_path(args.image)

    if not ensure_pillow():
        log("Pillow unavailable — degrading to text-only TiMini job")
        if args.dry_run:
            return 1
        return run_timini(["--text", args.text or "(no text)"])

    if args.dry_run:
        out = args.out or "print_preview.png"
        compose(args.text, image_path, out)
        log("dry run: composed job written to %s" % out)
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        job_path = os.path.join(tmp, "job.png")
        compose(args.text, image_path, job_path)
        return run_timini([job_path])


if __name__ == "__main__":
    sys.exit(main())
