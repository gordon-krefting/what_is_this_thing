local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFunctionContext = import 'LrFunctionContext'

local PlantNet = dofile(LrPathUtils.child(_PLUGIN.path, "PlantNet.lua"))
local ExportTemp = dofile(LrPathUtils.child(_PLUGIN.path, "ExportTemp.lua"))

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("What is this Thing?", "No photos selected.", "info")
        return
    end

    LrFunctionContext.callWithContext("WhatIsThisThingLookup", function(context)
        local progressScope = LrDialogs.showModalProgressDialog {
            title = "What is this Thing?",
            caption = "Exporting photos...",
            cannotCancel = true,
            functionContext = context,
        }

        local exportOk, photoPathsOrError, tempDir = LrTasks.pcall(ExportTemp.exportToTempJpegs, photos)

        if not exportOk then
            progressScope:done()
            LrDialogs.message("What is this Thing?", "Export failed: " .. tostring(photoPathsOrError), "critical")
            return
        end

        local photoPaths = photoPathsOrError

        progressScope:setCaption("Looking up species...")

        local ok, resultsOrError = LrTasks.pcall(PlantNet.identify, photoPaths)

        ExportTemp.cleanup(tempDir)
        progressScope:done()

        if not ok then
            LrDialogs.message("What is this Thing?", "Lookup failed: " .. tostring(resultsOrError), "critical")
            return
        end

        local results = resultsOrError
        if #results == 0 then
            LrDialogs.message("What is this Thing?", "No matches found.", "info")
            return
        end

        local lines = {}
        for _, r in ipairs(results) do
            local label = r.scientificName
            if r.commonName then
                label = r.commonName .. " (" .. r.scientificName .. ")"
            end
            table.insert(lines, string.format("%5.1f%%  %s", r.score, label))
        end

        LrDialogs.message(
            "Pl@ntNet Suggestions",
            table.concat(lines, "\n"),
            "info"
        )
    end)
end)
