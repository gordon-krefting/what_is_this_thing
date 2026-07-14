local LrHttp = import 'LrHttp'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local JSON = dofile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))

local INaturalist = {}

local API_URL = "https://api.inaturalist.org/v1/computervision/score_image"
local TAXA_URL = "https://api.inaturalist.org/v1/taxa/"
local TAXA_SEARCH_URL = "https://api.inaturalist.org/v1/taxa"

-- Ranks worth showing as their own level in a keyword hierarchy -- skips
-- kingdom/phylum (near-useless for browsing a personal photo library) and
-- the various sub/infra/super/tribe in-between ranks.
local MAJOR_RANKS = { class = true, order = true, family = true, genus = true }

local function promptForToken()
    local token = nil

    LrFunctionContext.callWithContext("INaturalistTokenPrompt", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.token = ""

        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text {
                title = "Grab your token here (it expires after 24 hours):",
            },
            f:push_button {
                title = "https://www.inaturalist.org/users/api_token",
                action = function()
                    LrHttp.openUrlInBrowser("https://www.inaturalist.org/users/api_token")
                end,
            },
            f:edit_field {
                value = LrView.bind("token"),
                passwordField = true,
                width_in_chars = 40,
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "iNaturalist API Token",
            contents = contents,
            actionVerb = "Save",
        }

        if result == "ok" and props.token ~= "" then
            token = props.token
        end
    end)

    return token
end

local function getStoredToken()
    local prefs = LrPrefs.prefsForPlugin()
    return prefs.inaturalistToken
end

local function storeToken(token)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.inaturalistToken = token
end

