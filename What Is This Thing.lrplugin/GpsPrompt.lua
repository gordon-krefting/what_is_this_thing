local LrApplication = import 'LrApplication'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'

local HomeLocation = dofile(LrPathUtils.child(_PLUGIN.path, "HomeLocation.lua"))
local JSON = dofile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))

local GpsPrompt = {}

-- Nominatim (OpenStreetMap) reverse geocoding for the "Use Most Recent"
-- button's label -- raw coordinates alone don't carry much sense of place,
-- confirmed as a real live gap (2026-08-01). A descriptive User-Agent is
-- required by Nominatim's usage policy, not optional.
local NOMINATIM_REVERSE_URL = "https://nominatim.openstreetmap.org/reverse"
local NOMINATIM_USER_AGENT = "WhatIsThisThing-LightroomPlugin/0.1 (org.krefting.whatisthisthing)"

-- zoom=14 empirically (live-tested against real coordinates during
-- planning, several very different regions -- rural Chilean Patagonia,
-- Yellowstone, Yosemite) lands on the most specific NAMED node Nominatim
-- has near the point -- often a genuinely evocative one ("Upper Geyser
-- Basin", "Yosemite Lodge", "Torres del Paine") -- without going so fine
-- that it resolves to a bare trail/road name instead (confirmed live:
-- zoom=18 on a point deep in Yosemite returned "Half Dome Trail", not
-- anything about Half Dome itself). Not a hard guarantee for arbitrary
-- coordinates, just the best single fixed zoom level found in testing.
local NOMINATIM_ZOOM = 14

-- Live map preview for hand-typed coordinates -- Geoapify's Static Maps
-- API, chosen over a raw-OSM-tile grid (an earlier version of this)
-- after live use showed a marker pin was essential: without one, no
-- single fixed zoom could serve both "recognize the area" and "confirm
-- the exact point" at once, and there's no way to draw one on raw tiles
-- (no image-manipulation library available, and LrView can't layer
-- widgets to fake an overlay). Geoapify composes the whole thing --
-- center, zoom, marker -- server-side in one request: no stitching, no
-- gaps, no client-side drawing needed. Confirmed live 2026-08-07 against
-- the real endpoint with a real key -- clean single image, marker landed
-- exactly on the requested coordinate. Free tier, no credit card
-- (3000 credits/day, 1 credit per static map request) -- signup at
-- https://www.geoapify.com/.
local GEOAPIFY_STATIC_MAP_URL = "https://maps.geoapify.com/v1/staticmap"
local MAP_WIDTH, MAP_HEIGHT = 650, 520
local MAP_ZOOM_STEP = 2
local MAP_ZOOM_MIN, MAP_ZOOM_MAX = 1, 20
-- Two zoom-out steps from the original default (14) -- confirmed live
-- 2026-08-07 that 14 was too tight as a STARTING view (fine once you've
-- already zoomed to confirm a point, too close to get oriented from
-- cold); the map now also loads immediately at dialog-open (Home's own
-- location, see below), so this is the very first thing shown.
local DEFAULT_MAP_ZOOM = 10

-- Same prompt-once-and-remember shape as PlantNet.lua's own API key
-- handling (promptForApiKey/getStoredApiKey/storeApiKey) -- deliberately
-- NOT reused directly (different prefs key, different service, no
-- reason to couple the two), just the same established pattern.
local function promptForGeoapifyKey()
    local apiKey = nil

    LrFunctionContext.callWithContext("GeoapifyApiKeyPrompt", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.apiKey = ""

        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text {
                title = "Add a free Geoapify API key to see a live map preview\nwhen typing coordinates (optional -- Skip to continue without one):",
            },
            f:push_button {
                title = "https://www.geoapify.com/",
                action = function()
                    LrHttp.openUrlInBrowser("https://www.geoapify.com/")
                end,
            },
            f:edit_field {
                value = LrView.bind("apiKey"),
                passwordField = true,
                width_in_chars = 40,
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Geoapify API Key",
            contents = contents,
            actionVerb = "Save",
            cancelVerb = "Skip",
        }

        if result == "ok" and props.apiKey ~= "" then
            apiKey = props.apiKey
        end
    end)

    return apiKey
end

local function getStoredGeoapifyKey()
    local prefs = LrPrefs.prefsForPlugin()
    return prefs.geoapifyApiKey
end

local function storeGeoapifyKey(key)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.geoapifyApiKey = key
end

-- Cached on disk, keyed by (lat, lng, zoom) -- Home's own map (always the
-- exact same coordinate) is loaded on every single dialog open (see
-- GpsPrompt.choose below), so without caching that's a network round
-- trip every time for a view that's almost always identical to the last
-- one. Deliberately NOT cleaned up when a dialog closes (unlike this
-- plugin's other temp-file downloads, e.g. CandidatePicker.lua's
-- thumbnails) -- the whole point is for it to still be there next time.
-- Low volume in practice (Home is one fixed value; typed/recent
-- coordinates vary, but each still only generates a handful of cache
-- entries per session), so unbounded growth isn't a real concern the way
-- it is for this project's log files (see TODO.md).
local MAP_CACHE_DIR = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"), "WhatIsThisThing-mapcache")

