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
local HomeLocation = dofile(LrPathUtils.child(_PLUGIN.path, "HomeLocation.lua"))

local INaturalist = {}

local API_URL = "https://api.inaturalist.org/v1/computervision/score_image"
local TAXA_URL = "https://api.inaturalist.org/v1/taxa/"
local TAXA_SEARCH_URL = "https://api.inaturalist.org/v1/taxa"
local OBSERVATIONS_URL = "https://api.inaturalist.org/v1/observations"
local OBSERVATIONS_V2_URL = "https://api.inaturalist.org/v2/observations"

-- Ranks worth showing as their own level in a keyword hierarchy -- skips
-- phylum (near-useless for browsing a personal photo library) and the
-- various sub/infra/super/tribe in-between ranks. Kingdom is handled
-- separately below.
local MAJOR_RANKS = { class = true, order = true, family = true, genus = true }

-- Kingdom is skipped everywhere except these -- for animals it's always
-- Animalia (a photo of any wildlife shares the same kingdom, so it's not a
-- useful split), but plants and fungi are both plausible subjects for the
-- "What is This Plant?" command, so showing Kingdom there actually
-- separates the keyword tree usefully.
local KINGDOMS_TO_SHOW = { Plantae = true, Fungi = true }

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

-- Returns a stored token, prompting (and storing the result) if none is
-- saved yet. Exposed (unlike getStoredToken/promptForToken/storeToken,
-- which stay private) so other modules -- e.g. the iNaturalist sync
-- feature -- can get an authenticated header without duplicating the
-- prompt dialog. Callers needing 401-retry behavior (like identify()
-- already does) should call promptForToken again themselves and re-store
-- via a fresh call to this same get-or-prompt shape; this function only
-- covers the "no token saved yet" case, not mid-call expiry.
function INaturalist.getAuthToken()
    local token = getStoredToken()
    if not token or token == "" then
        token = promptForToken()
        if not token then
            error("No iNaturalist API token provided.")
        end
        storeToken(token)
    end
    return token
end

