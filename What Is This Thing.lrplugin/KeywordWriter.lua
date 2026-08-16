local LrApplication = import 'LrApplication'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local TaxonStore = dofile(LrPathUtils.child(_PLUGIN.path, "TaxonStore.lua"))
local ColorCode = dofile(LrPathUtils.child(_PLUGIN.path, "ColorCode.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))

local KeywordWriter = {}

-- Fields written per photo whenever a taxon-level entry (fetched or cached
-- via TaxonStore) is available. Kept as a list rather than separate
-- if-blocks so it's one place to update if a field gets added/removed.
-- Two deliberate exclusions: commonNames/preferredCommonName don't
-- denormalize onto the photo directly (they drive the `commonName` write
-- below instead -- see the commonName-resolution block in
-- applyIdentification); gardenLocations is a map, not a scalar, so it
-- can't go through this generic loop's plain setPropertyForPlugin call --
-- see the dedicated TaxonStore.formatGardenLocations call after the loop.
local TAXON_LEVEL_FIELDS = {
    "conservationStatus", "establishmentMeans", "growthHabit", "nativity", "wikipediaUrl", "notes",
}

-- { [value] = title } for the garden-location enum, built once from
-- MetadataDefinition.lua's own declared values (the specimen-level
-- gardenLocation field -- same 7 locations the taxon-level checklist
-- uses) -- passed to TaxonStore.formatGardenLocations wherever this file
-- denormalizes that map onto a photo, so the panel-facing string reads
-- "Meadow" rather than the raw "meadow".
local LOCATION_TITLES = {}
do
    local metadataDef = dofile(LrPathUtils.child(_PLUGIN.path, "MetadataDefinition.lua"))
    for _, field in ipairs(metadataDef.metadataFieldsForPhotos) do
        if field.id == "gardenLocation" then
            for _, entry in ipairs(field.values) do
                if entry.value then
                    LOCATION_TITLES[entry.value] = entry.title
                end
            end
        end
    end
end

-- Every custom field that makes up a photo's identification -- everything
-- clearIdentification below wipes. Deliberately excludes
-- approximateLocation/iNatRecoveredPlaceholder/pendingMetadataSave --
-- those are operational/provenance facts about the photo (GPS-approximation
-- flag, recovered-placeholder origin, pending-save tracking), not part of
-- what species it's identified as, and stay valid independent of whether
-- the identification itself was ever correct. Includes the specimen fields
-- (2026-08-11) -- a specimen belongs to one species, so if the species
-- identification was wrong, whatever specimen it was linked to is no
-- longer valid either, same reasoning already applied to observationId.
local IDENTIFICATION_FIELDS = {
    "scientificName", "commonName", "taxonRank", "taxonId", "taxonUrl", "idConfidence", "cultivar",
    "observationNickname", "observationNotes", "observationId",
    "iNatObservationId", "iNatObservationUrl", "iNatQualityGrade", "iNatSuggestedId",
    "conservationStatus", "establishmentMeans", "growthHabit", "nativity", "gardenLocations", "wikipediaUrl", "notes",
    "specimenId", "gardenLocation", "locationNotes", "plantingMethod", "plantingYear", "nickname",
}

-- All species-ID keywords are nested under this parent (not itself included
-- on export) so a re-ID can reliably find and remove the *old* leaf keyword
-- without touching any keywords the user added by hand elsewhere.
local PARENT_KEYWORD_NAME = "Species ID"

local function formatLabel(commonName, scientificName)
    if commonName then
        return commonName .. " (" .. scientificName .. ")"
    end
    return scientificName
end

-- Minor words that stay lowercase mid-name in proper title case, unless
-- they're the first or last word -- see ManageFloraObservation.lua's own
-- copy of this list for the full rationale.
local MINOR_WORDS = {
    ["a"] = true, ["an"] = true, ["and"] = true, ["as"] = true, ["at"] = true,
    ["but"] = true, ["by"] = true, ["for"] = true, ["in"] = true, ["nor"] = true,
    ["of"] = true, ["on"] = true, ["or"] = true, ["so"] = true, ["the"] = true,
    ["to"] = true, ["up"] = true, ["yet"] = true, ["via"] = true, ["vs"] = true,
}

local function capitalizeWord(word)
    return (word:gsub("(%a)([%a']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end))
end

-- Normalizes a common name to proper Title Case ("great mullein" ->
-- "Great Mullein", "charmin of the woods" -> "Charmin of the Woods") --
-- see ManageFloraObservation.lua's own copy of this helper for the full
-- rationale (iNat's raw API casing is inconsistent, PlantNet's more so).
-- Applied centrally in addName below, the single chokepoint every
-- automatically-merged name passes through regardless of which API field
-- it came from, so differently-cased spellings of the same name collapse
-- into one TaxonStore entry instead of accumulating as separate ones.
local function titleCase(str)
    if not str then
        return str
    end
    local words = {}
    for word in str:gmatch("%S+") do
        table.insert(words, word)
    end
    if #words == 0 then
        return str
    end
    for i, word in ipairs(words) do
        local bare = word:match("^%a+$")
        if i ~= 1 and i ~= #words and bare and MINOR_WORDS[bare:lower()] then
            words[i] = bare:lower()
        else
            words[i] = capitalizeWord(word)
        end
    end
    return table.concat(words, " ")
end

-- True if `keyword` is `ancestorKeyword` itself or nested anywhere beneath
-- it, walking up via getParent(). Bounded so a (shouldn't-happen) cycle
-- can't hang the plugin.
local function isDescendantOf(keyword, ancestorKeyword)
    local current = keyword
    for _ = 1, 20 do
        if not current then
            return false
        end
        if current == ancestorKeyword then
            return true
        end
        current = current:getParent()
    end
    return false
end

local function findParentKeyword(catalog)
    for _, kw in ipairs(catalog:getKeywords()) do
        if kw:getName() == PARENT_KEYWORD_NAME then
            return kw
        end
    end
    return nil
end

-- Generates a UUID v4 (Lightroom's SDK has no built-in generator). Used for
-- the "Observation ID" custom field -- a purely local id shared by every
-- photo identified together in one batch, so they can be found again later
-- (e.g. to correct or annotate the identification) without having to
-- remember/reselect the original photos. Exported (not just used
-- internally by applyIdentification below) so other commands needing a
-- fresh Observation ID -- e.g. SplitObservation.lua, splitting a
-- mistakenly-shared group back apart -- don't need their own copy.
function KeywordWriter.generateUUID()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (template:gsub("[xy]", function(c)
        local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
        return string.format("%x", v)
    end))
end

-- Returns the Observation ID already on any photo in `photos`, or nil if
-- none of them have one yet -- so re-identifying an existing batch (or
-- adding a straggler photo to it) reuses the same id instead of forking a
-- new group.
local function findExistingObservationId(photos)
    for _, photo in ipairs(photos) do
        local id = photo:getPropertyForPlugin(_PLUGIN, "observationId")
        if id then
            return id
        end
    end
    return nil
end

-- Returns the label (e.g. "Common Name (Scientific Name)") of whichever
-- keyword `photo` was identified with via applyIdentification (the
-- attached keyword nested under "Species ID"), or nil if it hasn't been
-- identified yet. Read-only; does not require a write-access transaction.
function KeywordWriter.findSpeciesName(photo)
    local catalog = LrApplication.activeCatalog()
    local parentKeyword = findParentKeyword(catalog)
    if not parentKeyword then
        return nil
    end

    local currentKeywords = photo:getRawMetadata("keywords") or {}
    for _, kw in ipairs(currentKeywords) do
        if isDescendantOf(kw, parentKeyword) then
            return kw:getName()
        end
    end
    return nil
end

-- True if `photo`'s species keyword (see findSpeciesName) is nested at
-- least one level below the "Species ID" root -- i.e. has a real ancestry
-- chain (class/order/family/genus) rather than being a flat "Species ID >
-- leaf" tag with nothing in between. False if the photo has no species
-- keyword at all, or if its keyword sits directly under the root.
--
-- Exists to detect and repair photos whose ancestry lookup silently failed
-- when they were originally tagged -- getMajorAncestry degrades to an
-- empty list on ANY failure (rate limiting, a network hiccup) by design,
-- with no error ever surfaced at the time, so a flat tag from a bulk
-- operation (e.g. a historical backfill) can go unnoticed indefinitely
-- unless something explicitly checks for it later, as the iNaturalist
-- sync's applyMatch now does.
function KeywordWriter.hasFullAncestry(photo)
    local catalog = LrApplication.activeCatalog()
    local parentKeyword = findParentKeyword(catalog)
    if not parentKeyword then
        return false
    end

    local currentKeywords = photo:getRawMetadata("keywords") or {}
    for _, kw in ipairs(currentKeywords) do
        if isDescendantOf(kw, parentKeyword) then
            return kw:getParent() ~= parentKeyword
        end
    end
    return false
end

-- Removes any keyword on `photo` nested anywhere under `parentKeyword`,
-- other than `exceptKeyword` -- i.e. clears out a previous run's
-- identification (at whatever rank/depth it was tagged at) before the new
-- one is added. Returns true if `exceptKeyword` itself was already attached
-- (re-identifying to the same taxon again), so the caller doesn't add it a
-- second time.
local function removeOldChildKeywords(photo, parentKeyword, exceptKeyword)
    local alreadyHasNew = false
    local currentKeywords = photo:getRawMetadata("keywords") or {}
    for _, kw in ipairs(currentKeywords) do
        if kw == exceptKeyword then
            alreadyHasNew = true
        elseif isDescendantOf(kw, parentKeyword) then
            photo:removeKeyword(kw)
        end
    end
    return alreadyHasNew
end

-- Fully reverses applyIdentification -- for a photo whose identification
-- turned out to be flat-out wrong (not just mis-grouped with a real
-- neighbor -- see SplitObservation.lua for that narrower case, which
-- only detaches grouping/clears the iNat link, not the species ID
-- itself). Removes any keyword nested under "Species ID" (exceptKeyword
-- = nil clears all of them, not just the old one being replaced), clears
-- Title/Caption back to unset, clears every IDENTIFICATION_FIELDS custom
-- property, and clears the color label -- ColorCode.applyToPhotos only
-- ever SETS purple/blue/green (see its own doc comment), so without this
-- a cleared photo would keep whatever color it was stamped with before,
-- now stale and misleading (confirmed live 2026-08-09). Exported for
-- ClearIdentification.lua.
--
-- Caller must already be inside a catalog:withWriteAccessDo block (same
-- convention as applyIdentification's own per-photo work below).
function KeywordWriter.clearIdentification(photo)
    local parentKeyword = findParentKeyword(LrApplication.activeCatalog())
    if parentKeyword then
        removeOldChildKeywords(photo, parentKeyword, nil)
    end

    photo:setRawMetadata("title", nil)
    photo:setRawMetadata("caption", nil)
    -- "" here, not nil -- confirmed live 2026-08-10: nil crashed with
    -- "bad argument #1 to 'lower' (string expected, got nil)", Lightroom's
    -- own internal handler for this field apparently normalizes the value
    -- via :lower() and doesn't accept nil as "no color" the way title/
    -- caption do.
    photo:setRawMetadata("colorNameForLabel", "")

    for _, field in ipairs(IDENTIFICATION_FIELDS) do
        photo:setPropertyForPlugin(_PLUGIN, field, nil)
    end
end

-- Builds (or reuses) a chain of keywords under `parentKeyword`, one per
-- entry in `ancestry` (each { rank, name, commonName }, broadest first),
-- labeled "Common Name (Scientific Name)" (or just the scientific name, if
-- no common name is available for that level) for easier browsing in
-- Lightroom's Keyword List panel. Returns the deepest keyword in the
-- chain -- the direct parent the leaf species/taxon keyword should be
-- created under.
local function buildAncestryChain(catalog, parentKeyword, ancestry)
    local current = parentKeyword
    for _, level in ipairs(ancestry) do
        local label = formatLabel(level.commonName, level.name)
        current = catalog:createKeyword(label, {}, true, current, true)
    end
    return current
end

-- Ensures every photo in `photos` (normally one whole observation) has a
-- leaf "Species ID" keyword matching `newLabel`, removing any other
-- descendant of the "Species ID" root along the way. Mirrors
-- applyIdentification's own keyword-swap pattern below exactly -- one
-- keyword object created ONCE and reused across every photo,
-- remove-old-then-add-if-missing (via removeOldChildKeywords' object-
-- identity check, not a name-string comparison), all inside ONE shared
-- withWriteAccessDo transaction -- rather than a per-photo/
-- per-transaction/verify-then-remove design tried first, which caused
-- real, repeated keyword loss in live testing (confirmed 2026-08-17)
-- despite several mitigation attempts (reordering add/remove, an
-- in-transaction verification read, isolating each photo into its own
-- transaction). applyIdentification's pattern has been proven reliable
-- across every identification this plugin has ever made; this now
-- follows it instead of reinventing a different, less reliable one --
-- including getting the case-only-rename scenario right for free
-- (removeOldChildKeywords' `kw == exceptKeyword` identity check is true
-- whenever createKeyword's case-insensitive match returns the SAME
-- keyword already attached, so it's correctly left alone, no special
-- case needed).
--
-- Unlike applyIdentification, doesn't rebuild the ancestry chain --
-- reuses whatever branch the FIRST photo's existing leaf keyword already
-- lives under (falling back to the bare "Species ID" root if none has
-- one yet), since nothing about the taxonomic classification changed
-- here, only the common-name text embedded in the label. Exported for
-- ManageFloraObservation.lua's Common Name picker -- editing the
-- preferred common name there was updating the photo's Caption but
-- leaving this keyword stale (confirmed live 2026-08-17). Self-contained
-- (owns its own withWriteAccessDo transaction) -- unlike the old
-- per-photo version, the caller should NOT wrap this in its own
-- transaction.
function KeywordWriter.syncSpeciesKeyword(photos, newLabel)
    if #photos == 0 then
        return
    end
    local catalog = LrApplication.activeCatalog()
    local parentKeyword = findParentKeyword(catalog)
    if not parentKeyword then
        return
    end

    catalog:withWriteAccessDo("Sync species keyword", function()
        local branchKeyword = parentKeyword
        local firstKeywords = photos[1]:getRawMetadata("keywords") or {}
        for _, kw in ipairs(firstKeywords) do
            if isDescendantOf(kw, parentKeyword) then
                branchKeyword = kw:getParent() or parentKeyword
                break
            end
        end

        local newKeyword = catalog:createKeyword(newLabel, {}, true, branchKeyword, true)

        for _, photo in ipairs(photos) do
            local alreadyHasNew = removeOldChildKeywords(photo, parentKeyword, newKeyword)
            if not alreadyHasNew then
                photo:addKeyword(newKeyword)
            end
        end
    end)
end

-- Recursively fills `map[name] = keyword` for every keyword nested anywhere
-- beneath `keyword` (at any depth), keyed by its exact label text.
local function collectKeywordsByName(keyword, map)
    for _, child in ipairs(keyword:getChildren()) do
        map[child:getName()] = child
        collectKeywordsByName(child, map)
    end
end

-- For each entry in `candidates` ({ scientificName, commonName, ... }),
-- looks up how many photos already carry that exact label as a keyword
-- somewhere under "Species ID" (at whatever rank/depth it lives at) --
-- e.g. so a candidate picker dialog can show "already tagged" counts.
-- Returns a table keyed by the *candidate table itself* (not by index),
-- mapping to a photo count; entries with no existing keyword or zero
-- current photos are simply absent from the table.
--
-- Read-only: a single traversal of the existing "Species ID" keyword tree,
-- then one getPhotos() call per candidate that matches -- no write-access
-- transaction needed, and nothing here creates a keyword just to check it.
function KeywordWriter.countExistingPhotos(candidates)
    local catalog = LrApplication.activeCatalog()
    local parentKeyword = findParentKeyword(catalog)
    local counts = {}
    if not parentKeyword then
        return counts
    end

    local byName = {}
    collectKeywordsByName(parentKeyword, byName)

    for _, candidate in ipairs(candidates) do
        local label = formatLabel(candidate.commonName, candidate.scientificName)
        local kw = byName[label]
        if kw then
            local n = #kw:getPhotos()
            if n > 0 then
                counts[candidate] = n
            end
        end
    end

    return counts
end

-- Applies an identification `candidate` ({ scientificName, commonName, ... })
-- to every photo in `photos`, in one write-access transaction:
--   - removes any previous "Species ID > ..." keyword from a prior run
--     (at whatever depth it was nested), then adds a keyword labeled
--     "Common Name (Scientific Name)" (matching every ancestor level) --
--     nested under `ancestry` (a list of { rank, name, commonName },
--     broadest first, e.g. class/order/family/genus; pass an empty list or
--     nil for a flat "Species ID > name" tag) under a shared "Species ID"
--     parent. The leaf keyword no longer needs to match iNaturalist's exact
--     taxonomy text the way Title does, since keywords are stripped
--     entirely before export -- Title alone carries the species guess, so
--     the keyword tree can consistently favor human-readable labels
--     instead. Re-IDing doesn't leave stale species keywords behind
--     regardless of how deep they were (keyword identity for removal is
--     based on catalog object identity/parent chain, not label text, so
--     this is unaffected by the label itself changing),
--   - sets Title to the bare scientific name (iNaturalist's uploader reads
--     dc:title for its species guess; unlike Keywords this isn't stripped
--     on export, so it must stay an exact taxonomy match), and
--   - sets Caption to "Common Name (Scientific Name)" (or just the
--     scientific name, if no common name is available) for human reading,
--   - sets the custom metadata fields (Scientific Name, Common Name, Taxon
--     Rank, ID Confidence, Observation ID) declared in
--     MetadataDefinition.lua, so identifications are searchable/filterable
--     as real structured data, not just free text,
--   - and sets the taxon-level fields (Conservation Status, Establishment
--     Means, Growth Habit, Nativity, Garden Locations, Wikipedia, Notes)
--     from TaxonStore.lua's local cache -- fetching fresh from
--     iNaturalist only the first time this species is encountered
--     (TaxonStore.get() returns a non-nil, even if empty, table for
--     anything already checked, so a species with no notable data doesn't
--     get re-fetched every time either). Growth Habit/Nativity/Garden
--     Locations/Notes are manual-only (see ManageFloraObservation.lua) but flow
--     through the same cache, so a species already annotated
--     automatically carries that forward onto newly-identified photos of
--     it too. If any of the `photos` already carries a `cultivar`, the
--     lookup is cultivar-aware (see TaxonStore.lua) -- re-identifying an
--     already-cultivar-tagged photo won't clobber its cultivar-specific
--     growth habit/nativity/garden locations with the bare species'.
--   - resolves Common Name through the same cache (2026-08-11): once a
--     species has a `preferredCommonName` on file, every future
--     identification uses it -- overriding whatever this run's own API
--     result says -- for the same consistency guarantee the other
--     taxon-level fields already have. The very first identification of a
--     species seeds it from its own resolved name. Either way, every name
--     actually seen this run (`candidate.commonName`, plus
--     `candidate.allCommonNames` if present -- see PlantNet.lua) is merged
--     into the taxon's `commonNames` list, deduped, tagged by source, so
--     it grows opportunistically without ever silently changing what's
--     preferred.
-- Must be called from within an async task; performs a catalog write.
function KeywordWriter.applyIdentification(photos, candidate, ancestry)
    local catalog = LrApplication.activeCatalog()
    -- Nil rank means species by this codebase's established convention
    -- (see isSpecies() in SpeciesIdentification.lua) -- normalize it here
    -- rather than storing an ambiguous-looking blank/"(unknown)" value
    -- for the common case.
    local rankValue = candidate.rank or "species"
    local observationId = findExistingObservationId(photos) or KeywordWriter.generateUUID()
    -- "First found wins" -- same convention findExistingObservationId
    -- above already uses -- a batch is normally one subject/individual,
    -- so differing cultivar values across `photos` isn't expected.
    local existingCultivar
    for _, photo in ipairs(photos) do
        existingCultivar = photo:getPropertyForPlugin(_PLUGIN, "cultivar")
        if existingCultivar then
            break
        end
    end

    -- Network call (inside getTaxonFacts) -- must happen before the write
    -- transaction starts, not inside it. Checked against the BARE species
    -- entry specifically (not the cultivar-aware merged view below) --
    -- API-sourced facts (conservationStatus/establishmentMeans/
    -- wikipediaUrl/commonNames/preferredCommonName) only ever live on the
    -- bare entry (see TaxonStore.lua's BARE_ONLY_FIELDS), so THAT's what
    -- actually indicates whether they've ever been fetched, regardless of
    -- whether a cultivar-specific entry already independently exists.
    --
    -- Gate is TaxonStore.hasInatCommonNames, NOT just `not bareEntry` or
    -- `not bareEntry.commonNames` -- found live 2026-08-16, two layers
    -- deep: (1) virtually every species already had a bare entry
    -- (conservationStatus/wikipediaUrl, cached long before commonNames
    -- existed), so `not bareEntry` alone almost never fired; (2) even
    -- fixing that to check `commonNames` specifically still wasn't enough,
    -- since commonNames gains an "identify"-tagged entry on literally
    -- every identify run regardless (this function's own merge logic
    -- below, unconditional) -- so a species could easily have a non-nil
    -- commonNames list despite the richer iNat &all_names=true fetch
    -- never having actually run. Only an "inat"-sourced entry proves the
    -- bulk fetch happened -- see TaxonStore.hasInatCommonNames's own
    -- comment.
    local bareEntry = TaxonStore.get(candidate.scientificName)
    if (not bareEntry or not TaxonStore.hasInatCommonNames(bareEntry.commonNames)) and candidate.id then
        local gps = photos[1] and photos[1]:getRawMetadata("gps")
        local lat = gps and gps.latitude
        local lng = gps and gps.longitude
        local facts = INaturalist.getTaxonFacts(candidate.id, lat, lng)
        TaxonStore.set(candidate.scientificName, facts)
    end
    local taxonEntry = TaxonStore.get(candidate.scientificName, existingCultivar)

    -- Common-name resolution (2026-08-11) -- see this function's own doc
    -- comment above for the full rationale.
    local resolvedCommonName = titleCase(candidate.commonName)
    do
        local existingPreferred = taxonEntry and taxonEntry.preferredCommonName
        if existingPreferred then
            resolvedCommonName = existingPreferred
        end

        -- Tracked directly rather than via a before/after count comparison
        -- -- titleCase normalization can now SHRINK the merged list (two
        -- old case-variant duplicates collapsing into one) in the same
        -- pass that ADDS a genuinely new name, so a raw count comparison
        -- could mask a real addition behind a simultaneous dedup.
        local seen, mergedNames = {}, {}
        local changed = false
        for _, entry in ipairs((taxonEntry and taxonEntry.commonNames) or {}) do
            local name = titleCase(entry.name)
            if name and not seen[name] then
                seen[name] = true
                table.insert(mergedNames, { name = name, source = entry.source })
            else
                changed = true
            end
            if name ~= entry.name then
                changed = true
            end
        end
        local function addName(name, source)
            name = titleCase(name)
            if name and not seen[name] then
                seen[name] = true
                table.insert(mergedNames, { name = name, source = source })
                changed = true
            end
        end
        addName(candidate.commonName, "identify")
        for _, name in ipairs(candidate.allCommonNames or {}) do
            addName(name, "plantnet")
        end

        if not existingPreferred or changed then
            local fields = { commonNames = mergedNames }
            if not existingPreferred then
                fields.preferredCommonName = resolvedCommonName
            end
            -- Always the bare species -- commonNames/preferredCommonName
            -- are never cultivar-keyed (see TaxonStore.lua).
            taxonEntry = TaxonStore.set(candidate.scientificName, fields, existingCultivar)
        end
    end

    local caption = formatLabel(resolvedCommonName, candidate.scientificName)

    catalog:withWriteAccessDo("Add species identification", function()
        local parentKeyword = catalog:createKeyword(PARENT_KEYWORD_NAME, {}, false, nil, true)
        local branchKeyword = buildAncestryChain(catalog, parentKeyword, ancestry or {})
        local newKeyword = catalog:createKeyword(caption, {}, true, branchKeyword, true)

        for _, photo in ipairs(photos) do
            local alreadyHasNew = removeOldChildKeywords(photo, parentKeyword, newKeyword)
            if not alreadyHasNew then
                photo:addKeyword(newKeyword)
            end
            photo:setRawMetadata("title", candidate.scientificName)
            photo:setRawMetadata("caption", caption)

            photo:setPropertyForPlugin(_PLUGIN, "scientificName", candidate.scientificName)
            photo:setPropertyForPlugin(_PLUGIN, "commonName", resolvedCommonName)
            photo:setPropertyForPlugin(_PLUGIN, "taxonRank", rankValue)
            if candidate.id then
                photo:setPropertyForPlugin(_PLUGIN, "taxonId", tostring(candidate.id))
                photo:setPropertyForPlugin(_PLUGIN, "taxonUrl", "https://www.inaturalist.org/taxa/" .. tostring(candidate.id))
            end
            if candidate.score then
                photo:setPropertyForPlugin(_PLUGIN, "idConfidence", string.format("%.1f%%", candidate.score))
            end
            photo:setPropertyForPlugin(_PLUGIN, "observationId", observationId)

            if taxonEntry then
                for _, field in ipairs(TAXON_LEVEL_FIELDS) do
                    if taxonEntry[field] then
                        photo:setPropertyForPlugin(_PLUGIN, field, taxonEntry[field])
                    end
                end
                photo:setPropertyForPlugin(_PLUGIN, "gardenLocations",
                    TaxonStore.formatGardenLocations(taxonEntry.gardenLocations, LOCATION_TITLES))
            end

            PendingMetadataSave.markIfNeeded(catalog, photo)
        end

        -- Keeps the color label current the moment a photo is identified
        -- (or re-identified) -- see ColorCode.lua. observationId passed
        -- explicitly (just written above, in THIS same transaction --
        -- confirmed live 2026-08-02 that reading it back here isn't
        -- reliable); iNatObservationId/iNatQualityGrade are read live,
        -- correctly, since this function doesn't touch either -- a
        -- re-identification of an already-linked photo recomputes from
        -- its still-current values, so it correctly stays purple/blue
        -- rather than wrongly flipping to green.
        ColorCode.applyToPhotos(photos, { observationId = observationId })
    end)
end

return KeywordWriter
