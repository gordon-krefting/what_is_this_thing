# Project TODO

The single canonical todo list for this project. When asked to save
something as a todo, it goes here. When asked "what's on the todo list,"
this file is the answer -- not memory, not conversation history.

Completed items are deleted, not checked off -- `git log`/`DEVELOPMENT_NOTES.md`
already have the history of what shipped and when.

- Reorganize plugin data files + verify/ensure backup coverage.
  Confirmed live (2026-08-09): `taxon-data.lua` IS already landing on the
  NAS/Backblaze as intended -- but so are the logs and HTML reports,
  since everything currently dumps into one swept folder
  (`~/Photos/local/WhatIsThisThing/`) with no way for the backup script
  to tell them apart. Current contents: 2 unbounded logs
  (`inat-sync-log.txt` 676KB, `inat-sync-claim-trace.log` 302KB, both
  actively growing), 2 orphaned files nobody writes anymore
  (`inat-recovery-log.txt`, `inat-sync-mismatches.html` -- confirmed no
  code references either, safe to just delete), 2 HTML reports
  (`inat-sync-needs-attention.html`, `observation-report.html`), and
  `taxon-data.lua` itself (TaxonStore.lua's cache of iNat taxon facts --
  expensive to rebuild, not something to lose).

  Revised categories (2026-08-09, per the user):
  - **Reports are NOT disposable** -- reclassified after the user noted
    they might point a webserver at them eventually. Move to a NEW
    dedicated location, `~/Photos/output/reports` (2026-08-09, per the
    user) -- a 5th top-level `~/Photos/` category alongside the 4 already
    named in `manage_photo_backups.rb`'s own comment block (import/local/
    catalog/archive), for "generated output artifacts" specifically, kept
    separate from `~/Photos/local/` (which is about mastered PHOTO files,
    not app-generated data -- taxon-data.lua and reports were both a bit
    of a stretch living there). `taxon-data.lua` itself stays put in
    `~/Photos/local/WhatIsThisThing/` -- no reason to touch what's
    already confirmed working. Only the logs are genuinely throwaway/
    regenerable-by-rerunning.
  - Since `~/Photos/output/` is a brand new location, it isn't covered by
    any existing `manage_photo_backups.rb` source -- needs a new
    `OUTPUT_SOURCE`/`OUTPUT_BACKUP` pair (and menu option, or folded into
    "Backup Everything") added to the script, or reports silently stop
    being backed up at all despite being reclassified as worth keeping.
  - **"Single log" is only achievable per-runtime, not universally** --
    Python (PlantBook's `book_formatter/`, once folded in) can't call
    `LrLogger` at all, so it will always need its own separate log file
    (as it already has: `book_formatter/log/o.log`) no matter what the
    Lua plugin does. Consolidate to one log WITHIN the Lua plugin's own
    scope; don't try to force Python and Lua onto one shared file.
  - **Concurrent-write risk is low within the Lua plugin** -- LrTasks
    uses cooperative coroutines, not OS threads, so two async tasks can't
    execute at the literal same instant; a plain `f:write(...)` doesn't
    yield mid-call, so it completes atomically from the Lua VM's
    perspective. The real risk would be cross-process (Lua plugin +
    Python subprocess both writing the same physical file), which is one
    more reason to keep them as separate per-subsystem logs rather than
    force a shared one.
  - Plan: move ONLY the logs to Lightroom's own `LrLogger` facility
    (`~/Documents/LrClassicLogs/`, consistent with how PlantBook's plugin
    already does its own logging -- confirmed live it uses `LrLogger`,
    not a hand-rolled `io.open` file log) -- naturally outside any photo
    backup sweep since it's not under `~/Photos/` at all. Verify live
    that `LrLogger` itself handles concurrent calls safely before relying
    on it -- it's Adobe's own facility, presumably built for this, but
    not independently confirmed.
  - Consolidate `inat-sync-log.txt` + `inat-sync-claim-trace.log` into
    one `LrLogger`-based log -- and check whether the claim-trace log
    (`logClaim` in `INatSync.lua`) is even still needed at all, not just
    worth merging: it was built to diagnose a cross-species "already
    claimed" bug that the species-first sync redesign (2026-07-31) may
    have already fixed structurally.
  - Prefer writing to that log over showing a dialog full of data, where
    reasonable (fewer interruptions for diagnostic-only info).
  - Delete the 2 confirmed-orphaned files.
  - Related, not yet decided: whether `manage_photo_backups.rb` itself
    (currently in `~/bin`, its own separate thing) gets folded into this
    repo as part of a broader single-repo photo-management consolidation
    -- see the PlantBook discussion.
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
