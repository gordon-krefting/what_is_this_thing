#!/usr/bin/env python3
"""Identify plants/animals in a photo using the iNaturalist computer vision API.

Setup:
  1. Log into https://www.inaturalist.org
  2. Grab your token from https://www.inaturalist.org/users/api_token
  3. export INATURALIST_TOKEN="<paste token here>"   (expires after 24h)

Usage:
  python3 identify_animals.py path/to/photo.jpg
"""
import getpass
import os
import sys

import requests

API_URL = "https://api.inaturalist.org/v1/computervision/score_image"


def prompt_for_token() -> str:
    print("Get your token from https://www.inaturalist.org/users/api_token")
    return getpass.getpass("INaturalist API token: ").strip()


def identify(image_path: str, token: str, top_n: int = 5) -> None:
    with open(image_path, "rb") as f:
        response = requests.post(
            API_URL,
            headers={"Authorization": token},
            files={"image": f},
        )

    if response.status_code == 401:
        print("Token missing or invalid (401 Unauthorized).")
        token = prompt_for_token()
        if not token:
            sys.exit("No token provided.")
        with open(image_path, "rb") as f:
            response = requests.post(
                API_URL,
                headers={"Authorization": token},
                files={"image": f},
            )

    if response.ok:
        os.environ["INATURALIST_TOKEN"] = token

    response.raise_for_status()
    results = response.json().get("results", [])

    if not results:
        print("No matches found.")
        return

    print(f"Top {min(top_n, len(results))} matches for {image_path}:\n")
    for r in results[:top_n]:
        taxon = r["taxon"]
        common = taxon.get("preferred_common_name", "")
        name = taxon.get("name", "unknown")
        score = r.get("combined_score", 0)
        label = f"{common} ({name})" if common else name
        print(f"  {score:5.1f}%  {label}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"Usage: {sys.argv[0]} <image_path>")

    token = os.environ.get("INATURALIST_TOKEN")
    if not token:
        token = prompt_for_token()
        if not token:
            sys.exit("No token provided.")

    identify(sys.argv[1], token)
