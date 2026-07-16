#!/usr/bin/env python3
"""Geotags photos from a GPX track using exiftool.

Called by the "What is this Thing?" Lightroom plugin's "Update Location
from GPX" command, but fully usable and testable standalone:

  python3 geotag_from_gpx.py [--gpx track.gpx] PHOTO [PHOTO ...]

If --gpx is omitted, the most recently modified file in ~/Downloads whose
name contains ".gpx" anywhere (not just as a strict extension -- some
apps' repeat exports get a macOS/AirDrop de-dupe suffix appended after the
extension, like "track.gpx 2", which a strict extension check would miss)
is used automatically.

Prints a plain-text summary to stdout; the calling plugin just displays
whatever this prints. Exits non-zero on any failure that prevented
producing a summary at all (exiftool not found, no GPX file found/given).
"""
import argparse
import glob
import os
import re
import shutil
import subprocess
import sys

# The D7200 is fixed to New York time zone with Daylight Saving Time
# permanently off (a deliberate choice, so its clock always represents a
# constant UTC-5 year-round and regardless of travel) -- this correction
# never needs to change per shoot. If the camera setting is ever changed,
# this constant needs to change with it.
CAMERA_UTC_OFFSET = "-05:00"


def find_exiftool():
    path = shutil.which("exiftool")
    if path:
        return path
    # GUI apps (like Lightroom) that spawn subprocesses often don't
    # inherit an interactive shell's PATH, so Homebrew's install
    # location (not on that PATH) needs an explicit fallback check.
    for candidate in ("/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool"):
        if os.path.isfile(candidate):
            return candidate
    return None


def find_most_recent_gpx(downloads_dir):
    candidates = [
        p for p in glob.glob(os.path.join(downloads_dir, "*"))
        if ".gpx" in os.path.basename(p).lower() and os.path.isfile(p)
    ]
    if not candidates:
        return None
    return max(candidates, key=os.path.getmtime)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gpx", help="Path to the GPX track file")
    parser.add_argument("photos", nargs="+", help="Photo file paths to geotag")
    args = parser.parse_args()

    exiftool = find_exiftool()
    if not exiftool:
        print("exiftool not found (checked PATH, /opt/homebrew/bin, /usr/local/bin)", file=sys.stderr)
        sys.exit(1)

    gpx_path = args.gpx
    if not gpx_path:
        downloads_dir = os.path.join(os.path.expanduser("~"), "Downloads")
        gpx_path = find_most_recent_gpx(downloads_dir)
        if not gpx_path:
            print(f"No .gpx file found in {downloads_dir}", file=sys.stderr)
            sys.exit(1)

    print(f"Using GPX track: {gpx_path}")

    cmd = [
        exiftool,
        "-geotag", gpx_path,
        f"-geotime<${{DateTimeOriginal}}{CAMERA_UTC_OFFSET}",
    ] + args.photos

    result = subprocess.run(cmd, capture_output=True, text=True)
    output = result.stdout + result.stderr

    updated_match = re.search(r"(\d+) image files updated", output)
    unchanged_match = re.search(r"(\d+) image files unchanged", output)

    if not updated_match and not unchanged_match:
        print("Couldn't parse exiftool's output. Raw output:")
        print(output)
        sys.exit(1)

    updated = int(updated_match.group(1)) if updated_match else 0
    unchanged = int(unchanged_match.group(1)) if unchanged_match else 0
    skipped = len(re.findall(r"Warning: Time is too far", output))

    print(f"Updated: {updated} file(s)")
    print(f"Unchanged: {unchanged} file(s)")
    if skipped > 0:
        print(f"({skipped} file(s) had no matching GPS track data -- outside the track's time range)")


if __name__ == "__main__":
    main()
