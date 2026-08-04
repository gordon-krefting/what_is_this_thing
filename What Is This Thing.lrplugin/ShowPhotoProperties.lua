local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

-- One-off diagnostic (2026-08-02): DSC_0121.JPG (#387535194, Chrysaora
-- chesapeakei) is Research Grade on iNat but came out of a sync colored
-- blue, not purple, even though the catalog's colorLabels field confirmed
-- the write itself landed. Rather than guess (a same-transaction read-
-- after-write visibility issue in ColorCode.applyToPhotos reading
-- iNatQualityGrade right after INatSync.applyMatch just wrote it is the
-- leading hypothesis), show the actual current live values read straight
-- from the SDK for whatever photo(s) are selected -- read-only, no writes
-- at all.
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Show Photo Properties", "No photos selected.", "info")
        return
    end

    local lines = {}
    for _, photo in ipairs(photos) do
        local fileName = photo:getFormattedMetadata("fileName")
        table.insert(lines, fileName .. ":")
        table.insert(lines, "  iNatObservationId: " .. tostring(photo:getPropertyForPlugin(_PLUGIN, "iNatObservationId")))
        table.insert(lines, "  iNatQualityGrade: " .. tostring(photo:getPropertyForPlugin(_PLUGIN, "iNatQualityGrade")))
        table.insert(lines, "  observationId: " .. tostring(photo:getPropertyForPlugin(_PLUGIN, "observationId")))
        table.insert(lines, "  scientificName: " .. tostring(photo:getPropertyForPlugin(_PLUGIN, "scientificName")))
        table.insert(lines, "  taxonRank: " .. tostring(photo:getPropertyForPlugin(_PLUGIN, "taxonRank")))
        table.insert(lines, "  taxonId: " .. tostring(photo:getPropertyForPlugin(_PLUGIN, "taxonId")))
        table.insert(lines, "  colorNameForLabel: " .. tostring(photo:getRawMetadata("colorNameForLabel")))
        table.insert(lines, "")
    end

    LrDialogs.message("Show Photo Properties", table.concat(lines, "\n"), "info")
end)
