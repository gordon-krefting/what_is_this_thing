local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'

local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))
local ColorCode = dofile(LrPathUtils.child(_PLUGIN.path, "ColorCode.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))

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
-- Also clears iNatObservationId/iNatObservationUrl/iNatQualityGrade/
-- iNatSuggestedId on the selected photos -- whatever they were linked to
-- (if anything) is no longer reliable once the group is split apart, so
-- the next "Sync from iNaturalist" run re-resolves each photo's real
-- match from scratch, now that they're independent. All four are cleared
-- together (2026-08-03 -- previously only the two link fields were,
-- leaving a stale quality grade/suggestion behind on an otherwise-unlinked
-- photo).
--
-- EXCEPT a recovered placeholder (iNatRecoveredPlaceholder == "yes",
-- see INatRecovery.lua): its filename IS the exact observation+photo pair
-- it was downloaded from ("iNat_<observationId>_<photoId>.jpg") -- there's
-- nothing uncertain about that link for sync to "re-resolve," so splitting
-- it into its own local observation must NOT also clear it (confirmed
-- live 2026-08-03: a merge-then-split on a placeholder alongside an
-- ordinary RAW lost the placeholder's own certain iNat id right along
-- with the RAW's genuinely-uncertain one).
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Split Observation", "No photos selected.", "info")
        return
    end

    catalog:withWriteAccessDo("Split into separate observations", function()
        local unlinkedPhotos = {}
        for _, photo in ipairs(photos) do
            photo:setPropertyForPlugin(_PLUGIN, "observationId", KeywordWriter.generateUUID())
            if photo:getPropertyForPlugin(_PLUGIN, "iNatRecoveredPlaceholder") ~= "yes" then
                photo:setPropertyForPlugin(_PLUGIN, "iNatObservationId", nil)
                photo:setPropertyForPlugin(_PLUGIN, "iNatObservationUrl", nil)
                photo:setPropertyForPlugin(_PLUGIN, "iNatQualityGrade", nil)
                photo:setPropertyForPlugin(_PLUGIN, "iNatSuggestedId", nil)
                table.insert(unlinkedPhotos, photo)
            end
            PendingMetadataSave.markIfNeeded(catalog, photo)
        end
        -- The color label (if any) reflected the OLD, now-broken link --
        -- recompute now that iNatObservationId is cleared, so a
        -- previously purple/blue photo correctly drops to green (still
        -- identified locally, just no longer linked) rather than keeping
        -- a stale color that no longer means anything. Only for the
        -- photos actually unlinked above -- a preserved placeholder's
        -- color is untouched by this transaction, so it's safe (and
        -- correct) to just leave it alone entirely. ColorCode.CLEARED
        -- (not plain nil) signals "just explicitly cleared in THIS
        -- transaction" -- confirmed live 2026-08-02 that reading a
        -- just-written value back here isn't reliable. observationId is
        -- read live (safe even though a fresh UUID was also just written
        -- above -- every photo reaching this command already had SOME
        -- non-nil observationId before the split, so the presence check
        -- this relies on gives the same true/false answer either way).
        ColorCode.applyToPhotos(unlinkedPhotos, { iNatObservationId = ColorCode.CLEARED })
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
