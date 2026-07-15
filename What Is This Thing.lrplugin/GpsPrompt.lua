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

-- Parses "latitude, longitude" (comma-separated, optional surrounding
-- whitespace) into two numbers. Returns nil if the string doesn't match,
-- isn't numeric, or falls outside valid lat/lng ranges (catches e.g. the
-- two values being swapped).
local function parseCoordinates(str)
    if not str then
        return nil
    end
    local latStr, lngStr = str:match("^%s*(-?%d+%.?%d*)%s*,%s*(-?%d+%.?%d*)%s*$")
    if not latStr then
        return nil
    end
    local lat = tonumber(latStr)
    local lng = tonumber(lngStr)
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
                placeholder_string = "e.g. 41.303145, -74.239233",
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
            errorText = "Couldn't read that as \"latitude, longitude\" -- try again, or Cancel."
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
