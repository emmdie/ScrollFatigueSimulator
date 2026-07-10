#!/usr/bin/env python3
"""Mock print job.

CLI contract (design doc §5): --text [--image <path>] -> exit 0 on success.
Swap for the real thermal-pocket-printer call for production (§7 step 7):
https://github.com/ChiaraCannolee/thermal-pocket-printer
"""
import argparse
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--text", default="")
    parser.add_argument("--image", default="")
    args = parser.parse_args()

    time.sleep(1.5)  # stand-in for real print duration
    print(f"[mock print] {args.text}", file=sys.stderr)
    if args.image:
        print(f"[mock print] with image: {args.image}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
