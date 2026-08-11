# Project TODO

The single canonical todo list for this project. When asked to save
something as a todo, it goes here. When asked "what's on the todo list,"
this file is the answer -- not memory, not conversation history.

Completed items are deleted, not checked off -- `git log`/`DEVELOPMENT_NOTES.md`
already have the history of what shipped and when.

- Add a "Manage Observation" menu item/dialog consolidating per-observation
  actions that currently live as separate commands -- "Drop Photo" (remove
  a photo from its observation/group), "Set Cultivar", etc. Details TBD.
  Prompted (2026-08-09) by the Review iNat Links / Clear Identification
  work -- reviewing ~10 real bad links surfaced how many small,
  related per-observation operations are currently scattered across
  separate menu items (SplitObservation.lua, SetCultivar.lua,
  ClearIdentification.lua, SetINatObservation.lua) rather than one place.
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
  - Related, not yet decided: whether `manage_photo_backups.rb` itself
    (currently in `~/bin`, its own separate thing) gets folded into this
    repo as part of the same single-repo photo-management consolidation.
- Add a way to refresh iNat taxonomy for local-only observations (never
  uploaded to iNat)
- Design an iPhone -> Lightroom workflow for all photos (not just iNat
  observations)
- Show local + iNat observation counts for the selected species (deferred
  to the ID-process redo)
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
- Add a way to find observations with an unresponded community ID
  suggestion. `INatSync.lua`'s `describeUnrespondedSuggestion` already
  computes this per observation during Sync -- someone else's current
  identification disagrees with the owner's own latest one -- and stores
  the result on each photo as `iNatSuggestedId`, but it's currently only
  ever surfaced as a one-off "iNaturalist Data Changed" notice at the
  moment of that sync run (`INatSyncRunner.lua`'s `showFieldChangeNotice`)
  -- there's no way to come back later and find/select every photo
  currently carrying one. Likely the same `catalog:findPhotosWithProperty`
  + select pattern already used by `SelectPendingMetadataSave.lua`.
