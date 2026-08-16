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
-- taxa search, requiring an exact name match (case-insensitive, and with
-- leading/trailing whitespace trimmed -- easy typos for a hand-typed
-- name, e.g. the manual-entry flow in CandidatePicker.lua, but not the
-- same risk as a fuzzy/spelling-tolerant match) against the results, so a
-- wrong match is never silently accepted. The candidate's own
-- scientificName still ends up as iNaturalist's own correctly-cased
-- canonical name, not whatever case the caller passed in (see
-- resolveByName's use of taxon.name below). Returns nil if no exact match
-- is found or the request fails.
local function findTaxonId(scientificName, rank)
    local trimmedName = scientificName:match("^%s*(.-)%s*$")
    local url = TAXA_SEARCH_URL .. "?q=" .. urlEncode(trimmedName) .. "&per_page=10"
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
        if r.name:lower() == trimmedName:lower() then
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
        -- in SpeciesIdentification.lua), for the same reason commonName prefers
        -- iNat: consistency with the source of truth now that we're
        -- resolving through it anyway.
        rank = taxon.rank or candidate.rank,
        -- Carried through unchanged (2026-08-11) -- Pl@ntNet's full name
        -- array (see PlantNet.lua) still matters for TaxonStore's
        -- commonNames list even though commonName itself just got
        -- overridden above; dropping it here would silently lose it on
        -- essentially every real Pl@ntNet identification, since this is
        -- the actual resolution path SpeciesIdentification.lua calls for
        -- whichever candidate the user picked.
        allCommonNames = candidate.allCommonNames,
    }
    return updatedCandidate, majorAncestryFromTaxon(taxon)
end

-- Resolves a user-typed scientific name to a full candidate + ancestry, for
-- the case where neither iNaturalist's nor Pl@ntNet's own identification
-- found a match but the user already knows what it is. Requires an exact
-- match (case-insensitive, whitespace-trimmed -- see findTaxonId's own
-- doc comment) against iNaturalist's taxonomy, same as
-- getMajorAncestryByName -- a real spelling typo or unrecognized name
-- still fails rather than silently guessing.
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

