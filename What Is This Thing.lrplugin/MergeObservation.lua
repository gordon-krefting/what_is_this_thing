local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

local ObservationMerge = dofile(LrPathUtils.child(_PLUGIN.path, "ObservationMerge.lua"))

-- Inverse of SplitObservation.lua: merges every selected photo into ONE
-- observation, sharing a single Observation ID, all carrying the same
-- identification as whichever existing identification is chosen as
-- master.
--
-- Used to rely on Lightroom's own "most selected" photo
-- (catalog:getTargetPhoto(), confirmed live 2026-07-23 to be whichever
-- photo you click FIRST, not the last one) as the master -- fragile in
-- practice: easy to click the wrong photo first, and if more than one
-- selected photo was already identified, whichever happened to be
-- clicked first silently won with no chance to notice. Now finds every
-- DISTINCT existing identification among the selected photos (grouped by
-- the local Observation ID, not just scientificName -- two genuinely
-- separate already-linked observations could coincidentally share a
-- species name, and grouping by Observation ID keeps them correctly
-- distinct, matching the same split-detection concept SetCultivar.lua
-- already uses). Zero identified photos: nothing to merge into, same
-- error as before. Exactly one: no ambiguity, proceeds immediately, no
-- dialog. More than one: asks explicitly which identification should
-- win, rather than leaving it to click order.
--
-- Exists for the case surfaced by "Sync from iNaturalist"'s photo-count
-- mismatch report: an iNat observation has more photos than the matched
-- local group, because some sibling photos were never run through this
-- plugin's identify flow at all -- select the already-identified photo(s)
-- plus the untagged siblings, run this, and they all end up as one group
-- with the chosen identification and iNat link, ready for the next sync
-- to reconcile cleanly. For when you already know exactly which photos
-- belong together -- see MergeCandidatesDialog.lua for the assisted
-- picker used by the sync mismatch-resolution flow instead.
--
-- Actual merge logic lives in ObservationMerge.lua, shared with
-- MergeCandidatesDialog.lua.
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos < 2 then
        LrDialogs.message("Merge Observation", "Select at least 2 photos -- the already-identified one(s) plus any untagged siblings.", "info")
        return
    end

    local groupsById = {}
    local groupOrder = {}
    for _, photo in ipairs(photos) do
        local obsId = photo:getPropertyForPlugin(_PLUGIN, "observationId")
        if obsId then
            local group = groupsById[obsId]
            if not group then
                group = {
                    representativePhoto = photo,
                    scientificName = photo:getPropertyForPlugin(_PLUGIN, "scientificName"),
                    commonName = photo:getPropertyForPlugin(_PLUGIN, "commonName"),
                    count = 0,
                }
                groupsById[obsId] = group
                table.insert(groupOrder, group)
            end
            group.count = group.count + 1
        end
    end

    if #groupOrder == 0 then
        LrDialogs.message(
            "Merge Observation",
            "None of the selected photos are identified yet -- identify at least one first, then select it "
                .. "along with the untagged siblings to merge, and try again.",
            "info"
        )
        return
    end

    local master = nil

    if #groupOrder == 1 then
        master = groupOrder[1].representativePhoto
    else
        LrFunctionContext.callWithContext("MergeObservationChoice", function(context)
            local props = LrBinding.makePropertyTable(context)
            props.chosenIndex = 1

            local f = LrView.osFactory()
            local radios = {}
            for i, group in ipairs(groupOrder) do
                local label = group.scientificName or "(unidentified)"
                if group.commonName then
                    label = label .. " (" .. group.commonName .. ")"
                end
                label = label .. string.format(" -- %d photo%s", group.count, group.count == 1 and "" or "s")
                table.insert(radios, f:radio_button {
                    title = label,
                    value = LrView.bind("chosenIndex"),
                    checked_value = i,
                })
            end

            local contents = f:column {
                bind_to_object = props,
                spacing = f:control_spacing(),
                f:static_text { title = "Multiple identifications found in the selection -- merge into:" },
                f:column(radios),
            }

            local result = LrDialogs.presentModalDialog {
                title = "Merge Observation",
                contents = contents,
                actionVerb = "Merge",
                cancelVerb = "Cancel",
            }

            if result == "ok" then
                master = groupOrder[props.chosenIndex].representativePhoto
            end
        end)

        if not master then
            return
        end
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
