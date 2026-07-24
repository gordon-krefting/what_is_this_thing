local LrApplication = import 'LrApplication'
local LrPathUtils = import 'LrPathUtils'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))

local ObservationMerge = {}

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
-- Master's iNatObservationId/iNatObservationUrl (if any) are then
-- separately copied onto every merged photo, in a second write
-- transaction.
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
    local masterINatObservationId = master:getPropertyForPlugin(_PLUGIN, "iNatObservationId")
    local masterINatObservationUrl = master:getPropertyForPlugin(_PLUGIN, "iNatObservationUrl")

    local orderedPhotos = { master }
    for _, photo in ipairs(otherPhotos) do
        table.insert(orderedPhotos, photo)
    end

    -- Network call (ancestry lookup) -- must happen before the write
    -- transaction starts, not inside it.
    local resolvedCandidate, ancestry = INaturalist.getMajorAncestryForCandidate(candidate)

    KeywordWriter.applyIdentification(orderedPhotos, resolvedCandidate, ancestry)

    if masterINatObservationId then
        catalog:withWriteAccessDo("Link merged photos to iNaturalist observation", function()
            for _, photo in ipairs(orderedPhotos) do
                photo:setPropertyForPlugin(_PLUGIN, "iNatObservationId", masterINatObservationId)
                photo:setPropertyForPlugin(_PLUGIN, "iNatObservationUrl", masterINatObservationUrl)
            end
        end)
    end

    return resolvedCandidate, orderedPhotos
end

return ObservationMerge