-- Finds candidate ancestor rollups for a set of candidates. A candidate
-- with a real iNaturalist taxon `id` uses it directly; one without (e.g. a
-- Pl@ntNet result) is resolved by exact scientific-name match instead, the
-- same fallback getMajorAncestryForCandidate already uses -- so a candidate
-- is only skipped if that resolution genuinely fails to find a match. This
-- is a client-side fallback for when iNaturalist's own confidence-gated
-- common_ancestor rollup doesn't fire (e.g. a batch of very scattered,
-- low-confidence genus guesses) -- so the user can still tag at some
-- rolled-up level instead of guessing wrong.
--
-- IMPORTANT: `candidates` must all come from the *same* identification
-- service/run. Scores are summed across sibling candidates (see below) on
-- the premise that they're mutually exclusive alternative readings of the
-- same evidence -- true within one model's output, but not between two
-- different services' independently-computed, differently-calibrated
-- confidence scores. Mixing e.g. iNaturalist and Pl@ntNet candidates into
-- one call here would silently combine incomparable numbers into a
-- meaningless sum. CandidatePicker.lua's tabbed dialog (one tab per
-- service) already keeps this straight structurally -- each tab's own
-- "Find Common Ancestor" button calls this once, against just that tab's
-- own candidates, never mixed with another tab's.
--
-- Earlier versions of this forced a single lowest-common-ancestor (LCA)
-- across the *entire* candidate list -- one taxonomic outlier (e.g. a Brown
-- Bear guess sitting alongside a cluster of bovid guesses) would drag that
-- single result all the way up to a near-useless rank (e.g. superorder
-- Laurasiatheria), even though the bovid cluster on its own shares a much
-- more specific, useful ancestor. Instead of one forced-broad result, this
-- returns up to `maxOptions` rollup options -- one per meaningful branch
-- point -- so a good option can exist for a subset of the candidates even
-- when the full set shares nothing useful.
--
-- Fetches each usable candidate's full ancestor chain (one taxon-detail
-- round trip per candidate -- meant to be called on demand, not on every
-- identify, to avoid the extra API load/latency on the common case), then
-- merges all the chains into a single tree (shared prefixes collapsed
-- together). Every internal branch node of that tree is, by construction,
-- the LCA of exactly the original candidates in its subtree -- so this only
-- ever considers real, contiguous taxonomic groupings (e.g. genus Bos
-- naturally groups Bison + Wisent + Domestic Cattle in one branch, separate
-- from Brown Bear's own branch), never an arbitrary/nonsensical
-- combination, and building it costs time proportional to the total chain
-- length -- NOT the 2^N combinatorial search a brute-force "try every
-- subset" approach would need.
--
-- Returns a list of { candidate, ancestry, memberCount }, each shaped like
-- resolveByName's own return pair, plus memberCount (how many of the
-- original candidates this option rolls up) -- sorted best (highest score)
-- first. Empty list if fewer than 2 candidates resolve to a usable taxon,
-- or none share any ancestor at all (e.g. the candidates span different
-- kingdoms).
--
-- Each option's score is the *sum* of the contributing candidates' own
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
function INaturalist.commonAncestorOptions(candidates, maxOptions)
    maxOptions = maxOptions or 3

    local chains = {}
    local scores = {}

    for _, c in ipairs(candidates) do
        -- Same id-or-name dispatch as getMajorAncestryForCandidate: use the
        -- real taxon id when present, otherwise resolve by exact
        -- scientific-name match (the only option for a Pl@ntNet result,
        -- which never carries an iNat id of its own).
        local taxonId = c.id or findTaxonId(c.scientificName, c.rank)
        if taxonId then
            local taxon = fetchTaxonDetail(taxonId)
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
        return {}
    end

    -- Merge every chain into one tree. `root` is a sentinel with no taxon
    -- of its own, just children keyed by taxon id; every real node tracks
    -- its parent (to reconstruct ancestry later) and, once a candidate's
    -- own chain ends on it, which original candidate that was.
    local root = { children = {}, depth = 0 }
    for chainIndex, chain in ipairs(chains) do
        local node = root
        for _, step in ipairs(chain) do
            local child = node.children[step.id]
            if not child then
                child = {
                    id = step.id, rank = step.rank, name = step.name, commonName = step.commonName,
                    children = {}, parent = node, depth = node.depth + 1,
                }
                node.children[step.id] = child
            end
            node = child
        end
        node.isOwnCandidate = true
        node.candidateIndex = chainIndex
    end

    -- Post-order walk: bubble each node's own candidate (if any) plus every
    -- descendant's candidates up to itself, so every node ends up knowing
    -- exactly which original candidates its subtree covers.
    local allNodes = {}
    local function visit(node)
        node.candidateIndices = {}
        if node.isOwnCandidate then
            table.insert(node.candidateIndices, node.candidateIndex)
        end
        for _, child in pairs(node.children) do
            visit(child)
            for _, idx in ipairs(child.candidateIndices) do
                table.insert(node.candidateIndices, idx)
            end
        end
        if node.id then
            table.insert(allNodes, node)
        end
    end
    visit(root)

    -- Same anti-double-counting rule as before: a candidate whose own node
    -- has another candidate anywhere in its subtree is an ancestor of that
    -- other one, so its own score is excluded from any rollup sum -- the
    -- broader guess's probability mass already overlaps the more specific
    -- one's. This fact is subtree-independent (an ancestor/descendant
    -- relationship doesn't change depending on which node's rollup you're
    -- computing), so it's computed once globally rather than per option.
    local isAncestorOfAnother = {}
    for _, node in ipairs(allNodes) do
        if node.isOwnCandidate then
            isAncestorOfAnother[node.candidateIndex] = #node.candidateIndices > 1
        end
    end

    local function rollupScore(node)
        local total = 0
        for _, idx in ipairs(node.candidateIndices) do
            if not isAncestorOfAnother[idx] then
                total = total + scores[idx]
            end
        end
        return total
    end

    -- Only nodes that actually roll up more than one candidate are
    -- meaningful options -- a node covering just one candidate carries no
    -- more information than that candidate's own already-shown row.
    local rollupNodes = {}
    for _, node in ipairs(allNodes) do
        if #node.candidateIndices > 1 then
            table.insert(rollupNodes, node)
        end
    end

    -- Dedupe by exact candidate membership -- if two branch points cover
    -- the identical set of original candidates (possible when a rank has
    -- only one representative at each level in between), keep only the
    -- deepest (most specific) one; a broader node with the same membership
    -- adds no new information.
    local bestByMembership = {}
    for _, node in ipairs(rollupNodes) do
        local members = {}
        for _, idx in ipairs(node.candidateIndices) do
            table.insert(members, idx)
        end
        table.sort(members)
        local key = table.concat(members, ",")
        local existing = bestByMembership[key]
        if not existing or node.depth > existing.depth then
            bestByMembership[key] = node
        end
    end
    local deduped = {}
    for _, node in pairs(bestByMembership) do
        table.insert(deduped, node)
    end

    table.sort(deduped, function(a, b) return rollupScore(a) > rollupScore(b) end)

    local results = {}
    for i = 1, math.min(maxOptions, #deduped) do
        local node = deduped[i]

        local ancestryEntries = {}
        local step = node.parent
        while step and step.id do
            table.insert(ancestryEntries, 1, { rank = step.rank, name = step.name, commonName = step.commonName })
            step = step.parent
        end

        table.insert(results, {
            candidate = {
                id = node.id,
                score = rollupScore(node),
                scientificName = node.name,
                commonName = node.commonName,
                rank = node.rank,
            },
            ancestry = filterMajorRanks(ancestryEntries),
            memberCount = #node.candidateIndices,
        })
    end

    return results
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
-- Extracts every English common name from a `?all_names=true` taxa
-- response's `names` array ({ name, locale, lexicon, position, is_valid }
-- per entry, confirmed live 2026-08-11 against a real taxon -- e.g.
-- Eastern Bluebird genuinely has more than one: "Eastern Bluebird" at
-- position 0, "Blue-bird" at position 13). Filters to `locale == "en"`
-- (hardcoded -- no locale-config concept exists anywhere in this
-- codebase) and `is_valid == true` (skips deprecated/historical names),
-- sorted by `position` ascending (iNat's own preference/display order).
-- Tagged `source = "inat"` for TaxonStore's commonNames list. Returns an
-- empty list, never nil, if `taxon.names` is absent (e.g. the request
-- didn't ask for it, or the taxon genuinely has none).
local function extractEnglishCommonNames(taxon)
    local matches = {}
    for _, entry in ipairs(taxon.names or {}) do
        if entry.locale == "en" and entry.is_valid then
            table.insert(matches, entry)
        end
    end
    table.sort(matches, function(a, b) return (a.position or 0) < (b.position or 0) end)

    local names = {}
    for _, entry in ipairs(matches) do
        table.insert(names, { name = entry.name, source = "inat" })
    end
    return names
end

-- Returns a table (possibly with some/all fields nil) -- never errors,
-- since this is an optional enrichment. Always fetches fresh from the
-- API; TaxonStore-level caching (so this isn't re-fetched for a species
-- already looked up before) is the caller's responsibility.
function INaturalist.getTaxonFacts(taxonId, lat, lng)
    if not taxonId then
        return {}
    end

    -- &all_names=true added 2026-08-11 specifically for commonNames below
    -- -- without it, iNat's response has no `names` array at all, only the
    -- single `preferred_common_name` already used elsewhere in this file.
    local url = TAXA_URL .. tostring(taxonId) .. "?preferred_place_id=" .. tostring(HOME_PLACE_ID) .. "&all_names=true"
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
        commonNames = extractEnglishCommonNames(taxon),
        -- Added 2026-08-15 for ManageFloraObservation.lua's plant/fungus
        -- scope gate -- same Plantae/Fungi value space as KINGDOMS_TO_SHOW
        -- above (both check the SAME iNat vocabulary, just for different
        -- purposes: that one filters ancestry display, this one gates
        -- which observations the dialog will touch at all). Free to
        -- capture here -- KeywordWriter.applyIdentification already calls
        -- this exactly once per newly-identified species (only when no
        -- bare TaxonStore entry exists yet), so every species identified
        -- from now on gets this cached with zero extra requests. Species
        -- identified before this existed need the separate
        -- getIconicTaxonName lazy-backfill path below instead.
        iconicTaxonName = taxon.iconic_taxon_name,
    }
end

-- Cheap, single-field lookup for the "species was identified before the
-- iconicTaxonName backfill existed" case -- reuses fetchTaxonDetail rather
-- than calling getTaxonFacts again, since a full getTaxonFacts refetch
-- would return only iNat's raw commonNames list and, written back via
-- TaxonStore.set, would CLOBBER any manually-added or Pl@ntNet-sourced
-- names already merged into TaxonStore's own commonNames array.
function INaturalist.getIconicTaxonName(taxonId)
    local taxon = fetchTaxonDetail(taxonId)
    return taxon and taxon.iconic_taxon_name
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
-- Second return value is a per-page diagnostic trace (url, resultCount,
-- totalResults per iNat's own response) -- added 2026-07-24 while
-- diagnosing a live case where several incremental pulls in a row
-- returned nothing new for observations already confirmed (via requests
-- made outside Lightroom) to be visible on iNat's side. Threaded through
-- to the sync log so a live failure can be diagnosed from what was
-- actually requested/returned, rather than guessed at from outside.
-- `Cache-Control`/`Pragma: no-cache` request headers added at the same
-- time -- confirmed live that this endpoint sits behind a CDN
-- (`Cache-Control: public, max-age=300` on its responses) -- asking it to
-- skip that cache is a cheap, safe precaution for a correctness-critical
-- incremental pull, even though it isn't yet confirmed to be the actual
-- cause of the observed misses.
function INaturalist.getMyObservations(username, updatedSince, onProgress)
    local observations = {}
    local pullDebug = {}
    local page = 1
    local perPage = 200

    while true do
        local url = OBSERVATIONS_URL .. "?user_id=" .. urlEncode(username)
            .. "&order_by=updated_at&order=asc&per_page=" .. perPage .. "&page=" .. page
        if updatedSince then
            url = url .. "&updated_since=" .. urlEncode(updatedSince)
        end

        local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url, {
            { field = "Cache-Control", value = "no-cache" },
            { field = "Pragma", value = "no-cache" },
        })
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

        table.insert(pullDebug, {
            url = url,
            page = page,
            resultCount = #results,
            totalResults = decoded.total_results,
        })

        if onProgress then
            onProgress(#observations)
        end

        if #results < perPage then
            break
        end
        page = page + 1
        LrTasks.sleep(1.0)
    end

    return observations, pullDebug
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

-- Substitutes the size segment of an iNat photo URL (e.g.
-- ".../photos/704633426/square.jpg") for a different one -- iNat's
-- storage uses a plain, consistent size-word-in-the-path convention
-- (square/small/medium/large/original). Falls back to returning `url`
-- unchanged if it doesn't match the expected shape, rather than raising
-- -- callers already treat a failed/short download as "couldn't recover
-- this one," not a hard error.
local function toSizeUrl(url, size)
    return (url:gsub("/[%w_]+%.(%a+)$", "/" .. size .. ".%1"))
end

-- Downloads ONE photo entry (using its `url` field the standard v1 pull
-- already includes -- see getMyObservations, no extra API call needed) to
-- a local temp file, so the sync dialogs can show an actual iNat
-- thumbnail next to a local candidate photo instead of just text. NOT
-- cached/persisted across runs -- a fresh one-shot fetch each time a
-- dialog needs it, deleted by the caller once the dialog closes. Returns
-- the local file path, or nil if the photo has no usable URL or the
-- download failed for any reason (network, non-200 status, write
-- failure) -- callers should treat nil as "couldn't show a preview this
-- time," not an error worth interrupting the sync over. `tempFileSuffix`
-- just needs to be unique per call (observation id, or observation id +
-- photo index) so concurrent/sequential downloads don't collide on the
-- same temp path.
--
-- Uses the "small" size (240x240), not the default `url` field's "square"
-- (75x75) -- confirmed live 2026-07-30 against a real photo: "square" was
-- visibly blurry once upscaled to the dialogs' 150x150 display size,
-- while "small" (only ~5x the file size, ~51KB vs ~10KB in the real test)
-- comfortably covers it with no upscaling at all.
local function downloadPhotoThumbnail(photo, tempFileSuffix)
    if not photo or not photo.url or photo.url == "" then
        return nil
    end

    local url = toSizeUrl(photo.url, "small")
    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url)
    if not ok or not hdrs or hdrs.status ~= 200 or not response or response == "" then
        return nil
    end

    local tempDir = LrPathUtils.getStandardFilePath("temp")
    local tempPath = LrPathUtils.child(tempDir, "inat-thumb-" .. tostring(tempFileSuffix) .. ".jpg")

    local writeOk = pcall(function()
        local f = assert(io.open(tempPath, "wb"))
        f:write(response)
        f:close()
    end)

    return writeOk and tempPath or nil
end

-- Downloads the FIRST photo of an already-pulled observation -- see
-- downloadPhotoThumbnail above for the mechanics. Confirmed live: the
-- downloaded file renders correctly via LrView's `picture` control (see
-- buildINatThumbnail in INatSyncRunner.lua).
function INaturalist.downloadObservationThumbnail(observation)
    return downloadPhotoThumbnail(observation.photos and observation.photos[1], observation.id)