-- lat/lng, if given, feed iNaturalist's own geo-based accuracy boost (a
-- "frequency_score" folded into combined_score, confirmed in their
-- computervision_controller.js source) -- confirmed via that same source
-- that score_image does NOT extract location from the uploaded image's own
-- EXIF, only from these explicit request fields.
local function buildMultipartBody(boundary, photoPath, lat, lng)
    local fileName = LrPathUtils.leafName(photoPath)
    local data = LrFileUtils.readFile(photoPath)

    local parts = {}
    parts[#parts + 1] = "--" .. boundary .. "\r\n"
    parts[#parts + 1] = 'Content-Disposition: form-data; name="image"; filename="' .. fileName .. '"\r\n'
    parts[#parts + 1] = "Content-Type: application/octet-stream\r\n\r\n"
    parts[#parts + 1] = data
    parts[#parts + 1] = "\r\n"

    if lat and lng then
        parts[#parts + 1] = "--" .. boundary .. "\r\n"
        parts[#parts + 1] = 'Content-Disposition: form-data; name="lat"\r\n\r\n'
        parts[#parts + 1] = tostring(lat)
        parts[#parts + 1] = "\r\n"

        parts[#parts + 1] = "--" .. boundary .. "\r\n"
        parts[#parts + 1] = 'Content-Disposition: form-data; name="lng"\r\n\r\n'
        parts[#parts + 1] = tostring(lng)
        parts[#parts + 1] = "\r\n"
    end

    parts[#parts + 1] = "--" .. boundary .. "--\r\n"
    return table.concat(parts)
end

local function callApi(photoPath, token, lat, lng)
    local boundary = "----WhatIsThisThingBoundary" .. tostring(math.random(1000000000))
    local body = buildMultipartBody(boundary, photoPath, lat, lng)

    local headers = {
        { field = "Content-Type", value = "multipart/form-data; boundary=" .. boundary },
        { field = "Authorization", value = token },
    }

    local response, hdrs = LrHttp.post(API_URL, body, headers)
    local status = hdrs and hdrs.status
    return response, status
end

-- Turns a non-200 response into a readable message: pulls the "error" field
-- out of the JSON body if present (iNaturalist's own error responses are
-- shaped like { "error": "...", "status": ... }), falling back to the raw
-- body if it doesn't parse. 5xx errors get a note that it's likely on
-- iNaturalist's end, not something wrong with the photo or token.
local function friendlyErrorMessage(status, response)
    local ok, decoded = pcall(JSON.decode, response)
    local detail = ok and decoded and decoded.error

    if status and status >= 500 then
        local suffix = detail and (" (\"" .. detail .. "\")") or ""
        return "iNaturalist's servers had trouble processing this image" .. suffix
            .. ". This is usually temporary on their end -- try again in a moment."
    end

    if detail then
        return "iNaturalist request failed (status " .. tostring(status) .. "): " .. detail
    end
    return "iNaturalist request failed (status " .. tostring(status) .. "):\n" .. tostring(response)
end

-- Runs the lookup for a single photo, prompting for the API token if missing
-- and re-prompting once on auth failure (tokens expire after 24h). lat/lng
-- are optional (pass both or neither) and feed iNaturalist's own geo-based
-- accuracy boost when given. Returns { results, commonAncestor }:
--   results        - list of { id, score, scientificName, commonName, rank },
--                     highest score first.
--   commonAncestor - { id, score, scientificName, commonName, rank } or nil.
--                     iNaturalist's vision model computes this itself when
--                     individual species-level confidence is too scattered
--                     to pick one, rolling the score up to a shared ancestor
--                     taxon (e.g. a family) instead. Not present on every
--                     response.
function INaturalist.identify(photoPath, lat, lng)
    local token = getStoredToken()
    if not token or token == "" then
        token = promptForToken()
        if not token then
            error("No iNaturalist API token provided.")
        end
    end

    local response, status = callApi(photoPath, token, lat, lng)

    if status == 401 then
        token = promptForToken()
        if not token then
            error("No iNaturalist API token provided.")
        end
        response, status = callApi(photoPath, token, lat, lng)
    end

    if status and status >= 500 then
        -- iNaturalist's vision backend occasionally fails on a given
        -- request (e.g. "Error scoring image") for reasons unrelated to
        -- our request itself; one retry often clears it.
        response, status = callApi(photoPath, token, lat, lng)
    end

    if status ~= 200 then
        error(friendlyErrorMessage(status, response))
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

-- Fetches the full taxon detail record (name, rank, common name, ancestors)
-- for an iNaturalist taxon id, or nil if the id is nil or the lookup fails
-- for any reason. No API token needed; this is a public read endpoint.
-- Shared by getMajorAncestry() and resolveByName() so a taxon id only ever
-- needs one round trip regardless of which is called.
local function fetchTaxonDetail(taxonId)
    if not taxonId then
        return nil
    end

    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, TAXA_URL .. tostring(taxonId))
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

    return decoded.results and decoded.results[1]
end

-- Filters a flat list of { rank, name, commonName } ancestor entries down
-- to the major ranks (class, order, family, genus -- whichever are
-- present), ordered broadest first. Kingdom is included only for
-- Plantae/Fungi (see KINGDOMS_TO_SHOW). Shared by majorAncestryFromTaxon
-- (working from a raw taxon's `ancestors` field) and commonAncestorOf
-- (working from a manually-sliced ancestor chain), so both stay consistent.
local function filterMajorRanks(entries)
    local ancestry = {}
    for _, a in ipairs(entries) do
        if a.rank == "kingdom" then
            if KINGDOMS_TO_SHOW[a.name] then
                table.insert(ancestry, { rank = a.rank, name = a.name, commonName = a.commonName })
            end
        elseif MAJOR_RANKS[a.rank] then
            table.insert(ancestry, { rank = a.rank, name = a.name, commonName = a.commonName })
        end
    end
    return ancestry
end

-- Filters a full taxon record's ancestors down to the major ranks (class,
-- order, family, genus -- whichever are present), ordered broadest first.
-- taxon.ancestors is already ordered broadest-first, so kingdom naturally
-- lands ahead of class without any extra sorting.
local function majorAncestryFromTaxon(taxon)
    local entries = {}
    for _, a in ipairs(taxon.ancestors or {}) do
        table.insert(entries, { rank = a.rank, name = a.name, commonName = a.preferred_common_name })
    end
    return filterMajorRanks(entries)
end

-- Fetches the major-rank ancestry (class, order, family, genus -- whichever
-- are present) for an iNaturalist taxon id, ordered from broadest to
-- narrowest. Returns a list of { rank, name, commonName } entries
-- (commonName may be nil), or an empty list if the taxon id is nil or the
-- lookup fails for any reason -- this is an optional enrichment for keyword
-- hierarchy, so a failure here should never block the core tag/title/
-- caption write.
function INaturalist.getMajorAncestry(taxonId)
    local taxon = fetchTaxonDetail(taxonId)
    if not taxon then
        return {}
    end
    return majorAncestryFromTaxon(taxon)
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

-- Resolves ancestry for a candidate regardless of which service it came
-- from -- iNaturalist-sourced candidates carry a real taxon `id` (fast,
-- direct path via getMajorAncestry); Pl@ntNet-sourced ones don't (falls
-- back to the name-based lookup below). Needed once a single candidate
-- picker can show results from either service in the same dialog, since
-- the selected candidate's origin can no longer be assumed from which
-- command was launched.
--
-- Returns candidate, ancestry -- the candidate is usually the same table
-- passed in, except for a Pl@ntNet-sourced one: while resolving its
-- ancestry by name anyway, this also replaces its commonName with
-- iNaturalist's own preferred_common_name. Pl@ntNet's commonNames[1] is
-- arbitrary -- its array carries no ordering guarantee (confirmed against
-- their own docs), which is why the exact same species can come back
-- labeled "Hoary skullcap" one time and "Downy skullcap" another,
-- depending on API response order alone. iNaturalist's is a single,
-- deliberately-curated name instead. Only fetched for the one candidate
-- the user actually picked, not every row shown in the picker, to avoid
-- extra API calls for a cosmetic difference that only matters once
-- something is actually about to be written to a photo.
function INaturalist.getMajorAncestryForCandidate(candidate)
    if candidate.id then
        return candidate, INaturalist.getMajorAncestry(candidate.id)
    end

    local taxonId = findTaxonId(candidate.scientificName, candidate.rank)
    local taxon = fetchTaxonDetail(taxonId)
    if not taxon then
        return candidate, {}
    end

    local updatedCandidate = {
        -- The whole point of this branch is that candidate.id is nil
        -- (Pl@ntNet never provides one) -- use the id we just resolved via
        -- name lookup instead. Without this, candidate.id stays nil
        -- downstream, which silently skips getTaxonFacts entirely (its
        -- caller in KeywordWriter.applyIdentification only fetches when
        -- candidate.id is truthy) -- found via a real report of
        -- Establishment Means never populating for Pl@ntNet-identified
        -- plants.
        id = taxon.id,
        score = candidate.score,
        scientificName = candidate.scientificName,
        commonName = taxon.preferred_common_name or candidate.commonName,
        -- Prefer the freshly-resolved iNat taxon's own rank over Pl@ntNet's
        -- (which is often nil for species-level results -- see isSpecies()
        -- in WhatIsThisAnimal.lua), for the same reason commonName prefers
        -- iNat: consistency with the source of truth now that we're
        -- resolving through it anyway.
        rank = taxon.rank or candidate.rank,
    }
    return updatedCandidate, majorAncestryFromTaxon(taxon)
end

-- Resolves a user-typed scientific name to a full candidate + ancestry, for
-- the case where neither iNaturalist's nor Pl@ntNet's own identification
-- found a match but the user already knows what it is. Requires an exact
-- (case-sensitive) match against iNaturalist's taxonomy, same as
-- getMajorAncestryByName -- a typo or unrecognized name fails rather than
-- silently guessing.
--
-- Returns candidate, ancestry:
--   candidate - { id, score, scientificName, commonName, rank }, the same
--               shape as any other picker candidate (score is a nominal
--               100, since there's no vision-model confidence to report),
--               or nil if no exact match was found.
--   ancestry  - list of { rank, name, commonName }, same shape as
--               getMajorAncestry's return; {} if candidate is nil.
function INaturalist.resolveByName(scientificName)
    local taxonId = findTaxonId(scientificName, nil)
    local taxon = fetchTaxonDetail(taxonId)
    if not taxon then
        return nil, {}
    end

    local candidate = {
        id = taxon.id,
        score = 100,
        scientificName = taxon.name or scientificName,
        commonName = taxon.preferred_common_name,
        rank = taxon.rank,
    }
    return candidate, majorAncestryFromTaxon(taxon)
end

-- Computes the lowest common ancestor of a set of candidates (each needing
-- a real iNaturalist taxon `id` -- Pl@ntNet-sourced candidates don't have
-- one and are silently skipped). This is a client-side fallback for when
-- iNaturalist's own confidence-gated common_ancestor rollup doesn't fire
-- (e.g. a batch of very scattered, low-confidence genus guesses) -- so the
-- user can still tag at some rolled-up level instead of guessing wrong.
--
-- Fetches each usable candidate's full ancestor chain (one taxon-detail
-- round trip per candidate -- meant to be called on demand, not on every
-- identify, to avoid the extra API load/latency on the common case), then
-- finds the deepest taxon shared by all of them (the longest common prefix
-- of their ancestor-id lists, which are already ordered broadest-first).
--
-- Returns candidate, ancestry (same shapes as resolveByName), or nil, {} if
-- fewer than 2 candidates have a usable id, or no ancestor is shared at all
-- (e.g. the candidates span different kingdoms).
--
-- The candidate's score is the *sum* of the contributing candidates' own
-- scores, but only over the ones that aren't themselves an ancestor of
-- another candidate in the set. Sibling suggestions (e.g. two different
-- genera in the same family) are mutually exclusive possibilities for what
-- the organism actually is, so their probabilities add: P(family) =
-- P(genus A) + P(genus B) + ... If one suggestion is already an ancestor
-- of another in the set (e.g. a family-level guess alongside one of its
-- own genera), it's excluded from the sum -- its probability mass already
-- contains the more specific one, so counting both would double-count the
-- same possibility, same class of bug as the mergeResults score-inflation
-- fix. Note this can still occasionally read over 100%: iNaturalist's raw
-- combined_score isn't a strictly-calibrated probability (it factors in a
-- geo-based frequency boost too), so summing genuinely disjoint candidates
-- can nominally exceed 100 -- that reflects the input scores not being true
-- probabilities, not a bug in this logic.
function INaturalist.commonAncestorOf(candidates)
    local chains = {}
    local scores = {}

    for _, c in ipairs(candidates) do
        if c.id then
            local taxon = fetchTaxonDetail(c.id)
            if taxon then
                local chain = {}
                for _, a in ipairs(taxon.ancestors or {}) do
                    table.insert(chain, { id = a.id, rank = a.rank, name = a.name, commonName = a.preferred_common_name })
                end
                table.insert(chain, { id = taxon.id, rank = taxon.rank, name = taxon.name, commonName = taxon.preferred_common_name })
                table.insert(chains, chain)
                table.insert(scores, c.score or 0)
            end
        end
    end

    if #chains < 2 then
        return nil, {}
    end

    local totalScore = 0
    for i, chain in ipairs(chains) do
        local selfId = chain[#chain].id
        local isAncestorOfAnother = false
        for j, otherChain in ipairs(chains) do
            if j ~= i then
                for k = 1, #otherChain - 1 do
                    if otherChain[k].id == selfId then
                        isAncestorOfAnother = true
                        break
                    end
                end
            end
            if isAncestorOfAnother then
                break
            end
        end
        if not isAncestorOfAnother then
            totalScore = totalScore + scores[i]
        end
    end

    local shortestLength = #chains[1]
    for _, chain in ipairs(chains) do
        if #chain < shortestLength then
            shortestLength = #chain
        end
    end

    local commonLength = 0
    for i = 1, shortestLength do
        local id = chains[1][i].id
        local allMatch = true
        for _, chain in ipairs(chains) do
            if chain[i].id ~= id then
                allMatch = false
                break
            end
        end
        if allMatch then
            commonLength = i
        else
            break
        end
    end

    if commonLength == 0 then
        return nil, {}
    end

    local lca = chains[1][commonLength]
    local candidate = {
        id = lca.id,
        score = totalScore,
        scientificName = lca.name,
        commonName = lca.commonName,
        rank = lca.rank,
    }

    local ancestryEntries = {}
    for i = 1, commonLength - 1 do
        table.insert(ancestryEntries, chains[1][i])
    end

    return candidate, filterMajorRanks(ancestryEntries)
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

    local function ensurePooled(entry)
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
        if not pooled.commonName and entry.commonName then
            pooled.commonName = entry.commonName
        end
        return pooled
    end

    for _, photoResult in ipairs(perPhotoResults) do
        -- A single photo's own response can list the same taxon both as a
        -- ranked `results` entry AND as `commonAncestor` -- e.g. when
        -- several of the top species candidates all share one genus, the
        -- vision model predicts that genus directly *and* it's also the
        -- rollup ancestor for the scattered species candidates. Take this
        -- photo's single best score per taxon before folding into the
        -- cross-photo pool, so one photo never contributes more than once
        -- for the same taxon -- otherwise the average can climb past the
        -- natural ~100% ceiling.
        local bestThisPhoto = {}
        local function noteThisPhoto(entry)
            local key = poolKey(entry)
            local existing = bestThisPhoto[key]
            if not existing or entry.score > existing.score then
                bestThisPhoto[key] = entry
            end
        end

        for _, r in ipairs(photoResult.results) do
            noteThisPhoto(r)
        end
        if photoResult.commonAncestor then
            noteThisPhoto(photoResult.commonAncestor)
        end

        for _, entry in pairs(bestThisPhoto) do
            local pooled = ensurePooled(entry)
            pooled.scoreSum = pooled.scoreSum + entry.score
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

-- Runs identify() for every entry in `photoEntries` (each a
-- { path, lat, lng } table -- lat/lng optional) calling onProgress(i, n)
-- before each, if given, and merges the results. Works for a single photo
-- too -- averaging over N=1 is a no-op, so this is the only entry point
-- callers need.
function INaturalist.identifyAll(photoEntries, onProgress)
    local perPhoto = {}
    for i, entry in ipairs(photoEntries) do
        if onProgress then
            onProgress(i, #photoEntries)
        end
        table.insert(perPhoto, INaturalist.identify(entry.path, entry.lat, entry.lng))
    end
    return INaturalist.mergeResults(perPhoto)
end

-- iNaturalist's place id for New York state, confirmed live (2026-07-22)
-- via /v1/places/autocomplete?q=New York (id 48, place_type 8, admin_level
-- 10 -- the state itself, distinct from the city and county entries also
-- named "New York"). Hardcoded rather than resolved per-photo: tried
-- resolving an arbitrary GPS point to its containing place via
-- /v1/places/nearby with a properly-sized bounding box and it only ever
-- returned "North America", nothing state/country-specific, regardless of
-- box size -- not a reliable mechanism. Given this plugin's actual use is
-- overwhelmingly local, one fixed known-good place id is simpler and
-- actually works.
local HOME_PLACE_ID = 48
local HOME_RADIUS_MILES = 50

local function getHomeLocation()
    return HomeLocation.lat, HomeLocation.lng
end

-- Great-circle distance in miles between two lat/lng points (haversine).
local function milesBetween(lat1, lng1, lat2, lng2)
    local earthRadiusMiles = 3958.8
    local function toRadians(deg) return deg * math.pi / 180 end
    local dLat = toRadians(lat2 - lat1)
    local dLng = toRadians(lng2 - lng1)
    local a = math.sin(dLat / 2) ^ 2 + math.cos(toRadians(lat1)) * math.cos(toRadians(lat2)) * math.sin(dLng / 2) ^ 2
    local c = 2 * math.atan(math.sqrt(a), math.sqrt(1 - a))
    return earthRadiusMiles * c
end

-- Picks a representative conservation status out of a taxon's
-- conservation_statuses array. There's no single "global" entry to rely
-- on -- confirmed live against a real taxon with 16 assessments (France,
-- Finland, several US states, the actual IUCN Red List, etc.), each with
-- its own `authority` and `place`, and the taxon's own singular
-- `conservation_status` field stays null unless there happens to be an
-- exact match for whatever preferred_place_id was requested. Rather than
-- try to fully replicate iNat's own resolution logic, this takes the first
-- entry whose authority mentions IUCN as a reasonable "widely recognized
-- status" heuristic -- not a claim of full accuracy for any specific
-- place, just good enough for casual reference. Returns nil if no such
-- entry exists (common -- many species only have regional/national
-- listings, no global IUCN assessment at all).
local function pickConservationStatus(taxon)
    for _, entry in ipairs(taxon.conservation_statuses or {}) do
        if entry.authority and entry.authority:lower():find("iucn", 1, true) then
            return entry.status
        end
    end
    return nil
end

-- Fetches the taxon-level facts cached in TaxonStore.lua (Conservation
-- Status, Establishment Means, Wikipedia URL) in a single round trip.
-- `lat`/`lng` (the photo's own GPS) are optional; Establishment Means is
-- only resolved when they're within HOME_RADIUS_MILES of the fixed home
-- location (see HomeLocation.lua) -- iNat's establishment_means
-- is inherently place-specific, and there's no reliable way to resolve an
-- arbitrary GPS point to the right iNat place (confirmed live: even a
-- correctly-sized bounding box around a real point only ever returned
-- "North America" from /v1/places/nearby, never anything as specific as a
-- state) -- so this only ever asks about one fixed, known-good place
-- (HOME_PLACE_ID) and only when there's a reasonable chance it's the
-- right context. Conservation Status and Wikipedia URL aren't
-- place-gated -- they come along for free in the same request regardless.
--
-- Returns a table (possibly with some/all fields nil) -- never errors,
-- since this is an optional enrichment. Always fetches fresh from the
-- API; TaxonStore-level caching (so this isn't re-fetched for a species
-- already looked up before) is the caller's responsibility.
function INaturalist.getTaxonFacts(taxonId, lat, lng)
    if not taxonId then
        return {}
    end

    local url = TAXA_URL .. tostring(taxonId) .. "?preferred_place_id=" .. tostring(HOME_PLACE_ID)
    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url)
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

    local establishmentMeans = nil
    if lat and lng then
        local homeLat, homeLng = getHomeLocation()
        if homeLat and milesBetween(lat, lng, homeLat, homeLng) <= HOME_RADIUS_MILES then
            establishmentMeans = taxon.preferred_establishment_means
        end
    end

    return {
        conservationStatus = pickConservationStatus(taxon),
        establishmentMeans = establishmentMeans,
        wikipediaUrl = taxon.wikipedia_url,
    }
end

-- Pulls every observation for `username` (paginated, 200/page), optionally
-- constrained to those updated since `updatedSince` (an ISO8601 string) --
-- pass nil for a first-ever full pull. Calls onProgress(pulledSoFar) after
-- each page, if given. Returns a flat list of raw observation entries --
-- shape confirmed live during planning: { id, taxon, time_observed_at,
-- photos, identifications, user, updated_at, ... }, where `taxon` already
-- carries { id, name, rank, preferred_common_name } (the current
-- community-agreed ID, no extra fetch needed to know what it currently is).
-- Errors (rather than returning {}) on failure -- unlike the optional-
-- enrichment functions elsewhere in this file, a sync pull failing outright
-- should stop the whole run, not silently proceed with partial data.
function INaturalist.getMyObservations(username, updatedSince, onProgress)
    local observations = {}
    local page = 1
    local perPage = 200

    while true do
        local url = OBSERVATIONS_URL .. "?user_id=" .. urlEncode(username)
            .. "&order_by=updated_at&order=asc&per_page=" .. perPage .. "&page=" .. page
        if updatedSince then
            url = url .. "&updated_since=" .. urlEncode(updatedSince)
        end

        local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url)
        if not ok then
            error("Couldn't reach iNaturalist to pull observations.")
        end
        local status = hdrs and hdrs.status
        if status ~= 200 then
            error("iNaturalist request failed (status " .. tostring(status) .. ") while pulling observations.")
        end

        local decodeOk, decoded = pcall(JSON.decode, response)
        if not decodeOk then
            error("Couldn't parse iNaturalist's observations response.")
        end

        local results = decoded.results or {}
        for _, r in ipairs(results) do
            table.insert(observations, r)
        end

        if onProgress then
            onProgress(#observations)
        end

        if #results < perPage then
            break
        end
        page = page + 1
        LrTasks.sleep(1.0)
    end

    return observations
end

-- Fetches specific observations by id (comma-joined, standard iNat API
-- convention -- NOT separately live-verified this session the way the
-- other new endpoints here were; worth confirming on the first real run).
-- Used by the sync's retry-list mechanism to re-fetch observations that
-- failed to apply on a previous run, independent of `updated_since`.
-- Returns {} (not an error) if `ids` is empty, since an empty retry list
-- is the normal/common case, not a failure.
function INaturalist.getObservationsByIds(ids)
    if not ids or #ids == 0 then
        return {}
    end

    local idList = {}
    for _, id in ipairs(ids) do
        table.insert(idList, tostring(id))
    end
    local url = OBSERVATIONS_URL .. "?id=" .. table.concat(idList, ",")

    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url)
    if not ok then
        error("Couldn't reach iNaturalist to pull retry-list observations.")
    end
    local status = hdrs and hdrs.status
    if status ~= 200 then
        error("iNaturalist request failed (status " .. tostring(status) .. ") while pulling retry-list observations.")
    end

    local decodeOk, decoded = pcall(JSON.decode, response)
    if not decodeOk then
        error("Couldn't parse iNaturalist's observations response.")
    end

    return decoded.results or {}
end

-- Checks whether `username` currently agrees with an observation's
-- consensus ID, via its `identifications` array: finds the entry where
-- `user.login == username` and `current == true`, and checks its
-- `category` -- "maverick" means the user's current identification
-- disagrees with the community consensus; any other category ("supporting",
-- "leading", "improving") means they agree. Returns true if the user has no
-- identification on this observation at all (nothing to disagree with, so
-- "agrees" is the sensible default -- callers should only skip an update on
-- an explicit disagreement signal, not the absence of one). Confirmed live
-- against a real observation (inaturalist.org/observations/382468756)
-- during planning.
function INaturalist.observationAgreesWithMe(observation, username)
    for _, ident in ipairs(observation.identifications or {}) do
        if ident.user and ident.user.login == username and ident.current then
            return ident.category ~= "maverick"
        end
    end
    return true
end

-- Shared v2-endpoint fetch-with-401-retry helper for the two functions
-- below. Requires the v2 endpoint's sparse `fields` syntax with an
-- authenticated request -- confirmed live during planning that
-- `original_filename` is omitted from the standard v1 response (and even
-- an unauthenticated v2 request), so this needs INaturalist.getAuthToken()'s
-- token specifically. The v2 token is the same 24-hour JWT identify() uses;
-- unlike identify(), an earlier version of this never retried on 401 --
-- confirmed live as the real cause of untagged sibling photos staying
-- untagged even after other fixes: a stale stored token made every call
-- here fail outright with no visible error, silently skipping every
-- mismatch check and absorption attempt in the entire run. Retries once
-- with a freshly-prompted token, same pattern identify() already uses.
-- Returns the single decoded observation object, or nil if the
-- request/decode failed for any reason.
local function fetchV2Observation(observationId, fieldsParam)
    local token = INaturalist.getAuthToken()
    local url = OBSERVATIONS_V2_URL .. "?id=" .. tostring(observationId)
        .. "&fields=" .. urlEncode(fieldsParam)

    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url, { { field = "Authorization", value = token } })
    local status = ok and hdrs and hdrs.status

    if status == 401 then
        token = promptForToken()
        if token then
            storeToken(token)
            ok, response, hdrs = LrTasks.pcall(LrHttp.get, url, { { field = "Authorization", value = token } })
            status = ok and hdrs and hdrs.status
        end
    end

    if status ~= 200 then
        return nil
    end

    local decodeOk, decoded = pcall(JSON.decode, response)
    if not decodeOk then
        return nil
    end

    return decoded.results and decoded.results[1]
end

-- Fetches the original filenames of every photo attached to an iNat
-- observation, for the group-membership-mismatch check. Returns a list of
-- filenames (possibly empty), or nil if the request fails for any reason --
-- callers should treat nil as "couldn't check this time", not as "zero
-- photos", so a transient failure here doesn't get misread as an actual
-- mismatch.
function INaturalist.getObservationPhotoFilenames(observationId)
    local observation = fetchV2Observation(observationId, "(id:!t,photos:(original_filename:!t))")
    if not observation then
        return nil
    end

    local rawPhotos = observation.photos or {}
    local filenames = {}
    for _, photo in ipairs(rawPhotos) do
        if photo.original_filename and photo.original_filename ~= "" then
            table.insert(filenames, photo.original_filename)
        end
    end

    -- If the observation genuinely has photos but NONE of them yielded a
    -- usable filename, this is a failed/incomplete fetch, not "zero
    -- filenames" -- confirmed live that the v2 fields-based fetch doesn't
    -- always populate original_filename even when authenticated (worked
    -- for one observation, came back empty for another, for reasons not
    -- fully understood). Returning an empty list here would be truthy
    -- (Lua only treats nil/false as falsy), so the caller's mismatch check
    -- would wrongly read it as "iNat confirmed zero photos" and flag every
    -- local photo as "missing from iNat" -- confirmed live this happened.
    -- Returning nil instead makes the caller correctly treat this as
    -- "couldn't verify" and skip the mismatch check, same as any other
    -- fetch failure.
    if #rawPhotos > 0 and #filenames == 0 then
        return nil
    end

    return filenames
end

-- Fallback signal for sibling-photo absorption when original_filename
-- isn't usable at all -- confirmed live: iNat can return a fully valid,
-- authenticated 200 response whose photos array has ONLY `id` fields, no
-- filenames, for a given observation, for reasons unrelated to auth/token
-- expiry. The photo COUNT itself is unaffected by that (the `photos` array
-- always reflects how many photos are actually attached), so it remains a
-- reliable way to know whether the local group is missing any, even when
-- there's no way to tell WHICH ones by name. Returns nil on failure.
function INaturalist.getObservationPhotoCount(observationId)
    local observation = fetchV2Observation(observationId, "(id:!t,photos:(id:!t))")
    if not observation then
        return nil
    end
    return #(observation.photos or {})
end

-- Diagnostic-only (used by ShowObservationFilenames.lua): performs the
-- exact same fetch as getObservationPhotoFilenames, but never swallows the
-- failure -- returns the URL, the raw pcall/HTTP-status/response-snippet
-- for the first attempt, and (if a 401 triggered a retry) the same detail
-- for the retry, so a real failure can actually be diagnosed instead of
-- just seeing "request failed" with nothing else to go on. Added after
-- getObservationPhotoFilenames's own 401-retry fix (see there) didn't
-- visibly change anything live -- confirming whether that's because the
-- status genuinely isn't 401 (e.g. the request errors out before ever
-- getting a status at all) or something else entirely.
function INaturalist.debugObservationPhotoFetch(observationId)
    local token = INaturalist.getAuthToken()
    local url = OBSERVATIONS_V2_URL .. "?id=" .. tostring(observationId)
        .. "&fields=" .. urlEncode("(id:!t,photos:(original_filename:!t))")

    local function attempt(tok)
        local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url, { { field = "Authorization", value = tok } })
        return {
            ok = ok,
            errorMessage = (not ok) and tostring(response) or nil,
            status = ok and hdrs and hdrs.status or nil,
            responseSnippet = (ok and type(response) == "string") and response:sub(1, 300) or nil,
        }
    end

    local info = { url = url, first = attempt(token) }

    if info.first.status == 401 then
        local freshToken = promptForToken()
        info.retriedWithFreshToken = freshToken ~= nil
        if freshToken then
            storeToken(freshToken)
            info.retry = attempt(freshToken)
        end
    end

    return info
end

return INaturalist
