local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFunctionContext = import 'LrFunctionContext'

local PlantNet = dofile(LrPathUtils.child(_PLUGIN.path, "PlantNet.lua"))
local ExportTemp = dofile(LrPathUtils.child(_PLUGIN.path, "ExportTemp.lua"))

-- Below this confidence (%), lead with the best family/genus rollup instead
-- of a pile of uncertain species guesses.
local CONFIDENCE_THRESHOLD = 85

local function formatEntry(r)
    local label = r.scientificName
    if r.commonName then
        label = r.commonName .. " (" .. r.scientificName .. ")"
    end
    if r.rank then
        label = label .. " [" .. r.rank .. "]"
    end
    return string.format("%5.1f%%  %s", r.score, label)
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("What is This Plant?", "No photos selected.", "info")
        return
    end

    LrFunctionContext.callWithContext("WhatIsThisPlantLookup", function(context)
        local progressScope = LrDialogs.showModalProgressDialog {
            title = "What is This Plant?",
            caption = "Exporting photos...",
            cannotCancel = true,
            functionContext = context,
        }

        local exportOk, photoPathsOrError, tempDir = LrTasks.pcall(ExportTemp.exportToTempJpegs, photos)

        if not exportOk then
            progressScope:done()
            LrDialogs.message("What is This Plant?", "Export failed: " .. tostring(photoPathsOrError), "critical")
            return
        end

        local photoPaths = photoPathsOrError

        progressScope:setCaption("Looking up species...")

        local ok, identifyResultOrError = LrTasks.pcall(PlantNet.identify, photoPaths)

        ExportTemp.cleanup(tempDir)
        progressScope:done()

        if not ok then
            LrDialogs.message("What is This Plant?", "Lookup failed: " .. tostring(identifyResultOrError), "critical")
            return
        end

        local results = identifyResultOrError.results
        local genusResults = identifyResultOrError.genusResults
        local familyResults = identifyResultOrError.familyResults

        if #results == 0 then
            LrDialogs.message("What is This Plant?", "No matches found.", "info")
            return
        end

        local lines = {}

        local bestSpecies = results[1]
        if bestSpecies.score < CONFIDENCE_THRESHOLD then
            -- Pl@ntNet's "detailed" rollup always includes these when
            -- available, unlike iNaturalist's confidence-gated common
            -- ancestor -- lead with whichever of family/genus is present.
            if familyResults[1] then
                table.insert(lines, "Low confidence at species level -- best family match:")
                table.insert(lines, "  " .. formatEntry(familyResults[1]))
                table.insert(lines, "")
            end
            if genusResults[1] then
                table.insert(lines, "Best genus match:")
                table.insert(lines, "  " .. formatEntry(genusResults[1]))
                table.insert(lines, "")
            end
        end

        for _, r in ipairs(results) do
            table.insert(lines, formatEntry(r))
        end

        LrDialogs.message(
            "Pl@ntNet Suggestions",
            table.concat(lines, "\n"),
            "info"
        )
    end)
end)
