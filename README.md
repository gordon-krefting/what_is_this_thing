# What is this Thing?

A Lightroom Classic plugin for identifying plants and animals in nature
photography, using [Pl@ntNet](https://plantnet.org) and
[iNaturalist](https://www.inaturalist.org)'s computer-vision APIs -- without
leaving Lightroom. Built for a personal yard-photography workflow: shoot a
few angles of an organism, get a species guess, tag it, and later export a
clean batch for upload to iNaturalist.

It's pretty specific to me and my own workflows. Probably won't really work 
for you, but have a look if you think it would be interesting.

Also, I let Claude Code write pretty much the whole thing. I have to admit,
I don't know Lua very well, and the Lightroom SDK docs are a little
idiosyncratic. Claude made this go much faster!

## Features

- **iNaturalist Identification / Pl@ntNet Identification** (formerly "What is
  This Animal? / What is This Plant?") -- select up to 4 photos of the same
  subject (different angles/organs help), and the plugin exports temporary
  JPEGs, sends them to iNaturalist or Pl@ntNet, and shows a candidate picker:
  scientific + common name, confidence score, taxonomic rank, reference links
  (iNat / Pl@ntNet / Wikipedia), and how many photos you've already tagged
  with that same identification. Below an 85% confidence threshold, a
  broader match (genus/family) is preselected instead of guessing a
  low-confidence species. A "Find Common Ancestor" button will compute the
  lowest common ancestor across several scattered low-confidence candidates,
  for when the API is confident about the general kind of thing but not the
  exact species. An "Also try [other service]" button re-runs the same
  photos against the other API and shows both services' results side by
  side, in case one does better than the other for a given subject. If
  neither API finds a match -- or you know better -- there's a manual
  scientific-name entry option that still resolves the full taxonomic
  ancestry.
- **Shared taxonomy tree**: both commands file their keyword under the same
  iNaturalist-based taxonomy (kingdom > class > order > family > genus >
  species -- kingdom only shown for Plantae/Fungi, since it's always the
  same value for animals), nested under a "Species ID" root, so plant and
  animal identifications live in one consistent tree in Lightroom's Keyword
  List panel. Title is set to the bare scientific name; Caption and the leaf
  keyword show "Common Name (Scientific Name)".
- **Custom metadata fields**: each identification also writes structured,
  searchable/browsable Lightroom metadata -- Scientific Name, Common Name,
  Taxon Rank, ID Confidence, and a locally-generated Observation ID shared by
  every photo identified together in one batch (so a later correction can
  find the whole group again without reselecting it by hand). These show up
  in the Metadata panel and can be filtered on via the Library Filter bar or
  Smart Collections.
- **Taxon-level reference data**: the plugin also maintains a small local
  cache of per-species facts pulled from iNaturalist -- Conservation Status,
  Establishment Means (native/introduced, gated to a fixed home region),
  and a Wikipedia link -- plus a manually-maintained Growth Habit and free-
  text Notes field, editable via **Edit Taxon Info**. These apply to every
  photo of that species, not just one batch.
- **Set Cultivar**: a small manual command for noting a cultivar name (e.g.
  "Symphyotrichum oblongifolium 'October Skies'") on purchased/planted
  specimens -- no API tracks this, so it's entirely user-entered. Applies to
  every photo sharing the same Observation ID as the current selection.
- **GPS pre-flight gate**: if a photo has no location data, you're prompted
  to use a saved "home" location, type coordinates directly, or abort --
  before any identification runs, since both APIs (and iNaturalist's
  uploader) benefit from having it. Coordinate entry accepts plain decimal
  degrees as well as degrees/minutes/seconds format (including the way
  iPhones format them, e.g. `49°19'27.35" S 72°53'35.59" W`).
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
- The custom metadata fields and taxon-level reference data are only written
  when a photo is (re-)identified -- there's no backfill for photos that
  were already identified before these fields existed.
