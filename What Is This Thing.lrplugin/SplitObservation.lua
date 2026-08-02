local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'

local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))
local ColorCode = dofile(LrPathUtils.child(_PLUGIN.path, "ColorCode.lua"))

-- Splits each selected photo into its OWN separate observation -- gives
-- every selected photo a fresh, distinct Observation ID, breaking it apart
-- from whatever group (shared Observation ID) it currently belongs to.
--
-- Exists for the case where photos were mistakenly identified together in
-- one batch (e.g. two different individuals of the same species,
-- photographed separately but selected together when running an identify
-- command) -- the sync's matching logic can't split one local group across
-- two different iNat observations, so this needs to happen manually first.
--
-- Also clears iNatObservationId/iNatObservationUrl on the selected photos
-- -- whatever they were linked to (if anything) is no longer reliable once
-- the group is split apart, so the next "Sync from iNaturalist" run
-- re-resolves each photo's real match from scratch, now that they're
-- independent.
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Split Observation", "No photos selected.", "info")
        return
    end

    catalog:withWriteAccessDo("Split into separate observations", function()
        for _, photo in ipairs(photos) do
            photo:setPropertyForPlugin(_PLUGIN, "observationId", KeywordWriter.generateUUID())
            photo:setPropertyForPlugin(_PLUGIN, "iNatObservationId", nil)
            photo:setPropertyForPlugin(_PLUGIN, "iNatObservationUrl", nil)
        end
        -- The color label (if any) reflected the OLD, now-broken link --
        -- recompute now that iNatObservationId is cleared, so a
        -- previously purple/blue photo correctly drops to green (still
        -- identified locally, just no longer linked) rather than keeping
        -- a stale color that no longer means anything. ColorCode.CLEARED
        -- (not plain nil) signals "just explicitly cleared in THIS
        -- transaction" -- confirmed live 2026-08-02 that reading a
        -- just-written value back here isn't reliable. observationId is
        -- read live (safe even though a fresh UUID was also just written
        -- above -- every photo reaching this command already had SOME
        -- non-nil observationId before the split, so the presence check
        -- this relies on gives the same true/false answer either way).
        ColorCode.applyToPhotos(photos, { iNatObservationId = ColorCode.CLEARED })
    end)

    LrDialogs.message(
        "Split Observation",
        string.format(
            "%d photo%s split into %s own separate observation%s.",
            #photos, #photos == 1 and "" or "s",
            #photos == 1 and "its" or "their", #photos == 1 and "" or "s"
        ),
        "info"
    )
end)
