local LrApplication = import 'LrApplication'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrPrefs = import 'LrPrefs'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'

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

-- Short "<named feature or locality>, <country>" label for a coordinate,
-- or nil if the request failed or Nominatim had nothing usable at all
-- (e.g. open ocean). Never raises -- this is a nice-to-have label, not
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
    local place = nil
    for _, key in ipairs(NAMED_FEATURE_ADDRESS_KEYS) do
        if address[key] then
            place = address[key]
            break
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
local function storeRecentEntry(lat, lng, isApproximate)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.recentLat = lat
    prefs.recentLng = lng
    prefs.recentApproximate = isApproximate
    prefs.recentPlaceName = reverseGeocodeLabel(lat, lng)
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

-- Prompts for coordinates to use when photo(s) have no GPS data, offering:
-- the fixed home location, the last hand-typed coordinates (if any --
-- "Use Most Recent", handy for a run of photos from the same outing), or
-- typing coordinates in as "latitude, longitude" (or DMS) -- plus Cancel.
-- Reprompts (with an error) on unparseable input rather than treating a
-- typo as a cancel.
--
-- Returns lat, lng, isApproximate, or nil, nil, nil if the user canceled.
-- isApproximate reflects the "This is an approximate location" checkbox
-- (only shown/relevant for hand-typed coordinates -- per the user, usually
-- a memory/Google Maps guess, so it defaults checked, but sometimes it's an
-- exact reading and they want to uncheck it) and is always false for the
-- "Use Home" fallback (accurate to within ~100 yards -- close enough not to
-- flag, and not a per-instance judgment call the way typed coordinates are).
function GpsPrompt.choose(promptText)
    local errorText = nil
    local recentLat, recentLng, recentApproximate, recentPlaceName = getRecentEntry()

    while true do
        local resultLat, resultLng, resultApproximate, canceled, parseFailed

        LrFunctionContext.callWithContext("GpsPrompt", function(context)
            local props = LrBinding.makePropertyTable(context)
            props.coordinatesText = ""
            props.isApproximate = true

            local f = LrView.osFactory()

            local args = {
                bind_to_object = props,
                spacing = f:control_spacing(),
            }
            if errorText then
                table.insert(args, f:static_text { title = errorText })
            end
            table.insert(args, f:static_text { title = promptText })
            table.insert(args, f:edit_field {
                value = LrView.bind("coordinatesText"),
                placeholder_string = "e.g. 41.303145, -74.239233 or 41°18'11\" N 74°14'21\" W",
                width_in_chars = 30,
            })
            table.insert(args, f:checkbox {
                title = "This is an approximate location",
                value = LrView.bind("isApproximate"),
            })

            if recentLat and recentLng then
                local recentButton
                local label = string.format("Use Most Recent (%.4f, %.4f)", recentLat, recentLng)
                if recentPlaceName then
                    label = label .. " -- " .. recentPlaceName
                end
                if recentApproximate then
                    label = label .. " [approx]"
                end
                recentButton = f:push_button {
                    title = label,
                    action = function()
                        LrDialogs.stopModalWithResult(recentButton, "recent")
                    end,
                }
                table.insert(args, recentButton)
            end

            local dialogArgs = {
                title = "No GPS Data",
                contents = f:column(args),
                actionVerb = "Use These Coordinates",
                cancelVerb = "Cancel",
                otherVerb = string.format("Use Home (%.4f, %.4f)", HomeLocation.lat, HomeLocation.lng),
            }

            local result = LrDialogs.presentModalDialog(dialogArgs)

            if result == "other" then
                resultLat, resultLng, resultApproximate = HomeLocation.lat, HomeLocation.lng, false
            elseif result == "recent" then
                resultLat, resultLng, resultApproximate = recentLat, recentLng, recentApproximate
            elseif result == "ok" then
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

    local lat, lng, isApproximate = GpsPrompt.choose(promptText)
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