-- Downloads one composed static map (center + zoom + marker, all server-
-- side), returns its path or nil on failure -- same LrHttp.get +
-- io.open("wb") pattern already proven live for binary image downloads
-- elsewhere in this plugin (see INaturalist.lua's downloadPhotoThumbnail).
local function downloadStaticMap(lat, lng, zoom, apiKey)
    LrFileUtils.createAllDirectories(MAP_CACHE_DIR)
    local cachePath = LrPathUtils.child(MAP_CACHE_DIR, string.format("map-%.6f-%.6f-%d.jpg", lat, lng, zoom))
    if LrFileUtils.exists(cachePath) then
        return cachePath
    end

    local url = string.format(
        "%s?style=osm-bright&width=%d&height=%d&center=lonlat:%s,%s&zoom=%d" ..
        "&marker=lonlat:%s,%s;type:awesome;color:%%23ff0000;size:48&apiKey=%s",
        GEOAPIFY_STATIC_MAP_URL, MAP_WIDTH, MAP_HEIGHT,
        tostring(lng), tostring(lat), zoom, tostring(lng), tostring(lat), apiKey
    )
    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url)
    if not ok or not hdrs or hdrs.status ~= 200 or not response or response == "" then
        return nil
    end

    local writeOk = pcall(function()
        local f = assert(io.open(cachePath, "wb"))
        f:write(response)
        f:close()
    end)
    return writeOk and cachePath or nil
end

-- `address` keys that represent a genuinely notable, non-administrative
-- feature (park, natural landmark, protected area) when Nominatim's
-- reverse lookup happens to have one tagged nearby -- checked in priority
-- order. Administrative locality keys (city/town/etc., checked separately
-- below as the fallback) are deliberately excluded here even though they
-- often turn out just as evocative in practice (e.g. a Chilean commune
-- literally named "Torres del Paine") -- that's exactly what the locality
-- fallback already covers.
local NAMED_FEATURE_ADDRESS_KEYS = {
    "natural", "national_park", "protected_area", "leisure", "tourism", "water", "peak", "mountain_range", "attraction",
}
local LOCALITY_ADDRESS_KEYS = {
    "neighbourhood", "hamlet", "suburb", "village", "town", "city", "municipality", "county",
}

local OVERPASS_URL = "https://overpass-api.de/api/interpreter"

