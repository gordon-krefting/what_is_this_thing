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
                    iNatObservationId = photo:getPropertyForPlugin(_PLUGIN, "iNatObservationId"),
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
            -- Same disambiguation approach as the sync's own collision
            -- picker (resolveClusterManually, INatSyncRunner.lua) -- a
            -- text-only label isn't enough to tell two candidates apart
            -- when they share the same species (confirmed live 2026-08-04:
            -- two DISTINCT Vulpes vulpes candidates, both reading "Vulpes
            -- vulpes (Red Fox) -- 1 photo", gave no way to tell which was
            -- which). The radio's own title is just the filename -- short,
            -- immediately recognizable, and the actual selectable label;
            -- the thumbnail and iNat link status are the real
            -- differentiators, since the species name is identical by
            -- construction (that's exactly what makes these ambiguous).
            local candidateColumns = {}
            for i, group in ipairs(groupOrder) do
                local filename = group.representativePhoto:getFormattedMetadata("fileName") or "?"
                local radio = f:radio_button {
                    title = filename,
                    value = LrView.bind("chosenIndex"),
                    checked_value = i,
                    width_in_chars = 22,
                }
                local statusLines = {}
                if group.count > 1 then
                    table.insert(statusLines, group.count .. " photos in this group")
                end
                table.insert(statusLines,
                    group.iNatObservationId and ("Linked to iNat #" .. group.iNatObservationId) or "Not yet linked to iNat")
                local statusText = f:static_text {
                    title = table.concat(statusLines, "\n"),
                    width_in_chars = 22,
                    height_in_lines = 2,
                }
                local photoView = f:catalog_photo {
                    photo = group.representativePhoto,
                    width = 150,
                    height = 150,
                    frame_width = 1,
                }
                table.insert(candidateColumns, f:column { photoView, radio, statusText })
            end

            -- Only name the species in the intro line when every candidate
            -- actually shares one -- candidates can also be genuinely
            -- DIFFERENT species (see Case 4/mock_test_mergeobservation.lua),
            -- where naming just the first one would be misleading.
            local sameSpecies = true
            for _, group in ipairs(groupOrder) do
                if group.scientificName ~= groupOrder[1].scientificName then
                    sameSpecies = false
                    break
                end
            end
            local introText = "Multiple identifications found in the selection -- merge into:"
            if sameSpecies then
                local label = groupOrder[1].scientificName or "(unidentified)"
                if groupOrder[1].commonName then
                    label = label .. " (" .. groupOrder[1].commonName .. ")"
                end
                introText = "Multiple " .. label .. " identifications found in the selection -- merge into:"
            end

            local contents = f:column {
                bind_to_object = props,
                spacing = f:control_spacing(),
                f:static_text { title = introText },
                f:row(candidateColumns),
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