local function buildMultipartBody(boundary, photoPath)
    local fileName = LrPathUtils.leafName(photoPath)
    local data = LrFileUtils.readFile(photoPath)

    local parts = {}
    parts[#parts + 1] = "--" .. boundary .. "\r\n"
    parts[#parts + 1] = 'Content-Disposition: form-data; name="image"; filename="' .. fileName .. '"\r\n'
    parts[#parts + 1] = "Content-Type: application/octet-stream\r\n\r\n"
    parts[#parts + 1] = data
    parts[#parts + 1] = "\r\n"
    parts[#parts + 1] = "--" .. boundary .. "--\r\n"
    return table.concat(parts)
end

local function callApi(photoPath, token)
    local boundary = "----WhatIsThisThingBoundary" .. tostring(math.random(1000000000))
    local body = buildMultipartBody(boundary, photoPath)

    local headers = {
        { field = "Content-Type", value = "multipart/form-data; boundary=" .. boundary },
        { field = "Authorization", value = token },
    }

    local response, hdrs = LrHttp.post(API_URL, body, headers)
    local status = hdrs and hdrs.status
    return response, status
end

-- Runs the lookup for a single photo, prompting for the API token if missing
-- and re-prompting once on auth failure (tokens expire after 24h). Returns
-- { results, commonAncestor }:
--   results        - list of { id, score, scientificName, commonName, rank },
--                     highest score first.
--   commonAncestor - { id, score, scientificName, commonName, rank } or nil.
--                     iNaturalist's vision model computes this itself when
--                     individual species-level confidence is too scattered
--                     to pick one, rolling the score up to a shared ancestor
--                     taxon (e.g. a family) instead. Not present on every
--                     response.
function INaturalist.identify(photoPath)
    local token = getStoredToken()
    if not token or token == "" then
        token = promptForToken()
        if not token then
            error("No iNaturalist API token provided.")
        end
    end

    local response, status = callApi(photoPath, token)

    if status == 401 then
        token = promptForToken()
        if not token then
            error("No iNaturalist API token provided.")
        end
        response, status = callApi(photoPath, token)
    end

    if status ~= 200 then
        error("iNaturalist request failed (status " .. tostring(status) .. "):\n" .. tostring(response))
    end

    storeToken(token)

    local decoded = JSON.decode(response)
    local results = {}
    for _, r in ipairs(decoded.results or {}) do
        local taxon = r.taxon or {}
        table.insert(results, {
            id = taxon.id,
            score = r.combined_score or 0,
            scientificName = taxon.name or "unknown",
            commonName = taxon.preferred_common_name,
            rank = taxon.rank,
        })
    end

    local commonAncestor = nil
    if decoded.common_ancestor then
        local ca = decoded.common_ancestor
        local taxon = ca.taxon or {}
        commonAncestor = {
            id = taxon.id,
            score = ca.score or 0,
            scientificName = taxon.name or "unknown",
            commonName = taxon.preferred_common_name,
            rank = taxon.rank,
        }
    end

    return { results = results, commonAncestor = commonAncestor }
end

-- Fetches the major-rank ancestry (class, order, family, genus -- whichever
-- are present) for an iNaturalist taxon id, ordered from broadest to
-- narrowest. Returns a list of { rank, name, commonName } entries
-- (commonName may be nil), or an empty list if the taxon id is nil or the
-- lookup fails for any reason -- this is an optional enrichment for keyword
-- hierarchy, so a failure here should never block the core tag/title/
-- caption write. No API token needed; this is a public read endpoint.
function INaturalist.getMajorAncestry(taxonId)
    if not taxonId then
        return {}
    end

    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, TAXA_URL .. tostring(taxonId))
    if not ok then
        return {}
    end
    local status = hdrs and hdrs.status
    if status ~= 200 then
        return {}
    end

    local decodeOk, decoded = pcall(JSON.decode, response)
    if not decodeOk then
        return {}
    end

    local taxon = decoded.results and decoded.results[1]
    if not taxon then
        return {}
    end

    local ancestry = {}
    for _, a in ipairs(taxon.ancestors or {}) do
        if MAJOR_RANKS[a.rank] then
            table.insert(ancestry, { rank = a.rank, name = a.name, commonName = a.preferred_common_name })
        end
    end
    return ancestry
end

local function urlEncode(str)
    return (str:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Resolves a scientific name (optionally constrained to a rank, e.g.
-- "species"/"genus"/"family") to an iNaturalist taxon id via their public
-- taxa search, requiring an exact (case-sensitive) name match against the
-- results -- so a fuzzy/wrong match is never silently accepted. Returns nil
-- if no exact match is found or the request fails.
local function findTaxonId(scientificName, rank)
    local url = TAXA_SEARCH_URL .. "?q=" .. urlEncode(scientificName) .. "&per_page=10"
    if rank then
        url = url .. "&rank=" .. urlEncode(rank)
    end

    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url)
    if not ok then
        return nil
    end
    local status = hdrs and hdrs.status
    if status ~= 200 then
        return nil
    end

    local decodeOk, decoded = pcall(JSON.decode, response)
    if not decodeOk then
        return nil
    end

    for _, r in ipairs(decoded.results or {}) do
        if r.name == scientificName then
            return r.id
        end
    end
    return nil
end

-- Like getMajorAncestry, but for a bare scientific name that has no
-- iNaturalist taxon id of its own (e.g. a Pl@ntNet result, which only
-- carries a GBIF id) -- so both plant and animal identifications end up
-- filed under the same taxonomic tree. `rank` (species/genus/family, if
-- known) narrows the name search to avoid an unlikely cross-rank homonym
-- match. Returns {} if no exact name match is found or either request
-- fails; this is an optional enrichment, never required.
function INaturalist.getMajorAncestryByName(scientificName, rank)
    local taxonId = findTaxonId(scientificName, rank)
    return INaturalist.getMajorAncestry(taxonId)
end

-- Merge key for a taxon entry -- prefer the numeric taxon id (stable across
-- photos), falling back to scientific name if id is somehow missing.
local function poolKey(entry)
    if entry.id then
        return "id:" .. tostring(entry.id)
    end
    return "name:" .. entry.scientificName
end

-- Merges per-photo identify() results into one ranked list, averaging each
-- taxon's score across all N photos (missing = 0 for that photo) so a
-- species/ancestor recognized consistently across angles ranks above one
-- that only scored well in a single (e.g. blurry) photo. Each photo's
-- commonAncestor, if present, is folded into the same pool as just another
-- taxon -- so callers no longer need to special-case it; the best
-- non-species entry (if any) simply falls out of the merged, ranked list.
function INaturalist.mergeResults(perPhotoResults)
    local n = #perPhotoResults
    if n == 0 then
        return {}
    end

    local pool = {}

    local function addEntry(entry)
        local key = poolKey(entry)
        local pooled = pool[key]
        if not pooled then
            pooled = {
                id = entry.id,
                scientificName = entry.scientificName,
                commonName = entry.commonName,
                rank = entry.rank,
                scoreSum = 0,
            }
            pool[key] = pooled
        end
        pooled.scoreSum = pooled.scoreSum + entry.score
        if not pooled.commonName and entry.commonName then
            pooled.commonName = entry.commonName
        end
    end

    for _, photoResult in ipairs(perPhotoResults) do
        for _, r in ipairs(photoResult.results) do
            addEntry(r)
        end
        if photoResult.commonAncestor then
            addEntry(photoResult.commonAncestor)
        end
    end

    local merged = {}
    for _, pooled in pairs(pool) do
        table.insert(merged, {
            id = pooled.id,
            score = pooled.scoreSum / n,
            scientificName = pooled.scientificName,
            commonName = pooled.commonName,
            rank = pooled.rank,
        })
    end

    table.sort(merged, function(a, b) return a.score > b.score end)
    return merged
end

-- Runs identify() for every photo (calling onProgress(i, n) before each, if
-- given) and merges the results. Works for a single photo too -- averaging
-- over N=1 is a no-op, so this is the only entry point callers need.
function INaturalist.identifyAll(photoPaths, onProgress)
    local perPhoto = {}
    for i, path in ipairs(photoPaths) do
        if onProgress then
            onProgress(i, #photoPaths)
        end
        table.insert(perPhoto, INaturalist.identify(path))
    end
    return INaturalist.mergeResults(perPhoto)
end

return INaturalist
