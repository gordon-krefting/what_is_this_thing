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
local GpsPrompt = dofile(LrPathUtils.child(_PLUGIN.path, "GpsPrompt.lua"))
local ManualEntry = dofile(LrPathUtils.child(_PLUGIN.path, "ManualEntry.lua"))

-- Below this confidence (%), preselect the best family/genus rollup instead
-- of the top species guess.
local CONFIDENCE_THRESHOLD = 85

-- This command expects a handful of photos of the *same* plant from
-- different angles/organs, not an arbitrary batch -- more than this is
-- almost always an accidental over-selection.
local MAX_PHOTOS = 4

local function urlEncode(str)
    return (str:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function wikipediaUrl(name)
    local titled = name:gsub(" ", "_")
    titled = titled:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return "https://en.wikipedia.org/wiki/" .. titled
end

-- Pl@ntNet's own species pages key on "scientificName authorship" together
-- (e.g. "Tradescantia ohiensis Raf."), confirmed against a real cited
-- example plus our own captured API response ("bestMatch": "Tradescantia
-- ohiensis Raf."). Only species-level results carry an authorship (and a
-- confirmed URL pattern) -- genus/family rollup entries have neither, so
-- those rows get no Pl@ntNet link, just iNat search + Wikipedia.
--
-- KNOWN LIMITATION: when a species has been taxonomically reclassified,
-- Pl@ntNet's identification API returns the current accepted name, but
-- their own website's species pages can still be filed under the older
-- synonym -- e.g. the API says "Securigera varia (L.) Lassen" while their
-- site only has a page for "Coronilla varia L.", so the link 404s. There's
-- no cheap way to detect this from the API response (would need a GBIF
-- synonym lookup per candidate, too slow for populating every dialog row),
-- so this is accepted as an occasional dead link rather than fixed -- the
-- iNat/Wikipedia links alongside it are a fallback for exactly this case.
local function linksForCandidate(r)
    local links = {}

    if not r.rank then
        local name = r.scientificName
        if r.authorship then
            name = name .. " " .. r.authorship
        end
        table.insert(links, {
            label = "Pl@ntNet",
            url = "https://identify.plantnet.org/k-world-flora/species/" .. urlEncode(name) .. "/data",
        })
    end

    table.insert(links, {
        label = "iNat",
        url = "https://www.inaturalist.org/taxa/search?q=" .. urlEncode(r.scientificName),
    })
    table.insert(links, { label = "Wikipedia", url = wikipediaUrl(r.scientificName) })

    return links
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Pl@ntNet Identification", "No photos selected.", "info")
        return
    end

    if #photos > MAX_PHOTOS then
        LrDialogs.message(
            "Pl@ntNet Identification",
            string.format(
                "You selected %d photos, but this command expects at most %d -- a few angles of the same plant, not a batch. Select fewer photos and try again.",
                #photos, MAX_PHOTOS
            ),
            "info"
        )
        return
    end

    -- Pl@ntNet doesn't use location at all for identification, but GPS is
    -- still worth having embedded in the file for when it's later exported
    -- and uploaded to iNaturalist manually.
    if not GpsPrompt.ensureGpsOnAllPhotos(photos, "iNaturalist's uploader uses to auto-locate your observation") then
        return
    end

    LrFunctionContext.callWithContext("WhatIsThisPlantLookup", function(context)
        local progressScope = LrDialogs.showModalProgressDialog {
            title = "Pl@ntNet Identification",
            caption = "Exporting photos...",
            cannotCancel = true,
            functionContext = context,
        }

        local exportOk, photoPathsOrError, tempDir, sourcePhotos = LrTasks.pcall(ExportTemp.exportToTempJpegs, photos)

        if not exportOk then
            progressScope:done()
            LrDialogs.message("Pl@ntNet Identification", "Export failed: " .. tostring(photoPathsOrError), "critical")
            return
        end

        local photoPaths = photoPathsOrError

        progressScope:setCaption("Looking up species...")

        local ok, identifyResultOrError = LrTasks.pcall(PlantNet.identify, photoPaths)

        progressScope:done()

        if not ok then
            ExportTemp.cleanup(tempDir)
            LrDialogs.message("Pl@ntNet Identification", "Lookup failed: " .. tostring(identifyResultOrError), "critical")
            return
        end

        local results = identifyResultOrError.results
        local genusResults = identifyResultOrError.genusResults
        local familyResults = identifyResultOrError.familyResults

        local selected, ancestry

        if #results == 0 then
            -- No automatic match at all -- go straight to manual entry
            -- rather than just giving up.
            selected, ancestry = ManualEntry.promptAndResolve()
        else
            -- Pl@ntNet's "detailed" rollup always includes these when
            -- available (unlike iNaturalist's confidence-gated common
            -- ancestor), so fold the best family/genus entries in as
            -- selectable candidates too, preselecting family (or genus, if
            -- no family) when species confidence is low.
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

            -- currentCandidates/sectionLabelForIndex/offerOtherService can
            -- all change after one pass through the loop below, if the user
            -- asks to also try iNaturalist -- see the loop comment.
            local currentCandidates = candidates
            local sectionLabelForIndex = nil
            local offerOtherService = "Also try iNaturalist"
            local wantManualEntry, wantOtherService

            -- Runs at most twice: once with just Pl@ntNet's own results,
            -- and again with iNaturalist's folded in as a second labeled
            -- section if the user asks for it (offerOtherService is cleared
            -- either way after that, so this can't loop a third time).
            -- Candidates from the two services are shown side by side, not
            -- merged/deduped -- see CandidatePicker.choose's doc comment.
            repeat
                local existingCounts = KeywordWriter.countExistingPhotos(currentCandidates)
                selected, wantManualEntry, wantOtherService = CandidatePicker.choose(
                    "Pl@ntNet Identification", currentCandidates, defaultIndex, hint, linksForCandidate,
                    function(r) return existingCounts[r] end,
                    function() return INaturalist.commonAncestorOf(currentCandidates) end,
                    offerOtherService,
                    sectionLabelForIndex
                )

                if wantOtherService then
                    offerOtherService = nil -- only one other service to try

                    LrFunctionContext.callWithContext("TryINaturalist", function(innerContext)
                        local inatProgress = LrDialogs.showModalProgressDialog {
                            title = "Pl@ntNet Identification",
                            caption = "Trying iNaturalist...",
                            cannotCancel = true,
                            functionContext = innerContext,
                        }

                        -- Every photo is guaranteed GPS at this point
                        -- (ensureGpsOnAllPhotos ran before export), so this
                        -- always feeds iNaturalist's geo-based accuracy boost.
                        local photoEntries = {}
                        for i, path in ipairs(photoPaths) do
                            local gps = sourcePhotos[i] and sourcePhotos[i]:getRawMetadata("gps")
                            table.insert(photoEntries, {
                                path = path,
                                lat = gps and gps.latitude,
                                lng = gps and gps.longitude,
                            })
                        end

                        local inatOk, inatResultOrError = LrTasks.pcall(INaturalist.identifyAll, photoEntries, function(i, n)
                            if n > 1 then
                                inatProgress:setCaption(string.format("Trying iNaturalist (%d/%d)...", i, n))
                            end
                        end)
                        inatProgress:done()

                        if inatOk then
                            local originalCount = #currentCandidates
                            local combined = {}
                            for _, r in ipairs(currentCandidates) do
                                table.insert(combined, r)
                            end
                            for _, r in ipairs(inatResultOrError) do
                                table.insert(combined, r)
                            end
                            currentCandidates = combined
                            sectionLabelForIndex = function(i)
                                if i == 1 then return "Pl@ntNet" end
                                if i == originalCount + 1 then return "iNaturalist" end
                                return nil
                            end
                        else
                            LrDialogs.message(
                                "Pl@ntNet Identification",
                                "iNaturalist lookup failed: " .. tostring(inatResultOrError),
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
                -- id-or-name dispatch since `selected` might now be an
                -- iNaturalist-sourced candidate with a real taxon id.
                selected, ancestry = INaturalist.getMajorAncestryForCandidate(selected)
            end
        end

        -- Only safe to clean up now -- the "Also try iNaturalist" path
        -- above needs these same temp JPEGs to still exist, since it reuses
        -- them rather than re-exporting.
        ExportTemp.cleanup(tempDir)

        if selected then
            KeywordWriter.applyIdentification(photos, selected, ancestry or {})
        end
    end)
end)
