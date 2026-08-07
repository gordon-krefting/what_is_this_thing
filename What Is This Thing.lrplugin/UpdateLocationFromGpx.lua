local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'

local JSON = dofile(LrPathUtils.child(_PLUGIN.path, "JSON.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))

-- geotag_from_gpx.py only ever COMPUTES coordinates now (reading each
-- real photo's own DateTimeOriginal tag, same as before, but matching
-- against a disposable proxy file rather than writing into the real
-- file at all -- see that script's own doc comment) -- so this file
-- applies the result itself, through Lightroom's own catalog
-- (photo:setRawMetadata), the same single write path every other
-- command in this plugin already uses. That eliminates a real dual-
-- writer race that existed when exiftool wrote straight to the file:
-- a photo with pending, not-yet-flushed catalog metadata could have
-- that silently discarded by a later Save Metadata to Files, since the
-- catalog never learned about exiftool's own direct write. See
-- DEVELOPMENT_NOTES.md.
local SCRIPT_PATH = LrPathUtils.child(_PLUGIN.path, "geotag_from_gpx.py")

local function shellQuote(path)
    return '"' .. path .. '"'
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Update Location from GPX", "No photos to update.", "info")
        return
    end

    LrFunctionContext.callWithContext("UpdateLocationFromGpx", function(context)
        local progressScope = LrDialogs.showModalProgressDialog {
            title = "Update Location from GPX",
            caption = "Computing matches from GPX track...",
            cannotCancel = true,
            functionContext = context,
        }

        -- photoForPath assumes distinct paths across the selection, true
        -- for any real Lightroom selection (two catalog entries can't
        -- share one file path).
        local paths = {}
        local photoForPath = {}
        for _, photo in ipairs(photos) do
            local path = photo:getRawMetadata("path")
            table.insert(paths, path)
            photoForPath[path] = photo
        end

        local outputFile = LrPathUtils.child(
            LrPathUtils.getStandardFilePath("temp"),
            "WhatIsThisThing-geotag-" .. tostring(math.random(1000000000)) .. ".log"
        )

        -- Use the system-provided python3 explicitly, not a bare "python3"
        -- lookup -- GUI-launched apps like Lightroom don't inherit an
        -- interactive shell's PATH, so a user-shell-managed interpreter
        -- (pyenv, Homebrew, etc.) would fail to resolve here the same way
        -- a bare "exiftool" did. /usr/bin/python3 ships with macOS itself,
        -- independent of shell configuration, and the script only uses
        -- standard library modules, so any Python 3 works.
        local cmdParts = { "/usr/bin/python3", shellQuote(SCRIPT_PATH) }
        for _, path in ipairs(paths) do
            table.insert(cmdParts, shellQuote(path))
        end
        table.insert(cmdParts, "> " .. shellQuote(outputFile) .. " 2>&1")

        LrTasks.execute(table.concat(cmdParts, " "))

        local output = ""
        if LrFileUtils.exists(outputFile) then
            output = LrFileUtils.readFile(outputFile) or ""
            LrFileUtils.delete(outputFile)
        end

        progressScope:done()

        local ok, decoded = pcall(JSON.decode, output)
        if not ok or not decoded then
            LrDialogs.message("Update Location from GPX", "Couldn't parse the script's output:\n\n" .. output, "critical")
            return
        end
        if decoded.error then
            LrDialogs.message("Update Location from GPX", decoded.error, "critical")
            return
        end

        local matchedCount, unmatchedByReason = 0, {}
        catalog:withWriteAccessDo("Update location from GPX", function()
            for _, result in ipairs(decoded.results or {}) do
                local photo = photoForPath[result.path]
                if photo then
                    if result.latitude and result.longitude then
                        photo:setRawMetadata("gps", { latitude = result.latitude, longitude = result.longitude })
                        PendingMetadataSave.markIfNeeded(catalog, photo)
                        matchedCount = matchedCount + 1
                    else
                        local reason = result.reason or "no match"
                        unmatchedByReason[reason] = (unmatchedByReason[reason] or 0) + 1
                    end
                end
            end
        end)

        local summary = string.format("Updated: %d photo(s)", matchedCount)
        for reason, count in pairs(unmatchedByReason) do
            summary = summary .. string.format("\n%d photo(s): %s", count, reason)
        end

        LrDialogs.message("Update Location from GPX", summary, "info")
    end)
end)
