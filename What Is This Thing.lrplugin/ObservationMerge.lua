local LrApplication = import 'LrApplication'
local LrPathUtils = import 'LrPathUtils'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))
local INatSync = dofile(LrPathUtils.child(_PLUGIN.path, "INatSync.lua"))
local ColorCode = dofile(LrPathUtils.child(_PLUGIN.path, "ColorCode.lua"))

local ObservationMerge = {}

-- Whichever of `photos` has an iNat link first, mirroring
-- KeywordWriter.findExistingObservationId's own "first found wins"
-- convention for the analogous local Observation ID -- deliberately NOT
-- just the chosen "master" (see below): "master" picks which SPECIES
-- identification should win when photos disagree, a separate concern
-- from "does this group have an iNat link at all." Confirmed live
-- 2026-08-03: merging a recovered placeholder (has a certain iNat link)
-- with an ordinary unlinked RAW, where the RAW's identification was
-- picked as master, silently left BOTH photos unlinked -- the placeholder
-- being merged as a mere "other photo" meant its link was never even
-- looked at.
local function findExistingINatLink(photos)
    for _, photo in ipairs(photos) do
        local id = photo:getPropertyForPlugin(_PLUGIN, "iNatObservationId")
        if id then
            return id,
                photo:getPropertyForPlugin(_PLUGIN, "iNatObservationUrl"),
                photo:getPropertyForPlugin(_PLUGIN, "iNatQualityGrade"),
                photo:getPropertyForPlugin(_PLUGIN, "iNatSuggestedId")
        end
    end
    return nil
end

-- Shared by MergeObservation.lua (explicit multi-selection) and
-- SuggestMergeCandidates.lua (assisted picker) -- both end up needing the
-- exact same "fold these photos into the master's identification" logic,
-- so it lives in one place rather than being duplicated.
--
-- `master` must already be identified (have a scientificName) -- there's
-- nothing to copy otherwise. `otherPhotos` is every other photo to merge
-- in (master itself must NOT be included in this list).
--
-- Reuses KeywordWriter.applyIdentification for the actual Title/Caption/
-- keyword-tree/metadata write (same path every identify command already
-- goes through), re-resolving ancestry by name via
-- INaturalist.getMajorAncestryForCandidate since the master's taxon id
-- isn't stored on the photo itself -- only its scientific name/rank are.
-- Master is placed first in the list passed to applyIdentification, since
-- it reuses whichever photo's existing Observation ID it finds FIRST (see
-- KeywordWriter.findExistingObservationId) -- the master's own id (if any)
-- must always win over some other photo's stale one.
--
-- Whichever merged photo has an iNat link (found via findExistingINatLink
-- above, not necessarily the master) has its iNatObservationId/
-- iNatObservationUrl/iNatQualityGrade/iNatSuggestedId copied onto every
-- merged photo, in a second write transaction -- otherwise a merged
-- sibling would show blank/wrong quality grade and suggestion state until
-- the NEXT sync happened to touch it (2026-08-03, previously only the two
-- link fields were copied here).
--
-- Returns the resolved candidate (scientificName, commonName, rank, id)
-- and the full list of merged photos (master first).
function ObservationMerge.merge(master, otherPhotos)
    local catalog = LrApplication.activeCatalog()

    local candidate = {
        scientificName = master:getPropertyForPlugin(_PLUGIN, "scientificName"),
        commonName = master:getPropertyForPlugin(_PLUGIN, "commonName"),
        rank = master:getPropertyForPlugin(_PLUGIN, "taxonRank"),
    }

    local orderedPhotos = { master }
    for _, photo in ipairs(otherPhotos) do
        table.insert(orderedPhotos, photo)
    end

    local masterINatObservationId, masterINatObservationUrl, masterINatQualityGrade, masterINatSuggestedId =
        findExistingINatLink(orderedPhotos)

    -- Network call (ancestry lookup) -- must happen before the write
    -- transaction starts, not inside it.
    local resolvedCandidate, ancestry = INaturalist.getMajorAncestryForCandidate(candidate)

    KeywordWriter.applyIdentification(orderedPhotos, resolvedCandidate, ancestry)

    if masterINatObservationId then
        catalog:withWriteAccessDo("Link merged photos to iNaturalist observation", function()
            for _, photo in ipairs(orderedPhotos) do
                photo:setPropertyForPlugin(_PLUGIN, "iNatObservationId", masterINatObservationId)
                photo:setPropertyForPlugin(_PLUGIN, "iNatObservationUrl", masterINatObservationUrl)
                photo:setPropertyForPlugin(_PLUGIN, "iNatQualityGrade", masterINatQualityGrade)
                photo:setPropertyForPlugin(_PLUGIN, "iNatSuggestedId", masterINatSuggestedId)
            end
            -- Recomputes the color label now that iNatObservationId is
            -- actually set -- applyIdentification's own color-code call
            -- above already ran for these same photos, but at that point
            -- none of them were linked yet, so it colored them green; left
            -- alone, that would stay stale/wrong once they're linked here.
            -- Both iNatObservationId and iNatQualityGrade passed
            -- explicitly (just written above, in THIS same transaction --
            -- confirmed live 2026-08-02 that reading either back here
            -- isn't reliable).
            ColorCode.applyToPhotos(orderedPhotos, {
                iNatObservationId = masterINatObservationId,
                iNatQualityGrade = masterINatQualityGrade,
            })
        end)

        -- Absorbing a missing/mismatched photo into an already-linked
        -- observation by hand (this is exactly what the sync's own
        -- mismatch picker, MergeCandidatesDialog.lua, does) resolves
        -- whatever the sync flagged it for -- clear the retry/mismatch
        -- bookkeeping here so it doesn't keep nagging on every future
        -- run. iNatObservationId is stored as a string (see
        -- INatSync.lua/SetINatObservation.lua); markRetryOutcome/
        -- markMismatchOutcome key by the numeric id used everywhere else.
        local numericId = tonumber(masterINatObservationId)
        if numericId then
            INatSync.markRetryOutcome(numericId, true)
            INatSync.markMismatchOutcome(numericId, false)
        end
    end

    return resolvedCandidate, orderedPhotos
end

return ObservationMerge
