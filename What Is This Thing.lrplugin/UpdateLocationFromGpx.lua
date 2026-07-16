local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'

-- All the actual logic (finding the GPX file, running exiftool, parsing
-- its output into a summary) lives in geotag_from_gpx.py, specifically so
-- it can be tested directly from a terminal without needing to reload the
-- plugin or click through Lightroom's UI. This file is just the glue: get
-- the target photos' paths (only Lightroom's catalog knows that), run the
-- script, show whatever it printed.
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
            caption = "Running exiftool...",
            cannotCancel = true,
            functionContext = context,
        }

        local paths = {}
        for _, photo in ipairs(photos) do
            table.insert(paths, photo:getRawMetadata("path"))
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

        -- exiftool writes straight to the file, and there's no reliable way
        -- for a plugin to refresh Lightroom's own metadata cache for it, so
        -- the user has to trigger that manually -- but only worth mentioning
        -- if exiftool actually changed anything.
        local updatedCount = tonumber(output:match("Updated:%s*(%d+)"))
        if updatedCount and updatedCount > 0 then
            output = output .. "\nTo see the new GPS data in Lightroom, select the photos and choose Metadata > Read Metadata from Files."
        end

        LrDialogs.message("Update Location from GPX", output, "info")
    end)
end)
