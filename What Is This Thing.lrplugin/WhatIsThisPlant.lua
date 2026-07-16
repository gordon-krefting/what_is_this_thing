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
        LrDialogs.message("What is This Plant?", "No photos selected.", "info")
        return
    end

    if #photos > MAX_PHOTOS then
        LrDialogs.message(
            "What is This Plant?",
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

            local existingCounts = KeywordWriter.countExistingPhotos(candidates)
            local wantManualEntry
            selected, wantManualEntry = CandidatePicker.choose(
                "What is This Plant?", candidates, defaultIndex, hint, linksForCandidate,
                function(r) return existingCounts[r] end
            )

            if wantManualEntry then
                selected, ancestry = ManualEntry.promptAndResolve()
            elseif selected then
                -- Resolve through iNaturalist's taxonomy (by name --
                -- Pl@ntNet results carry a GBIF id, not an iNat one) so
                -- plant and animal identifications end up filed under the
                -- same taxonomic tree. Best-effort: degrades to an empty
                -- list (flat "Species ID > name" tag) on any failure,
                -- never blocking the core write.
                ancestry = INaturalist.getMajorAncestryByName(selected.scientificName, selected.rank)
            end
        end

        if selected then
            KeywordWriter.applyIdentification(photos, selected, ancestry or {})
        end
    end)
end)
