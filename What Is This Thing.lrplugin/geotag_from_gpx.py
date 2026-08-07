#!/usr/bin/env python3
"""Computes GPS coordinates for photos from a GPX track using exiftool,
WITHOUT writing to the photos themselves.

Called by the "What is this Thing?" Lightroom plugin's "Update Location
from GPX" command, but fully usable and testable standalone:

  python3 geotag_from_gpx.py [--gpx track.gpx] PHOTO [PHOTO ...]

If --gpx is omitted, the most recently modified file in ~/Downloads whose
name contains ".gpx" anywhere (not just as a strict extension -- some
apps' repeat exports get a macOS/AirDrop de-dupe suffix appended after the
extension, like "track.gpx 2", which a strict extension check would miss)
is used automatically.

Each real photo's own DateTimeOriginal is read directly from the file
(same as before -- still requires the file to be reachable on disk for
this read-only step), but the actual geotag MATCH is computed against a
disposable, in-memory-sized proxy JPEG tagged with that same timestamp,
never against the real file. The real file is never written to by this
script at all -- exiftool's own "-geotag" feature is inherently a write
operation, so this sidesteps it while still reusing its exact, proven
interpolation/tolerance logic (rather than reimplementing GPX parsing
from scratch, which risks subtly deviating from exiftool's own behavior).
The caller (UpdateLocationFromGpx.lua) applies the computed coordinates
itself via Lightroom's own catalog (photo:setRawMetadata("gps", ...)),
so Lightroom's own catalog-to-file flush becomes the ONLY thing that ever
writes GPS into the real file -- eliminating a real dual-writer race that
existed when this script wrote directly (see DEVELOPMENT_NOTES.md).

Prints a single JSON object to stdout:
  {"gpxPath": "...", "results": [
      {"path": "...", "latitude": .., "longitude": ..},
      {"path": "...", "matched": false, "reason": "..."},
      ...
  ]}
or, on a failure that prevented running at all (exiftool not found, no
GPX file found/given): {"error": "..."}. Exits non-zero in that case;
zero otherwise (an individual photo not matching the track is reported
per-photo in `results`, not a script-level failure).
"""
import argparse
import base64
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# The D7200 is fixed to New York time zone with Daylight Saving Time
# permanently off (a deliberate choice, so its clock always represents a
# constant UTC-5 year-round and regardless of travel) -- this correction
# never needs to change per shoot. If the camera setting is ever changed,
# this constant needs to change with it.
CAMERA_UTC_OFFSET = "-05:00"

# A minimal, valid 1x1 white JPEG -- the proxy files this script tags and
# geotags are throwaway, so a real photo file is never needed as a
# template. Hardcoded rather than shelling out to sips/PIL so this script
# has no dependency beyond exiftool and the standard library, matching
# its own stated goal of being runnable standalone from a terminal.
_PROXY_JPEG_BYTES = base64.b64decode(
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkI"
    "CQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/wAALCAABAAEBAREA/8QAFAABAAAAAAAA"
    "AAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q=="
)


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


def fail(message):
    print(json.dumps({"error": message}))
    sys.exit(1)


