local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFunctionContext = import 'LrFunctionContext'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local ExportTemp = dofile(LrPathUtils.child(_PLUGIN.path, "ExportTemp.lua"))

-- Below this confidence (%), prefer a coarser (non-species) match over a
-- pile of uncertain species guesses, if the merged results offer one.
local CONFIDENCE_THRESHOLD = 85

local function isSpecies(r)
    return r.rank == nil or r.rank == "species"
end

-- Highest-scoring entry matching the given species/non-species filter, or nil.
local function bestMatching(results, wantSpecies)
    local best = nil
    for _, r in ipairs(results) do
        if isSpecies(r) == wantSpecies and (not best or r.score > best.score) then
            best = r
        end
    end
    return best
end

local function formatEntry(r)
    local label = r.scientificName
    if r.commonName then
        label = r.commonName .. " (" .. r.scientificName .. ")"
    end
    if r.rank and r.rank ~= "species" then
        label = label .. " [" .. r.rank .. "]"
    end
    return string.format("%5.1f%%  %s", r.score, label)
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("What is This Animal?", "No photos selected.", "info")
        return
    end

    LrFunctionContext.callWithContext("WhatIsThisAnimalLookup", function(context)
        local progressScope = LrDialogs.showModalProgressDialog {
            title = "What is This Animal?",
            caption = "Exporting photos...",
            cannotCancel = true,
            functionContext = context,
        }

        local exportOk, photoPathsOrError, tempDir = LrTasks.pcall(ExportTemp.exportToTempJpegs, photos)

        if not exportOk then
            progressScope:done()
            LrDialogs.message("What is This Animal?", "Export failed: " .. tostring(photoPathsOrError), "critical")
            return
        end

        local photoPaths = photoPathsOrError

        local ok, resultsOrError = LrTasks.pcall(INaturalist.identifyAll, photoPaths, function(i, n)
            if n > 1 then
                progressScope:setCaption(string.format("Looking up species (%d/%d)...", i, n))
            else
                progressScope:setCaption("Looking up species...")
            end
        end)

        ExportTemp.cleanup(tempDir)
        progressScope:done()

        if not ok then
            LrDialogs.message("What is This Animal?", "Lookup failed: " .. tostring(resultsOrError), "critical")
            return
        end

        local results = resultsOrError

        if #results == 0 then
            LrDialogs.message("What is This Animal?", "No matches found.", "info")
            return
        end

        local lines = {}

        -- iNaturalist's per-photo common_ancestor rollups (if any) are
        -- already folded into `results` by identifyAll/mergeResults, so a
        -- single scan for the best non-species entry covers both the
        -- single-photo and multi-photo cases.
        local bestSpecies = bestMatching(results, true)
        if not bestSpecies or bestSpecies.score < CONFIDENCE_THRESHOLD then
            local bestBroader = bestMatching(results, false)
            if bestBroader then
                table.insert(lines, "Low confidence at species level -- best broader match:")
                table.insert(lines, "  " .. formatEntry(bestBroader))
                table.insert(lines, "")
            end
        end

        for _, r in ipairs(results) do
            table.insert(lines, formatEntry(r))
        end

        LrDialogs.message(
            "iNaturalist Suggestions",
            table.concat(lines, "\n"),
            "info"
        )
    end)
end)
