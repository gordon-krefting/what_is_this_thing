local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrHttp = import 'LrHttp'

local INatSync = dofile(LrPathUtils.child(_PLUGIN.path, "INatSync.lua"))

-- catalog:findPhotosWithProperty requires the plug-in's toolkit identifier
-- as a plain string (unlike get/setPropertyForPlugin, which also accept
-- the _PLUGIN object) -- must match Info.lua's LrToolkitIdentifier exactly.
local TOOLKIT_ID = "org.krefting.whatisthisthing"

local function escapeHtml(s)
    s = tostring(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function urlEncode(str)
    return (tostring(str):gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
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

-- One row per locally-identified species (2026-08-04, broadened from the
-- original "never uploaded" list to a general-purpose view once that
-- proved useful) -- Local Observations (distinct Observation ID groups,
-- one per sighting) and Local Photos (raw count) are two different
-- numbers on purpose: several photos of the same sighting are one
-- opportunity to upload, not several. iNaturalist Observations is the
-- count of DISTINCT iNat observations linked across that species' local
-- photos -- 0 recovers exactly the original "never uploaded" list (sort
-- that column ascending), but a species can also have more than one if
-- it's been seen and posted on separate occasions.
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local username = INatSync.getUsername()

    local identifiedPhotos = catalog:findPhotosWithProperty(TOOLKIT_ID, "scientificName")

    local bySpecies = {}
    for _, photo in ipairs(identifiedPhotos) do
        local name = photo:getPropertyForPlugin(_PLUGIN, "scientificName")
        if name then
            local entry = bySpecies[name]
            if not entry then
                entry = {
                    commonName = photo:getPropertyForPlugin(_PLUGIN, "commonName"),
                    rank = photo:getPropertyForPlugin(_PLUGIN, "taxonRank"),
                    taxonId = nil,
                    observationIds = {},
                    observationCount = 0,
                    photoCount = 0,
                    iNatObservationIds = {},
                    iNatObservationCount = 0,
                }
                bySpecies[name] = entry
            end
            entry.photoCount = entry.photoCount + 1

            -- First one found wins, same "good enough" convention as
            -- KeywordWriter.findExistingObservationId -- every photo of
            -- the same species should carry the same taxonId anyway.
            if not entry.taxonId then
                entry.taxonId = photo:getPropertyForPlugin(_PLUGIN, "taxonId")
            end

            local observationId = photo:getPropertyForPlugin(_PLUGIN, "observationId")
            if observationId and not entry.observationIds[observationId] then
                entry.observationIds[observationId] = true
                entry.observationCount = entry.observationCount + 1
            end

            local iNatObservationId = photo:getPropertyForPlugin(_PLUGIN, "iNatObservationId")
            if iNatObservationId and not entry.iNatObservationIds[iNatObservationId] then
                entry.iNatObservationIds[iNatObservationId] = true
                entry.iNatObservationCount = entry.iNatObservationCount + 1
            end
        end
    end

    local species = {}
    for name, entry in pairs(bySpecies) do
        table.insert(species, {
            name = name,
            commonName = entry.commonName,
            rank = entry.rank,
            taxonId = entry.taxonId,
            observationCount = entry.observationCount,
            photoCount = entry.photoCount,
            iNatObservationCount = entry.iNatObservationCount,
        })
    end

    if #species == 0 then
        LrDialogs.message("Observation Report", "No locally-identified species found.", "info")
        return
    end

    -- Alphabetical by default -- a neutral starting point now that this
    -- covers every species, not just a "biggest gap first" worklist;
    -- click any column header to resort (see the inline script below).
    table.sort(species, function(a, b) return a.name < b.name end)

    local html = {
        "<!doctype html><html><head><meta charset=\"utf-8\">",
        "<title>Observation report</title>",
        "<style>",
        "body { font-family: -apple-system, sans-serif; margin: 2em; }",
        "h2 { margin-top: 0; }",
        ".table-scroll { max-height: 80vh; overflow-y: auto; border: 1px solid #ccc; }",
        "table { border-collapse: collapse; width: 100%; }",
        "td, th { padding: 0.3em 1.5em 0.3em 0.5em; text-align: left; white-space: nowrap; }",
        "th { border-bottom: 1px solid #ccc; background: #f5f5f5; position: sticky; top: 0; cursor: pointer; user-select: none; }",
        "th:hover { background: #e8e8e8; }",
        "th .arrow { color: #888; font-size: 0.8em; }",
        "tr:nth-child(even) td { background: #fafafa; }",
        "</style></head><body>",
        "<h2>Local observations by species</h2>",
        "<p>" .. #species .. " species identified locally. Click a column heading to sort.</p>",
        "<div class=\"table-scroll\"><table id=\"report-table\"><thead><tr>",
        "<th data-type=\"text\">Species <span class=\"arrow\"></span></th>",
        "<th data-type=\"text\">Common Name <span class=\"arrow\"></span></th>",
        "<th data-type=\"text\">Level <span class=\"arrow\"></span></th>",
        "<th data-type=\"number\">Local Observations <span class=\"arrow\"></span></th>",
        "<th data-type=\"number\">Local Photos <span class=\"arrow\"></span></th>",
        "<th data-type=\"number\">iNaturalist Observations <span class=\"arrow\"></span></th>",
        "</tr></thead><tbody>",
    }
    for _, entry in ipairs(species) do
        local commonName = entry.commonName or "(unknown)"
        local rankLabel = describeRank(entry.rank)

        -- Links out to "all my observations of this taxon" on iNaturalist
        -- when a taxonId is known (added to KeywordWriter.applyIdentification
        -- 2026-08-04) AND a username is on file -- both required to build a
        -- valid URL. Falls back to a plain, unlinked count otherwise (an
        -- identification made before taxonId existed, or Pl@ntNet/manual
        -- paths that happened not to resolve one), rather than a broken link.
        local iNatObservationsCell
        if entry.taxonId and username then
            local url = "https://www.inaturalist.org/observations?taxon_id=" .. urlEncode(entry.taxonId)
                .. "&user_id=" .. urlEncode(username) .. "&verifiable=any"
            iNatObservationsCell = "<a href=\"" .. escapeHtml(url) .. "\" target=\"_blank\">" .. entry.iNatObservationCount .. "</a>"
        else
            iNatObservationsCell = tostring(entry.iNatObservationCount)
        end

        table.insert(html, "<tr>"
            .. "<td data-value=\"" .. escapeHtml(entry.name) .. "\">" .. escapeHtml(entry.name) .. "</td>"
            .. "<td data-value=\"" .. escapeHtml(commonName) .. "\">" .. escapeHtml(commonName) .. "</td>"
            .. "<td data-value=\"" .. escapeHtml(rankLabel) .. "\">" .. escapeHtml(rankLabel) .. "</td>"
            .. "<td data-value=\"" .. entry.observationCount .. "\">" .. entry.observationCount .. "</td>"
            .. "<td data-value=\"" .. entry.photoCount .. "\">" .. entry.photoCount .. "</td>"
            .. "<td data-value=\"" .. entry.iNatObservationCount .. "\">" .. iNatObservationsCell .. "</td>"
            .. "</tr>")
    end
    table.insert(html, "</tbody></table></div>")
    table.insert(html, [[
<script>
(function() {
    var table = document.getElementById('report-table');
    var headers = table.tHead.rows[0].cells;
    for (var i = 0; i < headers.length; i++) {
        headers[i].addEventListener('click', function() {
            sortByColumn(Array.prototype.indexOf.call(headers, this));
        });
    }

    function sortByColumn(colIndex) {
        var header = headers[colIndex];
        var type = header.getAttribute('data-type');
        var ascending = header.getAttribute('data-sort-dir') !== 'asc';

        for (var i = 0; i < headers.length; i++) {
            headers[i].removeAttribute('data-sort-dir');
            headers[i].querySelector('.arrow').textContent = '';
        }
        header.setAttribute('data-sort-dir', ascending ? 'asc' : 'desc');
        header.querySelector('.arrow').textContent = ascending ? '▲' : '▼';

        var tbody = table.tBodies[0];
        var rows = Array.prototype.slice.call(tbody.rows);
        rows.sort(function(rowA, rowB) {
            var a = rowA.cells[colIndex].getAttribute('data-value');
            var b = rowB.cells[colIndex].getAttribute('data-value');
            if (type === 'number') {
                a = parseFloat(a);
                b = parseFloat(b);
                return ascending ? a - b : b - a;
            }
            a = a.toLowerCase();
            b = b.toLowerCase();
            if (a < b) return ascending ? -1 : 1;
            if (a > b) return ascending ? 1 : -1;
            return 0;
        });
        for (var j = 0; j < rows.length; j++) {
            tbody.appendChild(rows[j]);
        }
    }
})();
</script>
]])
    table.insert(html, "</body></html>")

    -- ~/Photos/output/reports (2026-08-09 reorg) -- deliberately NOT under
    -- ~/Photos/local/, and deliberately NOT backed up by
    -- manage_photo_backups.rb: this report is cheap to regenerate on demand.
    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "output")
    dir = LrPathUtils.child(dir, "reports")
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
