# Project TODO

The single canonical todo list for this project. When asked to save
something as a todo, it goes here. When asked "what's on the todo list,"
this file is the answer -- not memory, not conversation history.

Completed items are deleted, not checked off -- `git log`/`DEVELOPMENT_NOTES.md`
already have the history of what shipped and when.

- Bound unbounded log growth (`inat-sync-log.txt`,
  `inat-sync-claim-trace.log`, `inat-recovery-log.txt`)
- Add a way to refresh iNat taxonomy for local-only observations (never
  uploaded to iNat)
- Design an iPhone -> Lightroom workflow for all photos (not just iNat
  observations)
- Show local + iNat observation counts for the selected species (deferred
  to the ID-process redo)
- Design a report with info about local observations (spec TBD)
- Graceful degradation when the external archive drive isn't mounted
- Trim the one-off diagnostics (e.g. `logClaim`/`inat-sync-claim-trace.log`,
  no longer needed since the species-first sync redesign)
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
