local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFunctionContext = import 'LrFunctionContext'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local PlantNet = dofile(LrPathUtils.child(_PLUGIN.path, "PlantNet.lua"))
local ExportTemp = dofile(LrPathUtils.child(_PLUGIN.path, "ExportTemp.lua"))
local CandidatePicker = dofile(LrPathUtils.child(_PLUGIN.path, "CandidatePicker.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))
local GpsPrompt = dofile(LrPathUtils.child(_PLUGIN.path, "GpsPrompt.lua"))
local ManualEntry = dofile(LrPathUtils.child(_PLUGIN.path, "ManualEntry.lua"))

-- Below this confidence (%), preselect the best non-species entry (already
-- folded into the merged results) instead of the top species guess.
local CONFIDENCE_THRESHOLD = 85

-- This command expects a handful of photos of the *same* organism from
-- different angles, not an arbitrary batch -- more than this is almost
-- always an accidental over-selection, and would mean that many
-- sequential iNaturalist API calls.
local MAX_PHOTOS = 4

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
        LrDialogs.message("iNaturalist Identification", "No photos selected.", "info")
        return
    end

    if #photos > MAX_PHOTOS then
        LrDialogs.message(
            "iNaturalist Identification",
            string.format(
                "You selected %d photos, but this command expects at most %d -- a few angles of the same animal, not a batch. Select fewer photos and try again.",
                #photos, MAX_PHOTOS
            ),
            "info"
        )
        return
    end

    if not GpsPrompt.ensureGpsOnAllPhotos(photos, "iNaturalist uses for a real accuracy boost") then
        return
    end

    LrFunctionContext.callWithContext("WhatIsThisAnimalLookup", function(context)
        local progressScope = LrDialogs.showModalProgressDialog {
            title = "iNaturalist Identification",
            caption = "Exporting photos...",
            cannotCancel = true,
            functionContext = context,
        }

        local exportOk, photoPathsOrError, tempDir, sourcePhotos = LrTasks.pcall(ExportTemp.exportToTempJpegs, photos)

        if not exportOk then
            progressScope:done()
            LrDialogs.message("iNaturalist Identification", "Export failed: " .. tostring(photoPathsOrError), "critical")
            return
        end

        local photoPaths = photoPathsOrError

        -- Every photo is guaranteed GPS at this point (ensureGpsOnAllPhotos
        -- either found it already present or just wrote it), so this always
        -- feeds iNaturalist's geo-based accuracy boost.
        local photoEntries = {}
        for i, path in ipairs(photoPaths) do
            local gps = sourcePhotos[i] and sourcePhotos[i]:getRawMetadata("gps")
            table.insert(photoEntries, {
                path = path,
                lat = gps and gps.latitude,
                lng = gps and gps.longitude,
            })
        end

        local ok, resultsOrError = LrTasks.pcall(INaturalist.identifyAll, photoEntries, function(i, n)
            if n > 1 then
                progressScope:setCaption(string.format("Looking up species (%d/%d)...", i, n))
            else
                progressScope:setCaption("Looking up species...")
            end
        end)

        progressScope:done()

        if not ok then
            ExportTemp.cleanup(tempDir)
            LrDialogs.message("iNaturalist Identification", "Lookup failed: " .. tostring(resultsOrError), "critical")
            return
        end

        local results = resultsOrError

        local selected, ancestry

        if #results == 0 then
            -- No automatic match at all -- go straight to manual entry
            -- rather than just giving up.
            selected, ancestry = ManualEntry.promptAndResolve()
        else
            -- iNaturalist's per-photo common_ancestor rollups (if any) are
            -- already folded into `results` by identifyAll/mergeResults, so
            -- preselecting the best non-species entry covers both the
            -- single-photo and multi-photo cases.
            local defaultIndex = 1
            local hint = nil
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
                    hint = "Low confidence at species level -- best broader match preselected:"
                end
            end

            -- currentCandidates/sectionLabelForIndex/offerOtherService can
            -- all change after one pass through the loop below, if the user
            -- asks to also try Pl@ntNet -- see the loop comment.
            local currentCandidates = results
            local sectionLabelForIndex = nil
            local offerOtherService = "Also try Pl@ntNet"
            local wantManualEntry, wantOtherService

            -- Runs at most twice: once with just iNaturalist's own results,
            -- and again with Pl@ntNet's folded in as a second labeled
            -- section if the user asks for it (offerOtherService is cleared
            -- either way after that, so this can't loop a third time).
            -- Candidates from the two services are shown side by side, not
            -- merged/deduped -- see CandidatePicker.choose's doc comment.
            repeat
                local existingCounts = KeywordWriter.countExistingPhotos(currentCandidates)
                selected, wantManualEntry, wantOtherService = CandidatePicker.choose(
                    "iNaturalist Identification", currentCandidates, defaultIndex, hint, linksForCandidate,
                    function(r) return existingCounts[r] end,
                    function() return INaturalist.commonAncestorOf(currentCandidates) end,
                    offerOtherService,
                    sectionLabelForIndex
                )

                if wantOtherService then
                    offerOtherService = nil -- only one other service to try

                    LrFunctionContext.callWithContext("TryPlantNet", function(innerContext)
                        local plantNetProgress = LrDialogs.showModalProgressDialog {
                            title = "iNaturalist Identification",
                            caption = "Trying Pl@ntNet...",
                            cannotCancel = true,
                            functionContext = innerContext,
                        }
                        local plantNetOk, plantNetResultOrError = LrTasks.pcall(PlantNet.identify, photoPaths)
                        plantNetProgress:done()

                        if plantNetOk then
                            local originalCount = #currentCandidates
                            local combined = {}
                            for _, r in ipairs(currentCandidates) do
                                table.insert(combined, r)
                            end
                            for _, r in ipairs(plantNetResultOrError.results) do
                                table.insert(combined, r)
                            end
                            currentCandidates = combined
                            sectionLabelForIndex = function(i)
                                if i == 1 then return "iNaturalist" end
                                if i == originalCount + 1 then return "Pl@ntNet" end
                                return nil
                            end
                        else
                            LrDialogs.message(
                                "iNaturalist Identification",
                                "Pl@ntNet lookup failed: " .. tostring(plantNetResultOrError),
                                "critical"
                            )
                        end
                    end)
                end
            until not wantOtherService

            if wantManualEntry then
                selected, ancestry = ManualEntry.promptAndResolve()
            elseif selected then
                -- Best-effort enrichment: degrades to an empty list (flat
                -- "Species ID > name" tag) on any failure, so this never
                -- blocks the core tag/title/caption write. Uses the
                -- id-or-name dispatch since `selected` might now be a
                -- Pl@ntNet-sourced candidate with no id.
                selected, ancestry = INaturalist.getMajorAncestryForCandidate(selected)
            end
        end

        -- Only safe to clean up now -- the "Also try Pl@ntNet" path above
        -- needs these same temp JPEGs to still exist, since it reuses them
        -- rather than re-exporting.
        ExportTemp.cleanup(tempDir)

        if selected then
            KeywordWriter.applyIdentification(photos, selected, ancestry or {})
        end
    end)
end)
