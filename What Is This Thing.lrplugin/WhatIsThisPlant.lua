local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFunctionContext = import 'LrFunctionContext'

local PlantNet = dofile(LrPathUtils.child(_PLUGIN.path, "PlantNet.lua"))
local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local ExportTemp = dofile(LrPathUtils.child(_PLUGIN.path, "ExportTemp.lua"))
local CandidatePicker = dofile(LrPathUtils.child(_PLUGIN.path, "CandidatePicker.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))

-- Below this confidence (%), preselect the best family/genus rollup instead
-- of the top species guess.
local CONFIDENCE_THRESHOLD = 85

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

        -- Pl@ntNet's "detailed" rollup always includes these when available
        -- (unlike iNaturalist's confidence-gated common ancestor), so fold
        -- the best family/genus entries in as selectable candidates too,
        -- preselecting family (or genus, if no family) when species
        -- confidence is low.
        local candidates = {}
        local defaultIndex = 1
        local hint = nil

        local bestSpecies = results[1]
        if bestSpecies.score < CONFIDENCE_THRESHOLD then
            if familyResults[1] then
                table.insert(candidates, familyResults[1])
                defaultIndex = #candidates
                hint = "Low confidence at species level -- best family match preselected:"
            end
            if genusResults[1] then
                table.insert(candidates, genusResults[1])
                if not hint then
                    defaultIndex = #candidates
                    hint = "Low confidence at species level -- best genus match preselected:"
                end
            end
        end
        for _, r in ipairs(results) do
            table.insert(candidates, r)
        end

        local selected = CandidatePicker.choose("What is This Plant?", candidates, defaultIndex, hint)

        if selected then
            -- Resolve through iNaturalist's taxonomy (by name -- Pl@ntNet
            -- results carry a GBIF id, not an iNat one) so plant and animal
            -- identifications end up filed under the same taxonomic tree.
            -- Best-effort: degrades to an empty list (flat "Species ID >
            -- name" tag) on any failure, never blocking the core write.
            local ancestry = INaturalist.getMajorAncestryByName(selected.scientificName, selected.rank)
            KeywordWriter.applyIdentification(photos, selected, ancestry)
            LrDialogs.message("What is This Plant?", "Tagged with: " .. selected.scientificName, "info")
        end
    end)
end)
