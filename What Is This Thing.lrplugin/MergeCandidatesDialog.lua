local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrHttp = import 'LrHttp'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local ObservationMerge = dofile(LrPathUtils.child(_PLUGIN.path, "ObservationMerge.lua"))

-- Shared by SuggestMergeCandidates.lua (manual command, one photo at a
-- time) and INatSyncRunner.lua (popped up automatically during a sync run
-- whenever a photo-count mismatch is found -- see there for the
-- "Skip All Remaining" volume-control escape hatch, since a single Full
-- Sync can surface dozens of these at once).
--
-- Built on a pattern the user confirmed working through a batch of real
-- mismatches by hand: the missing sibling photos are almost always
-- positionally adjacent to the master in capture-time order (the same
-- shoot/session), regardless of the actual time gap -- not bounded by a
-- fixed tolerance window the way the sync's own time-based fallback is.
-- So this looks up to WINDOW_SIZE photos immediately before and after the
-- master in the WHOLE catalog's time-sorted order (excluding the master's
-- own existing group), and presents them as a checklist.
local MergeCandidatesDialog = {}

local WINDOW_SIZE = 3

function MergeCandidatesDialog.isEligible(photo)
    return not photo:getPropertyForPlugin(_PLUGIN, "observationId")
        and not photo:getPropertyForPlugin(_PLUGIN, "scientificName")
end

local function formatTimeDelta(deltaSeconds)
    local sign = deltaSeconds < 0 and "-" or "+"
    local abs = math.abs(deltaSeconds)
    if abs < 60 then
        return sign .. string.format("%ds", math.floor(abs))
    elseif abs < 3600 then
        return sign .. string.format("%dm%02ds", math.floor(abs / 60), math.floor(abs % 60))
    else
        return sign .. string.format("%dh%02dm", math.floor(abs / 3600), math.floor((abs % 3600) / 60))
    end
end

