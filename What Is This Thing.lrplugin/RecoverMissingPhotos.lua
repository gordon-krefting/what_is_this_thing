-- "Recover Missing Photos from iNaturalist": finds observations with no
-- local photo at all (lost locally, or made on the iNat iPhone app
-- straight from Apple Photos -- never local to begin with) and matched
-- groups missing some of their photos, downloads what iNat has, and
-- imports/absorbs them into the catalog. See the design plan and
-- DEVELOPMENT_NOTES.md for the full rationale, including why these are
-- accepted lower-quality placeholders (iNat caps stored photos at 2048px
-- regardless of source), not real backups.
--
-- Thin orchestration layer over INatRecovery.lua's logic -- mirrors the
-- INatSync.lua / INatSyncRunner.lua split for the same testability
-- reasons (this file is LR-dialog/progress-scope glue, not logic).
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrProgressScope = import 'LrProgressScope'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrDate = import 'LrDate'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

local INatSync = dofile(LrPathUtils.child(_PLUGIN.path, "INatSync.lua"))
local INatRecovery = dofile(LrPathUtils.child(_PLUGIN.path, "INatRecovery.lua"))

-- Same append-only, per-run log convention as writeFullSyncLog in
-- INatSyncRunner.lua (same directory, same reasoning: the closing dialog
-- is the only other record and it's gone the moment it's dismissed).
local function writeRecoveryLog(runLog)
    if #runLog == 0 then
        return nil
    end

    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "local")
    dir = LrPathUtils.child(dir, "WhatIsThisThing")
    local path = LrPathUtils.child(dir, "inat-recovery-log.txt")

    local lines = {
        "=== " .. LrDate.timeToW3CDate(LrDate.currentTime())
            .. " -- Recover Missing Photos -- " .. tostring(#runLog) .. " observation(s) ===",
    }
    for _, entry in ipairs(runLog) do
        local line = "  #" .. tostring(entry.observationId)
        if entry.taxonName then
            line = line .. " (" .. entry.taxonName .. ")"
        end
        line = line .. " -- " .. entry.outcome
        if entry.detail then
            line = line .. " -- " .. entry.detail
        end
        table.insert(lines, line)
    end
    table.insert(lines, "")

    local writeOk = pcall(function()
        LrFileUtils.createAllDirectories(dir)
        local f = assert(io.open(path, "a"))
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
    end)

    return writeOk and path or nil
end

LrTasks.startAsyncTask(function()
    local username = INatSync.getOrPromptUsername()
    if not username then
        LrDialogs.message("Recover Missing Photos from iNaturalist", "No username provided.", "info")
        return
    end

    local pullScope = LrProgressScope({ title = "Recover Missing Photos from iNaturalist" })
    pullScope:setCancelable(true)
    pullScope:setIndeterminate()

    local pullOk, candidates = LrTasks.pcall(INatRecovery.findCandidates, username, function(pulledSoFar)
        pullScope:setCaption("Checking your iNaturalist history... (" .. pulledSoFar .. " so far)")
    end)
    pullScope:done()

    if not pullOk then
        LrDialogs.message(
            "Recover Missing Photos from iNaturalist",
            "Couldn't check for recoverable photos:\n\n" .. tostring(candidates),
            "critical"
        )
        return
    end

    local totalLossPhotoCount = 0
    for _, observation in ipairs(candidates.totalLoss) do
        totalLossPhotoCount = totalLossPhotoCount + #(observation.photos or {})
    end

    if #candidates.totalLoss == 0 and #candidates.partialLoss == 0 then
        LrDialogs.message(
            "Recover Missing Photos from iNaturalist",
            "Nothing to recover -- every synced observation already has all its local photos.",
            "info"
        )
        return
    end

    -- Hard safety gate before any file is written or the catalog is
    -- touched -- real downloads + catalog mutation are much harder to
    -- cheaply reverse than a metadata-only sync, so this shows exact
    -- counts up front rather than just starting. Includes an optional
    -- per-category limit (blank = no limit) -- added specifically so a
    -- first run (or `catalog:addPhoto`, genuinely new SDK surface for
    -- this project as of this feature) can be spot-checked against a
    -- handful of observations before trusting a full batch, without
    -- relying on imprecisely mashing the progress scope's Cancel button.
    local confirmed = false
    local limitText = ""
    LrFunctionContext.callWithContext("RecoverMissingPhotosConfirm", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.limit = ""

        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text {
                title = string.format(
                    "Found %d observation(s) with no local photo at all (%d photo(s) total), and "
                        .. "%d observation(s) missing some of their photos.",
                    #candidates.totalLoss, totalLossPhotoCount, #candidates.partialLoss
                ),
                width_in_chars = 60,
                height_in_lines = 3,
            },
            f:static_text {
                title = "Downloaded photos are capped at 2048px by iNaturalist regardless of the "
                    .. "original resolution, and will be marked as recovered placeholders. Files "
                    .. "are saved to ~/Photos/import/RecoveredFromINat.",
                width_in_chars = 60,
                height_in_lines = 3,
            },
            f:row {
                f:static_text { title = "Limit to the first N of each category (optional):" },
                f:edit_field { value = LrView.bind("limit"), width_in_chars = 6 },
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Recover Missing Photos from iNaturalist",
            contents = contents,
            actionVerb = "Recover",
            cancelVerb = "Cancel",
        }
        confirmed = result == "ok"
        limitText = props.limit
    end)
    if not confirmed then
        return
    end

    local limit = tonumber(limitText)
    if limit and limit > 0 then
        limit = math.floor(limit)
        local limitedTotalLoss = {}
        for i = 1, math.min(limit, #candidates.totalLoss) do
            table.insert(limitedTotalLoss, candidates.totalLoss[i])
        end
        local limitedPartialLoss = {}
        for i = 1, math.min(limit, #candidates.partialLoss) do
            table.insert(limitedPartialLoss, candidates.partialLoss[i])
        end
        candidates.totalLoss = limitedTotalLoss
        candidates.partialLoss = limitedPartialLoss
    end

    local destDir = INatRecovery.recoveryDestDir()
    local runLog = {}
    local counts = { imported = 0, absorbed = 0, photosImported = 0, failed = 0, skipped = 0 }

    -- workScope is created BEFORE the outer LrTasks.pcall below and
    -- :done() is called unconditionally right after it returns --
    -- mirrors INatSyncRunner.lua's own established hardening (see its
    -- comment on the same pattern) so that ANY unexpected error partway
    -- through this loop (a view/dialog quirk, an SDK edge case, anything
    -- not already caught by the per-item LrTasks.pcall calls below)
    -- still reaches workScope:done() -- confirmed live as a real gap:
    -- this file didn't have that outer safety net, and Lightroom's
    -- dock/progress indicator stayed stuck open after a crash elsewhere
    -- in this same run.
    local workScope = LrProgressScope({ title = "Recover Missing Photos from iNaturalist" })
    workScope:setCancelable(true)

    local runOk, runErr = LrTasks.pcall(function()
        local totalItems = #candidates.totalLoss + #candidates.partialLoss
        local itemsDone = 0

        for _, observation in ipairs(candidates.totalLoss) do
            if workScope:isCanceled() then
                break
            end
            workScope:setCaption("Recovering #" .. tostring(observation.id) .. "...")
            local ok, result = LrTasks.pcall(INatRecovery.recoverTotalLoss, observation, username, destDir)
            if ok and result.applied then
                counts.imported = counts.imported + 1
                counts.photosImported = counts.photosImported + result.imported
                table.insert(runLog, { observationId = observation.id, taxonName = observation.taxon and observation.taxon.name,
                    outcome = "imported", detail = result.imported .. " photo(s)" })
            elseif ok then
                counts.failed = counts.failed + 1
                table.insert(runLog, { observationId = observation.id, taxonName = observation.taxon and observation.taxon.name,
                    outcome = "failed", detail = "no photos could be downloaded" })
            else
                counts.failed = counts.failed + 1
                table.insert(runLog, { observationId = observation.id, taxonName = observation.taxon and observation.taxon.name,
                    outcome = "failed", detail = tostring(result) })
            end
            itemsDone = itemsDone + 1
            workScope:setPortionComplete(itemsDone, totalItems)
        end

        for _, match in ipairs(candidates.partialLoss) do
            if workScope:isCanceled() then
                break
            end
            local observation = match.observation
            workScope:setCaption("Recovering #" .. tostring(observation.id) .. "...")
            local ok, result = LrTasks.pcall(INatRecovery.recoverPartialLoss, match.group, observation, username, destDir)
            if ok and result.applied then
                counts.absorbed = counts.absorbed + 1
                counts.photosImported = counts.photosImported + result.imported
                table.insert(runLog, { observationId = observation.id, taxonName = observation.taxon and observation.taxon.name,
                    outcome = "absorbed", detail = result.imported .. " photo(s)" })
            elseif ok and result.skipped then
                counts.skipped = counts.skipped + 1
                table.insert(runLog, { observationId = observation.id, taxonName = observation.taxon and observation.taxon.name,
                    outcome = "skipped", detail = result.skipped })
            elseif ok then
                counts.failed = counts.failed + 1
                table.insert(runLog, { observationId = observation.id, taxonName = observation.taxon and observation.taxon.name,
                    outcome = "failed", detail = "no photos could be downloaded" })
            else
                counts.failed = counts.failed + 1
                table.insert(runLog, { observationId = observation.id, taxonName = observation.taxon and observation.taxon.name,
                    outcome = "failed", detail = tostring(result) })
            end
            itemsDone = itemsDone + 1
            workScope:setPortionComplete(itemsDone, totalItems)
        end
    end)

    workScope:done()

    -- Write whatever the log accumulated regardless of runOk -- a partial
    -- run that hit an unexpected error still did real work worth a
    -- record, not just the happy-path summary.
    local logPath = writeRecoveryLog(runLog)

    if not runOk then
        LrDialogs.message(
            "Recover Missing Photos from iNaturalist",
            "Something went wrong partway through recovery:\n\n" .. tostring(runErr)
                .. "\n\nAny work already completed was saved" .. (logPath and (" -- see " .. logPath) or "")
                .. ". Run the command again to continue.",
            "critical"
        )
        return
    end

    local summary = string.format(
        "%d new observation(s) imported (%d photo(s) total)\n%d observation(s) absorbed missing photo(s)\n"
            .. "%d skipped (unreliable filename data)\n%d failed",
        counts.imported, counts.photosImported, counts.absorbed, counts.skipped, counts.failed
    )
    if logPath then
        summary = summary .. "\n\nFull log: " .. logPath
    end
    LrDialogs.message("Recover Missing Photos from iNaturalist", summary, "info")
end)
