local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrHttp = import 'LrHttp'

-- catalog:findPhotosWithProperty requires the plug-in's toolkit identifier
-- as a plain string (unlike get/setPropertyForPlugin, which also accept
-- the _PLUGIN object) -- must match Info.lua's LrToolkitIdentifier exactly.
local TOOLKIT_ID = "org.krefting.whatisthisthing"

local function escapeHtml(s)
    s = tostring(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Plain "Subtribe"-style display for a raw taxonRank value (see
-- MetadataDefinition.lua for the full enum this is a simplified echo of --
-- not worth importing that whole metadata-provider structure just for
-- this) -- "(unknown)" for nil, matching that same field's own "(unknown)"
-- enum entry.
local function describeRank(rank)
    if not rank then
        return "(unknown)"
    end
    return rank:sub(1, 1):upper() .. rank:sub(2)
end

-- First section of what's meant to grow into a broader "lots of info about
-- local observations" report (2026-08-02): every species identified
-- locally with ZERO iNaturalist observations at all -- not "every local
-- sighting uploaded," just "at least one." Per the user: routinely having
-- some local-only sightings of an otherwise-already-posted species is
-- normal, not a gap worth flagging -- only a species with NO iNat presence
-- whatsoever belongs here.
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()

    local identifiedPhotos = catalog:findPhotosWithProperty(TOOLKIT_ID, "scientificName")
    local linkedPhotos = catalog:findPhotosWithProperty(TOOLKIT_ID, "iNatObservationId")
    local isLinked = {}
    for _, photo in ipairs(linkedPhotos) do
        isLinked[photo] = true
    end

    local bySpecies = {}
    for _, photo in ipairs(identifiedPhotos) do
        local name = photo:getPropertyForPlugin(_PLUGIN, "scientificName")
        if name then
            local entry = bySpecies[name]
            if not entry then
                entry = {
                    commonName = photo:getPropertyForPlugin(_PLUGIN, "commonName"),
                    rank = photo:getPropertyForPlugin(_PLUGIN, "taxonRank"),
                    observationIds = {},
                    observationCount = 0,
                    everLinked = false,
                }
                bySpecies[name] = entry
            end
            -- Counts distinct LOCAL OBSERVATIONS (Observation ID groups --
            -- one per sighting/identify session), not raw photo count --
            -- several photos of the same sighting are one opportunity to
            -- upload, not several.
            local observationId = photo:getPropertyForPlugin(_PLUGIN, "observationId")
            if observationId and not entry.observationIds[observationId] then
                entry.observationIds[observationId] = true
                entry.observationCount = entry.observationCount + 1
            end
            if isLinked[photo] then
                entry.everLinked = true
            end
        end
    end

    local neverUploaded = {}
    for name, entry in pairs(bySpecies) do
        if not entry.everLinked then
            table.insert(neverUploaded, {
                name = name,
                commonName = entry.commonName,
                rank = entry.rank,
                count = entry.observationCount,
            })
        end
    end
    -- Most-observed-but-never-uploaded first -- the most actionable
    -- ordering (biggest existing backlog of documentation to draw an
    -- upload from), falling back to alphabetical for ties.
    table.sort(neverUploaded, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        return a.name < b.name
    end)

    if #neverUploaded == 0 then
        LrDialogs.message(
            "Observation Report",
            "Every locally-identified species has at least one iNaturalist observation.",
            "info"
        )
        return
    end

    local html = {
        "<!doctype html><html><head><meta charset=\"utf-8\">",
        "<title>Observation report</title>",
        "<style>",
        "body { font-family: -apple-system, sans-serif; margin: 2em; }",
        "h2 { margin-top: 2em; border-bottom: 1px solid #ccc; }",
        "table { border-collapse: collapse; }",
        "td, th { padding: 0.3em 1.5em 0.3em 0; text-align: left; }",
        "th { border-bottom: 1px solid #ccc; }",
        "</style></head><body>",
        "<h2>Species never uploaded to iNaturalist</h2>",
        "<p>" .. #neverUploaded .. " species identified locally with zero iNaturalist observations.</p>",
        "<table><tr><th>Species</th><th>Common Name</th><th>Level</th><th>Local Observations</th></tr>",
    }
    for _, entry in ipairs(neverUploaded) do
        table.insert(html, "<tr><td>" .. escapeHtml(entry.name) .. "</td><td>"
            .. escapeHtml(entry.commonName or "(unknown)") .. "</td><td>"
            .. escapeHtml(describeRank(entry.rank)) .. "</td><td>" .. entry.count .. "</td></tr>")
    end
    table.insert(html, "</table></body></html>")

    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "local")
    dir = LrPathUtils.child(dir, "WhatIsThisThing")
    local path = LrPathUtils.child(dir, "observation-report.html")

    local writeOk = pcall(function()
        LrFileUtils.createAllDirectories(dir)
        local f = assert(io.open(path, "w"))
        f:write(table.concat(html, "\n"))
        f:close()
    end)

    if writeOk then
        LrHttp.openUrlInBrowser("file://" .. path)
    else
        LrDialogs.message("Observation Report", "Couldn't write the report file.", "error")
    end
end)
