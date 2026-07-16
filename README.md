# What is this Thing?

A Lightroom Classic plugin for identifying plants and animals in nature
photography, using [Pl@ntNet](https://plantnet.org) and
[iNaturalist](https://www.inaturalist.org)'s computer-vision APIs -- without
leaving Lightroom. Built for a personal yard-photography workflow: shoot a
few angles of an organism, get a species guess, tag it, and later export a
clean batch for upload to iNaturalist.

It's pretty specific to me and my own workflows. Probably won't really work 
for, but have a look if you think it would be interesting.

Also, I let Claude Code write pretty much the whole thing. I have to admit,
I don't know Lua very well, and the Lightroom SDK docs are a little
idiosyncratic. Claude made this go much faster!

## Features

- **What is This Plant? / What is This Animal?** -- select up to 4 photos of
  the same subject (different angles/organs help), and the plugin exports
  temporary JPEGs, sends them to Pl@ntNet or iNaturalist, and shows a
  candidate picker: scientific + common name, confidence score, taxonomic
  rank, reference links (iNat / Pl@ntNet / Wikipedia), and how many photos
  you've already tagged with that same identification. Below an 85%
  confidence threshold, a broader match (genus/family) is preselected instead
  of guessing a low-confidence species. If neither API finds a match -- or
  you know better -- there's a manual scientific-name entry option that still
  resolves the full taxonomic ancestry.
- **Shared taxonomy tree**: both commands file their keyword under the same
  iNaturalist-based taxonomy (class > order > family > genus > species),
  nested under a "Species ID" root, so plant and animal identifications live
  in one consistent tree in Lightroom's Keyword List panel. Title is set to
  the bare scientific name; Caption and the leaf keyword show
  "Common Name (Scientific Name)".
- **GPS pre-flight gate**: if a photo has no location data, you're prompted
  to use a saved "home" location, type coordinates directly, or abort --
  before any identification runs, since both APIs (and iNaturalist's
  uploader) benefit from having it.
- **Export for iNaturalist**: exports already-identified photos with
  Keywords removed entirely and Caption blanked (Title is left as the
  species guess). This exists because iNaturalist turns whatever Keyword you
  send into a permanent, uncorrectable "Tag" on the observation -- if an
  expert later corrects the taxon ID, the stale tag doesn't get cleaned up
  with it. If some selected photos haven't been identified yet, you're
  warned but can export anyway.
- **Update Location from GPX**: geotags photos (e.g. from a camera with no
  built-in GPS) against a GPX breadcrumb track recorded on a phone, by
  shelling out to `exiftool`. Operates on the current filmstrip/selection.

## Requirements

- Lightroom Classic (uses the Lua-based Lightroom Classic SDK, `LrSdkVersion
  6.0`).
- A free [Pl@ntNet API key](https://my.plantnet.org/) (for plant ID) and/or
  an [iNaturalist account](https://www.inaturalist.org/users/api_token) (for
  animal ID and shared taxonomy lookups). You'll be prompted for these the
  first time you need them; they're stored via Lightroom's plugin
  preferences. The iNaturalist token expires after 24 hours and you'll be
  re-prompted automatically.
- [`exiftool`](https://exiftool.org/) installed (e.g. via Homebrew), only
  needed for "Update Location from GPX".
- Python 3 (macOS's built-in `/usr/bin/python3` is used explicitly), only
  needed for "Update Location from GPX".

## Installation

1. In Lightroom Classic, go to **File > Plug-in Manager**.
2. Click **Add**, and select the `What Is This Thing.lrplugin` folder from
   this repo.
3. The commands appear under **File > Plug-in Extras**.

## Repo layout

- `What Is This Thing.lrplugin/` -- the plugin itself.
- `demo/` -- standalone CLI scripts (`identify_plants.py`,
  `identify_animals.py`) the plugin's API integrations grew out of; useful
  for testing API behavior directly without Lightroom.
- `sample_images/` -- test images for the demo scripts.
- `tests/` -- a small persisted test for `JSON.lua` (the plugin's hand-rolled
  JSON decoder, since Lightroom's Lua has no built-in JSON support). Most
  other verification is done ad hoc against mock Lightroom objects during
  development rather than kept as a formal suite, since there's no real
  Lightroom SDK test runtime to run a mock-based suite against.

## Known limitations

- Pl@ntNet's species-page links can occasionally 404 if a species has been
  taxonomically reclassified more recently on their API than on their
  website.
- After "Update Location from GPX" writes GPS data directly to a the image files with
  `exiftool`, Lightroom's own metadata cache doesn't refresh automatically --
  select the affected photos and run **Metadata > Read Metadata from
  Files** afterward.
