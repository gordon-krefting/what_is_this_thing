local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrTasks = import 'LrTasks'
local LrDialogs = import 'LrDialogs'
local LrProgressScope = import 'LrProgressScope'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrHttp = import 'LrHttp'

local INatSync = dofile(LrPathUtils.child(_PLUGIN.path, "INatSync.lua"))
local MergeCandidatesDialog = dofile(LrPathUtils.child(_PLUGIN.path, "MergeCandidatesDialog.lua"))

-- Shared orchestration for both "Sync from iNaturalist" (incremental,
-- `updated_since`-scoped after the first run) and "Full Sync from
-- iNaturalist" (always pulls the entire history, ignoring the stored
-- cursor -- for whenever the matching/apply logic itself changes and old
-- results need reconsidering, which came up often enough during
-- development that a one-off cursor-reset tool plus a separate sync
-- command was more friction than it was worth). Both entry points are
-- thin wrappers calling INatSyncRunner.run(options) below.
local INatSyncRunner = {}

-- One label per local candidate group in a cluster: its photos' filenames
-- plus its existing tag, if any -- shared between resolveClusterManually
-- (for the dialog text) and both call sites that log an unresolved
-- collision (so the log names the actual local file(s) involved, not just
-- a bare iNat observation id -- reported live that "skipped in the match
-- dialog" alone gave no way to know which photo the dialog was even about).
local function describeCandidateGroups(groups)
    local labels = {}
    for _, group in ipairs(groups) do
        local filenames = {}
        for _, photo in ipairs(group.photos) do
            table.insert(filenames, photo:getFormattedMetadata("fileName") or "?")
        end
        local label = table.concat(filenames, ", ")
        if group.scientificName then
            label = label .. "  (currently tagged: " .. group.scientificName .. ")"
        end
        table.insert(labels, label)
    end
    return labels
end

-- Presents one small dialog per still-ambiguous local group in a collision
-- cluster (more than one candidate group AND more than one candidate
-- observation shared a capture time, with no existing tag to disambiguate
-- automatically -- see INatSync.pullAndMatch). Each dialog offers the
-- remaining candidate observations as radio choices; picking one removes
-- it from the pool offered to the next group in the same cluster.
--
-- Returns resolvedPairs, unresolvedObservations, groupLabels. The second is
-- every observation still left in the pool once every group in the cluster
-- has either been matched or run out of candidates -- this includes
-- anything skipped via "Skip For Now". The caller MUST feed these into the
-- retry list (INatSync.markRetryOutcome) -- without that, a skipped
-- observation has no local match recorded and the `updated_since` cursor
-- still advances past it, so it would otherwise vanish rather than being
-- offered again next run (confirmed live: this was a real bug, not a
-- hypothetical). `groupLabels` is every local candidate group's filenames
-- (+ existing tag, if any) in the cluster (see describeCandidateGroups),
-- for the caller to fold into the sync log.
local function resolveClusterManually(cluster)
    local resolvedPairs = {}
    local remainingObservations = {}
    for _, obs in ipairs(cluster.observations) do
        table.insert(remainingObservations, obs)
    end

    local groupLabels = describeCandidateGroups(cluster.groups)

    for groupIndex, group in ipairs(cluster.groups) do
        if #remainingObservations == 0 then
            break
        end

        local groupLabel = groupLabels[groupIndex]

        local chosenIndex = nil

        LrFunctionContext.callWithContext("INatCollisionResolve", function(context)
            local props = LrBinding.makePropertyTable(context)
            props.selectedIndex = 1

            local f = LrView.osFactory()

            -- An actual thumbnail, not just the filename -- picking the
            -- right observation requires seeing what's in the photo, and a
            -- bare filename like "DSC_7378.NEF" doesn't help with that at
            -- all. One catalog_photo view per photo in the group (usually
            -- just one, but a group can be a whole identify batch).
            --
            -- A thumbnail can render blank/black with no explanation --
            -- checkPhotoAvailability() (must be called from an async task,
            -- which this already is) reports whether the file is
            -- currently reachable, so a note can at least say *why*
            -- instead of leaving an unexplained black box -- confirmed
            -- live this happens for files on a currently-disconnected
            -- external drive.
            local thumbnails = {}
            for _, photo in ipairs(group.photos) do
                local column = {
                    f:catalog_photo {
                        photo = photo,
                        width = 200,
                        height = 200,
                        frame_width = 1,
                    },
                }
                if not photo:checkPhotoAvailability() then
                    table.insert(column, f:static_text {
                        title = "(file not currently available -- on a disconnected drive?)",
                        width_in_chars = 30,
                    })
                end
                table.insert(thumbnails, f:column(column))
            end

            local args = {
                bind_to_object = props,
                spacing = f:control_spacing(),
                f:row(thumbnails),
                f:static_text {
                    title = "Several photos and iNat observations share a capture time.\n"
                        .. "Which observation is:\n" .. groupLabel .. "?",
                },
            }
            for i, obs in ipairs(remainingObservations) do
                local label = "#" .. tostring(obs.id)
                if obs.taxon then
                    label = label .. " -- " .. (obs.taxon.preferred_common_name or obs.taxon.name)
                        .. " (" .. obs.taxon.name .. ")"
                end
                local radio = f:radio_button {
                    title = label,
                    value = LrView.bind("selectedIndex"),
                    checked_value = i,
                    width_in_chars = 50,
                }
                -- Same per-row reference-link pattern as CandidatePicker.lua
                -- -- lets you actually look at the observation on iNat
                -- (photos, location, notes) before committing to a match,
                -- rather than guessing from just the id/species name here.
                local viewButton = f:push_button {
                    title = "View on iNat",
                    action = function()
                        LrHttp.openUrlInBrowser("https://www.inaturalist.org/observations/" .. tostring(obs.id))
                    end,
                }
                table.insert(args, f:row { radio, viewButton })
            end

            local result = LrDialogs.presentModalDialog {
                title = "Match iNat Observation",
                contents = f:column(args),
                actionVerb = "Match",
                cancelVerb = "Skip For Now",
            }

            if result == "ok" then
                chosenIndex = props.selectedIndex
            end
        end)

        if chosenIndex then
            table.insert(resolvedPairs, { group = group, observation = remainingObservations[chosenIndex] })
            table.remove(remainingObservations, chosenIndex)
        end
    end

    return resolvedPairs, remainingObservations, groupLabels
end

-- Short, generic mismatch description (no filenames) -- used both for the
-- dialog's capped preview and as the header line in the fuller log file
-- below.
local function describeMismatch(observationId, mismatch)
    local desc = "Observation #" .. tostring(observationId)
    if mismatch.countMismatch then
        -- iNat's filename data wasn't usable at all for this observation,
        -- so there's no way to name which photos differ -- just the
        -- counts (see applyMatch's time-based fallback).
        desc = desc .. string.format(
            " -- iNat reports %d photo(s), your local group has %d (filenames unavailable to identify them individually)",
            mismatch.countMismatch.iNatCount, mismatch.countMismatch.localCount
        )
    else
        if #mismatch.missingLocally > 0 then
            desc = desc .. " -- iNat has photo(s) not in your local group"
        end
        if #mismatch.missingOnINat > 0 then
            desc = desc .. " -- local group has photo(s) not on iNat"
        end
    end
    return desc
end

-- Captures filename + capture date for every photo in a matched group, at
-- the time of the mismatch -- for the log file below, so the user can work
-- through mismatches without re-running the sync or hunting through
-- Lightroom for each one. Uses the raw dateTimeOriginal (Cocoa epoch)
-- formatted via LrDate.timeToW3CDate -- already used elsewhere in this
-- file/ShowINatSyncState.lua, rather than guessing at a getFormattedMetadata
-- key for a human-readable date (unverified whether one even exists for
-- this field).
local function collectPhotoDetails(photos)
    local details = {}
    for _, photo in ipairs(photos) do
        local dateStr = nil
        local rawOk, raw = pcall(photo.getRawMetadata, photo, "dateTimeOriginal")
        if rawOk and raw then
            local formatOk, formatted = pcall(LrDate.timeToW3CDate, raw)
            if formatOk then
                dateStr = formatted
            end
        end
        table.insert(details, { fileName = photo:getFormattedMetadata("fileName"), dateStr = dateStr })
    end
    return details
end

local function escapeHtml(s)
    s = tostring(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

-- Writes a full HTML log of every mismatch this run -- a clickable link to
-- the iNat observation, the mismatch detail, and each locally-connected
-- photo's filename/capture date -- so the user can work through however
-- many there are (the dialog summary caps the preview at 10) without
-- re-running the sync, and spot patterns worth coding for later. HTML (not
-- plain text) specifically so the iNat links are clickable straight from
-- the file -- plain text can't do that. Lives alongside TaxonStore.lua's
-- cache file for consistency. Uses plain io.open, like TaxonStore.lua --
-- NOT yet confirmed live that writing a brand-new file this way works in
-- Lightroom's Lua sandbox (TaxonStore.lua's own note says the same);
-- wrapped in pcall so a failure here degrades to "couldn't write the log"
-- rather than losing the whole sync summary.
--
-- Returns the file path on success, or nil (with no error) if there was
-- nothing to log or the write failed.
local function writeMismatchLog(mismatches)
    if #mismatches == 0 then
        return nil
    end

    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "local")
    dir = LrPathUtils.child(dir, "WhatIsThisThing")
    local path = LrPathUtils.child(dir, "inat-sync-mismatches.html")

    local html = {
        "<!doctype html><html><head><meta charset=\"utf-8\">",
        "<title>iNaturalist sync mismatches</title>",
        "<style>",
        "body { font-family: -apple-system, sans-serif; margin: 2em; }",
        "h2 { margin-top: 2em; border-bottom: 1px solid #ccc; }",
        ".detail { color: #a33; }",
        "ul { margin: 0.3em 0; }",
        "code { background: #f0f0f0; padding: 0 0.3em; }",
        "</style></head><body>",
        "<p>iNaturalist sync mismatches -- " .. escapeHtml(LrDate.timeToW3CDate(LrDate.currentTime())) .. "</p>",
        "<p>" .. #mismatches .. " group(s) -- to jump to a photo in Lightroom, copy its filename and paste it into "
            .. "the Library Filter bar (or Cmd+F), searching by Filename.</p>",
    }
    for _, m in ipairs(mismatches) do
        table.insert(html, "<h2>Observation #" .. escapeHtml(m.observationId)
            .. " -- <a href=\"" .. escapeHtml(m.url) .. "\" target=\"_blank\">View on iNat</a></h2>")
        table.insert(html, "<p class=\"detail\">" .. escapeHtml(describeMismatch(m.observationId, m.mismatch):gsub("^Observation #%d+ %-%- ", "")) .. "</p>")
        if m.mismatch.missingLocally and #m.mismatch.missingLocally > 0 then
            table.insert(html, "<p>iNat filenames not in local group: <code>"
                .. escapeHtml(table.concat(m.mismatch.missingLocally, ", ")) .. "</code></p>")
        end
        if m.mismatch.missingOnINat and #m.mismatch.missingOnINat > 0 then
            table.insert(html, "<p>Local filenames not on iNat: <code>"
                .. escapeHtml(table.concat(m.mismatch.missingOnINat, ", ")) .. "</code></p>")
        end
        table.insert(html, "<p>Local photos in this group:</p><ul>")
        for _, p in ipairs(m.photos) do
            table.insert(html, "<li><code>" .. escapeHtml(p.fileName) .. "</code>"
                .. (p.dateStr and (" (" .. escapeHtml(p.dateStr) .. ")") or " (no capture date)") .. "</li>")
        end
        table.insert(html, "</ul>")
    end
    table.insert(html, "</body></html>")

    local writeOk = pcall(function()
        LrFileUtils.createAllDirectories(dir)
        local f = assert(io.open(path, "w"))
        f:write(table.concat(html, "\n"))
        f:close()
    end)

    return writeOk and path or nil
end

-- Appends a full per-observation record of this run -- every observation
-- actually reached, and exactly which outcome it landed in -- to a
-- plain-text, ever-growing log (unlike the mismatch HTML above, which is
-- overwritten each run and only covers unresolved mismatches). Exists
-- specifically because a run that appears to do "nothing" for some
-- observations previously left NO trace anywhere once the closing dialog
-- was dismissed -- confirmed live as a real diagnosis blocker. Plain text,
-- not HTML, and append-only (not overwritten) -- this is a debugging/audit
-- trail across runs, not a "work queue" like the mismatch report.
--
-- Uses plain io.open in append mode, same "not yet confirmed live in
-- Lightroom's Lua sandbox" caveat as writeMismatchLog/TaxonStore.lua;
-- wrapped in pcall so a failure here never breaks the rest of the summary.
--
-- Returns the file path on success, or nil if there was nothing to log
-- (empty run) or the write failed.
local function writeFullSyncLog(runLog, meta)
    if #runLog == 0 then
        return nil
    end

    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "local")
    dir = LrPathUtils.child(dir, "WhatIsThisThing")
    local path = LrPathUtils.child(dir, "inat-sync-log.txt")

    local lines = {
        "=== " .. LrDate.timeToW3CDate(LrDate.currentTime()) .. " -- " .. tostring(meta.syncType)
            .. " -- " .. tostring(#runLog) .. " observation(s) ===",
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

local function formatSummary(counts, mismatches, logPath, fullLogPath)
    local parts = {}
    if counts.applied > 0 then
        table.insert(parts, counts.applied .. " photo group" .. (counts.applied == 1 and "" or "s") .. " updated with a new ID")
    end
    if counts.linkedOnly > 0 then
        table.insert(parts, counts.linkedOnly .. " already correctly tagged, just linked to iNat")
    end
    if counts.repairedAncestry > 0 then
        table.insert(parts, counts.repairedAncestry .. " had a missing keyword ancestry chain repaired (species tag was already correct)")
    end
    if counts.skippedDisagreement > 0 then
        table.insert(parts, counts.skippedDisagreement .. " skipped -- iNat's current ID disagrees with your own, resolve on iNat")
    end
    if counts.failed > 0 then
        table.insert(parts, counts.failed .. " couldn't be applied this run -- will retry next time")
    end
    if counts.noLocalMatch > 0 then
        table.insert(parts, counts.noLocalMatch .. " iNat observation" .. (counts.noLocalMatch == 1 and "" or "s") .. " with no matching local photo")
    end
    if counts.unresolvedCollisions > 0 then
        table.insert(parts, counts.unresolvedCollisions .. " left unresolved (skipped in the match dialog)")
    end
    if counts.absorbedSiblings > 0 then
        table.insert(parts, counts.absorbedSiblings .. " untagged sibling photo" .. (counts.absorbedSiblings == 1 and "" or "s")
            .. " found elsewhere in the catalog and linked into an existing observation")
    end
    if counts.resolvedViaMergeDialog > 0 then
        table.insert(parts, counts.resolvedViaMergeDialog .. " photo-count mismatch"
            .. (counts.resolvedViaMergeDialog == 1 and "" or "es") .. " resolved via the merge-candidates picker")
    end

    local message = #parts > 0 and table.concat(parts, "\n") or "Nothing to sync -- everything's already up to date."

    if counts.repairedAncestry > 0 then
        -- Rebuilding ancestry re-parents the keyword under a new (deeper)
        -- chain -- the old flat one gets detached but can't be deleted by
        -- the SDK (no deleteKeyword call exists), so it's left behind as
        -- an orphaned zero-photo duplicate. Same known limitation as any
        -- other ancestry-reshaping operation in this plugin.
        message = message .. "\n\nWorth running Library > Metadata > Purge Unused Keywords afterward -- repairing an ancestry chain leaves the old flat keyword behind as an orphaned duplicate."
    end

    if #mismatches > 0 then
        local shown = {}
        for i = 1, math.min(#mismatches, 10) do
            table.insert(shown, "- " .. describeMismatch(mismatches[i].observationId, mismatches[i].mismatch))
        end
        local suffix = #mismatches > 10 and ("\n...and " .. (#mismatches - 10) .. " more") or ""
        message = message .. "\n\n" .. #mismatches .. " group(s) have a photo mismatch with their iNat observation (not changed automatically):\n"
            .. table.concat(shown, "\n") .. suffix
        if logPath then
            message = message .. "\n\nFull details (clickable iNat links, filenames, capture dates) written to (open in a browser):\n" .. logPath
        end
    end

    if fullLogPath then
        message = message .. "\n\nFull per-observation log appended to:\n" .. fullLogPath
    end

    return message
end

-- Runs a full sync, either incremental (default) or a forced full pull
-- (`options.forceFullPull = true`, ignoring the stored cursor entirely).
-- Either way, a successful uncanceled run updates the cursor at the end,
-- so a forced full pull doesn't cost you the incremental efficiency of
-- your NEXT regular sync -- it's "pull everything this one time," not "go
-- back to full pulls forever."
--
-- `options.forceRecheckAll` (used by RebuildMismatchList.lua): forces
-- EVERY match's mismatch check to run this one time, regardless of the
-- bounded pending-mismatch list -- for the one-time bootstrapping problem
-- that list has on its own: it only ever rechecks ids already ON it, so
-- historical mismatches logged before the list existed (or before a
-- comparison-logic fix like the filename-count-gate one) never get a
-- chance to be re-evaluated or removed. This is deliberately NOT wired to
-- forceFullPull (that would just reintroduce the every-single-run cost
-- problem forceRecheck was removed for) -- it's a separate, explicit,
-- one-time opt-in.
function INatSyncRunner.run(options)
    options = options or {}

    LrTasks.startAsyncTask(function()
        local catalog = LrApplication.activeCatalog()
        local username = INatSync.getOrPromptUsername()
        if not username then
            LrDialogs.message("Sync from iNaturalist", "No username provided.", "info")
            return
        end

        local lastSyncTime = not options.forceFullPull and INatSync.getLastSyncTime() or nil
        local updatedSinceStr = lastSyncTime and LrDate.timeToW3CDate(lastSyncTime) or nil
        local retryIds = INatSync.getPendingRetryIds()
        local pendingMismatchIds = INatSync.getPendingMismatchIds()
        local syncStartTime = LrDate.currentTime()

        -- Both retryIds and pendingMismatchIds need to be force-included in
        -- the pull regardless of the updated_since cursor (pullAndMatch's
        -- retryIds parameter already does exactly this re-fetch-and-merge,
        -- so both lists just ride along in it, deduplicated).
        local pullIds = {}
        local seenPullIds = {}
        for _, id in ipairs(retryIds) do
            if not seenPullIds[id] then
                seenPullIds[id] = true
                table.insert(pullIds, id)
            end
        end
        for _, id in ipairs(pendingMismatchIds) do
            if not seenPullIds[id] then
                seenPullIds[id] = true
                table.insert(pullIds, id)
            end
        end

        local pendingMismatchLookup = {}
        for _, id in ipairs(pendingMismatchIds) do
            pendingMismatchLookup[id] = true
        end

        local progressScope = LrProgressScope({ title = "Sync from iNaturalist" })
        progressScope:setCancelable(true)
        progressScope:setIndeterminate()

        -- The whole run is wrapped in one outer pcall so that ANY unexpected
        -- error partway through (a dialog/view quirk, an SDK edge case,
        -- anything not already caught by one of the inner LrTasks.pcall calls
        -- below) still reaches progressScope:done() and gets reported to the
        -- user -- rather than silently killing the async task and leaving
        -- Lightroom's progress indicator stuck open indefinitely, which is
        -- exactly what was observed live before this was added.
        --
        -- MUST be LrTasks.pcall, not plain pcall -- plain pcall is a C-call
        -- boundary that can't yield in Lightroom's Lua 5.1, and this body is
        -- full of yielding calls (HTTP requests, dialogs, sleeps). Using plain
        -- pcall here produced exactly the documented failure mode ("attempt
        -- to yield across metamethod/C-call boundary") live -- the third time
        -- this exact class of bug has hit this project (see project memory).
        -- Full per-observation record of every run, not just mismatches --
        -- confirmed live this was genuinely needed: a run that appeared to
        -- do "nothing" for several freshly-uploaded observations turned out
        -- to need this to even start diagnosing, since the closing dialog
        -- is the only other record and it's gone the moment you close it
        -- (or run the sync again). One entry per observation actually
        -- reached this run, covering every possible outcome -- including
        -- ones that previously left no trace at all (no local match,
        -- canceled before being reached).
        local runLog = {}
        local function logObservation(observation, outcome, detail)
            table.insert(runLog, {
                observationId = observation.id,
                taxonName = observation.taxon and observation.taxon.name,
                outcome = outcome,
                detail = detail,
            })
        end

        local runOk, runErr = LrTasks.pcall(function()
            -- Shows exactly what's being requested -- full history vs. a
            -- cutoff date -- for the whole pull phase (not just a fleeting
            -- initial caption the per-page update below would otherwise
            -- overwrite in under a second). Useful ongoing transparency
            -- either way, and specifically because a consistent "always full
            -- history" total across supposedly-incremental runs was
            -- otherwise invisible until you went looking for it.
            local pullDescription = updatedSinceStr and ("updated since " .. updatedSinceStr)
                or (options.forceFullPull and "full history (forced)" or "full history (first run)")

            local pullOk, report = LrTasks.pcall(INatSync.pullAndMatch, username, updatedSinceStr, pullIds, function(pulledSoFar)
                progressScope:setCaption("Pulling observations, " .. pullDescription .. "... (" .. pulledSoFar .. " so far)")
            end)

            if not pullOk then
                error("Couldn't pull observations: " .. tostring(report))
            end

            for _, obs in ipairs(report.noLocalMatchObservations) do
                logObservation(obs, "no_local_match")
            end

            local allMatches = {}
            for _, match in ipairs(report.toApply) do
                table.insert(allMatches, match)
            end

            local unresolvedCollisions = 0
            if not progressScope:isCanceled() then
                for _, cluster in ipairs(report.toResolveManually) do
                    local resolved, unresolvedObservations, groupLabels = resolveClusterManually(cluster)
                    for _, pair in ipairs(resolved) do
                        table.insert(allMatches, pair)
                    end
                    -- Anything left unresolved (including explicit "Skip For
                    -- Now") goes on the retry list, so it's offered again
                    -- next run regardless of the `updated_since` cursor --
                    -- see the doc comment on resolveClusterManually for why
                    -- this matters.
                    for _, obs in ipairs(unresolvedObservations) do
                        INatSync.markRetryOutcome(obs.id, false)
                        logObservation(
                            obs, "unresolved_collision",
                            "skipped in the match dialog -- candidate local photo(s) in this cluster: "
                                .. table.concat(groupLabels, "; ")
                        )
                    end
                    unresolvedCollisions = unresolvedCollisions + (#cluster.groups - #resolved)
                end
            else
                -- The whole run was canceled before manual resolution even
                -- started -- every observation in every remaining cluster is
                -- unresolved, and needs the same retry-list treatment.
                for _, cluster in ipairs(report.toResolveManually) do
                    local groupLabels = describeCandidateGroups(cluster.groups)
                    for _, obs in ipairs(cluster.observations) do
                        INatSync.markRetryOutcome(obs.id, false)
                        logObservation(
                            obs, "unresolved_collision",
                            "run canceled before manual resolution -- candidate local photo(s) in this cluster: "
                                .. table.concat(groupLabels, "; ")
                        )
                    end
                    unresolvedCollisions = unresolvedCollisions + #cluster.groups
                end
            end

            local counts = {
                applied = 0, linkedOnly = 0, repairedAncestry = 0, skippedDisagreement = 0, failed = 0,
                noLocalMatch = #report.noLocalMatchObservations, unresolvedCollisions = unresolvedCollisions,
                absorbedSiblings = 0, resolvedViaMergeDialog = 0,
            }
            local mismatches = {}
            local canceledDuringApply = false

            -- Once set (via the picker dialog's "Skip All Remaining" button
            -- -- see MergeCandidatesDialog.lua), no further mismatches this
            -- run trigger the interactive picker -- they just fall through
            -- to the normal mismatch log, same as before this feature
            -- existed. Exists specifically because a single Full Sync can
            -- surface dozens of these at once (confirmed live: 101 in one
            -- real run) -- popping up that many modal dialogs in a row
            -- with no way out would be worse than just reviewing the log
            -- afterward.
            local skipAllRemainingMismatchDialogs = false

            for i, match in ipairs(allMatches) do
                if progressScope:isCanceled() then
                    canceledDuringApply = true
                    for j = i, #allMatches do
                        logObservation(allMatches[j].observation, "canceled_before_apply")
                    end
                    break
                end

                progressScope:setCaption("Applying: " .. tostring(match.observation.taxon and match.observation.taxon.name or match.observation.id))
                progressScope:setPortionComplete(i - 1, #allMatches)

                local forceRecheck = options.forceRecheckAll or pendingMismatchLookup[match.observation.id]
                local applyOk, result = LrTasks.pcall(
                    INatSync.applyMatch, match.group, match.observation, username, lastSyncTime,
                    report.photosByFilename, forceRecheck, report.untaggedSingletonsSortedByTime
                )

                if applyOk then
                    INatSync.markRetryOutcome(match.observation.id, true)
                    counts[result.status] = (counts[result.status] or 0) + 1
                    counts.absorbedSiblings = counts.absorbedSiblings + (result.absorbedCount or 0)
                    if result.mismatch then
                        -- Only worth offering the interactive picker when
                        -- iNat has photos we don't -- local-has-more is
                        -- normal, not actionable (see candidateDiffersFromLocal
                        -- comment / project memory), and there's no
                        -- "missing" photo to go looking for in that case.
                        local worthOffering = (result.mismatch.missingLocally and #result.mismatch.missingLocally > 0)
                            or result.mismatch.countMismatch ~= nil
                        local resolvedInteractively = false

                        if worthOffering and not skipAllRemainingMismatchDialogs then
                            local master = match.group.photos[1]
                            local masterObservationId = master:getPropertyForPlugin(_PLUGIN, "observationId")
                            local beforeEntries, afterEntries, masterTime =
                                MergeCandidatesDialog.buildCandidateWindow(catalog, master, masterObservationId)

                            if beforeEntries and MergeCandidatesDialog.hasEligibleCandidate(beforeEntries, afterEntries) then
                                progressScope:setCaption(
                                    "Reviewing photo-count mismatch: " .. tostring(match.observation.taxon and match.observation.taxon.name or match.observation.id)
                                )
                                local outcome, mergedPhotos = MergeCandidatesDialog.presentAndMerge {
                                    catalog = catalog, master = master,
                                    beforeEntries = beforeEntries, afterEntries = afterEntries, masterTime = masterTime,
                                    allowSkipAll = true,
                                }
                                if outcome == "merged" then
                                    resolvedInteractively = true
                                    counts.resolvedViaMergeDialog = counts.resolvedViaMergeDialog + 1
                                    counts.absorbedSiblings = counts.absorbedSiblings + #mergedPhotos
                                elseif outcome == "skipAll" then
                                    skipAllRemainingMismatchDialogs = true
                                end
                            end
                        end

                        if not resolvedInteractively then
                            table.insert(mismatches, {
                                observationId = match.observation.id,
                                url = "https://www.inaturalist.org/observations/" .. tostring(match.observation.id),
                                mismatch = result.mismatch,
                                photos = collectPhotoDetails(match.group.photos),
                            })
                        end

                        -- Reflects whether it's STILL mismatched after the
                        -- interactive resolution attempt above, not the
                        -- pre-resolution state from applyMatch alone --
                        -- otherwise something just fixed this run would
                        -- incorrectly stay on the pending list forever.
                        if result.checkedMismatch then
                            INatSync.markMismatchOutcome(match.observation.id, not resolvedInteractively)
                        end

                        logObservation(
                            match.observation, result.status,
                            resolvedInteractively and "mismatch resolved via merge picker"
                                or "mismatch: " .. (result.mismatch.countMismatch
                                    and string.format("iNat has %d, local has %d", result.mismatch.countMismatch.iNatCount, result.mismatch.countMismatch.localCount)
                                    or table.concat(result.mismatch.missingLocally or {}, ", "))
                        )
                    else
                        if result.checkedMismatch then
                            INatSync.markMismatchOutcome(match.observation.id, false)
                        end
                        logObservation(match.observation, result.status)
                    end
                else
                    INatSync.markRetryOutcome(match.observation.id, false)
                    counts.failed = counts.failed + 1
                    logObservation(match.observation, "failed", tostring(result))
                end
            end

            -- Only advance the cursor on a full, uncanceled run -- a partial
            -- run (canceled mid-pull or mid-apply) should re-cover the same
            -- window next time rather than risk skipping anything that
            -- wasn't reached.
            if not progressScope:isCanceled() and not canceledDuringApply then
                INatSync.setLastSyncTime(syncStartTime)
            end

            local logPath = writeMismatchLog(mismatches)
            local syncType = options.forceRecheckAll and "Rebuild Mismatch List"
                or options.forceFullPull and "Full Sync" or "Sync"
            local fullLogPath = writeFullSyncLog(runLog, { syncType = syncType })
            LrDialogs.message("Sync from iNaturalist", formatSummary(counts, mismatches, logPath, fullLogPath), "info")
        end)

        progressScope:done()

        if not runOk then
            LrDialogs.message(
                "Sync from iNaturalist",
                "Something went wrong partway through the sync:\n\n" .. tostring(runErr)
                    .. "\n\nAny work already completed was saved -- run the sync again to continue.",
                "error"
            )
        end
    end)
end

return INatSyncRunner
