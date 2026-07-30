# Development Notes

Running history of architecture decisions, bugs found (and fixed) via live
testing, and design discussions behind this plugin -- originally kept as
Claude Code's own session memory, moved here so it's versioned and backed up
along with the rest of the project instead of living only on one machine.

**Status as of 2026-07-14: functional and pushed to GitHub.** Public repo at
github.com/gordon-krefting/what_is_this_thing (main branch), committed
through "Add reference links (iNat, Pl@ntNet, Wikipedia) to candidate
picker rows". Started from standalone CLI scripts and grew into a real
plugin: `What Is This Thing.lrplugin/`.

## Plugin file map
- `Info.lua` -- registers two `LrExportMenuItems`: "What is This Plant?" →
  `WhatIsThisPlant.lua`, "What is This Animal?" → `WhatIsThisAnimal.lua`.
  Surfaces under File > Plug-in Extras.
- `PlantNet.lua` -- Pl@ntNet `identify/all` API, `detailed=true` for
  genus/family rollups, API key prompt+retry, stored via `LrPrefs`.
- `INaturalist.lua` -- iNaturalist `score_image` (per-photo, merged across
  multiple photos), plus taxonomy helpers (`getMajorAncestry`,
  `getMajorAncestryByName`) used by *both* plugins. Token prompt+retry via
  `LrPrefs`.
- `ExportTemp.lua` -- exports selected photos to temp JPEGs via
  `LrExportSession` (handles RAW files) before sending to either API;
  cleans up after.
- `CandidatePicker.lua` -- shared modal radio-button dialog (`LrView`),
  preselects a default index, optional hint text, optional per-row
  reference links (`linksForCandidate` callback → list of `{label, url}`,
  rendered as extra push-buttons next to each row since `LrView` has no
  native hyperlink widget).
- `KeywordWriter.lua` -- applies a confirmed identification to selected
  photos in one `withWriteAccessDo` transaction: Title (bare scientific
  name), Caption ("Common Name (Scientific Name)"), and a nested Keyword
  under a "Species ID" root.
