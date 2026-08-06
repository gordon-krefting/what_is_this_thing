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
-- here (a Pl@ntNet result folded in via "Also try Pl@ntNet") -- resolved
-- lazily on click instead (CandidatePicker's resolveUrl support), rather
-- than linking to a search results page or paying for a name-search round
-- trip on every row before the user has asked for any of them.
local function linksForCandidate(r)
    local links = {}
    if r.id then
        table.insert(links, { label = "iNat", url = "https://www.inaturalist.org/taxa/" .. tostring(r.id) })
    else
        table.insert(links, { label = "iNat", resolveUrl = function() return INaturalist.taxonUrlForCandidate(r) end })
    end
    return links
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Species Identification", "No photos selected.", "info")
        return
    end

    if #photos > MAX_PHOTOS then
        LrDialogs.message(
            "Species Identification",
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
            title = "Species Identification",
            caption = "Exporting photos...",
            cannotCancel = true,
            functionContext = context,
        }

        local exportOk, photoPathsOrError, tempDir, sourcePhotos = LrTasks.pcall(ExportTemp.exportToTempJpegs, photos)

        if not exportOk then
            progressScope:done()
            LrDialogs.message("Species Identification", "Export failed: " .. tostring(photoPathsOrError), "critical")
            return
        end

        local photoPaths = photoPathsOrError

        -- Smaller, separate export just for the ID dialog's on-screen
        -- reference photo (CandidatePicker.lua's own 400x400 box) --
        -- decoding the full 2048px upload-sized JPEGs on every paging
        -- click was noticeably laggy, live-confirmed 2026-08-07.
        -- Best-effort: falls back to the upload-sized paths (still
        -- correct, just slower to page through) if this smaller export
        -- somehow fails, rather than blocking the whole command over a
        -- display nicety.
        local displayExportOk, displayPhotoPathsOrError, displayTempDir = LrTasks.pcall(ExportTemp.exportToTempDisplayJpegs, photos)
        local displayPhotoPaths = displayExportOk and displayPhotoPathsOrError or photoPaths
        if not displayExportOk then
            displayTempDir = nil
        end

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
            ExportTemp.cleanup(displayTempDir)
            LrDialogs.message("Species Identification", "Lookup failed: " .. tostring(resultsOrError), "critical")
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
            local wantOtherService

            -- Doesn't change across "Also try Pl@ntNet" reloads, so
            -- resolved once up front rather than inside the loop.
            local existingTag = KeywordWriter.findSpeciesName(photos[1])

            -- Runs at most twice: once with just iNaturalist's own results,
            -- and again with Pl@ntNet's folded in as a second labeled
            -- section if the user asks for it (offerOtherService is cleared
            -- either way after that, so this can't loop a third time).
            -- Candidates from the two services are shown side by side, not
            -- merged/deduped -- see CandidatePicker.choose's doc comment.
            repeat
                local existingCounts = KeywordWriter.countExistingPhotos(currentCandidates)
                selected, wantOtherService = CandidatePicker.choose(
                    "Species Identification", currentCandidates, defaultIndex, hint, linksForCandidate,
                    function(r) return existingCounts[r] end,
                    function() return commonAncestorGroups(currentCandidates) end,
                    offerOtherService,
                    sectionLabelForIndex,
                    displayPhotoPaths,
                    INaturalist.downloadThumbnailsForCandidate,
                    existingTag,
                    INaturalist.resolveByName
                )

                if wantOtherService then
                    offerOtherService = nil -- only one other service to try

                    LrFunctionContext.callWithContext("TryPlantNet", function(innerContext)
                        local plantNetProgress = LrDialogs.showModalProgressDialog {
                            title = "Species Identification",
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
                                "Species Identification",
                                "Pl@ntNet lookup failed: " .. tostring(plantNetResultOrError),
                                "critical"
                            )
                        end
                    end)
                end
            until not wantOtherService

            if selected then
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
        -- rather than re-exporting. displayTempDir is only used by the
        -- now-closed CandidatePicker dialog(s), so it's always safe to
        -- clean up here regardless.
        ExportTemp.cleanup(tempDir)
        ExportTemp.cleanup(displayTempDir)

        if selected then
            -- A photo already linked to a real iNat observation (via the
            -- "Sync from iNaturalist" feature) can silently drift out of
            -- sync with it if the LOCAL tag is reassigned here without
            -- also updating iNat -- applyIdentification only ever touches
            -- the local tag, never iNatObservationId (see its own doc
            -- comment), so nothing else would catch this. One warning
            -- covers the whole batch since these commands always operate
            -- on a handful of angles of the same organism.
            local alreadyLinkedId = nil
            for _, photo in ipairs(photos) do
                alreadyLinkedId = photo:getPropertyForPlugin(_PLUGIN, "iNatObservationId")
                if alreadyLinkedId then break end
            end
            local proceed = true
            if alreadyLinkedId then
                proceed = LrDialogs.confirm(
                    "Already linked to iNat",
                    "This photo is already linked to iNat observation #" .. tostring(alreadyLinkedId)
                        .. ". Reassigning its local ID here won't update iNat -- the two would then disagree"
                        .. " until the observation itself is edited or re-synced. Continue anyway?",
                    "Continue", "Cancel"
                ) == "ok"
            end
            if proceed then
                KeywordWriter.applyIdentification(photos, selected, ancestry or {})
            end
        end
    end)
end)
