local LrApplication = import 'LrApplication'

local KeywordWriter = {}

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
--     scientific name, if no common name is available) for human reading.
-- Must be called from within an async task; performs a catalog write.
function KeywordWriter.applyIdentification(photos, candidate, ancestry)
    local catalog = LrApplication.activeCatalog()
    local caption = formatCaption(candidate)

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
        end
    end)
end

return KeywordWriter