- `JSON.lua` -- hand-rolled decoder (Lightroom's Lua has no built-in JSON).
  Tested in `tests/test_json.lua` (project root, not inside `.lrplugin`).
- `WhatIsThisPlant.lua` / `WhatIsThisAnimal.lua` -- the two entry points,
  wiring the above together.

## Key architecture decisions
- **Menu trigger**: `LrExportMenuItems` (File > Plug-in Extras), not
  `LrLibraryMenuItems` or a full `LrExportServiceProvider`. Note: the
  right-click context menu does NOT reliably show these (checked live) --
  File > Plug-in Extras is the only confirmed path.
- **Async everywhere**: network calls wrapped in `LrTasks.startAsyncTask`;
  any `pcall` around a yielding call (network, dialogs) MUST be
  `LrTasks.pcall`, not plain `pcall` -- plain pcall is a C-call boundary
  that can't yield in Lightroom's Lua 5.1, hit this bug twice already.
- **Multi-photo handling**: Pl@ntNet takes all photos in one request with
  `organs="auto"` (their own organ classifier beats a hardcoded guess,
  confirmed via their docs). iNaturalist only takes one image per call, so
  `INaturalist.identifyAll()` calls `identify()` per photo **sequentially**
  (concurrent task orchestration judged too risky to ship unverified) and
  `mergeResults()` averages `combined_score` per taxon across photos
  (missing = 0), folding each photo's `common_ancestor` into the same pool.
- **Low-confidence handling** (`CONFIDENCE_THRESHOLD = 85`): below this,
  preselect a coarser match instead of the top species guess. iNat: best
  non-species entry already in the merged results (its own confidence-gated
  `common_ancestor` rollup). Pl@ntNet: best family, then genus, from its
  *unconditional* `detailed=true` rollup (richer than iNat's -- always
  present, not gated on confidence).
- **Shared taxonomy tree**: both plugins file keywords under iNaturalist's
  taxonomy specifically so plant and animal identifications share one tree.
  `getMajorAncestry(taxonId)` hits `GET /v1/taxa/{id}` (public, no token)
  for class/order/family/genus + common names. Pl@ntNet candidates have no
  iNat id (only a GBIF id), so `getMajorAncestryByName(name, rank)`
  resolves via `GET /v1/taxa?q=...&rank=...`, requiring an **exact**
  case-sensitive name match (never accepts a fuzzy guess). Ancestry fetch is
  best-effort -- any failure degrades to an empty list (flat tag), never
  blocks the core write.
- **Keyword tree labeling**: intermediate levels (class/order/family/genus)
  are labeled "Common Name (Scientific Name)" for browsing; the **leaf**
  keyword stays the bare scientific name on purpose, matching Title, so it
  reliably matches iNaturalist's own taxonomy for later manual import.
- **Re-ID safety**: keywords nest under a "Species ID" root
  (`includeOnExport=false`) specifically so re-identifying a photo can find
  and remove the *old* leaf keyword (`isDescendantOf` walks `getParent()`
  to any depth) without touching unrelated keywords the user added by hand.
  Caught and fixed a real bug in testing: re-identifying to the *same*
  taxon twice was appending a duplicate rather than being a no-op.
- **Reference links per candidate**: iNat (direct via taxon id for animals,
  free; search-by-name for plants, since resolving a real id for every row
  up front is too slow), Pl@ntNet (species-level plant rows only, via
  `scientificName + authorship` -- confirmed pattern, see limitation
  below), Wikipedia (`/wiki/Genus_species`, works for all ranks).

## Known limitations (accepted, not bugs to fix)
- **Pl@ntNet species-page links can 404**: their identify API returns the
  *current accepted* name, but their website's species pages can lag on an
  older taxonomic synonym (confirmed real case: API said "Securigera varia
  (L.) Lassen", their site only has "Coronilla varia L."). No cheap fix
  (would need a GBIF synonym lookup per candidate, too slow for populating
  every dialog row) -- iNat/Wikipedia links alongside it are the fallback.
  **Permanently accepted, not revisiting** -- confirmed 2026-07-22 it's
  rare enough in practice to just drop as a non-issue.
- identify.plantnet.org (the consumer website, not the `my-api.plantnet.org`
  API) has aggressive bot-detection -- don't curl it repeatedly to verify
  links; got a 429 doing this once.
- **Re-parenting a species' ancestry orphans its old keyword, and the SDK
  can't clean it up** (found 2026-07-19, via the Kingdom-for-Plantae/Fungi
  migration). `KeywordWriter.applyIdentification` matches/reuses a keyword
  by *name + parent together* (`catalog:createKeyword(..., parent,
  returnExisting=true)`), so whenever a photo's ancestry chain shape
  changes (e.g. Kingdom got inserted), the old same-named keyword under the
  old parent gets correctly *detached* from the photo but is never
  *deleted* from the catalog -- there is no `deleteKeyword` call anywhere in
  the Lightroom Classic SDK (confirmed: zero hits for "delete" in the SDK
  Guide or the `LrCatalog`/`LrKeyword` API reference). The orphaned,
  zero-photo duplicate then makes Lightroom's own "Enter Keywords" display
  disambiguate with a `<`-chained full path even though only one (correctly
  nested) keyword is actually applied to the photo -- looked exactly like a
  data bug but wasn't; confirmed via the Keyword List panel showing correct
  separate nesting and a clean Title. **Fix**: Library module > Metadata
  menu > **Purge Unused Keywords** (built-in, catalog-wide, removes every
  zero-count keyword in one pass). Not something the plugin can do for the
  user automatically. Will recur any time the ancestry shape changes again
  (e.g. further `MAJOR_RANKS`/`KINGDOMS_TO_SHOW` tweaks, or a future iNat
  reclassification) -- worth proactively mentioning "you may want to Purge
  Unused Keywords after this" in any future command that can re-shape
  existing ancestry chains.
- **`getRawMetadata` and `getFormattedMetadata` have asymmetric key lists for
  "title"** (found live 2026-07-22, building `BackfillMetadata.lua`):
  `setRawMetadata("title", ...)` is how Title gets written (already used by
  `KeywordWriter.applyIdentification`), but `getRawMetadata("title")` is NOT
  a valid read key -- crashed live with "Unknown key: title". Reading Title
  back requires `getFormattedMetadata("title")` instead. Confirmed against
  the real SDK reference's two separate key lists after the crash -- worth
  checking both the read AND write key lists separately for any metadata
  field before assuming symmetry, not just one or the other.
- **An `enum` field's `nil`/unset state must be explicitly declared too, not
  just its non-nil values** (found live 2026-07-22, `approximateLocation`
  field): declared only `{ value = "yes", title = "Yes" }` (single value,
  auto-set by `GpsPrompt.lua`) -- but with no `nil` entry in the list, the
  Metadata panel's dropdown had nothing to switch back to once "Yes" was
  set, so the field couldn't be hand-cleared in Lightroom at all. Fixed by
  adding `{ value = nil, title = "No" }` to the values list. This is the
  *inverse* of the original Taxon Rank lesson (an undeclared non-nil value
  renders blank) -- together they mean: every value a field can ever hold,
  including nil/unset, needs its own explicit entry in `values` if the user
  is meant to pick it from the panel dropdown.

## Backfill for pre-existing identifications -- built, run, and removed (2026-07-22)
`BackfillMetadata.lua` populated the custom metadata fields (Scientific
Name, Common Name, Taxon Rank, Observation ID, taxon-level fields) onto
photos identified before those fields existed. Confirmed working live
against the real catalog, then deliberately deleted (along with its
`Info.lua` entry) once backfilling was finished -- same temporary-tool
pattern as `RefreshTaxonomy.lua`/`DialogTest.lua` before it. Design notes
kept below for reference in case a similar migration is needed again in the
future.
- **Detection**: gated on `KeywordWriter.findSpeciesName(photo) ~= nil` (has
  a keyword nested under "Species ID"), NOT on Title content -- plenty of
  catalog photos have non-species titles ("Christmas 2021", "Susan at the
  Beach"), so Title alone would have produced false positives. Once a photo
  passes the keyword check, Title is safe to trust as the bare scientific
  name, since `applyIdentification` unconditionally overwrites Title for
  every photo it's ever touched.
- **Scope**: operates on `catalog:getTargetPhotos()` (the current selection),
  not `catalog:getAllPhotos()` -- deliberately changed from an initial
  whole-catalog design: this is bulk-writing, only-mock-tested code, so
  running it against a small reviewable batch first (widening the selection
  once trusted) was judged safer than one sweep across everything at once.
  Matches every other command in this plugin already.
- **Observation ID grouping heuristic**: since old photos have no record of
  which ones were identified together in one batch, photos sharing a
  resolved scientific name are grouped by capture-time proximity -- sorted
  chronologically, a new group starts whenever the gap to the previous photo
  exceeds 30 minutes (chosen over a 2-hour or same-day window, to avoid
  merging separate same-day sightings of a common species). Photos with no
  capture-time metadata get their own singleton group.
- **ID Confidence intentionally left unset** for backfilled photos -- no
  original score was ever recorded before this field existed, and
  `resolveByName`'s nominal 100% is fabricated, not a real confidence.
- Each distinct scientific name is resolved against iNaturalist exactly
  once regardless of how many observation groups it splits into, rate-
  limited at 2s/species (bumped from the earlier Kingdom-backfill tool's
  1.5s, since this one can cost up to 3 requests/species vs. 2 before).
- Has a cancelable `LrProgressScope` (title = "Backfill Metadata", caption =
  current scientific name, portion complete per species) -- added after the
  first successful run, since a large selection with the rate-limit sleep
  can take a while with no feedback otherwise. Canceling mid-run leaves
  already-backfilled photos untouched and the closing summary reports a
  partial count rather than pretending it finished.
- **Like `RefreshTaxonomy.lua`/`DialogTest.lua` before it, this is meant to
  be a temporary one-off tool** -- worth removing (file + `Info.lua` entry)
  once everything is backfilled, rather than leaving it in the permanent
  menu.

## Verification discipline used throughout
No live Lightroom instance available during most development, so: (1) local
`lua5.4` syntax-checks every file after edits, (2) pure-logic behavior is
verified with small mock-object test scripts (mocked `LrApplication`/
`LrKeyword`/`LrPhoto` for `KeywordWriter.lua`, real captured API JSON piped
through `JSON.lua` for parsing logic) before wiring into the actual plugin
files, (3) uncertain SDK method names get checked against the actual
Lightroom SDK Guide PDF or GitHub source before use, not guessed.

## Adjacent capability explored outside the plugin (not yet built in)
Demonstrated (via ad-hoc Python + direct SQLite read of the live `.lrcat`
catalog, copied to scratch first for safety) that Lightroom photos can be
matched to the user's own iNaturalist observations by capture-time
correlation: `GET /v2/observations` with `fields=...,time_observed_at,
photos.original_filename` (needs the same JWT from `/users/api_token`,
expires 24h) gives exact timestamps; matching against `Adobe_images.
captureTime` in the catalog found sub-second-precision matches for 58/60
recent observations, correctly identifying the 2 iPhone-direct-only ones
(no Lightroom import) as unmatched. Confirmed this would be *cleaner* as an
actual plugin feature -- `catalog:getAllPhotos()` +
`photo:getRawMetadata('dateTimeOriginal')` instead of raw SQLite parsing,
same stored-token pattern already in `INaturalist.lua`. This later became
the "Sync from iNaturalist" feature documented below.

## Open items / historical notes
- **TODO: convert `growthHabit` (in `MetadataDefinition.lua`) from `string`
  to `enum`** (discussed 2026-07-22, not yet built). Agreed value list,
  based on USDA PLANTS' own "Growth Habit" categories: Forb/Herb,
  Graminoid, Shrub, Subshrub, Tree, Vine, Fern -- covers realistic yard/
  garden usage. Moss/Bryophyte and Cactus/Succulent were considered but
  left out unless actually needed. Must keep the Taxon Rank lesson in mind
  when implementing: an enum value outside the declared list renders
  *blank* in the Metadata panel even with `allowPluginToSetOtherValues =
  true` set (that flag only prevents a write-time error, it doesn't help
  the popup display an undeclared value) -- so this list needs to be
  genuinely complete before shipping, not just a starting guess.
- **Custom metadata (`LrMetadataProvider`) storage decision, resolved
  2026-07-18**: field values are stored **only in Lightroom's own catalog
  database** -- the SDK guide explicitly states a plug-in cannot link a
  custom field to XMP or save it into the image file itself. This is a
  tension with an established sidecar-portability preference, but
  catalog-only storage is fine for `Subject Group ID` and any
  iNat-observation-ID field -- if a value ever needs to travel with the
  file (e.g. for export), that'll be handled explicitly at export time
  rather than by the field's native storage, most likely by folding the
  value into a keyword the way species ID already gets encoded.
- Also confirmed 2026-07-18: custom metadata fields **cannot** appear in
  Library grid cell text-template tokens (Library > View Options) --
  only `title` (Metadata panel), `searchable` (Smart Collection criteria),
  and `browsable` (Library Filter bar) are real visibility flags; there's
  no equivalent for the grid-cell-label token picker, confirmed against
  both the SDK reference and a live check. So a `Subject Group ID` or
  iNat-observation-ID field could not be shown as a grid thumbnail label
  without exporting/duplicating its value into a field that *is* supported
  there (unclear if any such field exists for plugin data -- not yet
  investigated).
- **TODO: a command to mark several photos as the same subject/organism**
  (discussed 2026-07-16, not yet built). Explicitly *not* Lightroom's native
  Stacking feature -- semantically wrong for this (stacks are about
  versions/near-duplicates of one shot, not "these are different photos of
  the same living thing"). Design agreed on:
  - A custom metadata field (e.g. `Subject Group ID`), same value written on
    *every* photo in the group -- deliberately symmetric, no privileged
    "first" photo pointing at it. A single equality query finds the whole
    group; deleting any one member just shrinks the group instead of
    leaving a dangling reference.
  - The group ID should be a **freshly generated UUID v4, not borrowed from
    any photo's own persistent uuid** (`photo:getRawMetadata('uuid')`,
    confirmed via the SDK reference to correspond to the embedded
    `xmpMM:OriginalDocumentID`/`DocumentID` XMP field -- verified by reading
    a real sidecar's XMP directly). Reusing a member photo's own id as the
    group key was considered and rejected: it conflates photo identity with
    group identity and invites exactly the "this one photo is secretly the
    root" assumption the symmetric design is meant to avoid. Lightroom's SDK
    has no built-in UUID generator, but a UUID v4 is trivial to synthesize
    in Lua (`math.random` per hex digit, forcing the version/variant
    nibbles) -- no dependency needed.
  - Command behavior: generate a new UUID, write it to `Subject Group ID` on
    every selected photo -- *unless* one or more of the selected photos
    already has a group ID, in which case reuse that existing value (so a
    straggler photo can be added to an existing group later without
    creating a duplicate group).
  - Relates to a still-open metadata-architecture question (organism-
    specific vs. species-specific vs. photo-specific metadata,
    `LrMetadataProvider`) from 2026-07-14/15 -- this "same subject"
    grouping is itself organism-specific metadata, just represented as a
    shared key across photo records rather than in an external table.

## Sync from iNaturalist

Built 2026-07-22/23 (`INatSync.lua` + `SyncFromINaturalist.lua`, new
`iNatObservationId`/`iNatObservationUrl` fields in `MetadataDefinition.lua`).
Manual menu command, matching the rest of the plugin. Pulls the user's own
observations (full history the first run, `updated_since`-scoped after),
matches to local photos by capture time, applies the current iNat taxon
only if the user's own current identification agrees with it (via the
`identifications` array/`category` mechanism), and links both directions.
Several real bugs found and fixed via live testing, worth remembering:

- **Time tolerance ended up tiered, not a single blanket number -- match
  the widened window to the specific evidence, don't apply it to
  everything**: some observations' `time_observed_at` is truncated
  (floored, not rounded -- confirmed by example: 8:43:56.81 showed up as
  exactly 8:43:00, the SAME minute, not rounded up to 8:44) to
  whole-minute precision, which bounds the worst case at just under 60s.
  First widened the tolerance to 90s "for margin" (blanket, applied to
  every observation), then to a "justified" 60s after padding beyond the
  evidence turned out to have a real cost (it's what let two unrelated
  photos 87.77s apart -- the frog/skipper case below -- land inside the
  window). But 90->60 only shrinks the coincidence window by a third, it
  doesn't address *why* the wide window applies to every single
  observation regardless of whether it needs it. Final design:
  `TIGHT_TOLERANCE_SECONDS = 2` (clock-drift only, used for the vast
  majority of observations, which have genuine sub-minute precision) and
  `TRUNCATED_TOLERANCE_SECONDS = 60`, applied ONLY to observations whose
  `time_observed_at` seconds component is exactly `:00`
  (`looksTimeTruncated` in `INatSync.lua`) -- since truncation always
  produces that signature, this confines the riskier wide window to just
  the subset that actually needs it instead of blanket-widening the search
  for everything. Lesson generalizes: when a fix requires trading precision
  for recall, look for a signature that lets you apply the trade-off
  conditionally rather than globally.
- **Skipped manual-resolution items must go on the retry list, not just
  get reported** -- an early version reported "N skipped" in the summary
  but never persisted that, so the `updated_since` cursor advanced right
  past them and they vanished for good next run. Fixed: anything left
  unresolved (including explicit "Skip For Now") goes through the same
  `markRetryOutcome` bookkeeping as an outright write failure.
- **The outer error-handling wrapper must be `LrTasks.pcall`, not plain
  `pcall`** -- hit live as "attempt to yield across metamethod/C-call
  boundary" (same bug class logged above for exactly this reason) when a
  plain `pcall` was used to wrap the whole sync body (needed so
  `progressScope:done()` always fires even if something throws mid-run,
  otherwise Lightroom's progress indicator gets stuck open indefinitely).
- **Filename mismatch-detection must compare base names, not exact
  strings**: comparing local filenames against
  `photos[].original_filename` (via the v2 sparse-`fields` endpoint, needs
  the same JWT as `score_image` -- the plain v1 response omits this field
  even authenticated) flagged ~145 essentially every-single-first-link
  group as "mismatched" until fixed -- the local file is a RAW (e.g.
  `DSC_7388.NEF`) but whatever uploaded it to iNat necessarily converted
  it to a JPEG first (iNat doesn't accept RAW), so an exact-string
  comparison could never match regardless of whether the photos actually
  correspond. Fixed by stripping extensions before comparing.
- **`getObservationPhotoFilenames` must distinguish "zero photos" from
  "photos exist but no usable filename came back"**: the v2 fields fetch
  for `original_filename` turns out unreliable -- worked for one
  observation, came back completely empty for another (confirmed live,
  reason not fully understood). Returning `{}` (empty list) either way
  was the bug: Lua only treats `nil`/`false` as falsy, so the mismatch
  check's `if iNatFilenames then` read an empty list as "iNat confirmed
  zero photos" and flagged the local photo as having something iNat
  doesn't -- when really the fetch just didn't come back usable. Fixed:
  if the observation's raw `photos` array is non-empty but zero filenames
  were extracted from it, return `nil` (same as any other fetch failure)
  instead of `{}`, so the caller correctly skips the mismatch check
  rather than acting on incomplete data.
- **Ancestry-repair must exclude coarse ranks**: a photo correctly
  identified only to Class (or broader) genuinely has no ancestors within
  `MAJOR_RANKS` (class/order/family/genus) by definition -- without
  excluding kingdom/phylum/subphylum/class, the repair logic misfired on
  every coarse-rank photo, every run, forever (a real gap, not just a
  one-time cost).
- **Manual-resolution thumbnails need `f:catalog_photo`** (an actual SDK
  view type for rendering a photo inline) plus a
  `photo:checkPhotoAvailability()` check -- a photo on a disconnected
  external drive renders as an unexplained black box otherwise; the
  availability check lets the dialog say why instead.
- **Matched local groups need explicit "claimed" tracking, or an
  already-resolved photo gets dragged into a LATER, unrelated
  collision** -- the most significant matching bug found, via a real
  live case (a correctly-tagged beetle photo, already unambiguously
  matched to its own observation, showing up again as a candidate in a
  manual-resolution dialog for a totally unrelated water-treader
  observation ~60s later). Root cause: `findCandidateGroups` has no
  memory between calls -- it just returns every local group within the
  time window every time, so a group claimed by an earlier observation
  in the same run is still "available" for every later observation's
  search too. Depending on processing order this isn't just a confusing
  dialog -- if the already-claimed group happens to be the *only* raw
  candidate for a later observation, it looks unambiguous and gets
  silently applied with no prompt at all (worse than the dialog case).
  Fixed with a `claimedGroups` set in `INatSync.pullAndMatch`, populated
  at every point a group is assigned (fast path, unambiguous match, or
  auto-paired-by-tag resolution) and filtered out of every subsequent
  candidate search in the same run.
- **"Needs an update" must compare common name and rank too, not just
  scientific name**: a photo whose scientific name already matched but
  whose COMMON NAME had drifted stale (an earlier resolution path had
  picked a different common name than iNat's current
  `preferred_common_name` for the same species) was silently never
  corrected -- the old check only looked at `observation.taxon.name ~=
  group.scientificName`, so `applyIdentification` never ran at all for a
  common-name-only (or rank-only) discrepancy. Fixed with
  `candidateDiffersFromLocal`, comparing all three fields (rank via the
  same nil-means-species convention used elsewhere). Required also
  tracking `commonName`/`rank` per group in `buildLocalIndex`, which
  previously only tracked `scientificName`.
- **Split Observation** (`SplitObservation.lua`, permanent command, not a
  one-off): gives each selected photo its own fresh Observation ID (and
  clears any stale `iNatObservationId`/`iNatObservationUrl`), for when
  photos were mistakenly identified together in one batch but are
  actually different individuals of the same species -- confirmed live
  as a real need (two individuals in one photo pair, sharing a local
  Observation ID, each needing to match a DIFFERENT real iNat
  observation, which the sync can't do without splitting the group
  first). `KeywordWriter.generateUUID` was made a public export (was
  private/internal-only before) so this new command could reuse it
  without duplicating the UUID-generation logic.
- **A known false-collision pattern, much less likely now but not
  eliminated**: two genuinely unrelated "orphans" (an iNat observation
  with no real local photo, and a local photo never uploaded to iNat)
  can coincidentally fall within the time-tolerance window of each other
  and get misread by the leftover-pairing heuristic as a candidate match
  (confirmed live: a frog photo and an unrelated skipper-butterfly
  observation, 87.77s apart). Under the tiered tolerance above, this
  specific case is now excluded twice over -- the skipper observation's
  own `time_observed_at` has genuine non-zero seconds, so it only ever
  gets the tight 2s window, never the wide 60s one. Two unrelated orphans
  can still coincidentally land within whichever tolerance actually
  applies to them, though (rarer now, but not impossible), so the
  underlying pattern remains possible, just rarer. Once the orphan
  photo-download/import feature below is built, a better fix would be a
  third dialog option -- "download this observation's photo from iNat
  instead" -- which actually resolves the root cause (the observation
  gets its own correctly-timestamped local photo) rather than just
  suppressing the recurring question.
- **Deleted observations still can't be detected incrementally**
  (confirmed live against the real API -- querying a deleted/nonexistent
  id returns HTTP 200 with an empty result set, no 404, no tombstone, no
  dedicated endpoint) -- still-open TODO: a separate, coarser periodic
  pass pulling the full list of the user's own observation ids and
  diffing against what's stored locally, layered on top of the
  incremental sync rather than replacing it.
- **Refactored into `INatSyncRunner.lua` + two thin entry points**
  (2026-07-23): `ResetINatSyncCursor.lua` got removed -- resetting the
  cursor just to force a full re-pull (needed repeatedly during
  development, every time the matching/apply logic changed and old
  results needed reconsidering) was more friction than it was worth as a
  separate one-off tool. The shared orchestration (`resolveClusterManually`,
  `formatSummary`, the whole run loop) moved out of `SyncFromINaturalist.lua`
  into `INatSyncRunner.lua`'s exported `run(options)`, so `SyncFromINaturalist.lua`
  and **`FullSyncFromINaturalist.lua`** (permanent menu command,
  `options.forceFullPull = true`) are now both thin wrappers with no
  duplicated logic. A forced full pull still updates the cursor at the
  end of a successful run, so it's "pull everything this once," not "stay
  in full-pull mode forever" -- the next regular sync goes back to being
  incremental.
- Two one-off diagnostic tools were briefly in `Info.lua`'s menu
  (`ShowINatSyncState.lua`, `ShowObservationFilenames.lua`) -- same
  temporary-tool pattern as `BackfillMetadata.lua` before them.
- **Auto-absorb untagged sibling photos (2026-07-23)** -- a deeper
  structural gap than the mismatch-detection bug above: the matching unit
  is one local "group" (photos sharing a local `observationId`) per iNat
  observation, so a local photo that was never individually run through
  this plugin's identify flow has no local `observationId` at all and is
  therefore invisible to matching, even when it genuinely belongs to an
  already-correctly-matched iNat observation. Confirmed live (the "onion"
  case): 3 photos of one onion, only 1 identified locally, then all 3
  uploaded to iNat and grouped into a single observation there -- the
  other 2 kept showing up as a permanent mismatch, every run, no matter
  how many times sync ran. Chose active auto-absorption over just clearer
  reporting. Fixed in `INatSync.lua`: `buildLocalIndex` now also builds a
  catalog-wide `photosByFilename` index (stripped filename -> photo),
  returned alongside `sortedGroups`/`byINatId`, with ambiguous stems (more
  than one local photo sharing a base filename) deliberately excluded
  rather than guessing which one is right. `applyMatch` takes this index
  and, for each iNat filename not already in the matched group, looks it
  up and absorbs it into `photos` **only if** the candidate has no
  existing `observationId` or `scientificName` of its own (an
  already-tagged photo that coincidentally shares a filename stem is left
  alone and still reported as a mismatch, never silently merged). The
  filename fetch is shared between absorption and the existing mismatch
  check (same `shouldCheckMismatch` gate) rather than doubling the API
  call per group. An absorption forces `needsSpeciesUpdate = true` so the
  newly-absorbed photo actually gets the species/keyword/title/caption
  write, not just the link fields. `INatSyncRunner.lua` reports an
  `absorbedSiblings` count in the closing summary.
- **Follow-up bug, found immediately live (2026-07-23): the onion
  siblings were STILL untagged after the above shipped.** Root cause: the
  mismatch/absorption check's own gate (`shouldCheckMismatch =
  not wasAlreadyLinked or observation-changed-since-last-sync`) was
  designed to avoid re-checking every historical group every run -- but
  that gate predates absorption, and the real onion group was already
  linked from an earlier sync (before this feature existed), with nothing
  changed on iNat's side since. So the new filename fetch (and therefore
  absorption) never ran for it. Worse: even **Full Sync** didn't help,
  despite its whole purpose being "reconsider old results under current
  logic" -- it only overrides the `updated_since` cursor on the *pull*,
  it never touched this per-group gate. Fixed by adding a `forceRecheck`
  6th parameter to `applyMatch`, OR'd into `shouldCheckMismatch`, with
  `INatSyncRunner.lua` passing `options.forceFullPull` through to it --
  so a Full Sync now actually re-examines every already-linked group for
  absorption, not just re-pulls observations. **Lesson**: any time a new
  per-group check/capability is layered onto an existing "only run this
  for new/changed groups" optimization, verify it against an
  *already-processed* fixture, not just a first-time-link one -- the two
  scenarios exercise completely different code paths and a fix that
  passes for one can be a complete no-op for the other. Also: Full Sync's
  "reconsider everything" promise needs to be checked against *every*
  gate that skips already-linked groups, not just the pull-side cursor.
- **Second follow-up bug, found immediately live (2026-07-23): "still no
  good" after the forceRecheck fix above.** Ran "Show Observation
  Filenames" against the real onion observation and got
  "getObservationPhotoFilenames returned nil (request failed outright)"
  -- a HARD failure, not the empty-list case from earlier. Root cause:
  `INaturalist.getObservationPhotoFilenames` never retried on a 401 the
  way `identify()` already does -- `INaturalist.getAuthToken()` only
  prompts when NO token is stored at all, it does nothing for a token
  that's stored but expired (the v2 endpoint's JWT is documented as
  24-hour-lived, same token `score_image` uses). So once the stored
  token went stale between sync runs, EVERY call to this function -- the
  mismatch check AND the absorption feature, for every group in every
  run -- silently failed with no error surfaced anywhere, regardless of
  the `forceRecheck` fix (that fix made the code correctly WANT to check,
  but the check itself was quietly failing at the network layer). Fixed
  by adding the same 401-retry-with-fresh-prompt pattern `identify()`
  already uses: on a 401, call `promptForToken()`, store the result, and
  retry the request once before giving up. **Lesson**: when one function
  in a file already has a hardening pattern (401-retry, always-yield-safe
  pcall, etc.) and a newer function added later calls the same underlying
  resource without it, that's a gap worth checking for explicitly -- this
  is the second time in this exact sync feature that a fix technically
  did what it claimed but didn't reach the real failure, because the
  actual root cause was one layer deeper than where the fix was aimed.
  When a fix doesn't seem to work, re-verify with a live diagnostic before
  proposing another code change based on assumption alone.
- **Third round, live (2026-07-23): the 401-retry fix produced no visible
  prompt and no change** -- meaning the failure isn't actually a 401 (or
  the request never even gets a status back at all, e.g. an exception
  inside `LrHttp.get` itself). Rather than guess a fourth time, added
  `INaturalist.debugObservationPhotoFetch(observationId)` -- a
  diagnostic-only function (does NOT change `getObservationPhotoFilenames`'s
  own nil-or-list contract used by the real sync path) that performs the
  identical fetch but returns the raw `ok`/HTTP status/response snippet
  for the first attempt, and the same for the retry if one was attempted
  -- wired into `ShowObservationFilenames.lua`'s output so the actual
  failure is visible instead of a flat "request failed" with nothing else
  to go on.
- **Ground truth from the diagnostic (2026-07-23): status=200, a fully
  valid authenticated response -- but the photos array had ONLY `id`
  fields, no `original_filename` at all** (`"photos":[{"id":703379783},
  {"id":703379769},{"id":703379766}]`). Not an auth/token problem at
  all -- filename-based matching simply cannot work for this observation.
  Since retries can't fix missing data, chose a time-based fallback over
  just reporting the gap more clearly. Built:
  - `INaturalist.getObservationPhotoCount(observationId)` -- a second v2
    fetch requesting only `photos:(id:!t)` (no filenames needed), so the
    photo COUNT stays reliable even when names aren't. Both this and
    `getObservationPhotoFilenames` were refactored to share a private
    `fetchV2Observation(observationId, fieldsParam)` helper (the
    401-retry logic now lives in exactly one place instead of being
    duplicated).
  - `buildLocalIndex` (`INatSync.lua`) now also returns
    `untaggedSingletonsSortedByTime` -- every photo never run through
    this plugin's identify flow at all (no local observationId, no
    scientificName -- always a singleton group by construction), sorted
    by capture time.
  - `applyMatch`'s fallback: when `getObservationPhotoFilenames` returns
    nil (unusable) but `getObservationPhotoCount` succeeds and reports
    MORE photos than the local group currently has, search
    `untaggedSingletonsSortedByTime` for candidates within a
    `SIBLING_TIME_FALLBACK_TOLERANCE_SECONDS = 120` window of the
    group's own capture time (reusing the existing generic
    `findCandidateGroups` binary search). Absorbs **only** when the
    number of candidates found EXACTLY matches the shortfall -- anything
    else (too many candidates, or the count fetch itself failing) is
    left as a `mismatch.countMismatch = { localCount, iNatCount,
    candidatesFoundNearby }` shape instead of guessed, the same
    "surface it, don't guess" principle as the filename-based absorption
    safety check.
  - Unlike the confirmed-evidence-based time tolerances elsewhere in this
    file (the 2s/60s truncation split), the 120s fallback window is a
    **judgment call, not derived from a specific confirmed data point** --
    explicitly documented as such in the code, since the real safety net
    against a wrong absorption is the exact-shortfall-match requirement,
    not the window size itself.
  - **Lesson for this whole debugging arc**: what started as "add
    absorption by filename" needed FOUR follow-up rounds live before it
    actually worked for the real motivating case (forceRecheck gate -> 401
    retry -> raw diagnostic to find the 401 theory was wrong -> time
    fallback for when the data genuinely isn't there at all). Each round
    was verified against real API responses rather than guessed, and each
    "fix" was real and correct for what it addressed -- the difficulty was
    that the real failure had multiple independent layers stacked on top
    of each other, each hiding the next until the previous one was
    cleared. Don't assume one fix necessarily addresses the whole problem
    just because it's a real, confirmed bug.
- **First real Full Sync with all the above fixes (2026-07-23): 34
  siblings absorbed, but 101 groups still flagged, almost all "filenames
  unavailable"** -- confirms `original_filename` isn't just missing for
  the one onion observation, it's unreliable across most of this
  account, so the time-based fallback path is hit far more often than a
  rare edge case. Two distinct shapes showed up in the mismatch list:
  (1) iNat reports MORE photos than the local group (genuine orphan, or
  an ambiguous/zero-candidate time-window search); (2) iNat reports
  FEWER photos than the local group (e.g. "iNat reports 1, local has 5")
  -- meaning a locally-batched group (one shared local Observation ID)
  has photos that don't all actually belong to that specific iNat
  observation, the same over-batching issue `SplitObservation.lua` was
  built for earlier. **Decision after seeing the real scale (101
  groups): manual fixing from here, not more automated heuristics.**
- **`INatSyncRunner.lua` writes a full HTML log** (`~/Photos/local/
  WhatIsThisThing/inat-sync-mismatches.html`, same directory
  `TaxonStore.lua` uses) every run that has any mismatches -- one block
  per mismatched group with a clickable iNat observation link, the
  mismatch detail (including the actual missing filenames on either
  side, when available), and every locally-connected photo's filename +
  capture date (via `LrDate.timeToW3CDate` on the raw `dateTimeOriginal`,
  reusing an already-confirmed-working formatter rather than guessing at
  an unverified `getFormattedMetadata` date key). The dialog summary caps
  its inline preview at 10 and points to this file for the rest. HTML
  (not plain text) specifically so the iNat links are clickable. Uses
  plain `io.open` (like `TaxonStore.lua`), wrapped in `pcall` so a write
  failure just means "no log this time," not a broken summary. Confirmed
  live constraint: **Lightroom Classic has no URL scheme**
  (`lightroom://` doesn't exist), so a browser link can never make
  Lightroom jump to and select a specific photo directly. The built-in
  fix instead: copy a filename from the report, paste it into Lightroom's
  own Library Filter bar (or Cmd+F) searching by Filename, which already
  jumps to/filters down to matches natively -- no new plugin code needed.
- **Local-has-more-than-iNat is NOT a mismatch**: not every photo taken
  gets uploaded to iNat, so the local group having more photos than iNat
  reports is completely normal, not a problem. Only iNat having a photo
  missing LOCALLY is worth surfacing (a genuine gap -- an untagged
  sibling that couldn't be confidently absorbed). Fixed in two places in
  `applyMatch`: the filename-based mismatch check now only triggers on
  `#missingLocally > 0` (missingOnINat is still computed and included for
  context if a REAL mismatch is already being reported, but never
  triggers one by itself); the count-based fallback's `shortfall < 0`
  branch (local has more than iNat's count) was removed outright -- no
  countMismatch is ever produced for that direction. **Standing
  principle for this feature going forward**: only flag directions
  confirmed to be genuinely actionable -- don't assume symmetry between
  "iNat has more" and "local has more" is automatically worth the same
  treatment just because the code can compute both.
- **Merge Observation** (`MergeObservation.lua`, permanent command,
  2026-07-23) -- the inverse of `SplitObservation.lua`: after seeing the
  real scale of count-mismatches and deciding to fix them manually, the
  chosen approach was to give the untagged sibling photos the same local
  Observation ID as the already-identified "master" photo, copying its
  metadata across. Uses Lightroom's own "most selected photo"
  (`catalog:getTargetPhoto()`) as the master -- the same convention
  Lightroom's native Photo > Sync Settings already uses for its source
  photo. **Confirmed live (2026-07-23) the click order is the OPPOSITE of
  what the code/messaging first assumed**: the master is whichever photo
  you click FIRST (the cell that gets the lighter/active border) -- later
  cmd/ctrl-clicks add to the selection without changing which one is
  active. Code comments and both user-facing error messages were
  corrected to say "click the identified photo first" accordingly. Reuses
  `KeywordWriter.applyIdentification` for the actual Title/Caption/
  keyword-tree/metadata write (same path every identify command goes
  through) rather than duplicating that logic -- resolves ancestry by
  name via `INaturalist.getMajorAncestryForCandidate` (built for Pl@ntNet
  candidates, which also lack a stored taxon id) since only the master's
  scientific name/rank are stored on the photo, not its taxon id.
  `applyIdentification` reuses whichever photo's EXISTING Observation ID
  it finds first in the list it's given, so the photo list is reordered
  master-first before calling it, guaranteeing the master's own id (not
  some other selected photo's) is the one everyone ends up sharing.
  Master's `iNatObservationId`/`iNatObservationUrl` (if any) are then
  separately copied onto every merged photo, in a second write
  transaction. Errors clearly (writes nothing) if fewer than 2 photos are
  selected, if there's no most-selected photo, or if the master itself
  isn't identified yet -- there's nothing meaningful to copy in that
  case.
- **Suggest Merge Candidates (2026-07-23, later removed -- see below)** --
  built after working through a batch of real mismatches by hand and
  noticing a pattern: the missing sibling photos are almost always
  positionally adjacent to the master in capture-time order (same
  shoot/session), regardless of the actual time gap -- NOT bounded by
  the sync's own fixed ±120s fallback tolerance.
  - **`ObservationMerge.lua`** (shared module) -- the actual "fold photos
    into the master's identification" logic was extracted out of
    `MergeObservation.lua` into `ObservationMerge.merge(master,
    otherPhotos)`, since a new command needed the exact same behavior
    (master-first reordering so its existing Observation ID wins,
    ancestry resolution, iNat link copy). `MergeObservation.lua` now just
    validates the selection and calls this shared function -- no logic
    duplicated between the two commands.
  - The original standalone command found up to 3 photos immediately
    before and 3 after the master in the WHOLE CATALOG's time-sorted
    order (positional adjacency, not a tolerance window), excluding the
    master's own existing group. Presented a dialog (`f:catalog_photo`
    thumbnails, same pattern as the sync's manual-resolution dialog) with
    a "View on iNat" link, each neighbor as a checkbox if genuinely
    untagged (no observationId AND no scientificName) or a grayed-out
    label showing its existing ID if not -- so it's never confusing why a
    visible photo isn't checkable, and there's never a risk of
    accidentally folding someone else's already-correct identification
    into this group. Re-fetched iNat's real photo count and showed the
    shortfall; if the number of checked candidates didn't match, a
    confirm sub-dialog ("Merge Anyway"/"Cancel") gated the merge rather
    than silently proceeding or blocking outright. If NO neighbors were
    eligible (or the master had no capture date at all), showed a clear
    message and skipped the picker dialog entirely rather than
    presenting an all-grayed-out, unusable UI.
  - **Wired into the sync itself (2026-07-23)**, per a follow-up request
    to have this pop up automatically during sync rather than being a
    separate standalone command. Extracted the dialog+merge logic into a
    shared **`MergeCandidatesDialog.lua`** (`buildCandidateWindow`,
    `hasEligibleCandidate`, `presentAndMerge`), used by both the
    standalone command and `INatSyncRunner.lua`'s apply loop. A single
    Full Sync had surfaced 101 mismatches in one real run, so popping up
    101 modal dialogs unconditionally would have been a poor experience
    -- decided to pop up for every mismatch, every sync (not just
    incremental), but with a **"Skip All Remaining" escape hatch**: a
    third `otherVerb` button (`result == "other"`, same established
    pattern as `ExportForINaturalist.lua`/`CandidatePicker.lua`) that sets
    a run-scoped flag; every mismatch after that point in the same run
    just falls through to the normal log, no more popups. Triggers for
    BOTH mismatch shapes (filename-based `missingLocally` and the
    count-based fallback) -- even in the filename case, the
    positional-adjacency search can catch what an exact-filename lookup
    missed. Only actually resolved mismatches get REMOVED from the
    log/summary list -- skipped, canceled, or skip-all'd ones still get
    logged exactly as before.
  - **Real bug found building the sync-integration test (2026-07-23), not
    a test-fixture gap**: the count-based fallback's candidate search
    (`untaggedSingletonsSortedByTime`, built ONCE at the start of the
    whole run) could match a group's OWN master photo as a "candidate for
    itself" -- since that list is captured before this run's own matches
    get applied, a photo that started as a genuinely untagged singleton
    (the ordinary first-time-sync case) is still sitting in it when its
    own match gets processed, and its own `group.time` is by definition
    exactly its own capture time (delta 0), so it always falls inside the
    ±120s window. This either silently "self-absorbed" (duplicate insert,
    no real fix, masking a genuine mismatch) or wrongly inflated the
    candidate count past what a REAL sibling's own exact-shortfall match
    would have been. Never caught by earlier test fixtures because every
    one gave the master a `scientificName` from the start of the test, so
    it was never itself in the untagged list to begin with -- only
    surfaced once a test modeled a photo that's genuinely brand new
    (untagged at run start, identified during the same run), which is the
    ordinary real-world case, not an edge case. Fixed by filtering the
    fallback's raw candidates against the group's current `photos` list
    before comparing to the shortfall. **Lesson**: a fixture that always
    pre-seeds the "master already has an identity" state can hide a whole
    class of self-reference bugs that only show up for a truly first-time
    match -- worth deliberately testing at least one scenario per feature
    where the master starts with nothing.
  - **`SuggestMergeCandidates.lua` removed (2026-07-23)** once it started
    popping up automatically during sync -- the standalone menu item
    became redundant. `MergeCandidatesDialog.lua`'s actual shared logic
    remains fully covered via the sync-integration test path -- no
    coverage gap from the removal.
  - **Real bug found live (2026-07-24): the picker popped up for a
    filename-only mismatch where the photo counts already matched**,
    showing "iNat reports 1, you have 1 (no more expected)" alongside 6
    completely unrelated neighbor photos -- there was never an actual
    missing sibling to search for; the original trigger was iNat's stored
    filename for the single photo not matching the local file (e.g. a
    rename), which the picker can't fix anyway. Root cause:
    `MergeCandidatesDialog.presentAndMerge` always built and showed the
    full dialog before its own fresh count re-fetch came back, so a
    same-count situation only got noticed too late (reflected in the
    dialog's text, not used to skip it). Fixed by moving the shortfall
    check earlier: if the fresh count confirms iNat doesn't actually have
    more photos than the local group, `presentAndMerge` returns a new
    `"noShortfall"` outcome without ever opening the dialog, falling
    through to the normal mismatch log exactly like "no eligible
    candidate nearby" already did. Regression test
    (`mock_test_sync_merge_integration.lua` Case 3) reproduces the exact
    scenario (real, non-unusable filenames from iNat, deliberately not
    matching the local file, with matching 1-to-1 counts) and confirms
    zero dialogs open.
  - **Regression immediately live (2026-07-24): the noShortfall fix itself
    crashed** -- "bad argument #2 to 'format' (number expected, got nil)"
    at `MergeCandidatesDialog.lua:193`. The refactor collapsed the old
    conditional `countLine` construction into an unconditional
    `string.format(" (%d more expected)", shortfall)`, but `shortfall` is
    nil whenever the count fetch itself fails (not just when it succeeds
    with a non-positive value) -- a case the earlier "noShortfall" early
    return doesn't touch (it only returns early when `shortfall` is
    non-nil AND `<= 0`; a nil shortfall falls through to this line).
    Fixed by restoring the `if iNatCount then ... else ... end` branching,
    only formatting `shortfall` in the branch where it's guaranteed
    non-nil. Not caught by the existing sync-integration tests because
    their stub always returns a valid count -- added a new, isolated
    `mock_test_mergecandidatesdialog.lua` calling
    `MergeCandidatesDialog.presentAndMerge` directly with a stubbed count
    fetch that fails outright (simulating a transient network error),
    confirming no crash and that the dialog still opens with a
    "Couldn't verify" message. **Lesson**: a refactor that collapses two
    branches into one expression needs to be checked against every value
    each variable can independently take (here: shortfall is nil OR
    positive at this point, not just "positive vs. non-positive") --
    and if no existing test stub can produce one of those values (a
    failed fetch, here), that's a gap worth closing with a new isolated
    test rather than assuming the existing coverage generalizes.

## `forceRecheck` removed (2026-07-24)

Reported live: Full Sync was taking noticeably longer each time it ran.
Root cause: `options.forceFullPull` was wired straight through as
`applyMatch`'s `forceRecheck` parameter, which OR'd into
`shouldCheckMismatch` -- meaning every Full Sync re-checked EVERY
already-linked, unchanged historical group for a mismatch (one extra
`getObservationPhotoFilenames` call, often a second
`getObservationPhotoCount` call too when filenames come back unusable --
already established as common), not just newly-changed observations. This
made Full Sync's cost scale with the user's *entire* observation history,
every single run, and that total only ever grows as more observations get
added on iNat between runs -- directly explaining "taking longer each
time."

`forceRecheck` was built specifically to fix the "onion" sibling-absorption
bug (an already-linked group needed reconsidering under newer matching
logic) -- but that bug had been fixed and confirmed working for a while
by the time this was reported. Rather than keep paying the full-history
recheck cost on every routine run just in case a *future* logic change
needs it again, removed the parameter entirely: `applyMatch` dropped
`forceRecheck` from its signature (now `group, observation, username,
lastSyncAt, photosByFilename, untaggedSingletonsSortedByTime`), and
`shouldCheckMismatch` is back to `not wasAlreadyLinked or
observation-changed-since-last-sync` only -- no override. Full Sync still
ignores the `updated_since` cursor for the *pull* (so it still catches
anything new or changed), it just no longer forces a mismatch recheck on
every historical group regardless.

**Tradeoff accepted knowingly**: if a future matching-logic change needs
old, already-settled groups reconsidered again, that won't happen
automatically via Full Sync anymore -- it'll need a deliberate one-off
migration (same pattern as `BackfillMetadata.lua`/`RefreshTaxonomy.lua`
before it), not something baked into a routine command's default
behavior. Given the count-mismatch backlog is already being resolved
manually rather than through more automated heuristics (see the "manual
fixing from here" decision above), this fits the same philosophy: don't
pay an ongoing cost for a one-time need.

`mock_test_inatsync.lua`'s Case 8e (which specifically tested
`forceRecheck`'s behavior) was rewritten to instead confirm the *current*
behavior: an already-linked group with an unchanged observation is never
rechecked for absorption, even when the data would otherwise support an
exact-shortfall match -- i.e., verifying the removal, not the removed
feature. All `applyMatch` call sites (in `INatSyncRunner.lua` and the
test suite) updated to the new 6-argument signature.

## Filename mismatch check was still too strict (2026-07-24)

Asked to look at `inat-sync-mismatches.html` directly (it's readable at
`~/Photos/local/WhatIsThisThing/` -- no need to ask the user to paste
examples when the file itself is on the same machine). Every single one of
96 mismatched groups showed the same shape: iNat's reported filename was
`original` (a literal generic placeholder, seen dozens of times), or some
completely different naming scheme entirely disconnected from the local
camera filename (`instagram-001_(1)`, `sapsucker`, `squirrel`, `creeper` --
descriptive/cross-posted names, not real original filenames at all) --
while the local group had photo counts either equal to or greater than
what iNat reported. Confirms the "unreliable" note logged earlier in this
file more concretely still: `original_filename` isn't just sometimes
missing, it's very often not the real camera filename at all even when
present.

The bug: the filename-based mismatch check trusted a STRING mismatch as
proof of "iNat has a photo we don't," even when the raw COUNTS already
proved there was nowhere for a missing photo to hide (iNat's count equal
to or less than the local count). A name that doesn't match anything
locally only means something's actually missing if iNat genuinely reports
MORE distinct photos than the local group has -- otherwise every iNat
photo could just be one of the local ones under a different (placeholder
or cross-posted) name. Fixed in `INatSync.lua`'s `applyMatch`: the
missingLocally-triggered mismatch now also requires
`iNatUniqueCount > localUniqueCount`, the same "trust the count, not just
the name" principle the count-based fallback already used, extended to
the filename-available path where it had been missing. This is a genuine
gap the earlier "local has more is not a mismatch" fix (2026-07-23) didn't
close -- that fix addressed `missingOnINat` triggering alone and the
count-fallback's negative-shortfall case, but not a filename-available
path where names simply don't match despite the counts already
reconciling.

Regression tests `mock_test_inatsync.lua` Case 8j (1 local photo, iNat
reports 1 photo named literally `"original"` -- counts equal, must not be
flagged) and Case 8k (3 local photos, iNat reports 1 `"original"` -- iNat
has fewer, must not be flagged) reproduce the exact patterns found in the
real log. The existing RAW-vs-JPEG case (`extra_photo_on_inat`, where iNat
genuinely has 2 photos against 1 local) still correctly flags, confirming
the count gate doesn't suppress genuine gaps -- only ones a name mismatch
alone can't actually prove.

## Bounded pending-mismatch list (2026-07-24)

After the filename-count-gate fix above, reported that the sync "didn't
seem to change anything." Checked the mismatch log's file timestamp
directly (`ls -la` on `~/Photos/local/WhatIsThisThing/inat-sync-mismatches.html`)
against its own internal timestamp -- unchanged since before the fix, even
across a fresh sync run. Root cause: removing `forceRecheck` (the previous
section) meant these 96 already-linked, unchanged observations would now
NEVER get rechecked again by any sync, ever -- so a run with zero
rechecked mismatches just short-circuited `writeMismatchLog` before ever
touching the file, silently leaving the stale 96-entry report in place.
There was no way left to verify the filename fix against the real backlog
at all.

Fix: reintroduced `forceRecheck` on `applyMatch`, but scoped narrowly this
time -- driven by a persisted, bounded list of observation ids CURRENTLY
known to be mismatched (`iNatPendingMismatchIds` in prefs,
`INatSync.getPendingMismatchIds()`/`markMismatchOutcome()`, same shape as
the existing retry list), not a blanket "is this Full Sync" flag. Every
sync (regular or full) now force-rechecks just this backlog -- bounded by
however many are actually still unresolved (currently ~96, shrinking over
time as things get fixed), not the user's entire history. `INatSyncRunner.lua`
merges `pendingMismatchIds` into the same re-fetch-and-merge mechanism the
retry list already uses (`pullAndMatch`'s `retryIds` parameter, reused
as-is), builds a lookup table, and passes `forceRecheck =
pendingMismatchLookup[observation.id]` per match. `applyMatch` now also
returns `checkedMismatch` (whether a check actually ran this call) so the
caller can correctly distinguish "checked and confirmed fine" from
"never looked" -- updating the pending list off `mismatch == nil` alone
would have been wrong, since that's also true when `shouldCheckMismatch`
was false. The pending-list update also accounts for the interactive
merge-candidates resolution: if the picker (or its automatic
exact-shortfall fallback) resolves the mismatch in the SAME run, the id
is removed even though `result.mismatch` itself (computed before the
resolution attempt) was non-nil.

Regression tests: `mock_test_inatsync.lua` Case 9b (unit test for
add-when-mismatched/remove-when-resolved) and, more importantly,
`mock_test_sync_merge_integration.lua` Case 4 -- a genuine two-run
end-to-end test proving the mechanism actually works across separate sync
invocations: run 1 finds an unresolvable count mismatch (no eligible
neighbor anywhere nearby) and adds it to the pending list; run 2 (nothing
else changed except a new untagged sibling now exists nearby) force-
rechecks it purely because it's on the list -- despite being
already-linked and unchanged on iNat's side, which would otherwise skip it
entirely -- finds the new sibling via the automatic exact-shortfall
fallback, resolves it, and removes it from the list. Building this test
surfaced a real fixture-design trap worth remembering: the merge-
candidates picker's neighbor window is POSITIONAL across the whole
catalog (no time bound), so an unrelated untagged photo hours away can
still leak into a "no eligible candidate" test unless deliberately crowded
out by closer, ineligible filler photos -- and separately, a test
observation whose fake timestamp happens to land exactly on a 60-second
boundary gets the wide *truncated* tolerance (60s) for PRIMARY time
matching (not just the narrow 120s sibling-fallback one), so filler
photos meant only to occupy the picker's window can accidentally create a
genuine multi-way collision needing the (test-unstubbed) manual-resolution
dialog if placed too close in time.

## Bootstrapping gap in the pending-mismatch list (2026-07-24)

Reported live, immediately after the bounded pending-mismatch list
shipped: the mismatch report "still seems the same," and the entries
"aren't real mismatches" anymore. Checked directly (now know exactly where
to look -- see below): the report file's own timestamp hadn't moved at
all, and `iNatPendingMismatchIds` didn't exist yet in Lightroom's
preferences. Root cause -- a genuine bootstrapping problem with the design
from the previous section: the bounded list only ever rechecks observation
ids already ON it, but the list started empty, and a normal sync (even
Full Sync) has no reason to add these 96 pre-existing, already-linked,
unchanged observations to it -- the check that would discover "is this
still a mismatch under the current logic" never even runs for them,
because running it in the first place is exactly what being on the list
unlocks. Chicken and egg: nothing will ever re-verify these unless
something forces a look, once.

Fix: `INatSyncRunner.run()` gained `options.forceRecheckAll` -- when set,
EVERY match's mismatch check runs regardless of the pending list (not
wired to `forceFullPull`, deliberately -- that would reintroduce the
every-single-run cost problem the original `forceRecheck` removal fixed).
New one-off command **`RebuildMismatchList.lua`** just calls
`INatSyncRunner.run({ forceFullPull = true, forceRecheckAll = true })` --
same temporary-migration-tool pattern as `BackfillMetadata.lua`/
`RefreshTaxonomy.lua` before it (run once, then remove the file and its
`Info.lua` entry). This correctly repopulates the bounded list under
whatever the CURRENT logic is -- the false positives just discovered by
the filename-count-gate fix get dropped, anything genuinely still
mismatched gets (re-)added, and from then on the normal bounded per-run
recheck keeps working as designed.

Along the way, needed to actually find where `LrPrefs.prefsForPlugin()`
persists on disk to confirm the diagnosis (rather than guess) --
`~/Library/Preferences/com.adobe.LightroomClassicCC7.plist`, key
`sdk_org.krefting.whatisthisthing`, the whole prefs table serialized as one
Lua-syntax string value. Lightroom-application-wide storage, not
per-catalog, not inside the `.lrcat` file itself (confirmed by checking
the catalog's own SQLite schema for a plugin-prefs table first and finding
none). Worth remembering this file also holds the iNaturalist API token in
plain text -- not something this session changed, just relevant if that
plist (or a backup of it) is ever shared.

Regression tests: `mock_test_sync_merge_integration.lua` Case 5 --
confirms a normal (even Full) sync leaves an already-linked,
never-yet-flagged observation alone, while `RebuildMismatchList.lua`
(forceRecheckAll) reaches it, finds the genuine mismatch, and adds it to
the pending list -- the exact bootstrapping scenario.

## Virtual copies broke the filename-count comparison too (2026-07-24)

Reported live against observation #377587718: all 3 photos genuinely
exist both on iNat and locally, but 2 of the 3 local photos are VIRTUAL
COPIES of the first -- same underlying source file, different Develop
edits. `photo:getFormattedMetadata("fileName")` reports the SAME filename
for all three, since a virtual copy isn't a separate file on disk, just a
separate set of edit instructions pointing at the same one.

This broke the filename-count-gate fix from earlier the same day in a
different way than the "original"/placeholder-name problem it was built
for: that fix computed `iNatUniqueCount`/`localUniqueCount` from the
DEDUPLICATED stripped-filename sets (Lua tables used as sets naturally
collapse duplicate keys) -- fine when the concern was unreliable NAMES, but
wrong here, since 3 local Lightroom photo objects sharing one filename
collapse to just 1 unique local name, while iNat (each virtual copy
presumably exported/uploaded separately, each getting its own generated
name) reports 3 distinct names. `iNatUniqueCount(3) > localUniqueCount(1)`
wrongly looked like a real gap.

Fixed by comparing raw counts instead of deduplicated-set sizes:
`#iNatFilenames` (the actual length of the list `getObservationPhotoFilenames`
returned) vs `#photos` (the actual number of local Lightroom photo objects
in the group) -- sidesteps name-deduplication entirely on both sides,
regardless of whether the underlying cause is virtual copies sharing a
name (local-side collapse) or a placeholder/cross-posted name coincidence
(iNat-side ambiguity, already covered by the exact-count-match principle
from the earlier fix). The `missingLocally`/`missingOnINat` detail lists
(informational, shown in the HTML log) are still computed from the
stripped-name sets as before -- only the trigger condition changed.

Regression test `mock_test_inatsync.lua` Case 8l reproduces the exact
scenario: 3 local photos (1 original + 2 virtual copies, all reporting the
identical filename), iNat reporting 3 distinctly-named photos (simulating
separate per-copy export names) -- confirms no mismatch even though not a
single individual filename matches between the two sides, because the raw
counts (3 and 3) do.

- **Set iNat Observation (2026-07-23)** -- permanent command, built after
  a design discussion surfaced three worries that all converged on one
  missing capability: (1) the sync occasionally picks the wrong
  observation (coincidental timestamp collision -- success rate is high
  enough not to need automated detection, just a fix once one's spotted
  by eye); (2) no way to find them except by eye, which is fine; (3) a
  concrete real case -- 4 local photos (one shared local Observation ID,
  same species) should actually have been split into 2 real iNat
  observations of 2 photos each, and since all 4 share one species,
  there's nothing in the local data to hint which 2 belong together
  (`Split Observation`'s own scientificName-based disambiguation has
  nothing to go on) -- the only fix is external knowledge (which photos
  are on which iNat observation), applied by hand.
  `iNatObservationId`/`iNatObservationUrl` are deliberately read-only in
  the Metadata panel (to prevent accidental edits), which also meant
  there was no way to CORRECT a wrong one, and clearing it (`Split
  Observation`) alone doesn't help since the same coincidence would
  likely just reproduce the same wrong guess next sync.
  - `SetINatObservation.lua`: select photo(s), paste in an iNat
    observation id OR full URL (parses trailing digits either way), it
    fetches that observation via `INaturalist.getObservationsByIds`
    (already used for the retry-list re-fetch, so no new API surface
    needed), applies its CURRENT taxon unconditionally (no agreement
    check like the automatic sync has -- choosing this specific
    observation IS the explicit judgment call), and writes the iNat link
    fields. A soft filename-mismatch confirm (not a hard block -- same
    "warn, don't block" principle as the unidentified-photo check on
    iNaturalist export) catches a likely wrong/typo'd id before
    committing, but never prevents an explicit override.
  - **Always assigns a brand-new local Observation ID to exactly the
    selected photos**, deliberately NOT reusing
    `KeywordWriter.applyIdentification`'s normal "reuse whichever
    existing id is found first" behavior -- necessary for the
    over-batched case: reusing the stale shared id would leave an
    unselected sibling still wrongly attached to the "fixed" group. Fix
    one subset at a time (select the 2 that belong to observation A, run
    it; select the other 2, run it again with observation B) -- each
    invocation only affects its own selection.

## Full per-observation sync log (2026-07-24)

Reported live: after uploading several new observations to iNat and
running "Sync from iNaturalist," nothing appeared to happen -- the
relevant photos weren't updated with an iNat ID or link. Live
investigation (plist inspection, direct `updated_since` curl calls against
the real API at two different cutoffs, direct SQLite queries against the
active `.lrcat`) confirmed the run itself completed and DID advance the
sync cursor past all the recently-touched observations, but only some of
them showed up anywhere in the closing summary dialog -- several were
unaccounted for in every bucket, including "no local match" (which showed
as zero/absent). Couldn't pin down further because the summary dialog is
the only record of a run and it's gone the moment it's closed (or the sync
is run again) -- there was no way to go back and see what actually
happened to a specific observation after the fact.

Fix: `INatSyncRunner.run()` now builds a `runLog` table alongside the
existing counts/mismatches, with one entry per observation actually
reached this run -- covering every outcome, including ones that
previously left no trace anywhere: `no_local_match`, `unresolved_collision`
(both the normal skip-in-dialog path and the run-canceled-before-
resolution path), `canceled_before_apply` (progress canceled partway
through the apply loop), the normal `applyMatch` status outcomes
(`applied`/`linkedOnly`/`repairedAncestry`/`skippedDisagreement`) with a
mismatch detail string when applicable, and `failed`. Written
append-only (never overwritten, unlike the mismatch HTML) to
`~/Photos/local/WhatIsThisThing/inat-sync-log.txt` via a new
`writeFullSyncLog()`, one timestamped `=== ... ===` header block per run
followed by one plain-text line per observation (id, taxon name if known,
outcome, detail). The closing summary dialog now mentions this path
(`formatSummary` gained a `fullLogPath` parameter) so it's discoverable
without having to know it exists.

This is diagnostic infrastructure, not a fix for the "nothing happened"
bug itself -- that investigation is still open. Next step is having the
user run the sync again and share the resulting log so the specific
observations in question can be traced by outcome instead of reconstructed
from screenshots.

Also required renaming `INatSync.pullAndMatch`'s report field
`noLocalMatchCount` (a bare integer) to `noLocalMatchObservations` (the
full list of observation objects), since the log needs to know which
observations landed there, not just how many -- `counts.noLocalMatch` in
the runner is now `#report.noLocalMatchObservations`.

Regression test: `mock_test_sync_merge_integration.lua` Case 6 runs a real
end-to-end sync (via `FullSyncFromINaturalist.lua`) against one observation
with a normal local match and one with no local match at all, then reads
the actual log file back off disk (using a real writable temp directory
for this one case, unlike every other case in that file, which
deliberately points `LrPathUtils.getStandardFilePath` at a nonexistent
path with a no-op `createAllDirectories` so the log write fails harmlessly)
and confirms both observation ids appear with the expected outcome,
including `no_local_match` for the unmatched one.

## Unresolved-collision log entries didn't name the local photo (2026-07-24)

Reported live right after the full sync log shipped: observation
#384443380 (a genuine collision needing manual resolution, skipped via
"Skip For Now") did show up in `inat-sync-log.txt`, but its detail was
just "skipped in the match dialog" -- no mention of `IMG_0630.JPG`, the
actual local photo the on-screen dialog had been asking about. Technically
present, practically useless -- there was no way to tell which local file
was involved without re-running the sync and watching the dialog again.

Fix: extracted the per-group "filenames + currently-tagged species"
label-building already used for the dialog's own text (previously
recomputed inline inside `resolveClusterManually`'s loop) into a shared
`describeCandidateGroups(groups)` helper. `resolveClusterManually` now
also returns `groupLabels` (one label per local candidate group in the
cluster), and both call sites in `INatSyncRunner.run` that log an
`unresolved_collision` outcome -- the normal skip-in-dialog path AND the
run-canceled-before-resolution path (which never called
`resolveClusterManually` at all, so needed its own
`describeCandidateGroups(cluster.groups)` call) -- fold those labels into
the log detail: `"skipped in the match dialog -- candidate local photo(s)
in this cluster: IMG_0630.JPG"`.

Regression test: `mock_test_syncfrominaturalist.lua`'s existing
manual-resolution-skip scenario (two untagged photos, `DSC_7378.NEF` /
`DSC_7379.NEF`, colliding with two observations, dialog always returns
"cancel") now also points `LrPathUtils.getStandardFilePath` at a real
writable temp directory (previously nonexistent/no-op like the other
cases, since this test only used to check the retry list) and reads the
actual log file back off disk to confirm both filenames appear in the
unresolved-collision entries.

## Collision dialog flipped to anchor on the observation; new-link confirmation added (2026-07-24)

Design discussion (not a live bug report this time): the collision-
resolution dialog asked "here's a local photo, which of these iNat ids is
it?" -- backwards from how the user actually thinks about it ("I have this
specific iNat post, which of my local photos is it?"), and left the iNat
side as a bare text label (species name only), requiring a "View on iNat"
click just to see anything concrete about each candidate.

`resolveClusterManually` (INatSyncRunner.lua) now iterates
`cluster.observations` as the outer loop instead of `cluster.groups`,
presenting each observation's own `describeObservation` header ("#id --
common name (scientific name) -- N photo(s)", built entirely from data
already in the pulled observation object -- no extra fetch) and offering
the remaining candidate LOCAL groups (with thumbnails, same
`catalog_photo` treatment as before) as the radio choices. `groupLabels`/
`labelForGroup` unchanged in spirit -- just no longer tied to loop order,
since groups now get removed from the pool as they're claimed rather than
observations. Deliberately kept text-only (no downloaded iNat photo) for
now -- explicitly requested, given the photo-count is already reliable and
free, whereas fetching iNat's own image would need a temp-file download
per candidate shown.

Separately, added a NEW confirmation dialog for brand-new links: even an
unambiguous, high-confidence match now gets a "Link this photo to #id --
common name (N photos)?" confirmation before being applied, requested
explicitly ("show the confirmation even if we feel good about the
match"). Scoped to first-time links only
(`match.group.iNatObservationId == nil`) -- an already-linked observation
being routinely re-verified every run skips it entirely, or every regular
Sync would turn back into a full manual review. "Skip For Now" leaves the
match unapplied and adds it to the retry list (same treatment as a skipped
collision, so it's offered again next run regardless of the cursor). A
Full Sync can surface hundreds of first-time links in one run (confirmed
live: 712 in one real run), so this dialog also has an "Accept All
Remaining" escape hatch (`acceptAllRemainingNewLinks`), same pattern as
`skipAllRemainingMismatchDialogs` for the merge-candidates picker --
confirming (or accepting-all) the current match, then silently applying
everything else the rest of the run.

`describeObservation` and the candidate-column builder (`buildCandidateColumn`)
are shared between the collision dialog and the new confirmation dialog,
since both need the same "show local photos + describe the iNat
observation" building blocks.

Layout follow-up, same session: the first version stacked each candidate
as its own full-width 200x200 block (thumbnail row, then a radio button
below it), one after another -- fine for one or two candidates, but grew
unbounded and routinely overflowed the screen for a cluster with more than
a couple. Reworked to match `MergeCandidatesDialog.lua`'s existing
layout instead (explicitly requested: "let's do the same photo layout as
in the other matching dialog") -- `buildCandidateColumn` now builds ONE
column per candidate (150x150 thumbnail(s), matching MergeCandidatesDialog's
own size, plus a 22-char-wide caption underneath, same as its
`buildNeighborColumn`), and all of a cluster's candidate columns get
placed side by side in a single `f:row(...)`, horizontally, instead of
stacked vertically.

New count bucket `counts.skippedNewLinkConfirmation`, surfaced in the
closing summary ("N new link(s) skipped at confirmation -- will offer
again next time").

Regression tests: `mock_test_sync_merge_integration.lua` Case 7 covers the
new confirmation dialog directly -- "Skip For Now" leaves a fresh link
unapplied and retry-listed (Case 7a), "Accept All Remaining" confirms the
current match and silently applies a second first-time link with no
second dialog (Case 7b). Needed two supporting mock fixes: the shared
`presentModalDialog` stub now distinguishes this dialog from the merge-
candidates picker by title (previously one shared counter, which would've
made every existing case's dialog-count assertions wrong now that every
scenario in that file involves a first-time link); and the mock's
`LrHttp.get` gained a real `?id=` handler (previously any retry-list
re-fetch silently returned empty results) so Case 7b's retry-listed
observation is actually re-fetched on the second run, not just
state-checked. That fix exposed a latent cross-case coupling in the test
file itself -- Cases 2 and 5 deliberately leave observations on
`iNatPendingMismatchIds`, which (now that `?id=` actually resolves) would
otherwise get force-re-pulled into Cases 3 and 7 and reopen their own
unrelated picker dialogs; both now explicitly reset
`iNatPendingMismatchIds`/`iNatPendingRetryIds` before they run.

## Same-scientific-name-and-day widening for camera-clock-skew rescue (2026-07-24)

Direct follow-up to the timezone diagnosis two sections back (the Nikon
D50 whose clock was never adjusted for a Montana trip). Explicitly
requested: "include any photos with the same scientific name and date as
the observation -- these photos are all already tagged." A photo whose
true capture time is hours off from what iNat reports falls outside even
`TRUNCATED_TOLERANCE_SECONDS` (60s), so it silently becomes
`noLocalMatchObservations` despite already carrying the exact right
identification from a prior identify pass.

`buildLocalIndex` (INatSync.lua) now also returns `groupsByScientificName`
(every already-tagged group, keyed by name) alongside its existing
indexes. In `pullAndMatch`, if the primary time-window search finds
ZERO candidates for an observation, `widenCandidatesByScientificName`
looks up that table for groups sharing the observation's `taxon.name`
AND calendar day (via a new `dateOnly` helper -- `LrDate.timeToW3CDate`
truncated to its first 10 characters, a deliberately loose comparison
since the whole point is tolerating a capture time that's hours off
true).

**Deliberately scoped as a fallback only** -- widening only runs when
`#candidateGroups == 0` from the time window, never added on top of an
already-successful match. Tried it unscoped first and immediately broke
several existing regression tests: an observation that already had a
clean single time-based candidate would get OTHER unrelated
same-species-same-day groups tacked on as extra "candidates" purely
because they happened to share a name and land within a day of each
other, turning a working match into a spurious collision. Scoping to
"only when time-based search found nothing at all" fixed all of it and
is also the more conservative, less risky behavior for real usage --
this never second-guesses a match the time window already got right.

**Found and fixed a real latent bug in `pairByScientificName` along the
way**: it paired a candidate group to an observation whenever the group's
name matched exactly one STILL-UNMATCHED observation, but never checked
whether OTHER candidate groups also shared that same name. With the
widening now able to surface multiple same-day, same-name groups for a
single observation, the old greedy loop would silently pair the
observation to whichever group came first in iteration order and just
drop the others -- no manual-resolution surfacing, no log entry, nothing.
Fixed by requiring a group's name to also be unique among the OTHER
candidate groups being considered before trusting it for auto-resolution
(`groupCountByName`) -- ambiguous cases now correctly fall through to
`toResolveManually` instead, where the (recently flipped) collision
dialog offers all of them as candidates for the user to pick from.

Regression tests: `mock_test_inatsync.lua` Cases 12a/b/c, added on a
dedicated, disconnected calendar day (`fakeTime(2024, 8, 1/5/10, ...)`)
specifically so they can't accidentally collide with any of this file's
many pre-existing same-species fixtures elsewhere in its shared
timeline. 12a: a single same-day candidate 4 hours off gets rescued into
`toApply`. 12b: two same-day candidates correctly become a genuine
`toResolveManually` cluster (both offered), not a silent pick of one.
12c: same scientific name but a DIFFERENT calendar day stays unmatched --
confirms the date actually gets checked, not just the name. Needed a
supporting mock fix: this test file's `LrDate.timeToW3CDate` stub had
always returned a single hardcoded constant regardless of input (harmless
before this feature existed, since nothing compared dates), which would
have made every group look like the same day as every observation --
replaced with a real conversion mirroring the file's own `isoFor`
convention.

## Sync dialogs audited for "View on iNat" links (2026-07-24)

Requested as a standing check ("if the dialog does not have a link to the
iNat page it should"), not a specific reported gap. Audited all three
dialogs shown during a sync run: the collision-resolution dialog and the
new-link confirmation dialog (both in INatSyncRunner.lua) and the
merge-candidates picker (MergeCandidatesDialog.lua) -- all three already
include a "View on iNat" button/link (as does the mismatch HTML log's
per-entry link). Nothing needed changing; noted here so this doesn't get
re-litigated as an open question later.

## Traceable "no local match" reasons for claimed-away candidates (2026-07-24)

Reported live: observation #384538806 (`Cirsium hookerianum`) should have
matched IMG_1309/1310/1311 -- all three already correctly tagged, no
`iNatObservationId` yet, no `iNatObservationId` conflict. Isolated
reproduction of the matching code against just these photos and this one
observation succeeded under every plausible timezone assumption (Mountain,
Eastern, raw UTC), so the algorithm wasn't wrong in isolation. The real
run's log held the actual clue: a *different* observation
(`#384538787`, a plant) had been offered squirrel-tagged photos
(`Urocitellus columbianus`) as candidates -- clear evidence of `claimedGroups`
cross-contamination, where an earlier-processed, completely unrelated
observation finds the same local group via pure time proximity (no
species check at that stage) and silently claims it before the correct
observation gets its turn. `claimedGroups` has existed since the original
"beetle incident" fix, but only ever recorded *that* something was
claimed, never *what* claimed it -- so this specific failure mode was
real but had no way to be confirmed or traced, just theorized.

Fix: `claimedGroups[group]` now stores the claiming observation itself
(previously just `true`) at all three assignment sites (fast path,
unambiguous single candidate, resolved collision pairs). Both places a
group gets excluded because it's already claimed -- the primary
time-window filter and `widenCandidatesByScientificName`'s same-day
fallback (which now also returns a `claimedAway` list alongside the
widened candidates) -- feed into a new `noLocalMatchReasons` table
(keyed by observation id), populated only when a "no local match" outcome
was actually caused by a lost race for a specific candidate, naming both
the claimed local filename(s) and the id/taxon of whichever observation
won it. `INatSyncRunner.run` passes this through to `logObservation` as
the detail string for `no_local_match` entries, so the *next* real run
against this exact case will show definitively (rather than
theoretically) who claimed IMG_1309-1311, if it's still contested.

This is diagnostic infrastructure, same spirit as the full per-observation
sync log -- it doesn't fix the underlying race (an unambiguous single-
candidate match still has no species cross-check, which is the actual
root cause), just makes it traceable instead of a silent, unexplained
"no local match." Whether to also add a species check to the unambiguous
fast path itself is a separate, not-yet-made decision -- doing so would
change the meaning of "unambiguous" for every existing untagged-photo
historical-backfill match too, where there's no species to check against.

Regression test: `mock_test_inatsync.lua` Case 12d reproduces the exact
shape live -- one local group sitting between two observations, both
within the wide truncated tolerance of it (one unrelated, processed
first in pull order, claims it via pure time proximity; one genuinely
matching by scientific name, processed second, finds nothing). Confirms
the second observation lands in `noLocalMatchObservations` with a
`noLocalMatchReasons` entry naming the actual claimed filename and the
specific claiming observation's id and taxon.

**Live-run follow-up, same day**: the feature worked -- a real Full Sync
correctly linked IMG_1309/1310/1311 to #384538806 -- but surfaced a
cosmetic bug in two OTHER genuine claimed-away cases: the same filename
appeared twice, back to back, joined by "; " (e.g. "DSC_5586.NEF already
claimed this run by #170277039 (Sphyrapicus varius); DSC_5586.NEF already
claimed this run by #170277039 (Sphyrapicus varius)"). Cause: a group
that's BOTH within the primary time window AND matches by scientific
name gets excluded (and recorded into `claimedAway`) at the primary-window
step, then found AGAIN by the widening fallback's own scan (whose dedup,
`alreadyCandidate`, only covers groups that made it into `candidateGroups`
-- a claimed-away group never does, so it's not protected against being
re-found and re-recorded). Fixed by deduplicating by group identity when
building the final reason string, rather than threading shared
already-recorded state through both collection sites. Confirmed
Case 12e's own fixture (photoStolen sits within both obsRescued's primary
window AND the widening lookup) already exercised this exact duplication
-- strengthened its assertion to check the filename appears exactly once,
verified it fails against the pre-fix code and passes with the fix.
(Renumbered from 12d to 12e when the midnight-crossing test below was
inserted ahead of it.)

## Same-day widening compared rendered dates, not absolute time (2026-07-24)

Same live investigation, next observation over: #384538778 (`Ursus
americanus`, a black bear) still showed `no_local_match` with no
`claimedAway` reason at all -- genuinely zero candidates, not a lost
race. Direct SQLite check found the obvious match sitting right there:
`IMG_0642.JPG`, already tagged `Ursus americanus`, captured at
`17:52:09`-ish local time, essentially identical to the observation's own
`18:22:00-06:00`. Reproduced in isolation under three timezone
assumptions for the local photo's Cocoa-epoch value (Mountain, Eastern,
raw UTC) -- Mountain matched via the primary time window outright (so
never needed the fallback), but BOTH Eastern and UTC failed even the
same-day widening fallback outright, which was surprising since the
species name matched exactly.

Root cause: the observation's own true absolute instant is
`2010-07-21T00:22:00Z` -- `18:22 Mountain` plus the `+6h` offset crosses
midnight into the NEXT day. The old `dateOnly()` helper rendered THIS
already-offset-corrected absolute instant via `LrDate.timeToW3CDate` and
compared its "YYYY-MM-DD" prefix against the local photo's own rendered
date -- under the Eastern/UTC assumptions, the photo's absolute instant
(correctly, for an 18:22 local reading under those offsets) stays on
`2010-07-20`, one day EARLIER than the observation's midnight-crossed
`2010-07-21`. Two photos of the same real moment, genuinely close in
absolute time, compared as different calendar dates purely because of
where the day boundary happened to fall for each side's own (possibly
wrong) offset assumption.

Fixed by abandoning rendered-date-string comparison entirely.
`widenCandidatesByScientificName` now compares `g.time` and `targetTime`
(both already-absolute Cocoa-epoch numbers) directly:
`math.abs(g.time - targetTime) <= SAME_DAY_WIDENING_TOLERANCE_SECONDS`
(86400, i.e. 24 hours) -- a pure arithmetic comparison with no rendering,
no timezone assumptions, and therefore no day-boundary edge case at all.
24 hours comfortably covers every clock-skew magnitude actually seen live
(2-6 hours) without depending on how any particular date string would
have rendered. `dateOnly()` and its `LrDate.timeToW3CDate`-based
`DEVELOPMENT_NOTES` framing are gone -- the comparison no longer
involves "calendar day" as a rendered concept at all, just absolute
closeness in time.

Regression test: `mock_test_inatsync.lua` Case 12d -- a photo at Aug 15
23:30 and an observation at Aug 16 00:30, exactly 1 hour apart in
absolute terms but on different rendered calendar dates. Also widened
Case 12c's negative control (previously exactly 24 hours apart, sitting
right at the new tolerance's boundary) to a full 2 days, so it stays a
genuinely unambiguous "too far apart" case regardless of exactly how the
boundary is handled.

## Claimed-away tracing extended to collisions, not just no-match (2026-07-24)

Same live investigation, next straggler: observation #384538787 ("bracted
lousewort") landed in `unresolved_collision` offering only unrelated
squirrel-tagged photos -- but the user confirmed the actual correct match
(`IMG_0680.JPG`) is already tagged with the exact right species and sits
9 seconds from the observation's stated time. Reproduced in isolation
against just this one photo/observation pair under four different
timezone assumptions (Mountain, Eastern, Pacific, UTC) -- all four
matched cleanly, ruling out a per-photo timezone issue with this file
specifically. That means the real run's failure is almost certainly the
same `claimedGroups` race diagnosed for the bear/thistle cases -- except
here it manifests as a genuine COLLISION (other, wrong candidates still
exist) rather than a clean "no local match," so the existing
`noLocalMatchReasons` diagnostic (only ever populated on the
`#candidateGroups == 0` path) never got a chance to fire and explain it.

Fix: extracted the reason-building logic (previously inlined only for
the no-match case, including its own dedup-by-group-identity handling)
into a shared `describeClaimedAway(claimedAway)` helper. `pullAndMatch`'s
collision branch now also calls it and attaches the result as
`claimedAwayReason` on the `toResolveManually` cluster whenever a
candidate was excluded there too (both the "canceled before resolution"
and normal skip-path logging in `INatSyncRunner.run` append it to the
`unresolved_collision` log detail when present). So a collision that's
missing its obviously-correct candidate now says so explicitly, rather
than just showing whichever wrong candidates happen to remain.

Regression test: `mock_test_inatsync.lua` Case 12f -- an unrelated
observation claims the correct, already-tagged candidate first (same
"stealer" shape as Case 12e), but this time two OTHER untagged candidates
also genuinely fall within the target observation's window, so it lands
in `toResolveManually` instead of `noLocalMatchObservations`. Confirms
the cluster's own candidate list correctly omits the claimed photo while
still offering the two wrong ones, and that `claimedAwayReason` names both
the claimed filename and the specific claiming observation. (Building
this test surfaced its own arithmetic trap: the fixture's times need to
each independently land on a `:00` **second** boundary to get the wide
truncated tolerance -- an offset that's merely "a clean multiple of 60
seconds from another already-aligned time" isn't sufficient on its own if
a further +/-30s adjustment is then applied on top, since that shifts the
result off the boundary again.)

## Same-scientific-name widening: removed the time bound entirely (2026-07-24)

Follow-up investigation on #384538787's lousewort case: isolated reproduction
of just IMG_0680.JPG against the observation succeeded under four different
timezone assumptions, ruling out a per-photo Lightroom quirk with that
specific file. A fuller reproduction (adding the real squirrel group and
its own observation, including its unusual `-08:00` stated offset) also
failed to reproduce the miss. Rather than keep chasing an increasingly
elaborate reproduction without live Lightroom access to the actual
per-photo timezone assignment, the user's call: stop trying to widen the
tolerance to exactly the right amount, since there may not BE a single
right amount -- a camera/Lightroom timezone problem can put a genuinely
correct match arbitrarily far away in absolute time, with no reliable
bound to guess.

The key realization (explicitly the user's): the earlier objection to
"just match on scientific name" -- that a species seen twice breaks
date-based matching -- only bites when just ONE of the two sightings falls
inside whatever window is chosen, silently resolving to it. If the window
is wide enough that BOTH sightings always show up together, that's not a
silent wrong pick anymore, it's a normal collision the user resolves by
hand (exactly the design already in place for a real, live example: the
spittlebug case, #368726410, discussed the same session). So: remove the
time bound entirely, accept that the tradeoff is now "always a visible
collision instead of possibly no match at all," and let the user pick.

Changed `widenCandidatesByScientificName`: previously bounded by
`SAME_DAY_WIDENING_TOLERANCE_SECONDS` (86400s -- itself already a
replacement for an even earlier, buggier calendar-date-string comparison),
now checks only `not already a candidate` and `not already claimed` --
ANY already-tagged group sharing the observation's scientific name,
anywhere in the catalog's history, becomes a candidate once the primary
time window has found nothing. Still strictly a fallback (never runs when
the time window already found something), and `pairByScientificName`'s
existing `groupCountByName` uniqueness check (from the earlier
claimed-away work) already ensures multiple same-named candidates surface
as a genuine `toResolveManually` collision rather than a greedy wrong
pick -- no changes needed there, that safety net was already in place.

Regression tests: `mock_test_inatsync.lua` Cases 12a-12c needed
restructuring, since with no time bound at all, several fixtures that
previously used the SAME placeholder species name (relying on the 24-hour
window to keep them from interfering with each other) now collide with
one another for real. Gave Cases 12a/12b/12c their own distinct species
names ("Testudo timezoneus" / "Testudo ambiguous" / "Testudo distantus"),
and flipped Case 12c from a negative control ("different day must NOT
match") into its logical opposite ("10 days apart must STILL match, since
there's no longer any bound to fail on"). Case 12d (the midnight-crossing
fix) still passes but is now redundant with the design itself -- kept for
historical regression coverage since it costs nothing to leave in.

## Widening: reintroduced a (smaller) time bound -- 12 hours (2026-07-24)

Immediate walk-back of the "no bound at all" decision two sections above,
same conversation. Reconsidered: unbounded is more permissive than the
actual problem needs -- the confirmed clock-skew magnitudes seen live all
season were 2-6 hours, and an unbounded search risks a large, unwieldy
candidate list for any species photographed many times across the whole
catalog's history (not just within one trip). Reintroduced a bound,
renamed `WIDENING_TIME_TOLERANCE_SECONDS` (was
`SAME_DAY_WIDENING_TOLERANCE_SECONDS`, before that removed entirely) and
set to 12 hours -- comfortably covers every real case confirmed so far
while still being narrow enough that two genuinely unrelated sightings of
a common species on different days usually won't both qualify.

The core insight from the "no bound" discussion still stands and didn't
need reverting: the risk being traded away (multiple same-named
candidates) was already made safe by the EARLIER `pairByScientificName`
`groupCountByName` fix -- ambiguous cases surface as a normal collision for
manual resolution, never a silent wrong pick. Only the WIDTH of the
window changed, not the safety mechanism.

Regression tests: `mock_test_inatsync.lua` Case 12c flipped back to a
negative control (same species, 20 hours apart -- comfortably beyond the
12-hour window, not just at its boundary -- correctly stays unmatched),
renamed `photoClockSkewedFarApart`/`obsClockSkewedFarApart` back to
`...TooFar` to match. Cases 12a/12b/12d all still comfortably fit within
12 hours, unaffected.

## Untagged local photos are never match candidates at all (2026-07-24)

Explicit direction, same conversation: "there's no point suggesting
photos with no ID at all" -- in the actual workflow this plugin is built
around (DSLR photos: identify in Lightroom, THEN export to iNat), a local
photo is always tagged before the observation it becomes even exists, so
an untagged photo could never legitimately be a workflow match. (Species
might still get corrected by iNat's own identification process after
upload -- that's fine, already handled by the existing
`candidateDiffersFromLocal`/`needsSpeciesUpdate` machinery in applyMatch,
which doesn't require the tag to already match, just to exist.) Confirmed
as real, not hypothetical: several genuine collisions this session were
offering nothing but unrelated untagged photos as "candidates" that could
never have been correct, both cluttering the dialog and masking that the
real answer was simply missing.

Fix: `pullAndMatch`'s candidateGroups filter (already excluding claimed
groups) now also requires `g.scientificName` to be non-nil. Confirmed via
user decision (asked explicitly, given the scale of the change) that this
applies EVERYWHERE, not just to declutter collisions -- an untagged photo
that would otherwise be a clean, unambiguous, non-colliding match must
also be excluded, correctly landing in `noLocalMatchObservations` (still
recoverable via `Set iNat Observation`'s manual override) rather than
auto-applying. `pairByScientificName` (downstream of this filter) no
longer needs to handle an untagged group at all -- updated its doc
comment accordingly, left the function's own defensive `scientificName`
checks in place since they're harmless and this repo doesn't otherwise
strip proven-redundant guards from tested code.

This deliberately does NOT touch the separate sibling-absorption
mechanism in `applyMatch` (`untaggedSingletonsSortedByTime`,
`photosByFilename`) -- an untagged sibling of an ALREADY-matched group is
a different, still-valid case (a burst-shot companion never individually
run through identify), unrelated to whether an untagged photo can be the
PRIMARY match for an observation.

Regression tests required a substantial rework, not just new cases --
this retires the "historical backfill" scenario (matching a never-before-
tagged photo via time correlation as the normal, expected case) that many
existing fixtures across three test files modeled as ordinary. Went
through each:
- `mock_test_inatsync.lua`: tagged `photoMinuteTruncated`,
  `photoFrogUnrelated`, and `photoNearbyGenuine` (previously untagged,
  used to test TIME-tolerance exclusion specifically) -- left untagged,
  these would now be excluded by the new tag filter instead, silently
  making the tests pass without ever exercising the time logic they were
  built to guard. Repurposed Case 5 (`photoUntaggedA`/`photoUntaggedB`)
  from "untagged collision left for manual resolution" to "collision with
  only untagged candidates correctly reports no local match." Tagged
  `photoWrongA`/`photoWrongB` (Case 12f) with distinct species (rather
  than leaving them untagged) so that case still tests what it was built
  for -- a genuine collision between other real candidates missing its
  best one -- since untagged versions would just make the whole cluster
  disappear into `noLocalMatchObservations` instead. Added Case 12g: the
  most basic version of this fix -- a single untagged photo that would
  have been a clean, non-colliding match must still be excluded.
- `mock_test_syncfrominaturalist.lua`: tagged `photoA`/`photoB` with the
  SAME placeholder species name (ambiguous between them, matching
  neither observation's real taxon) so the manual-resolution-then-skip
  retry-list test still has a genuine ambiguity to skip, rather than
  reporting no local match before any dialog is ever reached.
- `mock_test_sync_merge_integration.lua`: tagged every "master" photo
  fixture across all cases (`photoMaster`, `photoMaster2`,
  `photoMaster4`, `photoMaster8`, `photoMaster9`) with `scientificName =
  "Allium cernuum"`, matching their own observations' taxon -- modeling
  the realistic post-fix shape (tagged before upload) for what these
  cases actually test (mismatch detection, the merge-candidates picker,
  the pending-mismatch list, the new-link confirmation dialog), none of
  which are actually about whether the INITIAL tag exists. Left the
  untagged "neighbor" sibling fixtures alone -- those are the separate,
  still-valid sibling-absorption case, not primary-match candidates.

## Removed "Accept All Remaining" from the new-link confirmation dialog (2026-07-24)

Explicit direction: not wanted. `confirmNewLink` (INatSyncRunner.lua) no
longer has an `otherVerb` -- just "Confirm" / "Skip For Now" -- so it can
only ever return `"confirmed"` or `"skipped"` now (the `"acceptAll"`
outcome is gone). Removed the `acceptAllRemainingNewLinks` run-level flag
and its guard in the apply loop entirely -- every first-time link gets
its own confirmation dialog, every run, with no way to bulk-skip the rest.
This is a deliberate asymmetry with the merge-candidates picker's own
"Skip All Remaining", which stays -- that escape hatch was never in
question here, only this one.

Regression test: `mock_test_sync_merge_integration.lua` Case 7b rewritten
-- previously confirmed one link via `"other"` and asserted the second
applied silently with no second dialog; now confirms both individually
via `"ok"` and asserts TWO separate confirmation dialogs fired (one per
first-time link), matching the new no-bulk-accept behavior.

## iNat thumbnail added to the collision/confirmation dialogs (2026-07-24)

Revisits the idea deferred earlier in this same session ("I'd like to
revisit your idea of including a thumbnail from iNat"). New
`INaturalist.downloadObservationThumbnail(observation)` downloads the
FIRST photo of an already-pulled observation (using the `url` field the
standard v1 pull already includes in `observation.photos` -- no extra API
call needed) to a local temp file via `LrPathUtils.getStandardFilePath("temp")`
+ plain `io.open(..., "wb")`. Not cached across runs -- a fresh one-shot
fetch each time a dialog needs it. Returns nil (never errors) if the
observation has no photos or the download fails for any reason, so the
caller can gracefully fall back to a text placeholder instead of blocking
the dialog.

`INatSyncRunner.lua`'s `buildINatThumbnail(f, observation)` wraps this:
downloads the photo and renders it via `f:picture { value = tempPath, ... }`
(150x150, matching the local candidate thumbnails' own size) -- LrView's
`picture` control takes a plain file path rather than a Lightroom photo
object the way `catalog_photo` does, since this isn't a catalog photo at
all. Falls back to a "(iNat photo unavailable)" static_text if the
download failed. Returns the view plus the temp file's path so the caller
can delete it once the dialog closes (`cleanupINatThumbnail`, a
pcall-wrapped `os.remove`) -- wired into both `resolveClusterManually`
(the collision dialog) and `confirmNewLink` (the new-link confirmation
dialog), placed next to the existing "View on iNat" button in each.

**Confirmed live**: the downloaded photo renders correctly via `LrView`'s
`picture` control in both dialogs -- the assumption held.

Regression tests: `mock_test_inatsync.lua` Cases 0b/0c/0d test
`downloadObservationThumbnail` directly -- a successful download writes
the exact fetched bytes to a real temp file (using a configurable
`standardFilePathOverride`, same pattern as other test files' real-temp-
dir cases), a failed HTTP request (mocked non-200 status) returns nil, and
an observation with no photos (empty list or missing field entirely)
returns nil. Confirmed no existing test needed changes -- every test
fixture's `makeObservation` helper omits `photos` entirely, so the new
code's very first guard clause (`not photo`) returns nil immediately with
no HTTP call attempted, in every existing case across all test files.

## Sync cursor now trails the run's start time by a 60-minute safety margin (2026-07-24)

The "cursor-orphaned observations" gap noted below as deferred turned out
to have a second, more direct trigger, caught live the same day: the user
uploaded 5 new observations directly to iNaturalist and ran "Sync from
iNaturalist" shortly after. The run completed with no errors but silently
skipped all 5 -- they never appeared in the full per-observation sync log
at all (not even as `no_local_match`), which meant `pullAndMatch` never
received them from the API pull in the first place.

Reconstructed the timeline from the stored cursor and a live API query:
the 5 observations' `updated_at` was `2026-07-24T17:33:13/14Z`; the sync
run captured its cursor as `syncStartTime = LrDate.currentTime()` at
`17:33:57Z`, ~43 seconds later. Querying the live API directly just now
with `updated_since` set well before that window returns all 5
observations correctly -- so the API itself and the query logic are both
fine. The likely explanation is that iNaturalist's search backend hadn't
finished indexing the 5 observations yet at the moment the sync's HTTP
request actually went out, so that request came back with zero matches
for them even though the previous cursor was well before their creation
time. The run then stored `syncStartTime` (17:33:57Z) as the new cursor
regardless of what the pull found -- and since that's now *later* than
the 5 observations' `updated_at`, every future incremental run would have
kept excluding them forever, with no diagnostic, because they'd never
reach any of `pullAndMatch`'s report buckets to be logged.

This is the same failure shape as the deferred item below, just with a
different (and more mundane) trigger than "an earlier run's cursor
advanced without applying" -- a plain read-after-write race between
"cursor captured" and "observation indexed." Fix: `INatSyncRunner.lua`
now subtracts a `SYNC_CURSOR_SAFETY_MARGIN_SECONDS` (60 minutes, per user
request) from `syncStartTime` before calling `INatSync.setLastSyncTime`,
so every incremental pull re-covers a trailing hour-long window rather
than advancing to the exact instant the run started. This is cheap to
re-scan: anything already linked hits `pullAndMatch`'s fast path (a
direct `iNatObservationId` match) almost for free, as already evidenced
by the hundreds of `linkedOnly` entries a full-history pull produces.

Immediate workaround for the already-orphaned 5 observations (and
anything else affected before this fix): run "Full Sync from
iNaturalist" once, which ignores the stored cursor entirely.

Regression test: `mock_test_syncfrominaturalist.lua` asserts that after a
normal run, `fakePrefs.lastINatSyncAt` equals `syncStartTime - 3600`, not
`syncStartTime` itself.

## Real root cause found: `LrDate.timeToW3CDate` omits the timezone designator, silently zeroing the incremental pull (2026-07-24)

The 60-minute margin above did NOT fix the live problem -- the user tried
again (waited 5 minutes, ran incremental sync) and it still found
nothing. Three incremental runs in a row (17:55, 17:58, 18:05 UTC) all
returned byte-identical results (the same 3 unrelated retry-list
observations, nothing else) despite using genuinely different cursor
values each time, while every equivalent query made from outside
Lightroom succeeded immediately. That pattern -- identical stale output
across different real requests -- didn't fit either of the theories
tried so far (backend indexing lag, CDN staleness), so rather than keep
guessing from outside, added a diagnostic trace: `getMyObservations` now
returns a second value (per-page request URL, result count, iNat's
reported `total_results`), threaded through `pullAndMatch`'s `report` and
into the full sync log (`writeFullSyncLog`'s `meta.pullDebug`).

The next live run's log line was the actual smoking gun:

```
[pull] page 1 -- 0 result(s) of 0 total -- https://api.inaturalist.org/v1/observations?...&updated_since=2026-07-24T17%3A04%3A48.013
```

Decoded: `updated_since=2026-07-24T17:04:48.013` -- **no timezone
designator at all**, just fractional seconds. `LrDate.timeToW3CDate`, on
this system, renders a near-"now" cocoa time without any trailing `Z` or
`±HH:MM`. Confirmed live via direct A/B curl requests against the real
API:

- `updated_since=2026-07-24T17:04:48.013` (designator-less, matching
  what the plugin actually sent) -> `total_results: 0`
- `updated_since=2026-07-24T17:04:48Z` (same instant, `Z` appended) ->
  `total_results: 9`, including the observations the user had just
  uploaded

Also confirmed the numeric hour/minute/second the SDK renders IS correct
UTC (the value matched true wall-clock UTC at the time, not shifted by
the system's actual -06:00 local offset) -- only the designator itself is
missing. And confirmed the failure is specific to *near-now* values, not
designator-less timestamps generally: an old designator-less date (weeks
in the past) still returned correct results (286), matching the theory
that the API defaults an ambiguous/unparseable-as-such timestamp to
something that happens not to matter when it's already far in the past,
but does matter when it's within the pull's normal near-now range.
iNaturalist's API never errors on this -- it just silently reports zero
matches, which is exactly why it read as "sync isn't picking up new
observations" rather than as an obvious bug.

This fully explains the whole day's saga, including the two earlier
(wrong, or at best incomplete) theories:
- **CDN caching** (`Cache-Control: public, max-age=300`, confirmed live
  as real and reproducible via a cache `HIT` on a repeat request) is a
  genuine property of this endpoint, but wasn't the actual cause here --
  a red herring surfaced while investigating, not the bug.
- **Backend indexing lag** (the original explanation offered for the
  first "5 new observations" report) was also a plausible-sounding but
  ultimately wrong theory -- the observations were fully queryable via
  `updated_since` the whole time, given a correctly-formatted parameter.
- The 60-minute cursor margin (previous section) remains a reasonable
  defense-in-depth measure and is being kept, but it was never going to
  fix this: the cursor value was fine, the *string format* sent to the
  API was the actual defect.

Fix: `INatSyncRunner.lua` no longer passes `LrDate.timeToW3CDate`'s
output to the API directly. A small `toUtcW3CDate(time)` wrapper checks
whether the string already ends in `Z` or a `±HH:MM` offset and appends
`Z` if not, guaranteeing a valid UTC designator regardless of what the
underlying SDK call does on a given system/version. Deliberately doesn't
try to explain or rely on any theory of *why* the SDK omits it --- just
makes the code correct regardless.

Regression test: `mock_test_syncfrominaturalist.lua`'s `LrDate.timeToW3CDate`
mock was changed to reproduce the real bug (renders the date/time with NO
designator, matching the live "...T17:04:48.013" shape) rather than its
previous hardcoded "...Z" stub, which would have masked exactly this
class of bug. A new assertion decodes the actual `updated_since` value
from the request URL the mocked run produced and confirms it ends in
`Z`. Verified the test is meaningful (not vacuously passing) by
temporarily reverting the fix and confirming the assertion fails with
the exact designator-less shape.

Also added `Cache-Control: no-cache` / `Pragma: no-cache` request headers
to the observations pull, as a cheap precaution given the confirmed CDN
layer -- not proven necessary for this specific bug, but harmless and
directionally correct for a correctness-critical incremental request.

The pull diagnostic trace (`meta.pullDebug` in the full sync log) is kept
permanently, not stripped back out -- this exact category of "sync did
nothing and left no clue why" is precisely what it exists to prevent
next time.

## Data Quality Assessment and unreviewed-suggestion tracking (2026-07-25)

Two new read-only, searchable metadata fields, both written/refreshed by
`INatSync.applyMatch` on every sync (not just first link), alongside the
existing `iNatObservationId`/`iNatObservationUrl`:

- `iNatQualityGrade` -- iNat's own `quality_grade` (`casual` / `needs_id`
  / `research`), copied straight through. No new API call needed --
  confirmed live it's already a plain top-level field on every observation
  the existing pull already fetches.
- `iNatSuggestedId` -- a short summary (e.g. `"escol suggests Florilinus
  (leading)"`) when someone OTHER than the account owner has a CURRENT
  identification naming a DIFFERENT taxon, dated after the owner's own
  most recent identification on that observation (or the owner never
  having identified it at all) -- i.e. a suggestion that's been sitting
  there unanswered. Blank once answered (not a stale flag -- it's
  recomputed fresh every sync from the current `identifications` array).
  Also no new API call -- the full `identifications` array (user, taxon,
  `current`, `category`, `created_at`) is already present in the standard
  pull, confirmed live against real observations that actually have this
  pattern (e.g. #381789507, where `escol` suggested `Florilinus` after the
  owner's own last identification).

Implementation: `describeUnrespondedSuggestion(observation, username)` in
INatSync.lua, right after `candidateDiffersFromLocal`. Deliberately
compares actual parsed instants via the existing `parseIsoTimestamp`
helper, not the raw `created_at` strings -- confirmed live that different
identifiers' timestamps carry different UTC offsets (`+05:30` vs
`-04:00` on the very same observation), which a lexicographic string
comparison can't reliably order. Distinct from the existing
`INaturalist.observationAgreesWithMe` (which only asks whether the
owner's OWN current identification, if any, agrees with the community) --
this instead looks at what OTHER identifiers have said since the owner
last weighed in, independent of the owner's own agreement status; it's
computed unconditionally in `applyMatch`, not gated behind the
`agrees`/`needsSpeciesUpdate` branching.

Both fields are persisted metadata rather than a one-off report (unlike
the mismatch HTML / pending-retry list, which are deliberately
report-only because they represent transient sync-process state) --
these instead describe a property of the observation itself, so the
intended workflow is a Smart Collection (e.g. "iNat Suggested ID is not
empty") to browse the queue directly in Lightroom, refreshed every time
the sync runs.

Regression tests added to `mock_test_inatsync.lua` (Cases 7e/7f/7g):
quality grade + an unreviewed suggestion get written when someone else's
current ID is both newer and different from the owner's; the flag clears
once the owner has responded more recently than the suggestion; an
identification that merely agrees with the owner's own current taxon is
never flagged, even if it's dated later.

## "Recover Missing Photos from iNaturalist" (2026-07-25)

Built the "orphan" recovery feature designed 2026-07-18 (see the removed
deferred-item note below it used to live under) plus a second, related
case surfaced in the same design conversation: an already-matched local
group that's missing SOME of its photos (already detected by the
existing mismatch check, tracked in `iNatPendingMismatchIds`, but never
actually fixed before now -- only reported).

Verified live during planning, before writing any code:
- iNat caps every stored photo at 2048px on the long edge regardless of
  upload source -- confirmed by downloading a real `original.jpg` and
  checking its actual pixel dimensions matched the API's own
  `original_dimensions`. A D7200 RAW original is ~15x more pixels; a
  12MP iPhone photo (the user's other real source, phone-app
  observations that were never local to begin with) ~4x. Accepted
  tradeoff, not a blocker -- the user wants the best available image now
  and will replace these with real files from Apple Photos in a
  separate, deliberately out-of-scope future pass once that workflow
  exists.
- `photos[].url` (already used by the thumbnail feature) is always the
  `square.jpg` thumbnail; iNat's storage uses a plain size-word-in-path
  convention, confirmed live by substituting to `original.jpg` and
  getting the full-size (capped) copy back.
- `observation.location` is a `"lat,lng"` string; `observation.obscured`
  flags a fuzzed location -- confirmed live against real observations in
  both states.
- No catalog-import mechanism existed anywhere in this codebase before
  this feature -- every prior write operated on photos already in the
  catalog. `catalog:addPhoto(filePath)` is genuinely new SDK surface for
  this project and is **not yet confirmed live** -- first real thing to
  test.

Destination: `~/Photos/import/RecoveredFromINat` (user's explicit choice
-- a labeled subfolder under the normal import root, not mixed into
date-based import folders, not under the plugin's own
`Photos/local/WhatIsThisThing` data directory). Filenames are generated
deterministically (`iNat_<observationId>_<photoId>.jpg`), not from iNat's
own `original_filename` -- already established elsewhere this session as
frequently a placeholder/unreliable value.

**Key design win, found during planning**: `INatSync.applyMatch` has no
hidden dependency on its `group` argument pre-existing -- a synthetic
`{ photos = importedPhotos }` group with nil `scientificName`/
`iNatObservationId` just makes it correctly treat everything as new.
So `INatRecovery.lua`'s own code only needed to (a) find candidates,
(b) download + `addPhoto` + write GPS, then (c) hand off to the already-
tested `applyMatch` for species/keywords/`iNatObservationId`/
`iNatObservationUrl`/`iNatQualityGrade`/`iNatSuggestedId` -- none of that
needed reimplementing. Similarly, a single
`INatSync.pullAndMatch(username, nil, {}, onProgress)` full-history pull
(exactly what "Full Sync from iNaturalist" already does) sources BOTH
candidate lists in one pass: `report.noLocalMatchObservations` directly
for the total-loss list, and `report.toApply` entries whose observation
id is in the durable `iNatPendingMismatchIds` list for the partial-loss
list (with `group.photos` being the real current local photos to absorb
into) -- no changes needed to `INatSync.lua`'s matching logic itself.

**New files**:
- `INaturalist.lua` -- added `downloadOriginalPhoto(photoUrl, destPath)`,
  substituting the URL's size segment to `original` and writing to a
  given (not temp) path, alongside a private `toOriginalSizeUrl` helper.
- `INatRecovery.lua` (new) -- `findCandidates`, `recoverTotalLoss`,
  `recoverPartialLoss`, mirroring the `INatSync.lua`/`INatSyncRunner.lua`
  logic-vs-orchestration split.
- `RecoverMissingPhotos.lua` (new) -- thin command entry point: pulls
  candidates under a progress scope, shows a confirmation dialog with
  exact counts *before any file is written or the catalog touched* (real
  downloads + catalog mutation are much harder to cheaply reverse than a
  metadata-only sync), then processes both lists under a second
  cancelable progress scope with the same per-item
  `LrTasks.pcall`-wrapped resilience used elsewhere, logging to
  `inat-recovery-log.txt` (same directory/append-only convention as the
  sync log).
- `MetadataDefinition.lua` -- added `iNatRecoveredPlaceholder` (enum,
  nil/"yes", same shape as `approximateLocation`), set only on photos
  this command actually imports -- the queue for the future
  higher-quality-replacement pass via a Smart Collection.
- `Info.lua` -- registered "Recover Missing Photos from iNaturalist".

**A known, accepted residual risk** (not live-verified, documented
in-code): `recoverPartialLoss` correlates `getObservationPhotoFilenames`
(v2, the only source of filenames) against `observation.photos` (v1, the
only source of download URLs) by ARRAY POSITION, since neither endpoint's
photo entries carry a field cross-referencing the other, and the v2
endpoint's authenticated fetch couldn't be scripted standalone outside
Lightroom to verify ordering live. Mitigated, not eliminated: only
proceeds when both lists are the same length, skipping (reported, not
guessed at) otherwise, to avoid risking a duplicate import under a
different synthetic filename. Recommend spot-checking a real multi-photo
partial-loss recovery before trusting a large batch.

Regression tests: new `mock_test_inatrecovery.lua` (10 cases) covering
the URL substitution + download, `recoverTotalLoss` (full success,
partial download failure, total failure), `recoverPartialLoss` (correct
absorption of just the missing photo, and the skip-on-unreliable-data
path), and `findCandidates`'s list-splitting. Full `lua5.4` syntax sweep
and the whole existing suite still pass.

## Recovery follow-up: added a limit field, and fixed a real live bug in partial-loss recovery (2026-07-25)

Two things came out of the user's first live test.

**Usability**: the confirmation dialog was all-or-nothing -- no way to
try a handful of observations first before trusting a full batch,
despite that being the explicit recommendation for `catalog:addPhoto`
(new SDK surface for this project). Added an optional "Limit to the
first N of each category" field to the confirmation dialog
(`RecoverMissingPhotos.lua`, via `LrView`/`LrBinding`, same pattern as
`promptForUsername`) -- blank means no limit (unchanged default
behavior), a number truncates both `candidates.totalLoss` and
`candidates.partialLoss` to their first N entries before the recovery
loop runs.

**Real bug, confirmed live**: total-loss recovery worked correctly, but
partial-loss did not -- the recovered photo downloaded fine but got
neither its local `observationId` nor any species tag, even though the
group's `iNatObservationId` link field WAS written. Root cause:
`INatSync.applyMatch`'s "does the species need updating" check
(`needsSpeciesUpdate`/`needsAncestryRepair`) only fires when ITS OWN
absorption logic (via `photosByFilename`, never passed by
`recoverPartialLoss`) found something, or the group's already-recorded
`scientificName` disagrees with iNat's current taxon. Since
`recoverPartialLoss` appends the newly-downloaded photo to `group.photos`
itself, BEFORE calling `applyMatch`, an already-correctly-tagged group
(the normal case -- the surviving photo was already properly identified)
looks completely unchanged to that check. `applyMatch` fell through to
plain `"linkedOnly"`, which only ever writes the unconditional link
fields (`iNatObservationId`/`iNatObservationUrl`/`iNatQualityGrade`/
`iNatSuggestedId`) -- `KeywordWriter.applyIdentification` (the only thing
that writes local `observationId` and species/keywords) was never
reached for the new photo at all.

Fix: `recoverPartialLoss` now calls `KeywordWriter.applyIdentification`
directly on the whole (now-updated) group immediately after appending
the recovered photo -- reusing the same `observationAgreesWithMe` gate
`applyMatch` itself uses, so a genuine disagreement is still respected --
before still calling `applyMatch` afterward for the link-field
writes/mismatch recheck. Safe/idempotent for the already-correctly-tagged
sibling(s) too: `applyIdentification`'s own `findExistingObservationId`
reuses their existing local `observationId` rather than minting a new
one, and `removeOldChildKeywords` no-ops the keyword re-add.
`recoverTotalLoss` doesn't have this problem -- every photo in that group
is brand new, so `group.scientificName` starts nil and reliably differs
from iNat's taxon, correctly triggering `needsSpeciesUpdate` on its own.

Regression test (`mock_test_inatrecovery.lua` Case 8b) needed real care
to actually exercise the bug, not just LOOK like it did: the first
version of the fixture gave the existing photo a species-name property
but no real nested ancestry keyword chain, which meant `applyMatch`'s
SEPARATE `needsAncestryRepair` branch fired instead and called
`applyIdentification` anyway -- masking the bug regardless of whether the
actual fix was present (confirmed by deliberately stripping the fix and
seeing the test still pass). Building a genuinely separate
`makeKeyword("Species ID", ...)` root to fix that made it worse in a
different way: `findParentKeyword` returns the FIRST "Species ID" keyword
in `catalog:getKeywords()` iteration order, which by Case 8 was already
the one earlier cases (4-7) had created via the real
`mockCatalog:createKeyword` reuse-by-name path -- a second,
separately-instantiated root object was invisible to it, so
`hasFullAncestry` still (correctly, for what was actually on the mock
catalog) reported incomplete ancestry. Fixed by reusing
`mockCatalog:createKeyword` itself for the fixture's keyword chain,
exactly as production code would, rather than hand-constructing keyword
objects. Verified the final test is meaningful (not vacuously passing)
the same way the sync-cursor tests were earlier in this project: stripped
the fix, confirmed the specific assertion failed with the exact bug
shape, then restored it.

## Recovery follow-up #2: recovered partial-loss observations kept reappearing (2026-07-25)

Confirmed live after a couple of real recovery runs: two observations
that had genuinely already been recovered (photos downloaded, absorbed,
species-tagged -- confirmed correct on disk) kept showing up again as
"missing some of their photos" candidates on every subsequent run,
forever.

Root cause, in two parts, both needed together:

1. `INatSync.applyMatch` does NOT clear the durable pending-mismatch list
   itself -- that's always been the CALLER's job. `INatSyncRunner.lua`'s
   own apply loop calls `INatSync.markMismatchOutcome(...)` based on
   applyMatch's returned `checkedMismatch`/`mismatch` fields; both
   `INatRecovery.recoverPartialLoss` and `recoverTotalLoss` were calling
   `applyMatch` and discarding its return value entirely, so a resolved
   mismatch never got removed from `iNatPendingMismatchIds` -- and,
   separately, a genuine leftover shortfall (e.g. from a partial download
   failure in `recoverTotalLoss`) never got ADDED to it either, silently
   vanishing from view rather than being retried later.
2. Even once the return value is captured, `recoverPartialLoss`'s call
   needed `forceRecheck = true` explicitly passed to `applyMatch` --
   without it, `shouldCheckMismatch` (`forceRecheck or not wasAlreadyLinked
   or ...`) evaluates to false for an already-linked group (which, by
   definition, every partial-loss candidate is), so `applyMatch` would
   skip the mismatch check entirely and `checkedMismatch` would always be
   false -- making part 1's fix silently inert for the exact case it was
   meant to fix. `recoverTotalLoss` doesn't need this: its synthetic
   `{ photos = imported }` group is never "already linked", so
   `shouldCheckMismatch` is naturally true there already.

Fix: both functions now capture `applyMatch`'s result and call
`INatSync.markMismatchOutcome(observation.id, result.mismatch ~= nil)`
when `result.checkedMismatch` is true; `recoverPartialLoss`'s call now
passes `forceRecheck = true` as the 6th argument.

Regression tests: `mock_test_inatrecovery.lua` Case 8c (recovering a
partial-loss observation clears it from `iNatPendingMismatchIds` once
resolved) and Case 6b (a genuine leftover shortfall from a partial
download failure in `recoverTotalLoss` gets ADDED to the list, not
silently dropped). Both needed real `v2FilenamesByObservationId` fixture
data configured for their observations -- without it, the mock's
`getObservationPhotoFilenames` returns an empty-but-non-nil filename
list, and `applyMatch`'s own `#iNatFilenames > #photos` mismatch
condition never fires regardless of what's under test, which would have
made these cases pass vacuously exactly like the Case 8b masking issue
above. Verified meaningful the same way: stripped both pieces of the fix
together, confirmed Case 6b failed with the exact "silently dropped"
shape, then restored it.

## Recovery follow-up #3: recovered photos had no capture timestamp (2026-07-25)

Confirmed live: recovered photos came in with no capture date at all.
iNat's downloaded copy is a re-processed/resized JPEG (see the 2048px-cap
note) and evidently doesn't reliably carry usable EXIF
`DateTimeOriginal` -- and even setting that aside, nothing in
`INatRecovery.lua` ever wrote a capture date to begin with, only GPS.

`dateTimeOriginal` itself is read-only via the SDK (EXIF-derived, not
settable by a plugin); the writable counterpart is `dateCreated`, which
per the SDK docs accepts a plain ISO 8601 string -- exactly the shape
`observation.time_observed_at` is already in, so no reformatting is
needed. Added `applyCaptureDate(photo, observation)` in `INatRecovery.lua`
(same file/pattern as the existing `applyLocation`), called alongside it
in `importOnePhoto`'s write transaction. **Not yet confirmed live** --
same caveat as `catalog:addPhoto` itself; verify a freshly-recovered
photo actually shows a capture date after this.

Regression test: `mock_test_inatrecovery.lua` Case 5 now also asserts
`dateCreated` was written from `observation.time_observed_at`.

Follow-up, same session: a field audit turned up two more available-but-
unused pieces of data, already present in the standard pull (confirmed
live, no extra API call needed) -- `photos[].attribution` (a ready-made
copyright string, e.g. `"(c) Gordon Krefting, some rights reserved (CC
BY-NC)"`) and `observation.place_guess` (a free-text location
description). Added `applyCopyright(photo, photoEntry)` writing
`attribution` to the `copyright` raw metadata field, same
transaction/pattern as `applyLocation`/`applyCaptureDate` -- recovered
photos otherwise carried zero copyright info at all, unlike a normal
camera import. `place_guess` deliberately NOT added -- it's a single
unstructured string, not clean city/state/country data, so mapping it
onto Lightroom's IPTC location fields would be loose at best; left for a
future ask rather than guessed at now.

Regression test: `mock_test_inatrecovery.lua` Case 5 now also asserts
`copyright` was written from the photo's `attribution` string.

## A plugin-shipped Metadata panel view preset (2026-07-26)

The user had been maintaining a personal, per-machine custom Metadata
panel preset ("Plant Book") to see this plugin's own fields together.
Confirmed via a real working example (mikeyk730's
Lightroom-CR2-White-Balance plugin) that the SDK has a dedicated,
documented mechanism for this that ships WITH the plugin instead --
`LrMetadataTagsetFactory` in `Info.lua`, a sibling declaration to
`LrMetadataProvider`, pointing at a file that returns a single tagset
table (`id`, `title`, `items`). It appears in the same Metadata panel
dropdown as Default/EXIF/IPTC/etc. and any personal custom presets, but
is available automatically to anyone with the plugin installed -- no
per-machine setup, lives in source control with everything else.

Added `MetadataTagsetFactory.lua`, registered via
`LrMetadataTagsetFactory = "MetadataTagsetFactory.lua"` in `Info.lua`.
Titled "What is this Thing?" (matching `LrPluginName`, per the user's
request). Groups all 16 of this plugin's custom fields (from
`MetadataDefinition.lua`) into four labeled sections -- Identification,
Species Info, iNaturalist Link, Grouping & Flags -- via
`{ 'com.adobe.label', label = "..." }` pseudo-field entries (also
confirmed via the same real example), plus `com.adobe.filename` at the
top for context while reviewing. Custom field ids in `items` must be
fully qualified with this plugin's own `LrToolkitIdentifier`
("org.krefting.whatisthisthing.<fieldId>") -- confirmed via the same
example, which uses this exact form for its own fields -- hardcoded as
literal strings rather than built from `_PLUGIN.id`, since a
tagset-factory file's execution context isn't necessarily the same as a
command file's.

**Not yet confirmed live** -- first thing to check: does "What is this
Thing?" actually appear in the Metadata panel's dropdown, correctly
grouped and labeled. No meaningful way to unit-test this (pure static
declarative data, no logic) -- verified via `lua5.4 -e` dumping the
returned table and eyeballing the structure instead.

Follow-up, same session: added a "Photo" section at the top with 10
built-in fields (filename, folder, capture date, GPS, cropped/original
dimensions, title, caption, rating, copyright), fetched from the SDK's
own predefined-field list rather than guessed. Three naming decisions
worth remembering:
- `dateCreated`, not `dateTimeOriginal` -- the latter is read-only,
  EXIF-derived, and confirmed live to show blank on recovered photos
  (see the capture-timestamp fix above); `dateCreated` is the field this
  plugin actually writes and is guaranteed populated either way.
- No true "file path" field exists in the SDK's field list -- `folder`
  (the containing folder's NAME only, not a full path) is the closest
  available.
- IPTC has one Caption/Description field, exposed as `caption` -- there's
  no separate "description" field to add.

## "Move Flora & Fauna Pics": built, then abandoned as fundamentally unworkable (2026-07-26)

Goal: speed up graduating photos out of `~/Photos/import` into their
permanent, dated home across `~/Photos/local` and
`/Volumes/Photo Archive/archive` (both separately backed up by
`~/bin/manage_photo_backups.rb`). Originally scoped as a fully automatic
move; research confirmed the Lightroom Classic plugin SDK has no way to
move an already-cataloged photo's file while preserving its catalog
record at all (no `photo:move()`, no writable `path`, no
`photo:delete()` -- confirmed against Adobe's own feature-request
thread, where a well-known plugin author notes this has been requested
for years and never addressed). Scoped down instead to a safer hybrid:
compute the correct destination folder from capture date + a flora/
fauna/local/archive choice, create it on disk, and best-effort switch
Lightroom's Library view to it -- leaving the actual move as a manual
drag in Lightroom's own Folders panel, which preserves everything
perfectly but isn't plugin-accessible.

Built (`MoveFloraFaunaPics.lua`), then hit a sequence of live bugs while
testing, each fixed in turn: `dateCreated` turned out to be a write-only
raw-metadata key (`getRawMetadata` needed `dateTimeOriginal` instead);
`photo:getRawMetadata` and `catalog:getFolderByPath` both need
`LrTasks.pcall`, not plain `pcall`, to cross Lightroom's yield boundary
(the same bug class this project has hit and documented several times
before -- worth remembering yet again: **default to `LrTasks.pcall` for
any Lightroom SDK call wrapped in error-handling, not plain `pcall`,
unless there's a specific reason the call can't yield**).

**Then hit the wall that killed the feature**: even after all of the
above was fixed, the created folder never appeared in Lightroom's
Folders panel at all -- confirmed live, not a theory. Neither
"Synchronize Folder..." nor restarting Lightroom made it appear. Pulled
the complete `LrCatalog` method list from the SDK reference (every
method on the class, not a summary) and confirmed there is no
`createFolder` or any folder-creation capability whatsoever -- only
read-only lookups (`getFolderByPath`, `getFolders`). The actual
conclusion: **Lightroom's Folders panel appears to only show folders
that already contain at least one cataloged photo** -- a folder created
purely on disk, by any means, stays invisible no matter how it's
rescanned. The only thing that reliably creates a folder Lightroom
immediately shows is Lightroom's own native "Create Folder Inside..."
action, which isn't exposed to plugins either. This is a genuine
chicken-and-egg problem with no SDK-level way out: a plugin can't make
an empty destination folder visible for a drag-and-drop that needs it to
already be visible.

Presented this to the user as a real fork -- reduce the feature to "we
tell you the exact folder name to manually create via Lightroom's own
'Create Folder Inside...'" (real automation value shrinks to just
avoiding the mental math/typos), or drop it. **Decision: dropped
entirely.** `MoveFloraFaunaPics.lua` deleted, its `Info.lua` menu entry
removed, its scratch test discarded. Kept as one consolidated writeup
(collapsing what were four separate dated entries during active
development) specifically so the core finding survives for next time:
**don't build anything in this plugin that depends on a plugin-created,
not-yet-photo-containing folder becoming visible/selectable in
Lightroom's UI -- it won't, and there's no known workaround.**

## "Merge Observation" no longer depends on click order (2026-07-27)

`MergeObservation.lua` used to pick its "master" identification via
Lightroom's own `catalog:getTargetPhoto()` ("most selected" photo --
confirmed live 2026-07-23 to be whichever photo you click FIRST, not
last). Fragile in practice: easy to click the wrong photo first, and if
more than one selected photo was already identified, whichever got
clicked first silently won with no chance to notice a mistake.

Redesigned to group selected photos by their existing local Observation
ID (not scientificName alone -- two genuinely separate already-linked
observations could coincidentally share a species name; grouping by
Observation ID keeps them correctly distinct, the same split-detection
concept `SetCultivar.lua`'s `expandToObservationGroup` already uses).
Zero distinct groups: clear error, same as before conceptually. Exactly
one: merges immediately, no dialog -- this is now the common case (one
already-identified photo plus untagged siblings) and needed zero
friction. More than one: a radio-button dialog (same pattern as
`CandidatePicker.lua`/`INatSyncRunner.lua`) lists each distinct
identification with its photo count and asks explicitly which one
should win, rather than leaving it to click order.

Scope stayed contained to this one file: the shared `ObservationMerge.merge(master,
others)` function didn't need to change at all (it already just takes
an explicit master), and the other caller (`MergeCandidatesDialog.lua`,
used by the sync mismatch-resolution flow) already passes an explicit
master from its own context and never relied on click order either.
Also fixed a stale comment referencing a "SuggestMergeCandidates.lua"
that doesn't exist (renamed to `MergeCandidatesDialog.lua` at some
point without updating the comment).

Regression tests: `mock_test_mergeobservation.lua` rewritten for the new
behavior -- single-identification auto-merge with no dialog, zero-
identification error, multiple-identification dialog with an honored
explicit choice (including correcting the NON-chosen already-identified
photo to match, not just the untagged ones), same-species-different-
Observation-ID still treated as distinct candidates (confirms the
grouping key is Observation ID, not scientificName), and a canceled
dialog writing nothing.

## Diagnosed a real "no_local_match" case, found an iNat data-quality bug, and closed a diagnostic gap (2026-07-27)

The user asked why observation #385810257 (Uroleucon obscuricaudatum,
created ~2 hours earlier from an export/upload of DSC_2483.NEF) wasn't
linked after two sync runs. The full per-observation sync log confirmed
it as a genuine `no_local_match` (not a pull/cursor issue -- it was
present in the pull both times), with no `claimedAwayReason` detail at
all.

Direct investigation (SQLite against the live `.lrcat`, confirming the
established `AgSearchablePhotoProperty`/`AgPhotoPropertySpec` join
pattern from much earlier in this project; `exiftool` against the
actual NEF file) found the real cause: **iNat's own `time_observed_at`
for this observation carries an internal inconsistency**. Its embedded
offset is `-04:00` (`America/New_York` daylight time), but the
observation's own separately-reported `time_zone_offset` field says
`-05:00` -- and `-05:00` is also what the camera's own GPS-verified
capture instant actually confirms (`GPS Date/Time: 2026:07:27
21:25:21Z` vs. local `16:25:21` -- exactly 5 hours, i.e. true `-05:00`).
iNat's `time_observed_at`, taken at face value, is thus **1h 21s off**
from the true capture instant -- comfortably enough to blow the
matching algorithm's normal tight/truncated tolerances, though nowhere
near the 12-hour scientific-name widening fallback that exists
specifically to rescue clock-skew cases like this.

That raised the real question: why didn't the 12-hour widening rescue
a 1h21s gap? Investigating further would need the actual live-computed
`targetTime` and the local group's own `g.time` (Lightroom's per-photo
timezone assignment for the NEF, which -- per this project's own
long-established finding -- is not knowable from outside a live
Lightroom process). Rather than guess further, closed the actual gap
that made this undiagnosable in the first place:
`widenCandidatesByScientificName` now returns a third, diagnostic-only
value -- the closest same-scientific-name local group that was found
but fell outside even the widened tolerance, if any -- and
`pullAndMatch` surfaces it via a new `describeClosestMiss` helper
whenever `describeClaimedAway` has nothing to say. A future
`no_local_match` log line for a case like this will now read something
like `closest same-species local match (DSC_2483.NEF) is 1h 21m away,
outside the 12h widening tolerance` instead of giving no clue whether
a same-named local group even exists. Next actual sync run will reveal
the true live delta and settle whether this specific case needed a
wider tolerance or was hitting something else entirely.

Regression test: `mock_test_inatsync.lua` Case 12c (already covering
"same scientific name but 20 hours apart, correctly stays unmatched")
extended to also assert the new diagnostic names the closest local
match and the tolerance it fell outside of, rather than just checking
the observation landed in `noLocalMatchObservations` with no further
detail. Full existing suite re-run to confirm the added third return
value on `widenCandidatesByScientificName` didn't disturb any existing
caller.

**Follow-up, same session**: the user's third sync run pulled only 1
observation, and it wasn't #385810257 -- confirming this is actually the
already-documented "cursor-orphaned observations" gap (see the entry
above from 2026-07-24), not a new issue: the incremental cursor had
advanced past this observation's own `updated_at` (nothing tracks a
`no_local_match` outcome for retry, unlike mismatches or apply-
failures), so it had simply stopped being pulled at all. "Full Sync from
iNaturalist" is the correct fix -- not because full vs. incremental
changes the matching logic, but because Full Sync ignores the cursor
entirely and is the only way to force a re-pull right now.

## Fixed a stuck-progress-bar crash-safety gap in "Recover Missing Photos" (2026-07-27)

While investigating the above, the user separately reported Lightroom's
dock icon and in-app progress indicator staying stuck after running
recovery. Traced to `RecoverMissingPhotos.lua` not having the same
outer-`LrTasks.pcall`-around-the-whole-loop hardening
`INatSyncRunner.lua` already has (see its own comment: "wrapped in one
outer pcall so that ANY unexpected error partway through... still
reaches progressScope:done()"). The per-item recovery calls inside the
loop were already individually `LrTasks.pcall`-wrapped, but several
un-guarded calls surrounded them (`workScope:isCanceled()`,
`:setCaption()`, `:setPortionComplete()`, `recoveryDestDir()`) -- any
unexpected error among those would leave `workScope` permanently open,
with no way to close it from outside Lightroom short of a restart.

Fixed by mirroring `INatSyncRunner.lua`'s exact pattern: `workScope` is
now created BEFORE an outer `LrTasks.pcall` wraps the whole two-loop
body, and `workScope:done()` is called unconditionally right after,
regardless of success. On failure, shows a clear error (matching
`INatSyncRunner.lua`'s own wording) instead of the normal summary --
and, as a small improvement beyond what `INatSyncRunner.lua` does,
still writes whatever `runLog` accumulated before the crash to
`inat-recovery-log.txt`, since a partial run did real work worth a
record, not just the happy path.

Not covered by a new dedicated test -- the fix mirrors an already-
proven, already-tested pattern (`INatSyncRunner.lua`'s identical
hardening has its own passing "progressScope:done() still fires after
an uncaught error mid-run" test in `mock_test_syncfrominaturalist.lua`),
and building an equivalent mock harness for this file's much deeper
`INatRecovery`/`INatSync`/`INaturalist` dofile chain would be
substantial new scaffolding for a narrow, mechanical, structurally
low-risk change. Verified via the full existing suite (no regressions)
and careful manual re-reading of the restructured control flow instead.
**Practical note for the user**: if a stuck progress bar is ever seen
again after this fix, it likely means a genuinely new, not-yet-hardened
code path -- worth reporting rather than assuming it'll clear itself.

## Recovered photos now get real embedded EXIF, not just `dateCreated` (2026-07-28)

Follow-on from Recovery follow-up #3 above. `dateCreated` makes
Lightroom's own metadata panel show a capture date, but it's an SDK-level
field, not real EXIF -- the file itself still has no
`DateTimeOriginal`/`DateTimeDigitized`, the same two fields explained to
the user earlier this session (the third, `DateTime`/`ModifyDate`, means
"last modified," not capture time, and is deliberately left alone).

Since `dateTimeOriginal` is read-only via the SDK (confirmed earlier
session), the only way to get a *real* one onto a recovered photo is to
write it into the file on disk before `catalog:addPhoto` ever reads it.
Added `applyEmbeddedExif(destPath, observation)` in `INatRecovery.lua`,
called in `importOnePhoto` right after download and before the
`catalog:withWriteAccessDo` transaction (it's a blocking external-process
call on a file not yet in the catalog -- no business holding a catalog
write transaction open for it). Reformats
`observation.time_observed_at`'s local-clock digits into EXIF's own
`YYYY:MM:DD HH:MM:SS` shape and writes both `DateTimeOriginal` and
`CreateDate` (exiftool's alias for `DateTimeDigitized`) plus their
`OffsetTimeOriginal`/`OffsetTimeDigitized` companions (EXIF 2.31, holds
the embedded offset, e.g. `-04:00`) via `exiftool -overwrite_original`,
shelled out through `LrTasks.execute`.

Reused `UpdateLocationFromGpx.lua`/`geotag_from_gpx.py`'s own hard-won
fix for a real gotcha discovered building that feature: GUI-launched
apps like Lightroom don't inherit an interactive shell's PATH, so a bare
`exiftool` lookup fails even when it's on the user's normal PATH. Same
explicit-candidate-path fallback (`/opt/homebrew/bin/exiftool`,
`/usr/local/bin/exiftool`), just reimplemented directly in Lua this time
(`findExiftool()`) rather than delegating to a Python helper -- this
write is a single fixed-shape exiftool call with no parsing/glob/regex
work to justify Python's convenience the way the GPX script's more
involved logic did. Uses `-overwrite_original` (unlike the GPX pass,
which deliberately keeps an `_original` backup of irreplaceable camera
files) since these are disposable placeholder copies to begin with -- a
backup file here would just be clutter.

`applyCaptureDate` (the existing `dateCreated` write) is kept as-is, now
explicitly a belt-and-suspenders fallback: still fires even on a machine
without exiftool, or if the exiftool write silently no-ops for any
reason.

**Not yet confirmed live** -- same caveat as `catalog:addPhoto` and the
original `applyCaptureDate` addition. First real verification: run
recovery on a machine with exiftool actually installed at one of the two
checked paths, then check both `exiftool` on the resulting file directly
and Lightroom's own metadata panel (`Date Time Original`/`Date Time
Digitized` should now show real values, not just blank/derived-from-
dateCreated).

Regression tests added to `mock_test_inatrecovery.lua` (Cases 5b/5c):
mocks `LrFileUtils.exists` to control whether the fake exiftool path is
"found," and `LrTasks.execute` to capture the invoked command string.
Case 5b asserts the full command shape when exiftool is found (both
date fields, both offset fields, `-overwrite_original`, and explicitly
*not* touching `-ModifyDate`); Case 5c asserts recovery still succeeds
via the `dateCreated` fallback (no crash, no exiftool call at all) when
exiftool isn't found at either candidate path.

Confirmed live same day: a real recovery run produced a file with
correct `DateTimeOriginal`/`CreateDate`/`Offset*` values (checked
directly with `exiftool`).

**One-off backfill, same day**: the 163 photos already recovered before
this fix existed had no real EXIF timestamp at all. Rather than adding
plugin code for a single retroactive pass, queried the catalog directly
(`iNatRecoveredPlaceholder = 'yes'`) for their file paths + linked
`iNatObservationId`s, batch-fetched `time_observed_at` for the 148
unique observations from the iNat API, and ran the exact same exiftool
write (scripted in Python, scratch/throwaway, not added to the plugin)
against each file directly. All 163 updated, 0 skipped, 0 failed.

## Consolidated Sync + Recover Missing Photos into one command, and added a "Needs Attention" report (2026-07-29)

First of five improvement areas scoped this session (the other four:
graceful degradation when the external archive drive isn't mounted,
consolidating the Identify processes, this same logging/reporting work
already folded in below, and trimming the one-off diagnostics). Reached
through an extensive design conversation, not assumed up front -- see the
plan file this session used
(`~/.claude/plans/drifting-wobbling-sutton.md` at the time) for the full
back-and-forth if it's still around.

**What changed, user-facing**: "Sync from iNaturalist," "Full Sync from
iNaturalist," and "Recover Missing Photos from iNaturalist" (3 menu
entries) are now just "Sync from iNaturalist" (1 entry). Running it opens
a small pre-flight dialog asking Full vs. Incremental (replacing "which
menu item did you click" as how that choice got made). Recovering a
photo with no local copy is no longer a separate later command -- it's
offered inline, per observation, the moment sync notices it's missing,
as a plain yes/no ("Download iNat's own copy(s)?"), same one-decision-
at-a-time philosophy as the existing first-time-link confirmation (no
bulk-accept). Declining does nothing further -- no nagging -- but the
observation is retry-listed so it comes back up next run rather than
silently vanishing behind the incremental cursor.

**Design, verified against the real code rather than assumed**:

- Sync vs. Full Sync turned out to differ by exactly one boolean
  (`forceFullPull`) -- trivial to collapse into a dialog choice on one
  entry point.
- Recovery was more independent than it should have been: it ran its own
  separate full pull (`INatRecovery.findCandidates` called
  `INatSync.pullAndMatch` directly, redundant with whatever Sync just
  did), and its log-writer/crash-hardening were hand-duplicated from
  `INatSyncRunner.lua` -- concretely proven costly already, since the
  stuck-progress-bar crash-safety bug (2026-07-27, above) had to be
  diagnosed and fixed twice, once per file.
- `INatSync.lua`'s own mismatch check already has a deliberate asymmetry
  from an earlier session: only "iNat has a photo missing locally" is
  ever reported, never the reverse. That meant two seemingly separate
  cases -- an already-linked group missing *some* iNat photos ("partial
  loss") and a photo-count "mismatch" on a linked group -- are the same
  underlying signal, just differing in remedy (merge in an
  existing-but-unlinked local photo vs. download a placeholder because no
  local original exists). Both are now handled by one code path: try the
  existing nearby-candidate merge search first (`MergeCandidatesDialog`,
  unchanged), and only if that finds nothing, fall through to the new
  inline download offer.
- The existing `describeClosestMiss`/`describeClaimedAway` diagnostics
  (2026-07-27, above) turned out to already be exactly the signal needed
  to distinguish "confidently nothing local exists" (safe to offer a
  download) from "matching was uncertain" (a real local candidate might
  exist, just mis-correlated -- e.g. the #385810257 timezone case) --
  `INatSync.pullAndMatch`'s `noLocalMatchReasons[obs.id]` being present
  vs. nil already encodes this correctly. No `INatSync.lua` changes were
  needed at all for this part; the plan had assumed a new structured
  field would be required, but re-reading the actual code during
  implementation found the existing data already sufficient -- worth
  remembering as a case where checking the real code first avoided
  unnecessary rework.
- For the uncertain case, added a new "couldn't find a good local
  candidate" notice -- reuses the existing `buildINatThumbnail` helper,
  shows the observation's iNat photo, and requires only a single "OK" to
  dismiss (no decision to make -- there's nothing concrete to compare
  against). Retry-listed and logged either way. Expected to be rare now
  that legacy-observation matching is mostly caught up (per the user);
  revisit per-item-vs-aggregate notice style if that turns out wrong.
- `RebuildMismatchList.lua` (an explicitly one-time migration tool, see
  its own comment) depended on a `forceRecheckAll` option that only it
  ever passed -- removed along with the option itself once its only
  caller was gone, rather than leaving dead code behind.

**The "Needs Attention" report**: generalizes the old `writeMismatchLog`
(HTML, overwritten each run, clickable "View on iNat" links -- previously
scoped to just filename mismatches) into one report covering every
deferred outcome from the consolidated run: unresolved ambiguous
collisions, declined/failed downloads, the new no-good-candidate notices,
and filename mismatches. Auto-opens in the browser
(`LrHttp.openUrlInBrowser("file://" .. path)`) whenever it's non-empty
after a run -- no separate click needed to notice something's pending.
Thumbnails link directly to iNat's own hosted photo URL
(`observation.photos[1].url`, confirmed already the "square" size with
zero substitution needed) rather than being downloaded/embedded by the
plugin -- loaded by the browser when the report is viewed. Confirmed the
report reflects the FULL CURRENT retry-list state (not just this run's
deltas) essentially for free: every id on the retry list is already
force-included in every run's pull (`pullIds` in `INatSyncRunner.run`),
so anything still pending from a prior run gets re-attempted this run too
and, if still unresolved, lands back in the same report -- no separate
"read persisted state" step was needed.

The old plain-text `inat-sync-log.txt` (append-only, every observation
every run, for historical debugging) is unchanged in role, just extended
to cover the new outcome types (`recovered_total_loss`,
`recovered_partial_loss`, `declined_download`, `download_failed`,
`no_good_candidate`).

**Testing**: `INatRecovery.lua`'s `recoverTotalLoss`/`recoverPartialLoss`
didn't change at all (still covered by the existing
`mock_test_inatrecovery.lua`, minus its old `findCandidates` test case,
removed along with the function). `INatSyncRunner.lua`'s own
orchestration got a substantial new mock test
(`mock_test_inatsyncrunner.lua`, scratch, dispatches
`LrDialogs.presentModalDialog` by dialog title since one run now shows
several different dialogs in sequence) covering: the pre-flight dialog
appearing/being skippable; a confident no-local-match download offer
being accepted (imports) and declined (retry-listed, reported, nothing
downloaded); an uncertain (`closestMiss`) case never offering a download
and always showing the notice instead; the partial-loss inline download
fallback when the merge-candidates search finds nothing nearby, both
accepted and declined; and the report/browser-auto-open behavior firing
exactly when something's pending, never otherwise. Full `lua5.4` syntax
sweep across all remaining plugin files passes.

**Live-testing follow-up, same day**: ran a real Full Sync. Found one
genuine bug and several worthwhile UI refinements.

- **Real bug: a closestMiss 64+ hours away was wrongly routed to the
  "no good candidate" notice instead of confidently offering a
  download.** Live case: observation #386159770, a genuinely new photo
  with zero local copy, got flagged uncertain purely because a same-
  species photo existed in the catalog from 64 hours earlier -- an
  unrelated, coincidental sighting, not a clock-skew mis-correlation of
  the SAME photo (every real timezone/clock-skew case actually
  investigated this session was at most a few hours). The bucket 3/4
  split had been gating on "does `noLocalMatchReasons[obs.id]` exist at
  all," with no regard for HOW far away a `closestMiss` actually was.
  Fixed by adding `CLOSEST_MISS_STILL_UNCERTAIN_SECONDS` (24h) in
  `INatSync.lua` and a new `noLocalMatchUncertain` signal returned
  alongside `noLocalMatchReasons` from `pullAndMatch` -- a `claimedAway`
  reason is always uncertain (a real, in-tolerance candidate exists right
  now, just claimed elsewhere this run), but a `closestMiss` reason is
  only uncertain when its gap is within the new threshold; beyond that
  it's treated as confidently empty, same as no closestMiss at all.
  Deliberately kept `noLocalMatchReasons[obs.id]` a plain string (not
  restructured into a table) specifically so the existing
  `mock_test_inatsync.lua` assertions (`reason:find(...)`) didn't need
  touching -- the new signal is a parallel table, not a reshaping of the
  old one. Added `mock_test_inatsyncrunner.lua` Case 7 directly
  reproducing this exact live scenario (a 65-hour closestMiss must
  confidently offer the download, not show the notice) -- regression-
  proofed, not just fixed and forgotten.
- **All of an observation's iNat photos, not just the first, now show in
  the "Recover Missing Photo" and "Confirm New iNaturalist Link"
  dialogs** -- both previously showed only `photos[1]` via
  `buildINatThumbnail`/`downloadObservationThumbnail`. Added
  `INaturalist.downloadAllObservationThumbnails` (refactored the download
  mechanics into a shared private `downloadPhotoThumbnail`, reused by both
  the single- and all-photos paths) and `buildAllINatThumbnails` in
  `INatSyncRunner.lua`. Cheap to do -- these are already-small "square"
  thumbnails, not full downloads.
- **"Confirm New iNat Link" renamed to "Confirm New iNaturalist Link,"
  and reworded**: was "Link this photo to #386368622..." -- but the
  action links a local OBSERVATION (a group of one or more photos) to an
  iNat observation, not "a photo" to anything. Now: "Link your local
  observation to iNat observation #386368622...".
  - This ALSO happened to fix a real, separately-reported truncation
    bug: the per-group caption under the local thumbnails was
    `describeCandidateGroups`'s filename-list-plus-"(currently tagged:
    X)" string, squeezed into `buildCandidateColumn`'s 22-char-wide
    caption -- confirmed live cutting off mid-string ("DSC_0532.NEF
    (currently tagged:" with nothing after it, and a 4-photo group's
    filename list truncating before ever reaching the species name).
    Replaced with a new, purpose-built, full-width
    `describeLocalIdentification(group)` ("Locally identified as: X" or
    "Not yet identified locally.") -- the actual filenames aren't the
    useful part of this decision, whether/how the local observation is
    already identified is. `describeCandidateGroups` itself is
    unchanged and still used as-is by `resolveClusterManually`, where
    seeing each candidate's specific filenames + existing tag side by
    side genuinely is the useful comparison.

**Second live-testing follow-up, same day**: user asked whether there was
any downside to deleting a few just-recovered photos and re-running sync,
to exercise the recovery path again. While checking, found (and fixed) a
related small gap: a successful `recoverTotalLoss` never called
`INatSync.markRetryOutcome(obs.id, true)` -- every OTHER successful-apply
path in this file already clears a prior retry-list entry unconditionally
on success (confirmed by re-reading: the normal apply loop's own
`markRetryOutcome(..., true)` call fires right after `applyOk`, before its
mismatch-handling branch even runs, so the existing partial-loss recovery
path was already covered by that -- only the newer total-loss download
path, entirely its own branch, had been missing the equivalent call).
Harmless in practice (a stale retry-list entry just means one extra
observation gets force-re-pulled on future runs, no correctness impact,
since a recovered observation now has `iNatObservationId` set and hits the
fast path immediately) but worth fixing rather than leaving inconsistent
with the rest of the file. Added `mock_test_inatsyncrunner.lua` Case 4b,
seeding a fake prior retry-list entry before a successful recovery and
confirming it's cleared afterward.

## iNat thumbnail quality fix, and a new "iNaturalist Data Changed" notice for already-linked observations (2026-07-30)

**Thumbnail quality**: confirmed live against a real photo that the
default `photo.url` field (used for every dialog thumbnail) is iNat's
smallest "square" size (75x75px), badly upscaled to fill the dialogs'
150x150 display box. iNat's "small" size (240x240px) is only ~5x the file
size (51KB vs 10KB in the real test) and comfortably covers the display
size with no upscaling. Generalized the existing `toOriginalSizeUrl`
helper into `toSizeUrl(url, size)` (same substitution mechanism, now
parameterized) and switched `downloadPhotoThumbnail` to request "small"
instead of the raw default.

**"iNaturalist Data Changed" notice**: the user recalled intending (but,
per a confirmed pattern of lost input this session, apparently never
actually managing to say) that a sync should show a dialog for ANY
already-linked observation's data changing, not just for connecting new
observations. Built as a *purely informational* notice, deliberately with
no decline option -- per the user: "If the observations are correctly
matched... there would be no reason to decline." This is a real
simplification over a first draft of the design that would have gated the
write behind confirmation: since matching is already established by the
time this fires, the change just gets applied and the dialog is a
same-run FYI, not a gate.

- **`INatSync.lua`**: `applyMatch` now returns a `changes` list (e.g.
  `"Quality grade: needs_id -> research"`) -- a plain diff of
  scientificName/commonName/rank, `iNatQualityGrade`, and
  `iNatSuggestedId` against what's currently stored, computed BEFORE the
  write so old values are still readable. Always empty for a first-time
  link (`wasAlreadyLinked` false) -- that moment already gets its own
  dedicated review via `confirmNewLink`, so showing this too would be
  redundant.
- **`INatSyncRunner.lua`**: new `showFieldChangeNotice` (thumbnails +
  change list + "OK", reusing `buildAllINatThumbnails`), shown right
  after a successful apply whenever `result.changes` is non-empty. Added
  a "Skip All Remaining" escape hatch (own flag,
  `skipAllRemainingFieldChangeNotices`, independent of the mismatch
  picker's own skip-all) specifically because quality-grade transitions
  ("needs_id" -> "research") happen routinely as community IDs
  accumulate -- a Full Sync could plausibly surface this for dozens of
  already-linked observations at once, and unlike `confirmNewLink`
  (deliberately no bulk-accept, since first-time links are rarer and
  higher-stakes), this is routine churn with no decision being made at
  all. Skip-all only mutes the DIALOG -- changes keep applying silently
  either way, confirmed by a dedicated test.
- No retry-list or Needs Attention report involvement at all -- there's
  no "declined" state for this notice to produce.

**Testing**: `mock_test_inatsync.lua` gained two cases (7e-diag,
7e-diag2) confirming `changes` is empty for a first-time link even when
fields are being written for the first time, and correctly names each
field that's actually different for an already-linked group.
`mock_test_inatsyncrunner.lua` gained Cases 11-12 (notice fires when
quality grade actually changes and the change still applies; Skip All
Remaining mutes further notices but not the underlying writes) --
building these exposed that the existing Case 10 ("nothing pending")
fixture had incomplete commonName/rank fields that happened to never
matter before this feature existed, and that `dialogCallLog` wasn't being
reset before Case 10's block, letting an unrelated dialog title leak in
from Cases 8/9's similarly-incomplete fixtures -- both fixed as part of
adding this coverage, not just worked around.

**Live-testing follow-up, same day**: the notice showed the raw API
value ("needs_id") instead of iNat's own UI wording ("Research Grade").
Added `QUALITY_GRADE_LABELS`/`describeQualityGrade` in `INatSync.lua`
(casual/needs_id/research -> Casual/Needs ID/Research Grade, falling back
to the raw value for anything unrecognized) and updated the quality-grade
line in `changes` to use it. Updated the existing `mock_test_inatsync.lua`
assertion to expect the display label, not the raw value.

## Same truncation bug, second dialog: `resolveClusterManually`'s radio labels (2026-07-30)

Live-tested screenshot showed the exact same "(currently tagged:" cutoff
already fixed in `confirmNewLink` -- turned out `resolveClusterManually`'s
per-candidate radio buttons ALSO used `describeCandidateGroups`'
filename-list-plus-species-name string as their own single-line title,
squeezed into the same 22-char-wide constraint. User explicitly didn't
want the dialog widened to fit it.

Fix: reused `describeLocalIdentification` (moved earlier in the file, to
before `resolveClusterManually`, so it's defined before this new use).
Each radio's own title is now just the plain filename(s) -- short, and
the actual selectable label -- with the species-identification line as a
SEPARATE `static_text` underneath, `width_in_chars = 22` (same width as
before) but `height_in_lines = 2` so it wraps instead of truncating. Same
narrow dialog width throughout, just a couple of lines taller per
candidate when a real species name is present. `describeCandidateGroups`
itself is unchanged -- still used verbatim for the plain-text retry-list
log detail, where a verbose one-line string is fine (no UI width
constraint there).

## Real matching bug found via live testing: collision resolution used the wrong taxon name (2026-07-30, "plover" incident)

Live sync mis-linked two brand-new observations of the same species
(shorebirds, shot seconds apart during upload of 2016 archival photos):
DSC_1799.NEF (correct match: a Semipalmated Plover standing on a rock)
got silently claimed by the WRONG observation (one showing plovers in
flight, whose real local match was DSC_1800.NEF), while the observation
that actually belonged to DSC_1799 got a "no good candidate" notice
instead. Diagnosed with real data end to end: extracted embedded JPEG
previews from both NEFs via `exiftool -b -PreviewImage` and downloaded
both iNat photos directly for a visual side-by-side (confirmed the
mismatch conclusively, not just from timestamps), then found via direct
SQLite queries that the local candidate pool was more complex than
assumed -- the camera reuses filenames after wrapping past DSC_9999
(confirmed by the user), so a naive `WHERE file.baseName = 'DSC_1800'`
query without also joining on folder path conflated THREE unrelated
photos from 2016/2019/2026 that happen to share a filename -- a real
trap worth remembering for any future ad hoc catalog queries in this
project.

**Root cause, confirmed by the user**: DSC_1800 was tagged locally as
"Charadriiformes" (the order) at the time of upload -- that identification
is what actually generated the observation. Before this sync ran, another
iNat user corrected the observation's identification to species level,
"Charadrius semipalmatus". `pairByScientificName` (collision resolution)
and `widenCandidatesByScientificName` (the clock-skew-rescue fallback)
both compared a local group's tag against `observation.taxon.name` --
iNat's CURRENT identification -- via exact string match. Once corrected,
that current taxon no longer matched the local tag at all, so the group
carrying the *correct* original identification could never auto-resolve,
while an unrelated already-species-tagged photo taken seconds later
looked like the (wrong) unambiguous answer.

**Fix**: added `firstIdentificationTaxonName(observation, username)` in
`INatSync.lua` -- finds the OWNER's own EARLIEST identification (by
`created_at`, reusing `parseIsoTimestamp` the same way
`describeUnrespondedSuggestion` already does) and returns its taxon name,
falling back to `observation.taxon.name` only if the owner never
identified it at all. Both `pairByScientificName` and
`widenCandidatesByScientificName` now compare against this instead of the
observation's current taxon. Deliberately scoped narrowly: this only
changes the *matching* comparison (which local photo does this iNat post
correspond to) -- deciding whether to *update* an already-linked photo's
tag still correctly uses the CURRENT identification
(`candidateDiffersFromLocal`/`applyMatch`), since pulling in community
corrections after the fact is the whole point of that separate mechanism.

Testing: existing `mock_test_inatsync.lua` suite passed unchanged before
any new test was added, confirming backward compatibility; added Case 13,
directly reproducing the live scenario (two colliding observations, one
whose current taxon was corrected after upload) and confirming both now
resolve to their correct local groups. Hit Lua's 200-local-per-function
limit adding this (`mock_test_inatsync.lua` has grown to ~1600 lines over
the session) -- worked around by bundling the new fixtures into one table
(`plover.photoOriginalOrder`, etc.) instead of several top-level locals,
rather than touching unrelated existing code to make room.

## Folded "Show iNat Sync State" into the pre-flight dialog's own status section (2026-07-30)

The standalone one-off command showed the raw stored cursor
(`lastINatSyncAt`, both as a bare number and via `LrDate.timeToW3CDate`),
the pending-retry count, and the stored username -- useful, but a
separate menu entry nobody reaches for during a normal sync, and already
slightly stale (never updated to also show the pending-mismatch count,
which didn't exist yet when it was written). Removed
`ShowINatSyncState.lua` and its `Info.lua` entry entirely; the same
information now shows as a "Sync Status" group box at the top of the
sync's own pre-flight (Full/Incremental) dialog -- every run already
opens this dialog, so the status is visible without any extra step.

Added `describeElapsedTime(seconds)` in `INatSyncRunner.lua` for a
human-friendly "2 hours ago"/"3 days ago" label -- deliberately pure
arithmetic on the two Cocoa-epoch numbers (`LrDate.currentTime()` minus
the stored cursor), not string parsing/reformatting of a rendered date,
sidestepping the whole class of date-string bugs this project has hit
more than once. Pending count is now the COMBINED retry + mismatch total
(the old tool only ever showed retry), matching everything else's move
toward one unified view of "what's still pending" rather than
per-mechanism counts.

Used `f:group_box` (titled "Sync Status") for visual structure -- genuinely
new-to-this-project SDK surface, confirmed real via the SDK reference
before use (along with `f:separator`, not used here but confirmed
available if needed later) rather than assumed.

Testing: extended `mock_test_inatsyncrunner.lua`'s LrView stub with
`group_box`/`spacer`, and added a `collectTitles` helper that walks the
whole fake view tree collecting every `.title` string -- robust to the
exact nested structure changing later, unlike asserting on hardcoded
array positions. Cases 1b/1c confirm the status section correctly shows
"never synced"/"nothing pending" with fresh state, and a real elapsed
time + combined pending count ("3 hours ago", "3 observations still
pending" from 1 retry + 2 mismatch entries) with populated state.

## Explicitly deferred / still open

- **Cursor-orphaned observations have no *general* recheck mechanism** --
  diagnosed 2026-07-24 as (at least one cause of) the earlier "nothing
  happened" reports. Confirmed live against observation #384297708: iNat's
  current identification (agreed with, own "supporting" ID) is
  species-level `Polygonia interrogationis`; the local tag was still
  genus-level `Polygonia`, direct-queried from
  `AgSearchablePhotoProperty` (the actual storage table for this plugin's
  custom fields -- NOT `AgPhotoProperty`, which was the wrong table
  queried in earlier sessions, hence that standing "zero rows despite
  obvious usage" mystery; both tables exist, only the searchable one gets
  populated). The stored `lastINatSyncAt` cursor
  (2026-07-24T03:22:58 UTC) was already PAST this observation's
  `updated_at` (2026-07-24T02:42:22 UTC) -- a ~40-minute gap, so the
  60-minute safety margin added above (same day, see previous section)
  would have caught this specific case too, but the margin is a
  mitigation bounded by its size, not a structural fix: any cursor
  advance that outpaces an update by more than the margin -- a long
  `dofile` hang, a genuinely slow API index, a run spanning more than an
  hour -- can still orphan an observation with no bounded recheck list
  putting it back in view (unlike apply-failures, `iNatPendingRetryIds`,
  or filename mismatches, `iNatPendingMismatchIds`). Full Sync (ignores
  the cursor, full history pull) remains the workaround for anything that
  slips past the margin. TODO if this recurs: a periodic reconciliation
  pass, independent of the cursor, that re-verifies already-linked
  observations' current `updated_at` against what was last actually
  applied locally, rather than trusting the incremental delta alone.
- Deleted-observation detection (a separate, coarser periodic diff pass,
  see "Sync from iNaturalist" section above).
- `growthHabit` enum conversion (see "Open items" above).
- The "same subject/organism" grouping command (see "Open items" above).
