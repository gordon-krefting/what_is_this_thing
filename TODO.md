# Project TODO

The single canonical todo list for this project. When asked to save
something as a todo, it goes here. When asked "what's on the todo list,"
this file is the answer -- not memory, not conversation history.

Completed items are deleted, not checked off -- `git log`/`DEVELOPMENT_NOTES.md`
already have the history of what shipped and when.

- Reorganize plugin data files + verify/ensure backup coverage --
  everything currently dumps into one folder
  (`~/Photos/local/WhatIsThisThing/`): 2 unbounded logs
  (`inat-sync-log.txt` 676KB, `inat-sync-claim-trace.log` 302KB, both
  actively growing), 2 orphaned files nobody writes anymore
  (`inat-recovery-log.txt`, `inat-sync-mismatches.html` -- confirmed no
  code references either, safe to just delete), 2 regeneratable reports
  (`inat-sync-needs-attention.html`, `observation-report.html`), and 1
  piece of real master data (`taxon-data.lua`, TaxonStore.lua's cache of
  iNat taxon facts -- expensive to rebuild, not something to lose).
  Mixing disposable/regeneratable/master data in one location is the
  actual problem -- makes it hard to apply a sensible backup policy per
  category. Plan:
  - Consolidate the 2 active logs into a single log file -- and check
    whether `inat-sync-claim-trace.log` (`logClaim` in `INatSync.lua`)
    is even still needed at all, not just worth merging: it was built to
    diagnose a cross-species "already claimed" bug that the species-first
    sync redesign (2026-07-31) may have already fixed structurally.
  - Prefer writing to that log over showing a dialog full of data, where
    reasonable (fewer interruptions for diagnostic-only info).
  - Split logs (disposable) / reports (regeneratable) / taxon-data.lua
    (master, must be backed up) into distinct locations so each can have
    its own retention/backup treatment instead of living together by
    accident.
  - Delete the 2 confirmed-orphaned files.
  - `taxon-data.lua`'s current location was deliberately chosen (per
    TaxonStore.lua's own comment) because `manage_photo_backups.rb`'s
    `LOCAL_SOURCE` already sweeps `~/Photos/local/` wholesale -- verify
    live that it's actually landing on the NAS/Backblaze, not just
    assumed covered, before restructuring anything (a relocation that
    isn't itself re-verified against the backup script could
    accidentally make coverage worse, not better).
  - Related, not yet decided: whether `manage_photo_backups.rb` itself
    (currently in `~/bin`, its own separate thing) gets folded into this
    repo as part of a broader single-repo photo-management consolidation
    -- see the PlantBook discussion.
- Add a way to refresh iNat taxonomy for local-only observations (never
  uploaded to iNat)
- Design an iPhone -> Lightroom workflow for all photos (not just iNat
  observations)
- Show local + iNat observation counts for the selected species (deferred
  to the ID-process redo)
- Design a report with info about local observations (spec TBD)
- Graceful degradation when the external archive drive isn't mounted
- Write GPS accuracy into exported photos for approximate locations --
  iNat's importer reads the EXIF `GPSHPositioningError` tag straight into
  the observation's `positional_accuracy` (confirmed directly from
  iNaturalist's own source, `LocalPhoto#to_observation` in
  `app/models/local_photo.rb`). `ExportForINaturalist.lua` already
  controls exactly what EXIF goes into the uploaded JPEG -- it could set
  a real uncertainty radius (e.g. ~5000m) whenever the photo's
  `approximateLocation` flag is set (GpsPrompt.lua's Home/Recent/Nearest
  Before-After/typed-coordinate flows), so iNat's own accuracy circle
  reflects the guess instead of presenting a hand-typed location as
  precise. Not urgent for old photos -- the user is already handling
  those manually by marking the iNat observation itself as obscured,
  which works well -- but worth having going forward for new uploads.
  Confirmed at the same time: `captive_cultivated` and organism sex have
  no EXIF/XMP hook in iNat's importer at all -- not achievable this way.
- Maybe pull the "Sex" annotation from iNat back into a local field during
  Sync -- user is NOT convinced this is actually valuable, parked mainly
  so the research isn't lost. Each observation's `annotations` array has
  `controlled_attribute_id`/`controlled_value_id` pairs (Sex is attribute
  id 9; values 10=Female, 11=Male, 20=Cannot Be Determined -- confirmed
  live against iNat's own `/v1/controlled_terms` endpoint). Same shape as
  the already-pulled `iNatQualityGrade`/`iNatSuggestedId` fields in
  INatSync.lua. Caveat: annotations are community-editable, not exclusive
  to the observer, same as identifications.