def read_capture_times(exiftool, photos):
    """Returns {photo_path: "YYYY:MM:DD HH:MM:SS" or None} -- read
    directly from each real file's own DateTimeOriginal tag, unchanged
    from this script's original behavior. A missing/unreadable tag maps
    to None rather than raising, so one bad file doesn't abort the batch.
    """
    result = {p: None for p in photos}
    proc = subprocess.run(
        [exiftool, "-j", "-DateTimeOriginal"] + photos,
        capture_output=True, text=True,
    )
    try:
        entries = json.loads(proc.stdout)
    except ValueError:
        return result
    for entry in entries:
        source = entry.get("SourceFile")
        value = entry.get("DateTimeOriginal")
        if source in result and value:
            result[source] = value
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gpx", help="Path to the GPX track file")
    parser.add_argument("photos", nargs="+", help="Photo file paths to compute GPS for")
    args = parser.parse_args()

    exiftool = find_exiftool()
    if not exiftool:
        fail("exiftool not found (checked PATH, /opt/homebrew/bin, /usr/local/bin)")

    gpx_path = args.gpx
    if not gpx_path:
        downloads_dir = os.path.join(os.path.expanduser("~"), "Downloads")
        gpx_path = find_most_recent_gpx(downloads_dir)
        if not gpx_path:
            fail(f"No .gpx file found in {downloads_dir}")

    capture_times = read_capture_times(exiftool, args.photos)

    results = []
    no_time_paths = [p for p in args.photos if not capture_times[p]]
    for p in no_time_paths:
        results.append({"path": p, "matched": False, "reason": "no capture date found in file"})

    timed_paths = [p for p in args.photos if capture_times[p]]
    if not timed_paths:
        print(json.dumps({"gpxPath": gpx_path, "results": results}))
        return

    with tempfile.TemporaryDirectory(prefix="whatisthisthing-geotag-") as proxy_dir:
        proxy_for_path = {}
        argfile_lines = []
        for i, p in enumerate(timed_paths):
            proxy_path = os.path.join(proxy_dir, f"proxy_{i}.jpg")
            with open(proxy_path, "wb") as f:
                f.write(_PROXY_JPEG_BYTES)
            proxy_for_path[proxy_path] = p
            # exiftool's -@ argfile lets each file in one batched
            # invocation get its OWN distinct tag value -- preserves the
            # single-exiftool-call efficiency this script already relied
            # on, rather than one process spawn per photo. -execute is
            # required between each file's own block: confirmed live that
            # WITHOUT it, exiftool doesn't scope a -DateTimeOriginal=
            # value to just the file listed right after it -- the LAST
            # value in the whole argfile silently wins for every file
            # (caught here by a live test: two photos with different
            # timestamps both ended up tagged with the second one).
            # -execute makes each block behave like its own separate
            # invocation.
            argfile_lines.append(f"-DateTimeOriginal={capture_times[p]}")
            argfile_lines.append(proxy_path)
            argfile_lines.append("-execute")
        argfile_path = os.path.join(proxy_dir, "tag_args.txt")
        with open(argfile_path, "w") as f:
            f.write("\n".join(argfile_lines) + "\n")
        subprocess.run(
            [exiftool, "-overwrite_original", "-@", argfile_path],
            capture_output=True, text=True,
        )

        proxy_paths = list(proxy_for_path.keys())
        geotag_proc = subprocess.run(
            [
                exiftool, "-overwrite_original", "-geotag", gpx_path,
                f"-geotime<${{DateTimeOriginal}}{CAMERA_UTC_OFFSET}",
            ] + proxy_paths,
            capture_output=True, text=True,
        )
        geotag_output = geotag_proc.stdout + geotag_proc.stderr

        too_far_proxies = set(re.findall(
            r"Warning: Time is too far beyond track in File:Geotime \(ValueConvInv\) - (.+)", geotag_output
        ))

        readback_proc = subprocess.run(
            [exiftool, "-j", "-GPSLatitude", "-GPSLongitude", "-n"] + proxy_paths,
            capture_output=True, text=True,
        )
        try:
            readback_entries = {e["SourceFile"]: e for e in json.loads(readback_proc.stdout)}
        except ValueError:
            readback_entries = {}

        for proxy_path, original_path in proxy_for_path.items():
            entry = readback_entries.get(proxy_path, {})
            lat = entry.get("GPSLatitude")
            lon = entry.get("GPSLongitude")
            if lat is not None and lon is not None:
                results.append({"path": original_path, "latitude": lat, "longitude": lon})
            elif proxy_path in too_far_proxies:
                results.append({
                    "path": original_path, "matched": False,
                    "reason": "outside the GPX track's time range",
                })
            else:
                results.append({
                    "path": original_path, "matched": False,
                    "reason": "no matching GPS track data found",
                })

    print(json.dumps({"gpxPath": gpx_path, "results": results}))


if __name__ == "__main__":
    main()
