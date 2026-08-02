local ColorCode = {}

-- Shared by the manual "Color Code Identifications" bulk command and the
-- ID/Sync flows themselves (KeywordWriter.applyIdentification,
-- INatSync.applyMatch, ObservationMerge.lua, SetINatObservation.lua,
-- SplitObservation.lua) -- factored out so all of them stay in lockstep
-- rather than requiring the bulk command to be re-run after every
-- identify/sync (2026-08-02, folded in once the standalone command proved
-- useful run manually a few times).
--
-- Recomputes and writes the color label for each of `photos`: purple =
-- linked to iNat (iNatObservationId set) AND Research Grade; blue =
-- linked, any other (or no) quality grade; green = identified locally
-- (observationId set -- NOT scientificName, since an absorbed sibling
-- photo can carry observationId without ever getting its own independent
-- scientificName write) but not linked to iNat at all. Anything else
-- (neither property set) is left untouched -- this function only ever
-- SETS one of the three colors, never clears.
--
-- `overrides` (optional): { iNatObservationId = ..., iNatQualityGrade =
-- ..., observationId = ... } -- for whichever of these three fields THIS
-- SAME catalog:withWriteAccessDo transaction just wrote via
-- setPropertyForPlugin, pass the value directly here instead of letting
-- it be read back live. Confirmed live 2026-08-02: getPropertyForPlugin
-- does NOT reliably reflect a setPropertyForPlugin call made earlier in
-- the SAME transaction -- a photo just linked to a Research Grade
-- observation came out colored blue, not purple, because the
-- just-written "research" grade wasn't visible yet to this function's own
-- read. Only override whichever field(s) were actually just written in
-- THIS transaction -- anything else is safe (and should stay) reading
-- live, since it reflects an earlier, already-committed transaction.
-- Use ColorCode.CLEARED (not plain `= nil`) to explicitly override a
-- field to nil -- a table constructor silently drops a `= nil` entry
-- entirely, indistinguishable from the key never being passed, so nil
-- can't be used as its own "explicitly cleared" signal here.
--
-- Must be called from inside a catalog:withWriteAccessDo block. Returns
-- purpleCount, blueCount, greenCount (photos left untouched aren't
-- counted at all) -- callers that don't need the counts can ignore them.
ColorCode.CLEARED = {}

local function resolveField(overrides, key, photo)
    local v = overrides and overrides[key]
    if v == nil then
        return photo:getPropertyForPlugin(_PLUGIN, key)
    elseif v == ColorCode.CLEARED then
        return nil
    end
    return v
end

function ColorCode.applyToPhotos(photos, overrides)
    local purpleCount, blueCount, greenCount = 0, 0, 0

    for _, photo in ipairs(photos) do
        local iNatObservationId = resolveField(overrides, "iNatObservationId", photo)
        if iNatObservationId then
            local grade = resolveField(overrides, "iNatQualityGrade", photo)
            if grade == "research" then
                photo:setRawMetadata("colorNameForLabel", "purple")
                purpleCount = purpleCount + 1
            else
                photo:setRawMetadata("colorNameForLabel", "blue")
                blueCount = blueCount + 1
            end
        elseif resolveField(overrides, "observationId", photo) then
            photo:setRawMetadata("colorNameForLabel", "green")
            greenCount = greenCount + 1
        end
    end

    return purpleCount, blueCount, greenCount
end

return ColorCode
