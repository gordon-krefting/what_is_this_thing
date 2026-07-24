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

## Explicitly deferred / still open

- **Recovering "orphan" observations** (made in the iNat phone app, or
  from photos living in Apple Photos -- never imported into Lightroom;
  distinct from the false-collision case above, which involves photos
  that *are* already in the catalog). Design agreed 2026-07-18, not yet
  built: download the photo directly from the observation's own photo
  URLs (no separate lookup needed) and import it into the catalog **next
  to normal imports** -- this case has no matching ambiguity (clean 1:1),
  so write observation id/species/GPS/date immediately at import time.
  Caveat: iNat serves a resized/compressed JPEG copy of whatever was
  uploaded, not a RAW original, so these will be visibly lower quality
  than native camera captures sitting next to them -- likely worth
  marking them distinctly, e.g. a `Recovered from iNat` keyword or a
  dedicated subfolder/collection.
- Deleted-observation detection (a separate, coarser periodic diff pass,
  see "Sync from iNaturalist" section above).
- `growthHabit` enum conversion (see "Open items" above).
- The "same subject/organism" grouping command (see "Open items" above).
