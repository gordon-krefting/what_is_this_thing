#!/usr/bin/env python3
"""Identify a plant in a photo using the Pl@ntNet API.

Setup:
  1. Log into https://my.plantnet.org
  2. Grab your API key from https://my.plantnet.org/account (API access tab)
  3. export PLANTNET_API_KEY="<paste key here>"

Usage:
  python3 identify_plants.py path/to/photo.jpg [organ]

  organ is one of: leaf, flower, fruit, bark (default: leaf)
"""
import getpass
import os
import sys

import requests

API_URL = "https://my-api.plantnet.org/v2/identify/all"


def prompt_for_key() -> str:
    print("Get your API key from https://my.plantnet.org/account (API access tab)")
    return getpass.getpass("Pl@ntNet API key: ").strip()


def identify(image_path: str, api_key: str, organ: str = "leaf", top_n: int = 5) -> None:
    with open(image_path, "rb") as f:
        response = requests.post(
            API_URL,
            params={"api-key": api_key},
            files={"images": f},
            data={"organs": organ},
        )

    if response.status_code in (401, 403):
        print(f"API key missing or invalid ({response.status_code}).")
        api_key = prompt_for_key()
        if not api_key:
            sys.exit("No API key provided.")
        with open(image_path, "rb") as f:
            response = requests.post(
                API_URL,
                params={"api-key": api_key},
                files={"images": f},
                data={"organs": organ},
            )

    if response.ok:
        os.environ["PLANTNET_API_KEY"] = api_key

    response.raise_for_status()
    results = response.json().get("results", [])

    if not results:
        print("No matches found.")
        return

    print(f"Top {min(top_n, len(results))} matches for {image_path}:\n")
    for r in results[:top_n]:
        species = r["species"]
        common_names = species.get("common_names") or species.get("commonNames") or []
        common = common_names[0] if common_names else ""
        name = species.get("scientificNameWithoutAuthor", "unknown")
        score = r.get("score", 0) * 100
        label = f"{common} ({name})" if common else name
        print(f"  {score:5.1f}%  {label}")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(f"Usage: {sys.argv[0]} <image_path> [organ]")

    organ = sys.argv[2] if len(sys.argv) == 3 else "leaf"

    api_key = os.environ.get("PLANTNET_API_KEY")
    if not api_key:
        api_key = prompt_for_key()
        if not api_key:
            sys.exit("No API key provided.")

    identify(sys.argv[1], api_key, organ)
