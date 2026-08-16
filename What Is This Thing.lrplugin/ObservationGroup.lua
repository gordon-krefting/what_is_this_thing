local ObservationGroup = {}

-- catalog:findPhotosWithProperty requires the plug-in's toolkit identifier
-- as a plain string (unlike get/setPropertyForPlugin, which also accept
-- the _PLUGIN object) -- must match Info.lua's LrToolkitIdentifier exactly.
local TOOLKIT_ID = "org.krefting.whatisthisthing"

-- Expands `photos` (typically catalog:getTargetPhotos(), i.e. whatever's
-- literally selected) out to every photo sharing the same Observation ID
-- as any of them -- not just the selected ones -- so an edit doesn't
-- require reselecting the whole original identify batch. Falls back to
-- just `photos` if none of them have an Observation ID yet (e.g.
-- identified before that field existed).
--
-- Returns targetPhotos, errorMessage. If the selection spans more than one
-- distinct Observation ID (photos identified in separate batches), that's
-- an error, not something to silently resolve by picking one and dropping
-- the rest -- returns nil, errorMessage in that case.
--
-- Extracted 2026-08-15 from identical bodies duplicated in SetCultivar.lua
-- and (now-retired) ManageSpecimen.lua -- a third copy inside
-- ManageFloraObservation.lua would have been one too many.
function ObservationGroup.expand(catalog, photos)
    local distinctIds = {}
    local orderedIds = {}
    for _, photo in ipairs(photos) do
        local id = photo:getPropertyForPlugin(_PLUGIN, "observationId")
        if id and not distinctIds[id] then
            distinctIds[id] = true
            table.insert(orderedIds, id)
        end
    end

    if #orderedIds > 1 then
        return nil, "The selected photos are from different observations (identified in separate batches) -- select photos from just one observation at a time."
    end

    if #orderedIds == 0 then
        return photos, nil
    end

    local observationId = orderedIds[1]
    local candidates = catalog:findPhotosWithProperty(TOOLKIT_ID, "observationId")
    local matched = {}
    for _, photo in ipairs(candidates) do
        if photo:getPropertyForPlugin(_PLUGIN, "observationId") == observationId then
            table.insert(matched, photo)
        end
    end
    return matched, nil
end

return ObservationGroup
