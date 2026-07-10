#!/usr/bin/env python3
"""Mock horoscope generator.

CLI contract (design doc §5): --title --artist --date --tags (comma-joined)
-> stdout JSON {"text": "..."}. Swap for a real you.com API call for
production (§7 step 7) with no Godot-side changes needed.
"""
import argparse
import json
import random
import sys

TEMPLATES = [
    "{artist} has seen your {tag1}, and the stars agree: expect {tag2} before the week is out.",
    "The {tag1} in \"{title}\" reveals a hidden truth — you crave {tag2} more than you admit.",
    "Born of {tag1} and {tag2}, this piece says your next chapter smells like old varnish and new love.",
    "\"{title}\" whispers: beware of {tag1}, embrace {tag2}, and don't trust anyone born under a gilded frame.",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", default="")
    parser.add_argument("--artist", default="")
    parser.add_argument("--date", default="")
    parser.add_argument("--tags", default="")
    args = parser.parse_args()

    tags = [t.strip() for t in args.tags.split(",") if t.strip()]
    if not tags:
        tags = ["mystery"]
    while len(tags) < 2:
        tags.append(tags[0])

    tag1, tag2 = random.sample(tags, 2)
    template = random.choice(TEMPLATES)
    text = template.format(
        title=args.title or "this artwork",
        artist=args.artist or "the artist",
        tag1=tag1,
        tag2=tag2,
    )

    print(json.dumps({"text": text}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
