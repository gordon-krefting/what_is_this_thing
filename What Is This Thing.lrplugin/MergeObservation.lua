local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'

local ObservationMerge = dofile(LrPathUtils.child(_PLUGIN.path, "ObservationMerge.lua"))

-- Inverse of SplitObservation.lua: merges every selected photo into ONE
-- observation, sharing a single Observation ID, all carrying the same
-- identification as the "master" photo (Lightroom's own "most selected"
-- photo -- catalog:getTargetPhoto() -- the same convention Lightroom's
-- native Photo > Sync Settings uses for its source photo). Confirmed live
-- (2026-07-23): the master is whichever photo you click FIRST -- the cell
-- that gets the lighter/active border -- not the last one; subsequent
-- cmd/ctrl-clicks add to the selection without changing which one is
-- active.
--
-- Exists for the case surfaced by "Sync from iNaturalist"'s photo-count
-- mismatch report: an iNat observation has more photos than the matched
-- local group, because some sibling photos were never run through this
-- plugin's identify flow at all -- click the already-identified photo
-- FIRST, then cmd/ctrl-click its untagged siblings to add them to the
-- selection, run this, and they all end up as one group with the master's
-- identification and iNat link, ready for the next sync to reconcile
-- cleanly. For when you already know exactly which photos belong together
-- -- see SuggestMergeCandidates.lua for an assisted picker that suggests
-- candidates for you.
--
-- Actual merge logic lives in ObservationMerge.lua, shared with
-- SuggestMergeCandidates.lua.
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()
    local master = catalog:getTargetPhoto()

    if #photos < 2 then
        LrDialogs.message("Merge Observation", "Select at least 2 photos -- the already-identified one plus its untagged siblings.", "info")
        return
    end

    if not master then
        LrDialogs.message("Merge Observation", "No most-selected photo found -- select the photos, making sure the already-identified one is the first one you click.", "info")
        return
    end

    if not master:getPropertyForPlugin(_PLUGIN, "scientificName") then
        LrDialogs.message(
            "Merge Observation",
            "The most-selected photo (the first one you clicked) needs to already be identified -- it's used as the master.\n\n"
                .. "Click the identified photo FIRST, then cmd/ctrl-click the untagged siblings to add them, then try again.",
            "info"
        )
        return
    end

    local others = {}
    for _, photo in ipairs(photos) do
        if photo ~= master then
            table.insert(others, photo)
        end
    end

    local resolvedCandidate, orderedPhotos = ObservationMerge.merge(master, others)

    LrDialogs.message(
        "Merge Observation",
        string.format("%d photos merged into one observation (%s).", #orderedPhotos, resolvedCandidate.scientificName),
        "info"
    )
end)
