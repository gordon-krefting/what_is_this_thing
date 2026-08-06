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

local function urlEncode(str)
    return (str:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
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

-- Splits a (possibly two-service) candidate list into per-service common-
-- ancestor rollup groups for CandidatePicker's "Find Common Ancestor"
-- button -- iNaturalist candidates always carry a real taxon `id`,
-- Pl@ntNet ones never do, so that alone is a reliable split regardless of
-- which service's results were fetched first. Each group is rolled up
-- independently and kept in its own labeled group -- see
-- INaturalist.commonAncestorOptions' doc comment for why the two services'
-- scores must never be summed together in one rollup.
local function commonAncestorGroups(candidates)
    local withId, withoutId = {}, {}
    for _, r in ipairs(candidates) do
        table.insert(r.id and withId or withoutId, r)
    end
    local groups = {}
    if #withId > 0 then
        table.insert(groups, { label = "iNaturalist", options = INaturalist.commonAncestorOptions(withId) })
    end
    if #withoutId > 0 then
        table.insert(groups, { label = "Pl@ntNet", options = INaturalist.commonAncestorOptions(withoutId) })
    end
    return groups
end

-- iNaturalist's own vision API already gives us each candidate's taxon id,
-- so most rows get a direct link for free. A candidate can still lack one
-- here (a Pl@ntNet result folded in via "Also try Pl@ntNet") -- falls back
-- to an iNat name search instead of leaving the row with no link at all.
local function linksForCandidate(r)
    local links = {}
    local url = r.id and ("https://www.inaturalist.org/taxa/" .. tostring(r.id))
        or ("https://www.inaturalist.org/taxa/search?q=" .. urlEncode(r.scientificName))
    table.insert(links, { label = "iNat", url = url })
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
                    function() return commonAncestorGroups(currentCandidates) end,
                    offerOtherService,
                    sectionLabelForIndex,
                    photos
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