end

-- Downloads EVERY photo on an observation, not just the first -- for
-- dialogs where seeing the whole set side by side is worth the extra
-- (cheap -- these are already-small "square" thumbnails, not originals)
-- downloads. Returns a list of temp paths in the same order as
-- observation.photos; a photo whose own download failed is simply
-- omitted, never blocks showing the ones that worked.
function INaturalist.downloadAllObservationThumbnails(observation)
    local paths = {}
    for i, photo in ipairs(observation.photos or {}) do
        local path = downloadPhotoThumbnail(photo, tostring(observation.id) .. "-" .. tostring(i))
        if path then
            table.insert(paths, path)
        end
    end
    return paths
end

-- Downloads every available photo for a taxon -- its default_photo (the
-- one shown at the top of its iNaturalist taxon page) plus any others
-- from taxon_photos -- to local temp files, for the ID candidate
-- picker's live preview + paging of whichever row is currently selected.
-- Confirmed live against the real API 2026-08-07: default_photo and
-- taxon_photos are separate fields -- default_photo is its own selection,
-- NOT necessarily repeated as an entry in taxon_photos -- so both are
-- combined here, deduped by photo id (a taxon's default_photo is often
-- also its "best" taxon_photos entry, and showing the exact same image
-- twice while paging would be a confusing no-op click). Shares
-- downloadPhotoThumbnail's "small" size + one-shot temp-file mechanics
-- above. Returns a list of temp paths (empty if the taxon id doesn't
-- resolve, has no photos, or every download failed) -- a photo whose own
-- download failed is simply omitted, never blocks showing the ones that
-- worked.
function INaturalist.downloadTaxonThumbnails(taxonId)
    local taxon = fetchTaxonDetail(taxonId)
    if not taxon then
        return {}
    end

    local photoEntries = {}
    local seenPhotoIds = {}
    if taxon.default_photo then
        table.insert(photoEntries, taxon.default_photo)
        seenPhotoIds[taxon.default_photo.id] = true
    end
    for _, taxonPhoto in ipairs(taxon.taxon_photos or {}) do
        local photo = taxonPhoto.photo
        if photo and not seenPhotoIds[photo.id] then
            table.insert(photoEntries, photo)
            seenPhotoIds[photo.id] = true
        end
    end

    local paths = {}
    for i, photo in ipairs(photoEntries) do
        local path = downloadPhotoThumbnail(photo, "taxon-" .. tostring(taxonId) .. "-" .. tostring(i))
        if path then
            table.insert(paths, path)
        end
    end
    return paths
