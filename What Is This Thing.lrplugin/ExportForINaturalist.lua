local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrExportSession = import 'LrExportSession'
local LrPrefs = import 'LrPrefs'
local LrFileUtils = import 'LrFileUtils'
local LrView = import 'LrView'

local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))

-- Prompts for (or reuses a saved) destination folder, with an easy way to
-- switch to a different one. Returns the folder path, or nil if the user
-- canceled.
local function chooseDestinationFolder()
    local prefs = LrPrefs.prefsForPlugin()
    local saved = prefs.iNatExportFolder

    if saved and LrFileUtils.exists(saved) then
        local f = LrView.osFactory()
        local result = LrDialogs.presentModalDialog {
            title = "Export for iNaturalist",
            contents = f:column {
                spacing = f:control_spacing(),
                f:static_text { title = "Export to:" },
                f:static_text { title = saved },
            },
            actionVerb = "Export Here",
            otherVerb = "Choose Different Folder",
            cancelVerb = "Cancel",
        }
        if result == "ok" then
            return saved
        elseif result == "cancel" then
            return nil
        end
        -- "other": fall through to the folder picker below
    end

    local chosen = LrDialogs.runOpenPanel {
        title = "Choose Export Folder",
        canChooseFiles = false,
        canChooseDirectories = true,
        canCreateDirectories = true,
        allowsMultipleSelection = false,
    }
    if not chosen or #chosen == 0 then
        return nil
    end

    local folder = chosen[1]
    prefs.iNatExportFolder = folder
    return folder
end

-- Temporarily blanks Caption and removes every Keyword entirely, exports
-- `photo` to `destFolder`, then restores the photo's original Caption/
-- Keywords -- regardless of whether the export succeeded. Title is left
-- untouched: applyIdentification() already permanently set it to the bare
-- scientific name in the catalog, so it needs no export-time handling.
--
-- Keywords are removed rather than simplified to one, deliberately: iNat's
-- own tag-based species guess doesn't just get confused by an ancestor
-- chain, it also copies whatever keyword you send straight into the
-- observation's persistent "Tags" list. If a taxon ID later gets corrected
-- by someone more expert, that stale tag never gets corrected along with
-- it. Title alone still feeds the initial species guess without leaving
-- that residue. This is the only reliable way to control exactly what
-- ends up in the exported file's metadata -- Lightroom's export settings
-- have no "exclude just this field" option, and a plain export would also
-- flatten the full "Species ID > ... > name" keyword chain into the file.
local function exportWithSimplifiedMetadata(photo, destFolder)
    local catalog = LrApplication.activeCatalog()

    local originalCaption = photo:getFormattedMetadata("caption")
    local originalKeywords = photo:getRawMetadata("keywords") or {}

    catalog:withWriteAccessDo("Simplify metadata for export", function()
        for _, kw in ipairs(originalKeywords) do
            photo:removeKeyword(kw)
        end
        photo:setRawMetadata("caption", "")
    end)

    local exportOk, exportErr = LrTasks.pcall(function()
        local exportSession = LrExportSession {
            photosToExport = { photo },
            exportSettings = {
                LR_format = "JPEG",
                LR_jpeg_quality = 0.92,
                LR_export_destinationType = "specificFolder",
                LR_export_destinationPathPrefix = destFolder,
                LR_export_useSubfolder = false,
                LR_collisionHandling = "uniqueName",
                LR_reimportExportedPhoto = false,
                -- Explicit rather than relying on the (undocumented, and
                -- reportedly inconsistent) default -- this export exists
                -- specifically so iNat's uploader can read GPS from the
                -- file, so location metadata must survive.
                LR_embeddedMetadataOption = "all",
                LR_removeLocationMetadata = false,
            },
        }
        for _, rendition in exportSession:renditions() do
            local success, message = rendition:waitForRender()
            if not success then
                error("Export failed: " .. tostring(message))
            end
        end
    end)

    catalog:withWriteAccessDo("Restore metadata after export", function()
        for _, kw in ipairs(originalKeywords) do
            photo:addKeyword(kw)
        end
        photo:setRawMetadata("caption", originalCaption or "")
    end)

    if not exportOk then
        error(exportErr)
    end
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Export for iNaturalist", "No photos selected.", "info")
        return
    end

    -- Every photo must already be identified (via "What is This Plant?" /
    -- "What is This Animal?") -- abort the whole export rather than
    -- silently sending some photos with no useful tag at all.
    local unidentified = {}
    for _, photo in ipairs(photos) do
        if not KeywordWriter.findSpeciesName(photo) then
            table.insert(unidentified, photo:getFormattedMetadata("fileName"))
        end
    end

    if #unidentified > 0 then
        LrDialogs.message(
            "Export for iNaturalist",
            "These photos haven't been identified yet -- run \"What is This Plant?\" or "
                .. "\"What is This Animal?\" on them first, then try exporting again:\n\n"
                .. table.concat(unidentified, "\n"),
            "warning"
        )
        return
    end

    local destFolder = chooseDestinationFolder()
    if not destFolder then
        return
    end

    LrFunctionContext.callWithContext("ExportForINaturalist", function(context)
        local progressScope = LrDialogs.showModalProgressDialog {
            title = "Export for iNaturalist",
            caption = "Exporting...",
            cannotCancel = true,
            functionContext = context,
        }

        for i, photo in ipairs(photos) do
            progressScope:setCaption(string.format("Exporting %d/%d...", i, #photos))
            local ok, err = LrTasks.pcall(exportWithSimplifiedMetadata, photo, destFolder)
            if not ok then
                progressScope:done()
                LrDialogs.message("Export for iNaturalist", "Export failed: " .. tostring(err), "critical")
                return
            end
        end

        progressScope:done()
        LrDialogs.message(
            "Export for iNaturalist",
            string.format("Exported %d photo%s to %s", #photos, #photos == 1 and "" or "s", destFolder),
            "info"
        )
    end)
end)
