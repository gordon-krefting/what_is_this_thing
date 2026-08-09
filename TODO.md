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
  - Design this WITH PlantBook's own file types in mind, not just What Is
    This Thing's current ones (2026-08-09, per the user -- wants
    consistency across both rather than solving this narrowly then
    redoing it once PlantBook folds in). PlantBook writes its own kind of
    generatable HTML output too (`public_html/`, the published plant-
    guide site, analogous to but distinct from this project's own
    `observation-report.html`/`inat-sync-needs-attention.html`), plus its
    own logging -- confirmed live (2026-08-09) that PlantBook's plugin
    actually uses Lightroom's own `LrLogger` facility (writes to the SDK-
    standard `~/Documents/LrClassicLogs/PlantBookPlugin.log`), NOT a
    hand-rolled `io.open` file log like this project's `inat-sync-log.txt`
    -- a real mechanism difference, not just a location one, to reconcile
    before settling on one approach.
- Fold PlantBook into this project (2026-08-09, per the user -- leaning
  toward dropping the PlantBook plugin entirely, rebuilding its
  functionality here, single repo/single LRC plugin for all personal
  photo-management code, since they're the only user and the two-plugin
  overhead isn't earning its keep). Real scope, not a quick copy job --
  see the full discussion for details, summarized:
  - Data migration: PlantBook's custom metadata lives under a different
    toolkit id (`org.krefting.plant-book` vs
    `org.krefting.whatisthisthing`) -- a one-time script (same throwaway-
    migration-tool pattern as `BackfillTaxonId.lua`) needs to read each
    photo's `org.krefting.plant-book.*` properties and rewrite them as
    `org.krefting.whatisthisthing.*`.
  - Schema alignment found so far: `plantType` (PlantBook, already a
    real enum) vs `growthHabit` (this project, string, has its own open
    "convert to enum" history) are the same concept -- PlantBook's enum
    is the more useful starting point. `nativity` (PlantBook, hand-set
    enum) vs `establishmentMeans` (this project, auto-pulled from iNat)
    are the same concept sourced differently -- needs a decision on which
    model wins. `notes` is the same field name in both but different
    *mechanism*: this project enforces species-level consistency
    proactively via `TaxonStore.lua` (one edit fans out to every photo of
    that species); PlantBook allows per-photo divergence and reconciles/
    flags conflicts reactively at site-build time in `book_formatter.py`
    -- worth deciding which model to keep. `idConfidence` is a NAME
    collision, not a real overlap -- PlantBook's is a hand-set subjective
    enum (?/??/???), this project's is a computed percentage string --
    don't conflate them. PlantBook has no `cultivar` field at all despite
    being garden-focused; this project already does.
  - `PublishServiceProvider.lua` is a Lightroom *publish service*
    (`LrExportServiceProvider`) -- a bigger, different SDK surface than
    anything this plugin currently registers (just export-menu
    commands) -- porting the "export changed photos + thumbnails + dump
    JSON + shell out to the site generator" flow is real new scope.
  - `book_formatter/` is a separate Python/Poetry app (reads
    `PhotoBook.json`, renders Jinja2, rsyncs to the remote host) --
    needs a decision on where it lives structurally in a merged repo.
  - krefting.org/plantguide is a live site -- needs a cutover sequence
    that doesn't take it down mid-migration, not a rewrite-and-hope.
  - See also the file-locations item above -- do this with PlantBook's
    own logging/HTML-output patterns in mind, not just this project's.
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
