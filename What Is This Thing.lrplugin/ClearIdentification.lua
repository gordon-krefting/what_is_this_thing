local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'

local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))

-- Fully clears this plugin's identification data from the selected
-- photos -- species/taxon/iNat-link fields, the taxon-level facts, the
-- "Species ID" keyword, and Title/Caption (see
-- KeywordWriter.clearIdentification). For photos whose identification
-- turned out to be flat-out wrong -- e.g. a photo auto-linked to an
-- unrelated iNat observation by an early, since-fixed version of the
-- sync matcher -- not just mis-grouped with a real neighbor (see
-- SplitObservation.lua for that narrower case).
--
-- Confirms first -- unlike most commands in this plugin, this touches
-- Title/Caption directly (not just custom fields), so an accidental
-- multi-photo selection is more consequential to undo.
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Clear Identification", "No photos selected.", "info")
        return
    end

    local confirmResult = LrDialogs.confirm(
        "Clear Identification",
        string.format(
            "Clear all species identification data (including Title and Caption) from %d photo%s? "
                .. "This cannot be undone from within the plugin.",
            #photos, #photos == 1 and "" or "s"
        ),
        "Clear", "Cancel"
    )
    if confirmResult ~= "ok" then
        return
    end

    catalog:withWriteAccessDo("Clear identification", function()
        for _, photo in ipairs(photos) do
            KeywordWriter.clearIdentification(photo)
            PendingMetadataSave.markIfNeeded(catalog, photo)
        end
    end)

    LrDialogs.message(
        "Clear Identification",
        string.format("%d photo%s cleared.", #photos, #photos == 1 and "" or "s"),
        "info"
    )
end)
