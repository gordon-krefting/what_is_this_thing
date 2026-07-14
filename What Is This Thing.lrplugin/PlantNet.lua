local LrHttp = import 'LrHttp'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

local JSON = dofile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))

local PlantNet = {}

local API_URL = "https://my-api.plantnet.org/v2/identify/all"
local DEFAULT_ORGAN = "auto" -- Pl@ntNet detects the organ per image; no picker UI needed

local function promptForApiKey()
    local apiKey = nil

    LrFunctionContext.callWithContext("PlantNetApiKeyPrompt", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.apiKey = ""

        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text {
                title = "Get your API key here (API access tab):",
            },
            f:push_button {
                title = "https://my.plantnet.org/account",
                action = function()
                    LrHttp.openUrlInBrowser("https://my.plantnet.org/account")
                end,
            },
            f:edit_field {
                value = LrView.bind("apiKey"),
                passwordField = true,
                width_in_chars = 40,
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Pl@ntNet API Key",
            contents = contents,
            actionVerb = "Save",
        }

        if result == "ok" and props.apiKey ~= "" then
            apiKey = props.apiKey
        end
    end)

    return apiKey
end

local function getStoredApiKey()
    local prefs = LrPrefs.prefsForPlugin()
    return prefs.plantnetApiKey
end

local function storeApiKey(key)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.plantnetApiKey = key
end

local function buildMultipartBody(boundary, photoPaths, organ)
    local parts = {}
    for _, path in ipairs(photoPaths) do
        local fileName = LrPathUtils.leafName(path)
        local data = LrFileUtils.readFile(path)

        parts[#parts + 1] = "--" .. boundary .. "\r\n"
        parts[#parts + 1] = 'Content-Disposition: form-data; name="images"; filename="' .. fileName .. '"\r\n'
        parts[#parts + 1] = "Content-Type: application/octet-stream\r\n\r\n"
        parts[#parts + 1] = data
        parts[#parts + 1] = "\r\n"

        parts[#parts + 1] = "--" .. boundary .. "\r\n"
        parts[#parts + 1] = 'Content-Disposition: form-data; name="organs"\r\n\r\n'
        parts[#parts + 1] = organ
        parts[#parts + 1] = "\r\n"
    end
    parts[#parts + 1] = "--" .. boundary .. "--\r\n"
    return table.concat(parts)
end

local function callApi(photoPaths, organ, apiKey)
    local boundary = "----WhatIsThisThingBoundary" .. tostring(math.random(1000000000))
    local body = buildMultipartBody(boundary, photoPaths, organ)
    local url = API_URL .. "?api-key=" .. apiKey .. "&detailed=true"

    local headers = {
        { field = "Content-Type", value = "multipart/form-data; boundary=" .. boundary },
    }

    local response, hdrs = LrHttp.post(url, body, headers)
    local status = hdrs and hdrs.status
    return response, status
end

-- Extracts a { score, scientificName, commonName, rank } list from one of
-- otherResults' "genus" or "family" arrays (each entry keyed by that same
-- name, e.g. entry.genus / entry.family).
local function parseOtherResultsGroup(group, key)
    local parsed = {}
    for _, entry in ipairs(group or {}) do
        local taxon = entry[key] or {}
        local commonNames = taxon.commonNames or {}
        table.insert(parsed, {
            score = (entry.score or 0) * 100,
            scientificName = taxon.scientificName or "unknown",
            commonName = commonNames[1],
            rank = key,
        })
    end
    return parsed
end

-- Runs the lookup, prompting for the API key if missing and re-prompting once
-- on auth failure. Returns { results, genusResults, familyResults }:
--   results       - list of { score, scientificName, commonName }, species
--                    level, highest score first (the API returns them sorted).
--   genusResults  - list of { score, scientificName, commonName, rank="genus" },
--                    from the "detailed" otherResults.genus rollup.
--   familyResults - same shape, rank="family", from otherResults.family.
-- genusResults/familyResults are always populated (Pl@ntNet computes them
-- unconditionally when detailed=true, unlike iNaturalist's confidence-gated
-- common_ancestor) but may be empty tables if otherResults is absent.
function PlantNet.identify(photoPaths, organ)
    organ = organ or DEFAULT_ORGAN

    local apiKey = getStoredApiKey()
    if not apiKey or apiKey == "" then
        apiKey = promptForApiKey()
        if not apiKey then
            error("No Pl@ntNet API key provided.")
        end
    end

    local response, status = callApi(photoPaths, organ, apiKey)

    if status == 401 or status == 403 then
        apiKey = promptForApiKey()
        if not apiKey then
            error("No Pl@ntNet API key provided.")
        end
        response, status = callApi(photoPaths, organ, apiKey)
    end

    if status ~= 200 then
        error("Pl@ntNet request failed (status " .. tostring(status) .. "):\n" .. tostring(response))
    end

    storeApiKey(apiKey)

    local decoded = JSON.decode(response)
    local results = {}
    for _, r in ipairs(decoded.results or {}) do
        local species = r.species or {}
        local commonNames = species.commonNames or {}
        table.insert(results, {
            score = (r.score or 0) * 100,
            scientificName = species.scientificNameWithoutAuthor or "unknown",
            commonName = commonNames[1],
        })
    end

    local otherResults = decoded.otherResults or {}
    local genusResults = parseOtherResultsGroup(otherResults.genus, "genus")
    local familyResults = parseOtherResultsGroup(otherResults.family, "family")

    return { results = results, genusResults = genusResults, familyResults = familyResults }
end

return PlantNet
