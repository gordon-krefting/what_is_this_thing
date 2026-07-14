local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFunctionContext = import 'LrFunctionContext'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local ExportTemp = dofile(LrPathUtils.child(_PLUGIN.path, "ExportTemp.lua"))
local CandidatePicker = dofile(LrPathUtils.child(_PLUGIN.path, "CandidatePicker.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))

-- Below this confidence (%), preselect the best non-species entry (already
-- folded into the merged results) instead of the top species guess.
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

local function wikipediaUrl(name)
    local titled = name:gsub(" ", "_")
    titled = titled:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return "https://en.wikipedia.org/wiki/" .. titled
end

-- iNaturalist's own vision API already gives us each candidate's taxon id,
-- so the iNat link is free -- no extra lookup needed. Wikipedia's
-- consistent /wiki/Genus_species title pattern works reasonably well for
-- higher ranks too (e.g. "Lampyridae"), so it's added for every row.
local function linksForCandidate(r)
    local links = {}
    if r.id then
        table.insert(links, { label = "iNat", url = "https://www.inaturalist.org/taxa/" .. tostring(r.id) })
    end
    table.insert(links, { label = "Wikipedia", url = wikipediaUrl(r.scientificName) })
    return links
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

        local exportOk, photoPathsOrError, tempDir, sourcePhotos = LrTasks.pcall(ExportTemp.exportToTempJpegs, photos)

        if not exportOk then
            progressScope:done()
            LrDialogs.message("What is This Animal?", "Export failed: " .. tostring(photoPathsOrError), "critical")
            return
        end

        local photoPaths = photoPathsOrError

        -- Pair each exported path with its source photo's GPS (if any) so
        -- iNaturalist's geo-based accuracy boost applies wherever possible.
        local photoEntries = {}
        local missingGpsCount = 0
        for i, path in ipairs(photoPaths) do
            local gps = sourcePhotos[i] and sourcePhotos[i]:getRawMetadata("gps")
            local lat, lng = nil, nil
            if gps and gps.latitude and gps.longitude then
                lat, lng = gps.latitude, gps.longitude
            else
                missingGpsCount = missingGpsCount + 1
            end
            table.insert(photoEntries, { path = path, lat = lat, lng = lng })
        end

        local ok, resultsOrError = LrTasks.pcall(INaturalist.identifyAll, photoEntries, function(i, n)
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

        local hintLines = {}

        if missingGpsCount > 0 then
            if #photoPaths == 1 then
                table.insert(hintLines,
                    "Note: this photo has no GPS location data -- iNaturalist's location-based accuracy boost won't apply.")
            else
                table.insert(hintLines, string.format(
                    "Note: %d of %d selected photos have no GPS location data -- "
                        .. "iNaturalist's location-based accuracy boost won't apply for those.",
                    missingGpsCount, #photoPaths
                ))
            end
        end

        -- iNaturalist's per-photo common_ancestor rollups (if any) are
        -- already folded into `results` by identifyAll/mergeResults, so
        -- preselecting the best non-species entry covers both the
        -- single-photo and multi-photo cases.
        local defaultIndex = 1
        local bestSpecies = bestMatching(results, true)
        if not bestSpecies or bestSpecies.score < CONFIDENCE_THRESHOLD then
            local bestBroader = bestMatching(results, false)
            if bestBroader then
                for i, r in ipairs(results) do
                    if r == bestBroader then
                        defaultIndex = i
                        break
                    end
                end
                table.insert(hintLines, "Low confidence at species level -- best broader match preselected:")
            end
        end

        local hint = #hintLines > 0 and table.concat(hintLines, "\n") or nil

        local selected = CandidatePicker.choose("What is This Animal?", results, defaultIndex, hint, linksForCandidate)

        if selected then
            -- Best-effort enrichment: getMajorAncestry degrades to an empty
            -- list (flat "Species ID > name" tag) on any failure, so this
            -- never blocks the core tag/title/caption write.
            local ancestry = INaturalist.getMajorAncestry(selected.id)
            KeywordWriter.applyIdentification(photos, selected, ancestry)
            LrDialogs.message("What is This Animal?", "Tagged with: " .. selected.scientificName, "info")
        end
    end)
end)