local function urlEncode(str)
    return (str:gsub("[^%w%-%.%_%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Nominatim's own reverse-geocode address object doesn't reliably surface
-- protected-area containment at all -- confirmed live 2026-08-07 against
-- a real point inside Yellowstone National Park: at every zoom level
-- tried (10/12/14), with extratags/namedetails requested, it returned
-- only the hyper-local, ambiguous hamlet name "Madison" (a name shared by
-- many unrelated US towns) -- no park info whatsoever, even though
-- "national_park"/"protected_area" were already in NAMED_FEATURE_
-- ADDRESS_KEYS above. Overpass's `is_in()` spatial query answers this
-- correctly -- it checks which boundary polygons actually CONTAIN the
-- point, rather than Nominatim's nearest-named-thing approach -- and, as
-- a useful side effect, naturally can't return hamlet/village-level noise
-- at all (a hamlet is a point, not an area, so is_in() never surfaces
-- one). Narrowly scoped to just this one gap -- Nominatim below still
-- handles ordinary town/country naming, which it already does fine.
local function namedProtectedAreaLabel(lat, lng)
    local query = string.format(
        "[out:json][timeout:15];is_in(%s,%s)->.a;area.a;out tags;",
        tostring(lat), tostring(lng)
    )
    local url = OVERPASS_URL .. "?data=" .. urlEncode(query)
    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url, {
        { field = "User-Agent", value = NOMINATIM_USER_AGENT },
    })
    if not ok or not hdrs or hdrs.status ~= 200 then
        return nil
    end

    local decodeOk, decoded = pcall(JSON.decode, response)
    if not decodeOk or not decoded or not decoded.elements then
        return nil
    end

    for _, element in ipairs(decoded.elements) do
        local tags = element.tags or {}
        if tags.name and (tags.boundary == "protected_area" or tags.boundary == "national_park" or tags.leisure == "nature_reserve") then
            return tags.name
        end
    end
    return nil
end

-- Short "<named feature or locality>, <country>" label for a coordinate,
-- or nil if the request failed or nothing usable came back at all (e.g.
-- open ocean). Never raises -- this is a nice-to-have label, not
-- something that should ever block getting coordinates onto a photo.
local function reverseGeocodeLabel(lat, lng)
    local url = string.format(
        "%s?format=jsonv2&lat=%s&lon=%s&zoom=%d&addressdetails=1",
        NOMINATIM_REVERSE_URL, tostring(lat), tostring(lng), NOMINATIM_ZOOM
    )

    local ok, response, hdrs = LrTasks.pcall(LrHttp.get, url, {
        { field = "User-Agent", value = NOMINATIM_USER_AGENT },
    })
    if not ok or not hdrs or hdrs.status ~= 200 then
        return nil
    end

    local decodeOk, decoded = pcall(JSON.decode, response)
    if not decodeOk or not decoded or not decoded.address then
        return nil
    end

    local address = decoded.address
    -- Checked first, takes priority over Nominatim's own address object
    -- when it finds something -- a notable named park/reserve is a much
    -- more useful anchor than an arbitrary, possibly-ambiguous locality
    -- name (see this function's own doc comment above).
    local place = namedProtectedAreaLabel(lat, lng)
    if not place then
        for _, key in ipairs(NAMED_FEATURE_ADDRESS_KEYS) do
            if address[key] then
                place = address[key]
                break
            end
        end
    end
    if not place then
        for _, key in ipairs(LOCALITY_ADDRESS_KEYS) do
            if address[key] then
                place = address[key]
                break
            end
        end
    end

    if place and address.country then
        return place .. ", " .. address.country
    end
    return place or address.country
end

-- Remembers the last hand-typed coordinates (their approximate-location
-- checkbox state, and a reverse-geocoded place label) across invocations,
-- so a run of photos from the same outing/location doesn't require
-- retyping the same coordinates every time -- offered as its own "Use Most
-- Recent" button, distinct from the fixed "Use Home" one. Deliberately NOT
-- updated when "Use Home" is chosen (that path already has its own
-- dedicated button) or when nothing is submitted.
local function getRecentEntry()
    local prefs = LrPrefs.prefsForPlugin()
    if prefs.recentLat and prefs.recentLng then
        return prefs.recentLat, prefs.recentLng, prefs.recentApproximate, prefs.recentPlaceName
    end
    return nil
end

-- Reverse-geocodes once, here, at the moment new coordinates are actually
-- submitted -- not on every dialog open -- so showing the "Use Most
-- Recent" button never costs a network round trip, only typing in a new
-- location does.
--
-- The place name itself is only needed the NEXT time this dialog opens
-- (for the "Use Most Recent" button's label) -- doing the reverse-geocode
-- SYNCHRONOUSLY here used to block whatever called GpsPrompt.choose (e.g.
-- SpeciesIdentification.lua) from proceeding at all, on a live HTTP round
-- trip to a free, best-effort public API with no latency guarantee.
-- Confirmed live 2026-08-09 as an occasional ~10s stall between clicking
-- "Use These Coordinates" and the CALLER's own next dialog appearing --
-- well before any export/lookup work of its own even started. lat/lng/
-- isApproximate are stored immediately below (cheap, no network); the
-- geocode runs fire-and-forget in its own task so the caller never waits
-- on it. Self-healing race: if the dialog is reopened again before this
-- finishes, "Use Most Recent" shows a stale or missing place name for
-- that one open -- the coordinates themselves are already correct and
-- unaffected.
local function storeRecentEntry(lat, lng, isApproximate)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.recentLat = lat
    prefs.recentLng = lng
    prefs.recentApproximate = isApproximate

    LrTasks.startAsyncTask(function()
        LrPrefs.prefsForPlugin().recentPlaceName = reverseGeocodeLabel(lat, lng)
    end)
end

-- Smart/curly quotes -> straight quotes, so DMS input copied from
-- somewhere that auto-corrects punctuation (Notes, Messages, etc.) still
-- parses. Done as literal substring replacement rather than folding these
-- into a %[...%] character class -- Lua patterns match byte-by-byte, not
-- by Unicode codepoint, so a class containing multi-byte UTF-8 characters
-- can match stray bytes from within them instead of the whole character.
local function normalizeQuotes(str)
    str = str:gsub("’", "'"):gsub("‘", "'")
    str = str:gsub("”", '"'):gsub("“", '"')
    return str
end

local function dmsToDecimal(deg, min, sec, dir)
    local value = deg + min / 60 + sec / 3600
    dir = dir:upper()
    if dir == "S" or dir == "W" then
        value = -value
    end
    return value
end

-- Tries a few formats, in order, and returns the first that parses:
--   1. Decimal "latitude, longitude" (the original format, e.g.
--      "41.303145, -74.239233").
--   2. Decimal "latitude longitude" with just whitespace, no comma.
--   3. DMS with cardinal directions, e.g. the format iOS shares locations
--      in: 49°19'27.35" S 72°53'35.59" W (comma between the two halves is
--      optional; whitespace around the direction letter is optional too,
--      since some sources omit it).
-- Returns nil if nothing matches, isn't numeric, or falls outside valid
-- lat/lng ranges (catches e.g. the two values being swapped).
local function parseCoordinates(str)
    if not str then
        return nil
    end
    str = normalizeQuotes(str)

    local lat, lng

    local latStr, lngStr = str:match("^%s*(-?%d+%.?%d*)%s*,%s*(-?%d+%.?%d*)%s*$")
    if not latStr then
        latStr, lngStr = str:match("^%s*(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s*$")
    end
    if latStr then
        lat, lng = tonumber(latStr), tonumber(lngStr)
    else
        local latDeg, latMin, latSec, latDir, lngDeg, lngMin, lngSec, lngDir =
            str:match('^%s*(%d+)°(%d+)\'([%d%.]+)"%s*([NSns])%s*,?%s*(%d+)°(%d+)\'([%d%.]+)"%s*([EWew])%s*$')
        if latDeg then
            lat = dmsToDecimal(tonumber(latDeg), tonumber(latMin), tonumber(latSec), latDir)
            lng = dmsToDecimal(tonumber(lngDeg), tonumber(lngMin), tonumber(lngSec), lngDir)
        end
    end

    if not lat or not lng then
        return nil
    end
    if lat < -90 or lat > 90 or lng < -180 or lng > 180 then
        return nil
    end
    return lat, lng
end

-- Formats a Cocoa-epoch time delta (seconds) as a short human string,
-- e.g. "2.3h", "40m", "1.5d" -- shown directly in the Nearest Before/
-- After button labels (see below) so an obviously-bad match (weeks
-- away) is self-evidently unreliable rather than silently offered as if
-- it were trustworthy.
local function formatTimeDelta(deltaSeconds)
    local absSeconds = math.abs(deltaSeconds)
    if absSeconds < 3600 then
        return string.format("%dm", math.floor(absSeconds / 60 + 0.5))
    elseif absSeconds < 86400 then
        return string.format("%.1fh", absSeconds / 3600)
    else
        return string.format("%.1fd", absSeconds / 86400)
    end
end

-- Scans the SAME FOLDER as `referencePhoto` (not the whole catalog) for
-- the closest-in-time photo BEFORE and AFTER its own capture time that
-- already has real GPS data, excluding `excludePhotos` (the photo(s)
-- actually missing GPS -- can't match against themselves/each other).
-- Returns beforePhoto, beforeDeltaSeconds (negative), afterPhoto,
-- afterDeltaSeconds (positive) -- any pair can be nil if nothing exists
-- in that direction (including if the folder lookup itself fails for any
-- reason -- e.g. a cloud-sync-created device folder, a confirmed SDK bug
-- for folder:getPhotos() on those; not applicable to the user's own
-- workflow, which doesn't use cloud folders).
--
-- Deliberately folder-scoped, not catalog-wide -- per the user
-- (2026-08-07): a same-day DSLR+phone shoot landing in two different
-- folders happens, but rarely enough not to design around, and a
-- catalog-wide scan (no time/GPS-filtered query exists to narrow it
-- down) was confirmed live to be too slow to run synchronously before
-- the dialog is shown, which is what "loaded on first display" (also the
-- user's own request) actually requires -- a same-folder scan is small
-- enough to just run inline, no async task/loading state needed.
local function findNearestGpsPhotos(catalog, referencePhoto, excludePhotos)
    local referenceTime = referencePhoto:getRawMetadata("dateTimeOriginal")
    if not referenceTime then
        return nil, nil, nil, nil
    end

    local path = referencePhoto:getRawMetadata("path")
    local folder = path and catalog:getFolderByPath(LrPathUtils.parent(path))
    local folderPhotos = folder and folder:getPhotos()
    if not folderPhotos then
        return nil, nil, nil, nil
    end

    local excludeSet = {}
    for _, p in ipairs(excludePhotos) do
        excludeSet[p] = true
    end

    local beforePhoto, beforeDelta = nil, nil
    local afterPhoto, afterDelta = nil, nil

    for _, photo in ipairs(folderPhotos) do
        if not excludeSet[photo] then
            local gps = photo:getRawMetadata("gps")
            if gps and gps.latitude and gps.longitude then
                local t = photo:getRawMetadata("dateTimeOriginal")
                if t then
                    local delta = t - referenceTime
                    if delta < 0 and (not beforeDelta or delta > beforeDelta) then
                        beforePhoto, beforeDelta = photo, delta
                    elseif delta > 0 and (not afterDelta or delta < afterDelta) then
                        afterPhoto, afterDelta = photo, delta
                    end
                end
            end
        end
    end

    return beforePhoto, beforeDelta, afterPhoto, afterDelta
end

-- Prompts for coordinates to use when photo(s) have no GPS data, offering:
-- the fixed home location, the last hand-typed coordinates (if any --
-- "Use Most Recent", handy for a run of photos from the same outing),
-- the closest-in-time GPS-tagged photo in the SAME FOLDER before/after
-- `excludePhotos[1]`'s own capture time (handy for a non-GPS DSLR shot
-- alongside a phone the same day -- see findNearestGpsPhotos above), or
-- typing coordinates in as "latitude, longitude" (or DMS) -- plus Cancel.
-- Reprompts (with an error) on unparseable input rather than treating a
-- typo as a cancel.
--
-- `excludePhotos` (optional, a list) -- if given, its first entry is used
-- as the reference photo for the Nearest Before/After buttons (only
-- built at all if a candidate actually exists in that direction),
-- excluding these specific photos from matching against themselves/each
-- other. Omit (or pass an empty list) to skip offering them entirely --
-- e.g. a caller with no natural "reference photo" to search relative to.
--
-- Returns lat, lng, isApproximate, or nil, nil, nil if the user canceled.
-- isApproximate reflects the "This is an approximate location" checkbox
-- (only shown/relevant for hand-typed coordinates -- per the user, usually
-- a memory/Google Maps guess, so it defaults checked, but sometimes it's an
-- exact reading and they want to uncheck it), is always false for the
-- "Use Home" fallback (accurate to within ~100 yards -- close enough not to
-- flag, and always true for Nearest Before/After (per the user: "consider
-- these as approx" -- a nearby-in-time photo is a reasonable guess, not a
-- confirmed reading of the actual photo's own location).
function GpsPrompt.choose(promptText, excludePhotos)
    local errorText = nil
    local recentLat, recentLng, recentApproximate, recentPlaceName = getRecentEntry()
    excludePhotos = excludePhotos or {}

    -- Prompted here, BEFORE the coordinate dialog itself ever opens (not
    -- lazily from inside it, e.g. on first valid coordinate typed) --
    -- deliberately avoids ever needing a second modal dialog while the
    -- coordinate dialog is already open, which this project's own
    -- LrView gotcha notes flag as unverified/risky. Skippable (Skip
    -- button) -- a missing key just means no map preview this run, not a
    -- blocked GPS entry flow; nothing is stored on skip, so it's asked
    -- again next time rather than nagging with a "don't ask again" flag.
    local mapApiKey = getStoredGeoapifyKey()
    if not mapApiKey then
        mapApiKey = promptForGeoapifyKey()
        if mapApiKey then
            storeGeoapifyKey(mapApiKey)
        end
    end

    while true do
        local resultLat, resultLng, resultApproximate, canceled, parseFailed

        LrFunctionContext.callWithContext("GpsPrompt", function(context)
            local props = LrBinding.makePropertyTable(context)
            props.coordinatesText = ""
            props.isApproximate = true

            local f = LrView.osFactory()

            -- Map (+ its zoom controls) on the left, everything else on
            -- the right -- per the user's own request (2026-08-07).
            -- bind_to_object lives on the outer row below (the common
            -- ancestor of both columns), not on either column
            -- individually -- required to be somewhere in the ancestor
            -- chain of every LrView.bind() use, not just anywhere in the
            -- dialog (previously-documented gotcha).
            local leftArgs = { spacing = f:control_spacing() }
            local rightArgs = { spacing = f:control_spacing() }

            if errorText then
                table.insert(rightArgs, f:static_text { title = errorText })
            end
            table.insert(rightArgs, f:static_text { title = promptText })
            table.insert(rightArgs, f:edit_field {
                value = LrView.bind("coordinatesText"),
                placeholder_string = "e.g. 41.303145, -74.239233 or 41°18'11\" N 74°14'21\" W",
                width_in_chars = 30,
                -- Without this, the bound value only commits on focus
                -- loss (Tab, or clicking another control), not per
                -- keystroke -- a previously-documented LrView gotcha,
                -- confirmed live again 2026-08-07: the map preview below
                -- wasn't updating until the field lost focus.
                immediate = true,
            })
            table.insert(rightArgs, f:checkbox {
                title = "This is an approximate location",
                value = LrView.bind("isApproximate"),
            })

            -- Place-name label ("town, state/country") for the currently
            -- typed coordinates -- reuses reverseGeocodeLabel (already
            -- built for the "Use Most Recent" button's own label below),
            -- refreshed on the same debounce cycle as the map. Fixed
            -- width_in_chars up front -- a static_text control doesn't
            -- grow to fit a .title set after construction (previously-
            -- documented gotcha), and this starts out empty.
            local placeLabel = f:static_text { title = "", visible = false, width_in_chars = 50 }
            table.insert(rightArgs, placeLabel)

            -- Guards against a slow request finishing after the user has
            -- typed/clicked something newer -- same thumbnailRequestToken
            -- pattern already proven in CandidatePicker.lua for exactly
            -- this "don't let a stale async result overwrite a newer
            -- one" problem. Shared by both the map image and the place
            -- label below, and by both text-driven and zoom-button-
            -- driven refreshes.
            local mapRequestGeneration = 0
            local lastValidLat, lastValidLng = nil, nil

            -- Home/Recent just fill in coordinatesText exactly like typing
            -- would (see the button definitions below), which drives this
            -- same refresh path -- but for those two, the place label is
            -- often already known: Home's gets fetched once when the
            -- dialog opens (below), and Recent's is already sitting in
            -- prefs (recentPlaceName, from a previous run's
            -- storeRecentEntry). Without this cache, clicking either
            -- button re-ran a live Nominatim lookup for an answer already
            -- on hand -- confirmed as real, avoidable repeat traffic
            -- 2026-08-09 (per the user: "I just click one of the buttons
            -- ... seems like we could save a lookup"). Keyed by the exact
            -- same "%.6f, %.6f" string the buttons write into the field,
            -- so a hit is a plain string lookup, not a tolerance
            -- comparison -- also means a manually-typed coordinate that
            -- happens to exactly match a known one benefits too, not just
            -- button clicks specifically.
            local knownPlaceLabels = {}
            if recentLat and recentLng and recentPlaceName then
                knownPlaceLabels[string.format("%.6f, %.6f", recentLat, recentLng)] = recentPlaceName
            end

            local function refreshPlaceLabel(lat, lng, myGeneration)
                local key = string.format("%.6f, %.6f", lat, lng)
                local cached = knownPlaceLabels[key]
                if cached ~= nil then
                    placeLabel.title = cached
                    placeLabel.visible = true
                    return
                end
                LrTasks.startAsyncTask(function()
                    local label = reverseGeocodeLabel(lat, lng)
                    if myGeneration ~= mapRequestGeneration then
                        return -- superseded by a newer edit
                    end
                    if label then
                        placeLabel.title = label
                        placeLabel.visible = true
                        knownPlaceLabels[key] = label
                    else
                        placeLabel.visible = false
                    end
                end)
            end

            -- The map image + zoom controls only exist at all if a
            -- Geoapify key is on hand -- checked once, before this dialog
            -- ever opened (see the top of GpsPrompt.choose); no key means
            -- no map UI at all, rather than dead/disabled buttons for a
            -- feature that can't work this run. The place-name label
            -- above is unaffected -- it's Nominatim-based, no key needed,
            -- and stands on its own even without a map image.
            if mapApiKey then
                local mapWidget = f:picture { width = MAP_WIDTH, height = MAP_HEIGHT, visible = false }
                local currentZoom = DEFAULT_MAP_ZOOM

                local function refreshMap(myGeneration)
                    local lat, lng, zoom = lastValidLat, lastValidLng, currentZoom
                    LrTasks.startAsyncTask(function()
                        local path = downloadStaticMap(lat, lng, zoom, mapApiKey)
                        -- No cleanup/removal on staleness here, unlike
                        -- this plugin's other temp-file downloads --
                        -- downloadStaticMap's result is a CACHE entry
                        -- (see its own doc comment), meant to persist and
                        -- be reused, not a one-off temp file this dialog
                        -- owns and must delete.
                        if myGeneration ~= mapRequestGeneration then
                            return
                        end
                        if path then
                            mapWidget.value = path
                            mapWidget.visible = true
                        end
                    end)
                end

                -- Loads Home's own location by default, before any typing
                -- or button click -- per the user's own request
                -- (2026-08-07), so there's always something oriented on
                -- screen immediately rather than a blank box. Also seeds
                -- lastValidLat/lastValidLng so the zoom buttons work
                -- right away against this default view, not just after
                -- an explicit choice.
                lastValidLat, lastValidLng = HomeLocation.lat, HomeLocation.lng
                mapRequestGeneration = mapRequestGeneration + 1
                refreshMap(mapRequestGeneration)
                refreshPlaceLabel(HomeLocation.lat, HomeLocation.lng, mapRequestGeneration)

                -- Zoom buttons act immediately (no debounce -- a click is
                -- already one deliberate action, not a rapid keystroke
                -- stream) on whatever coordinates were last successfully
                -- parsed -- a no-op if nothing's been typed yet.
                local zoomOutButton = f:push_button {
                    -- Plain ASCII hyphen, not a fancier Unicode minus
                    -- sign -- \u{2212} is a Lua 5.3+ string escape;
                    -- confirmed live 2026-08-07 that Lightroom's actual
                    -- Lua runtime (5.1-based) doesn't recognize it and
                    -- renders the literal escape text ("u{2212}") on the
                    -- button instead of a character at all. My own local
                    -- `lua`/`luac` (a newer version) silently accepted it
                    -- at "syntax-check" time, which is why this wasn't
                    -- caught before live testing.
                    title = "-",
                    action = function()
                        if not lastValidLat then
                            return
                        end
                        currentZoom = math.max(MAP_ZOOM_MIN, currentZoom - MAP_ZOOM_STEP)
                        mapRequestGeneration = mapRequestGeneration + 1
                        refreshMap(mapRequestGeneration)
                    end,
                }
                local zoomInButton = f:push_button {
                    title = "+",
                    action = function()
                        if not lastValidLat then
                            return
                        end
                        currentZoom = math.min(MAP_ZOOM_MAX, currentZoom + MAP_ZOOM_STEP)
                        mapRequestGeneration = mapRequestGeneration + 1
                        refreshMap(mapRequestGeneration)
                    end,
                }
                table.insert(leftArgs, f:row { f:static_text { title = "Zoom:" }, zoomOutButton, zoomInButton })
                table.insert(leftArgs, mapWidget)

                -- Debounced: waits half a second of no further typing
                -- before actually fetching, so a run of keystrokes on an
                -- already-complete-looking number doesn't fire a map
                -- request (plus a geocode lookup) per character.
                props:addObserver("coordinatesText", function(_, _, newValue)
                    local lat, lng = parseCoordinates(newValue)
                    if not lat then
                        return
                    end
                    lastValidLat, lastValidLng = lat, lng
                    mapRequestGeneration = mapRequestGeneration + 1
                    local myGeneration = mapRequestGeneration
                    LrTasks.startAsyncTask(function()
                        LrTasks.sleep(0.5)
                        if myGeneration == mapRequestGeneration then
                            refreshMap(myGeneration)
                            refreshPlaceLabel(lat, lng, myGeneration)
                        end
                    end)
                end)
            else
                -- No map key -- the place label still works on its own
                -- (Nominatim needs no key), just debounced the same way,
                -- without a map request alongside it.
                props:addObserver("coordinatesText", function(_, _, newValue)
                    local lat, lng = parseCoordinates(newValue)
                    if not lat then
                        return
                    end
                    mapRequestGeneration = mapRequestGeneration + 1
                    local myGeneration = mapRequestGeneration
                    LrTasks.startAsyncTask(function()
                        LrTasks.sleep(0.5)
                        if myGeneration == mapRequestGeneration then
                            refreshPlaceLabel(lat, lng, myGeneration)
                        end
                    end)
                end)
            end

            -- Home/Recent no longer close the dialog immediately -- they
            -- just fill in coordinatesText (and isApproximate) the same
            -- as typing would, which drives the SAME observer above to
            -- load the map/place label for that location. "Use These
            -- Coordinates" is now the only way to actually submit,
            -- reading whatever's currently in the field -- so you see the
            -- map before committing, regardless of how the coordinates
            -- got there. Per the user's own request (2026-08-07): "the
            -- choose location buttons (Home, Recent) [should] load the
            -- map, 'Use These Coordinates' will save whatever the map
            -- shows."
            -- Numeric coordinates dropped from these labels (2026-08-07,
            -- per the user -- "I don't really need the coords on the
            -- buttons") -- the map itself is now the confirmation, not
            -- the raw numbers.
            local homeButton = f:push_button {
                title = "Use Home",
                action = function()
                    props.isApproximate = false
                    props.coordinatesText = string.format("%.6f, %.6f", HomeLocation.lat, HomeLocation.lng)
                end,
            }
            table.insert(rightArgs, homeButton)

            if recentLat and recentLng then
                local label = "Use Most Recent"
                if recentPlaceName then
                    label = label .. " -- " .. recentPlaceName
                end
                if recentApproximate then
                    label = label .. " [approx]"
                end
                local recentButton = f:push_button {
                    title = label,
                    action = function()
                        props.isApproximate = recentApproximate
                        props.coordinatesText = string.format("%.6f, %.6f", recentLat, recentLng)
                    end,
                }
                table.insert(rightArgs, recentButton)
            end

            -- "Nearest Before"/"Nearest After" -- the closest-in-time
            -- GPS-tagged photo in the SAME FOLDER (findNearestGpsPhotos
            -- above), for a non-GPS DSLR shot alongside a phone the same
            -- day (per the user's own workflow, 2026-08-07). Computed
            -- SYNCHRONOUSLY, right here, before the dialog is even
            -- presented -- not via a background task with a "Searching..."
            -- placeholder (an earlier version of this did that, backed by
            -- a catalog-wide scan) -- per the user's own follow-up
            -- request: "loaded on first display... the full scan is
            -- pretty quick, but not quick enough for that." A same-folder
            -- scan is small enough to just run inline. Buttons are only
            -- built at all when there's an actual candidate -- no hidden/
            -- disabled placeholder for a direction with nothing found.
            local referencePhoto = excludePhotos[1]
            if referencePhoto then
                local catalog = LrApplication.activeCatalog()
                local beforePhoto, beforeDelta, afterPhoto, afterDelta =
                    findNearestGpsPhotos(catalog, referencePhoto, excludePhotos)

                if beforePhoto then
                    local beforeGps = beforePhoto:getRawMetadata("gps")
                    table.insert(rightArgs, f:push_button {
                        title = string.format("Nearest Before -- %s earlier", formatTimeDelta(beforeDelta)),
                        action = function()
                            props.isApproximate = true
                            props.coordinatesText = string.format("%.6f, %.6f", beforeGps.latitude, beforeGps.longitude)
                        end,
                    })
                end

                if afterPhoto then
                    local afterGps = afterPhoto:getRawMetadata("gps")
                    table.insert(rightArgs, f:push_button {
                        title = string.format("Nearest After -- %s later", formatTimeDelta(afterDelta)),
                        action = function()
                            props.isApproximate = true
                            props.coordinatesText = string.format("%.6f, %.6f", afterGps.latitude, afterGps.longitude)
                        end,
                    })
                end
            end

            local dialogArgs = {
                title = "No GPS Data",
                contents = f:row {
                    bind_to_object = props,
                    f:column(leftArgs),
                    f:column(rightArgs),
                },
                actionVerb = "Use These Coordinates",
                cancelVerb = "Cancel",
            }

            local result = LrDialogs.presentModalDialog(dialogArgs)

            -- Bump the generation so any map/geocode request still in
            -- flight (sleeping through its debounce, or mid-download)
            -- recognizes itself as stale once it finishes and discards
            -- its own result instead of writing into a widget tree
            -- that's about to be torn down. No file cleanup needed here
            -- (unlike this plugin's other temp-downloads) -- map images
            -- are cache entries meant to persist, not this dialog's own
            -- temp files.
            mapRequestGeneration = mapRequestGeneration + 1

            if result == "ok" then
                local lat, lng = parseCoordinates(props.coordinatesText)
                if lat then
                    resultLat, resultLng, resultApproximate = lat, lng, props.isApproximate
                    storeRecentEntry(lat, lng, props.isApproximate)
                else
                    parseFailed = true
                end
            else
                canceled = true
            end
        end)

        if canceled then
            return nil, nil, nil
        end
        if resultLat then
            return resultLat, resultLng, resultApproximate
        end
        if parseFailed then
            errorText = "Couldn't read that as coordinates (decimal \"latitude, longitude\" or DMS like 41°18'11\" N 74°14'21\" W) -- try again, or Cancel."
        end
    end
end

-- Ensures every photo in `photos` has GPS data before the caller proceeds:
-- finds every one missing it, prompts once for coordinates covering the
-- whole batch (home location / typed in / cancel) if any are missing, and
-- writes them to just those photos -- ones that already had valid GPS are
-- left untouched. `reasonText` is a short clause describing why GPS
-- matters here (e.g. "iNaturalist uses for a real accuracy boost"),
-- slotted into "...which {reasonText}.".
--
-- Returns true if OK to proceed (nothing was missing, or coordinates were
-- obtained and written), or false if the user canceled -- meaning the
-- whole calling command should abort.
function GpsPrompt.ensureGpsOnAllPhotos(photos, reasonText)
    local missing = {}
    for _, photo in ipairs(photos) do
        local gps = photo:getRawMetadata("gps")
        if not (gps and gps.latitude and gps.longitude) then
            table.insert(missing, photo)
        end
    end

    if #missing == 0 then
        return true
    end

    local promptText
    if #missing == 1 then
        promptText = string.format("This photo has no GPS location data, which %s.", reasonText)
    else
        promptText = string.format(
            "%d of the %d selected photos have no GPS location data, which %s.",
            #missing, #photos, reasonText
        )
    end

    local lat, lng, isApproximate = GpsPrompt.choose(promptText, missing)
    if not lat then
        return false
    end

    local catalog = LrApplication.activeCatalog()
    catalog:withWriteAccessDo("Set GPS location", function()
        for _, photo in ipairs(missing) do
            photo:setRawMetadata("gps", { latitude = lat, longitude = lng })
            if isApproximate then
                photo:setPropertyForPlugin(_PLUGIN, "approximateLocation", "yes")
            end
            PendingMetadataSave.markIfNeeded(catalog, photo)
        end
    end)

    return true
end

return GpsPrompt