-- Finds up to WINDOW_SIZE photos immediately before and after `master` in
-- the whole catalog's time-sorted order, excluding the master itself and
-- any photo already sharing its local Observation ID (already part of the
-- same group, not a candidate). Returns before, after (each a list of
-- { photo, time }, chronological order), masterTime -- or nil, nil, nil if
-- the master has no capture time to sort by.
function MergeCandidatesDialog.buildCandidateWindow(catalog, master, masterObservationId)
    local masterTime = master:getRawMetadata("dateTimeOriginal")
    if not masterTime then
        return nil, nil, nil
    end

    local sorted = {}
    for _, photo in ipairs(catalog:getAllPhotos()) do
        if photo ~= master then
            local ownId = photo:getPropertyForPlugin(_PLUGIN, "observationId")
            local alreadyInMasterGroup = masterObservationId and ownId == masterObservationId
            if not alreadyInMasterGroup then
                local t = photo:getRawMetadata("dateTimeOriginal")
                if t then
                    table.insert(sorted, { photo = photo, time = t })
                end
            end
        end
    end
    table.sort(sorted, function(a, b) return a.time < b.time end)

    local lo, hi = 1, #sorted
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if sorted[mid].time < masterTime then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    local before = {}
    for i = lo - 1, math.max(1, lo - WINDOW_SIZE), -1 do
        table.insert(before, 1, sorted[i])
    end
    local after = {}
    for i = lo, math.min(#sorted, lo + WINDOW_SIZE - 1) do
        table.insert(after, sorted[i])
    end

    return before, after, masterTime
end

function MergeCandidatesDialog.hasEligibleCandidate(beforeEntries, afterEntries)
    for _, entry in ipairs(beforeEntries or {}) do
        if MergeCandidatesDialog.isEligible(entry.photo) then return true end
    end
    for _, entry in ipairs(afterEntries or {}) do
        if MergeCandidatesDialog.isEligible(entry.photo) then return true end
    end
    return false
end

local function buildNeighborColumn(f, entry, masterTime, key)
    local photo = entry.photo
    local delta = formatTimeDelta(entry.time - masterTime)
    local fileName = photo:getFormattedMetadata("fileName") or "?"

    local column = {
        f:catalog_photo { photo = photo, width = 150, height = 150, frame_width = 1 },
    }
    if not photo:checkPhotoAvailability() then
        table.insert(column, f:static_text { title = "(file not currently available)", width_in_chars = 22 })
    end

    if MergeCandidatesDialog.isEligible(photo) then
        table.insert(column, f:checkbox {
            title = fileName .. " (" .. delta .. ")",
            value = LrView.bind(key),
            width_in_chars = 22,
        })
    else
        local existing = photo:getPropertyForPlugin(_PLUGIN, "scientificName")
        local label = existing and ("already: " .. existing) or "already grouped"
        table.insert(column, f:static_text {
            title = fileName .. " (" .. delta .. ")\n" .. label,
            width_in_chars = 22,
        })
    end

    return f:column(column)
end

-- Presents the picker dialog for one master photo and performs the merge
-- if confirmed. `options`: catalog, master, beforeEntries, afterEntries,
-- masterTime (all from buildCandidateWindow), allowSkipAll (whether to
-- show the "Skip All Remaining" button -- used by the sync loop to let the
-- user bail out of reviewing a large batch mid-run).
--
-- Re-fetches iNat's real photo count and the current local group size
-- itself (network call). If that confirms there's no actual shortfall
-- (iNat doesn't have more photos than the local group already does), the
-- dialog is never even shown -- see the "noShortfall" outcome below; a
-- real live case triggered this via a filename-only mismatch (iNat's
-- stored name for a photo didn't match the local file) where the counts
-- already matched, so there was never a missing sibling to search for.
-- Otherwise, if what gets checked doesn't match the shortfall, a confirm
-- prompt gates the merge rather than silently proceeding or blocking
-- outright.
--
-- Returns outcome ("merged" | "nothingSelected" | "canceled" | "skipAll" |
-- "noShortfall"), mergedPhotos (the newly-added photos, NOT including
-- master -- only set when outcome == "merged"), resolvedCandidate (only
-- when "merged").
function MergeCandidatesDialog.presentAndMerge(options)
    local catalog = options.catalog
    local master = options.master
    local beforeEntries = options.beforeEntries
    local afterEntries = options.afterEntries
    local masterTime = options.masterTime
    local allowSkipAll = options.allowSkipAll

    local masterINatObservationId = master:getPropertyForPlugin(_PLUGIN, "iNatObservationId")
    local masterINatObservationUrl = master:getPropertyForPlugin(_PLUGIN, "iNatObservationUrl")
    local masterObservationId = master:getPropertyForPlugin(_PLUGIN, "observationId")

    -- Network calls -- must happen before the modal dialog, not inside it.
    local masterGroupPhotos = {}
    for _, photo in ipairs(catalog:getAllPhotos()) do
        if photo == master or (masterObservationId and photo:getPropertyForPlugin(_PLUGIN, "observationId") == masterObservationId) then
            table.insert(masterGroupPhotos, photo)
        end
    end
    local iNatCount = INaturalist.getObservationPhotoCount(masterINatObservationId)
    local shortfall = iNatCount and (iNatCount - #masterGroupPhotos) or nil

    -- The original mismatch that triggered offering this picker could have
    -- been filename-based (iNat's stored name for a photo doesn't match
    -- the local file -- e.g. a rename) with the COUNTS already equal --
    -- confirmed live: a dialog popped up saying "iNat reports 1, you have
    -- 1 (no more expected)" with 6 completely unrelated neighbor photos
    -- shown, since there was never an actual missing sibling to search
    -- for. The picker only makes sense when iNat genuinely has MORE
    -- photos than the local group -- if a fresh count confirms there's no
    -- real shortfall, skip the picker entirely (don't even open the
    -- dialog) and let it fall through to the normal mismatch log, same as
    -- "no eligible candidate nearby".
    if shortfall and shortfall <= 0 then
        return "noShortfall", nil, nil
    end

    -- If we get here, either the count fetch failed (iNatCount nil) or it
    -- succeeded with a genuine positive shortfall (the <= 0 case already
    -- returned above) -- shortfall is never nil-but-reachable here.
    local countLine
    if iNatCount then
        countLine = string.format(
            "iNat reports %d photo(s); you currently have %d locally attached. (%d more expected)",
            iNatCount, #masterGroupPhotos, shortfall
        )
    else
        countLine = "Couldn't verify iNat's photo count right now -- use the link above to check."
    end

    local outcome = "canceled"
    local mergedPhotos = nil
    local resolvedCandidate = nil

    LrFunctionContext.callWithContext("MergeCandidatesDialog", function(context)
        local props = LrBinding.makePropertyTable(context)
        local f = LrView.osFactory()

        local checkboxPhotoForKey = {}
        local beforeColumns = {}
        for i, entry in ipairs(beforeEntries) do
            local key = "before_" .. i
            props[key] = false
            checkboxPhotoForKey[key] = entry.photo
            table.insert(beforeColumns, buildNeighborColumn(f, entry, masterTime, key))
        end
        local afterColumns = {}
        for i, entry in ipairs(afterEntries) do
            local key = "after_" .. i
            props[key] = false
            checkboxPhotoForKey[key] = entry.photo
            table.insert(afterColumns, buildNeighborColumn(f, entry, masterTime, key))
        end

        local masterColumn = f:column {
            f:catalog_photo { photo = master, width = 150, height = 150, frame_width = 1 },
            f:static_text { title = "MASTER: " .. (master:getFormattedMetadata("fileName") or "?") },
        }

        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:push_button {
                title = "View on iNat",
                action = function() LrHttp.openUrlInBrowser(masterINatObservationUrl) end,
            },
            f:static_text { title = countLine },
            f:row { masterColumn },
            f:static_text { title = "Before (older):" },
            f:row(beforeColumns),
            f:static_text { title = "After (newer):" },
            f:row(afterColumns),
        }

        local dialogArgs = {
            title = "Suggest Merge Candidates",
            contents = contents,
            actionVerb = "Merge Checked",
            cancelVerb = "Cancel",
        }
        if allowSkipAll then
            dialogArgs.otherVerb = "Skip All Remaining"
        end

        local result = LrDialogs.presentModalDialog(dialogArgs)

        if result == "other" then
            outcome = "skipAll"
            return
        end
        if result ~= "ok" then
            outcome = "canceled"
            return
        end

        local checked = {}
        for key, photo in pairs(checkboxPhotoForKey) do
            if props[key] then
                table.insert(checked, photo)
            end
        end

        if #checked == 0 then
            outcome = "nothingSelected"
            return
        end

        if shortfall and #checked ~= shortfall then
            local confirmResult = LrDialogs.confirm(
                "Selected count doesn't match iNat's count",
                string.format("You've selected %d photo(s), but iNat reports %d more are expected. Merge anyway?", #checked, shortfall),
                "Merge Anyway", "Cancel"
            )
            if confirmResult ~= "ok" then
                outcome = "canceled"
                return
            end
        end

        resolvedCandidate = ObservationMerge.merge(master, checked)
        outcome = "merged"
        mergedPhotos = checked
    end)

    return outcome, mergedPhotos, resolvedCandidate
end

return MergeCandidatesDialog
