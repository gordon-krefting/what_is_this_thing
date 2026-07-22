local LrApplication = import 'LrApplication'
local LrPathUtils = import 'LrPathUtils'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local TaxonStore = dofile(LrPathUtils.child(_PLUGIN.path, "TaxonStore.lua"))

local KeywordWriter = {}

-- Fields written per photo whenever a taxon-level entry (fetched or cached
-- via TaxonStore) is available. Kept as a list rather than five separate
-- if-blocks so it's one place to update if a field gets added/removed.
local TAXON_LEVEL_FIELDS = { "conservationStatus", "establishmentMeans", "growthHabit", "wikipediaUrl", "notes" }

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

local function formatCaption(candidate)
    return formatLabel(candidate.commonName, candidate.scientificName)
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
-- remember/reselect the original photos.
local function generateUUID()
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
--     Means, Growth Habit, Wikipedia, Notes) from TaxonStore.lua's local
--     cache -- fetching fresh from iNaturalist only the first time this
--     species is encountered (TaxonStore.get() returns a non-nil, even if
--     empty, table for anything already checked, so a species with no
--     notable data doesn't get re-fetched every time either). Growth
--     Habit/Notes are manual-only (see EditTaxonInfo.lua) but flow through
--     the same cache, so a species already annotated automatically carries
--     that forward onto newly-identified photos of it too.
-- Must be called from within an async task; performs a catalog write.
function KeywordWriter.applyIdentification(photos, candidate, ancestry)
    local catalog = LrApplication.activeCatalog()
    local caption = formatCaption(candidate)
    -- Nil rank means species by this codebase's established convention
    -- (see isSpecies() in WhatIsThisAnimal.lua / linksForCandidate() in
    -- WhatIsThisPlant.lua) -- normalize it here rather than storing an
    -- ambiguous-looking blank/"(unknown)" value for the common case.
    local rankValue = candidate.rank or "species"
    local observationId = findExistingObservationId(photos) or generateUUID()

    -- Network call (inside getTaxonFacts) -- must happen before the write
    -- transaction starts, not inside it.
    local taxonEntry = TaxonStore.get(candidate.scientificName)
    if not taxonEntry and candidate.id then
        local gps = photos[1] and photos[1]:getRawMetadata("gps")
        local lat = gps and gps.latitude
        local lng = gps and gps.longitude
        local facts = INaturalist.getTaxonFacts(candidate.id, lat, lng)
        taxonEntry = TaxonStore.set(candidate.scientificName, facts)
    end

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
            photo:setPropertyForPlugin(_PLUGIN, "commonName", candidate.commonName)
            photo:setPropertyForPlugin(_PLUGIN, "taxonRank", rankValue)
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
            end
        end
    end)
end

return KeywordWriter
