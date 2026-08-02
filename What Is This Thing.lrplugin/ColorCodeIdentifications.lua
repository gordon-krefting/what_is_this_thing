local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'

local ColorCode = dofile(LrPathUtils.child(_PLUGIN.path, "ColorCode.lua"))

-- catalog:findPhotosWithProperty requires the plug-in's toolkit identifier
-- as a plain string (unlike get/setPropertyForPlugin, which also accept
-- the _PLUGIN object) -- must match Info.lua's LrToolkitIdentifier exactly.
local TOOLKIT_ID = "org.krefting.whatisthisthing"

-- Manual, catalog-wide sweep -- a one-off backfill/repair tool for photos
-- identified or synced before ColorCode.applyToPhotos was folded directly
-- into the ID flow (KeywordWriter.applyIdentification) and the Sync flow
-- (INatSync.applyMatch), 2026-08-02. Not needed for day-to-day use anymore
-- (both flows now keep color labels current on their own as they run) --
-- kept around for exactly this "catalog has stale photos from before that
-- existed" case, and as a manual fix if a color label ever gets out of
-- sync some other way.
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()

    local linkedPhotos = catalog:findPhotosWithProperty(TOOLKIT_ID, "iNatObservationId")
    local groupedPhotos = catalog:findPhotosWithProperty(TOOLKIT_ID, "observationId")

    local isLinked = {}
    for _, photo in ipairs(linkedPhotos) do
        isLinked[photo] = true
    end

    local allTagged = {}
    for _, photo in ipairs(linkedPhotos) do
        table.insert(allTagged, photo)
    end
    for _, photo in ipairs(groupedPhotos) do
        if not isLinked[photo] then
            table.insert(allTagged, photo)
        end
    end

    local purpleCount, blueCount, greenCount = 0, 0, 0
    catalog:withWriteAccessDo("Color code identifications", function()
        purpleCount, blueCount, greenCount = ColorCode.applyToPhotos(allTagged)
    end)

    LrDialogs.message(
        "Color Code Identifications",
        string.format(
            "%d photo%s marked purple (Research Grade)\n%d photo%s marked blue (on iNat, not yet Research Grade)\n%d photo%s marked green (identified locally, not on iNat)",
            purpleCount, purpleCount == 1 and "" or "s",
            blueCount, blueCount == 1 and "" or "s",
            greenCount, greenCount == 1 and "" or "s"
        ),
        "info"
    )
end)
