#!/usr/bin/env python3
"""you.com Express agent horoscope generator.

CLI contract (design doc §5): --title --artist --date --tags (comma-joined)
-> stdout JSON {"text": "..."} and exit 0. On failure: exit 1, nothing on
stdout, reason on stderr — ExternalBridge then uses a canned fallback line.

API key: external/secrets/you_api_key (single line) or $YOU_API_KEY.
Stdlib only — runs on the kiosk's system python3, no venv required.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

API_URL = "https://api.you.com/v1/agents/runs"
HTTP_TIMEOUT_SEC = 9  # stays under ExternalBridge's 12s timeout
# api.you.com sits behind Cloudflare, whose browser integrity check 403s
# (body: "error code: 1010") anything whose UA starts with "Python-urllib" —
# urllib's default. Any explicit UA gets through.
USER_AGENT = "ScrollFatigue/1.0"

PROMPT_TEMPLATE = (
    "You are a large language model that helps a viewer create a special "
    "connection to a given painting. The painting's title is {title} by "
    "{artist} and it has the attributes {tags}. Return a very brief and "
    "compact assessment of the viewer that decided to give their full "
    "attention to this painting, be funny, brief and playful. Only return "
    "this assessment, no filler text, fluff or otherwise."
)


def fail(message: str) -> int:
    print("[horoscope_api] %s" % message, file=sys.stderr)
    return 1


def load_api_key() -> str:
    key = os.environ.get("YOU_API_KEY", "").strip()
    if key:
        return key
    path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "secrets", "you_api_key"
    )
    try:
        with open(path, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def extract_answer(data: dict) -> str:
    """Express returns several output items; the prose lives in the
    'message.answer' one. web_search.results items carry no 'text'."""
    items = data.get("output", [])
    for item in items:
        if isinstance(item, dict) and item.get("type") == "message.answer":
            return str(item.get("text", "")).strip()
    for item in items:
        if isinstance(item, dict) and item.get("text"):
            return str(item["text"]).strip()
    return ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", default="")
    parser.add_argument("--artist", default="")
    parser.add_argument("--date", default="")  # accepted per contract, unused in prompt
    parser.add_argument("--tags", default="")
    parser.add_argument("--debug", action="store_true", help="dump request/response to stderr")
    args = parser.parse_args()

    api_key = load_api_key()
    if not api_key:
        return fail("no API key — set $YOU_API_KEY or write external/secrets/you_api_key")

    tags = ", ".join(t.strip() for t in args.tags.split(",") if t.strip()) or "mystery"
    prompt = PROMPT_TEMPLATE.format(
        title=args.title or "this artwork",
        artist=args.artist or "an unknown artist",
        tags=tags,
    )

    # "stream" is a REQUIRED field (422 without it). No "tools" key, so the
    # agent answers from the LLM alone — no web search, lowest latency.
    payload = {"agent": "express", "input": prompt, "stream": False}
    if args.debug:
        print("[horoscope_api] prompt: %s" % prompt, file=sys.stderr)

    request = urllib.request.Request(
        API_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            # Agents document Bearer; search/billing document X-API-Key.
            # Sending both makes this immune to that inconsistency.
            "Authorization": "Bearer %s" % api_key,
            "X-API-Key": api_key,
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SEC) as response:
            raw = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:500]
        hint = ""
        if "1010" in body:
            hint = " (Cloudflare blocked the client signature — check USER_AGENT)"
        elif e.code in (401, 403):
            hint = " (bad/expired key? verify with the account_balance endpoint)"
        return fail("HTTP %s %s: %s%s" % (e.code, e.reason, body, hint))
    except Exception as e:
        return fail("request failed: %s: %s" % (type(e).__name__, e))

    if args.debug:
        print("[horoscope_api] raw response: %s" % raw[:2000], file=sys.stderr)

    try:
        data = json.loads(raw)
    except ValueError:
        return fail("response was not JSON: %s" % raw[:300])

    text = extract_answer(data)
    if not text:
        return fail("no answer text in response: %s" % raw[:300])

    # Sole stdout output on success — nothing else may be printed here.
    print(json.dumps({"text": text}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