end

-- Like downloadTaxonThumbnails, but for a picker candidate regardless of
-- which service it came from -- same id-or-name dispatch as
-- getMajorAncestryForCandidate/commonAncestorOptions: a candidate with a
-- real iNat taxon id uses it directly, one without (a Pl@ntNet result)
-- resolves by exact scientific-name match first. Returns an empty list
-- if resolution fails.
function INaturalist.downloadThumbnailsForCandidate(candidate)
    local taxonId = candidate.id or findTaxonId(candidate.scientificName, candidate.rank)
    if not taxonId then
        return {}
    end
    return INaturalist.downloadTaxonThumbnails(taxonId)
end

-- Resolves any picker candidate to its iNaturalist taxon page URL,
-- regardless of which service it came from -- same id-or-name dispatch as
-- downloadThumbnailsForCandidate/getMajorAncestryForCandidate/
-- commonAncestorOptions. For a candidate that already carries a real
-- `id` (iNaturalist-sourced) this is free, no network call; for one that
-- doesn't (Pl@ntNet-sourced) it costs one name-search round trip.
-- Callers that don't want that cost paid at dialog-build time should call
-- this lazily, on demand, rather than for every row up front -- see
-- CandidatePicker.lua's `resolveUrl` link support. Returns nil if
-- resolution fails.
function INaturalist.taxonUrlForCandidate(candidate)
    local taxonId = candidate.id or findTaxonId(candidate.scientificName, candidate.rank)
    if not taxonId then
        return nil
    end
    return "https://www.inaturalist.org/taxa/" .. tostring(taxonId)
end

-- Downloads the ORIGINAL (largest available, still capped by iNat at
-- 2048px long edge -- confirmed live: downloading the substituted
-- "original.jpg" URL for a real photo returned a file whose actual pixel
-- dimensions matched the API's own reported `original_dimensions`, iNat
-- never retains the true original) copy of a single iNat photo to a GIVEN
-- destination path -- unlike downloadObservationThumbnail above, which
-- always uses a small default size and a temp path for a one-shot dialog
-- preview, this is for the "Recover Missing Photos" feature, where the
-- downloaded file needs to persist at a real, catalog-addable location.
-- Returns true on success, false on any failure (network, non-200 status,
-- empty body, write failure) -- callers should treat false as "couldn't
-- recover this one," not abort the whole run.
function INaturalist.downloadOriginalPhoto(photoUrl, destPath)
    if not photoUrl or photoUrl == "" then
        return false
    end

    local url = toSizeUrl(photoUrl, "original")
    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url)
    if not ok or not hdrs or hdrs.status ~= 200 or not response or response == "" then
        return false
    end

    local writeOk = pcall(function()
        local f = assert(io.open(destPath, "wb"))
        f:write(response)
        f:close()
    end)

    return writeOk
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
