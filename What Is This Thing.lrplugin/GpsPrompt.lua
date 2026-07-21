local LrApplication = import 'LrApplication'
local LrPrefs = import 'LrPrefs'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

local GpsPrompt = {}

local function getHomeLocation()
    local prefs = LrPrefs.prefsForPlugin()
    if prefs.homeLat and prefs.homeLng then
        return prefs.homeLat, prefs.homeLng
    end
    return nil
end

local function storeHomeLocation(lat, lng)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.homeLat = lat
    prefs.homeLng = lng
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

-- Prompts for coordinates to use when photo(s) have no GPS data, offering
-- up to three choices: use a saved home location (only shown if one is
-- already stored), type coordinates in as "latitude, longitude" (with an
-- option to save them as the new home location), or cancel entirely.
-- Reprompts (with an error) on unparseable input rather than treating a
-- typo as a cancel.
--
-- Returns lat, lng, or nil, nil if the user canceled.
function GpsPrompt.choose(promptText)
    local homeLat, homeLng = getHomeLocation()
    local errorText = nil

    while true do
        local resultLat, resultLng, canceled, parseFailed

        LrFunctionContext.callWithContext("GpsPrompt", function(context)
            local props = LrBinding.makePropertyTable(context)
            props.coordinatesText = ""
            props.saveAsHome = true

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
                title = "Save as home location",
                value = LrView.bind("saveAsHome"),
            })

            local dialogArgs = {
                title = "No GPS Data",
                contents = f:column(args),
                actionVerb = "Use These Coordinates",
                cancelVerb = "Cancel",
            }
            if homeLat and homeLng then
                dialogArgs.otherVerb = string.format("Use Home (%.4f, %.4f)", homeLat, homeLng)
            end

            local result = LrDialogs.presentModalDialog(dialogArgs)

            if result == "other" then
                resultLat, resultLng = homeLat, homeLng
            elseif result == "ok" then
                local lat, lng = parseCoordinates(props.coordinatesText)
                if lat then
                    resultLat, resultLng = lat, lng
                    if props.saveAsHome then
                        storeHomeLocation(lat, lng)
                    end
                else
                    parseFailed = true
                end
            else
                canceled = true
            end
        end)

        if canceled then
            return nil, nil
        end
        if resultLat then
            return resultLat, resultLng
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

    local lat, lng = GpsPrompt.choose(promptText)
    if not lat then
        return false
    end

    local catalog = LrApplication.activeCatalog()
    catalog:withWriteAccessDo("Set GPS location", function()
        for _, photo in ipairs(missing) do
            photo:setRawMetadata("gps", { latitude = lat, longitude = lng })
        end
    end)

    return true
end

return GpsPrompt
