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
local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local INatRecovery = dofile(LrPathUtils.child(_PLUGIN.path, "INatRecovery.lua"))
local MergeCandidatesDialog = dofile(LrPathUtils.child(_PLUGIN.path, "MergeCandidatesDialog.lua"))

-- Confirmed live 2026-07-24: observations uploaded moments before a sync
-- run can fail to appear in that run's `updated_since` pull even though
-- the cursor captured at the start of the run is already later than
-- their `updated_at` -- iNaturalist's search backend hadn't indexed them
-- yet at the moment of the query. Because the cursor still advances to
-- "now" regardless, and an observation's `updated_at` never changes again
-- on its own, this silently and permanently orphans it: it's never
-- pulled at all, so it never reaches any of pullAndMatch's report
-- buckets and never gets logged. Subtracting this margin before storing
-- the cursor makes every incremental pull re-cover a trailing window,
-- catching anything that was still indexing at the moment of the
-- previous run. Safe to re-scan -- anything already linked hits the
-- fast path in pullAndMatch almost for free.
local SYNC_CURSOR_SAFETY_MARGIN_SECONDS = 60 * 60

-- Confirmed live 2026-07-24 as the actual root cause of the incremental
-- sync silently finding nothing new: `LrDate.timeToW3CDate` on this
-- system renders a near-"now" cocoa time WITHOUT any trailing timezone
-- designator at all (e.g. "2026-07-24T17:04:48.013", not
-- "...T17:04:48-06:00" or "...Z") -- confirmed via the pull diagnostic
-- trace below. The numeric hour/minute/second IS correct UTC (cocoa time
-- is an absolute UTC instant, and the rendered value matched true
-- wall-clock UTC, not the local -06:00 offset) -- only the designator is
-- missing. iNaturalist's API silently treats a designator-less
-- `updated_since` near "now" as matching nothing (confirmed live:
-- `total_results: 0` for an offset-less near-now timestamp vs. correct
-- results for the identical instant with "Z" appended) rather than
-- erroring, so this was invisible except as "sync did nothing." Only
-- appends "Z" if a designator isn't already present, so this stays a
-- no-op if the SDK's behavior differs on another system/version.
local function toUtcW3CDate(time)
    local raw = LrDate.timeToW3CDate(time)
    if raw:match("Z$") or raw:match("[%+%-]%d%d:%d%d$") then
        return raw
    end
    return raw .. "Z"
end

-- "2 hours ago" / "3 days ago" style relative-time label for the
-- pre-flight dialog's status section -- deliberately pure arithmetic on
-- the two Cocoa-epoch numbers (LrDate.currentTime() minus the stored
-- cursor), not string parsing/reformatting of a rendered date -- this
-- project has been burned by date-string handling more than once (see
-- toUtcW3CDate above), so this sidesteps that whole class of risk
-- entirely for what's just a rough, human-friendly duration.
local function describeElapsedTime(seconds)
    if seconds < 0 then
        return "just now"
    elseif seconds < 60 then
        return "less than a minute ago"
    elseif seconds < 3600 then
        local m = math.floor(seconds / 60)
        return m .. " minute" .. (m == 1 and "" or "s") .. " ago"
    elseif seconds < 86400 then
        local h = math.floor(seconds / 3600)
        return h .. " hour" .. (h == 1 and "" or "s") .. " ago"
    else
        local d = math.floor(seconds / 86400)
        return d .. " day" .. (d == 1 and "" or "s") .. " ago"
    end
end

-- Single entry point for "Sync from iNaturalist" -- consolidates what were
-- previously three separate commands (Sync, Full Sync, Recover Missing
-- Photos) into one, per the 2026-07-29 consolidation plan
-- (DEVELOPMENT_NOTES.md). A pre-flight dialog (showPreFlightDialog below)
-- now supplies the Full/Incremental choice that used to be which menu item
-- you clicked; recovery (downloading a placeholder for a photo with no
-- local copy) is now offered inline, per observation, during the same run
-- instead of being a separate later command.
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

-- "Locally identified as: <name>" (or "Not yet identified locally.") --
-- what a local observation (group of photos) is currently tagged as,
-- independent of any iNat link. Shown as its own wrappable line (see
-- callers -- width_in_chars + height_in_lines, not squeezed into a
-- single-line radio/checkbox title) rather than folded into
-- describeCandidateGroups' filename-list string, which truncated badly
-- once a real species name was appended (confirmed live in both
-- confirmNewLink and resolveClusterManually's dialogs).
local function describeLocalIdentification(group)
    if group.scientificName then
        local label = group.commonName and (group.commonName .. " (" .. group.scientificName .. ")") or group.scientificName
        return "Locally identified as: " .. label
    end
    return "Not yet identified locally."
end

-- "#<id> -- <common name> (<scientific name>) -- N photo(s)" -- anchors
-- the collision dialog and the new-link confirmation dialog on what iNat
-- itself reliably reports (the taxon and the photo count, both already
-- present in the pulled observation, no extra fetch needed) rather than
-- filenames, which are frequently missing, unreliable, or entirely absent
-- from iNat's own data (see the filename-count-gate comments in
-- INatSync.lua). Paired with an actual downloaded thumbnail (see
-- buildINatThumbnail below) for a fuller visual comparison, not just text.
local function describeObservation(obs)
    local label = "#" .. tostring(obs.id)
    if obs.taxon then
        label = label .. " -- " .. (obs.taxon.preferred_common_name or obs.taxon.name)
            .. " (" .. obs.taxon.name .. ")"
    end
    local photoCount = obs.photos and #obs.photos or 0
    label = label .. " -- " .. photoCount .. " photo" .. (photoCount == 1 and "" or "s")
    return label
end

-- The observation's own first iNat photo URL, at the "square" size iNat's
-- standard pull already returns it in (confirmed live: no substitution
-- needed, `photo.url` is directly usable as a small thumbnail) -- used for
-- the Needs Attention report's <img> tags, loaded by the browser when the
-- report is viewed, not downloaded/embedded by the plugin.
local function firstPhotoUrl(observation)
    return observation.photos and observation.photos[1] and observation.photos[1].url
end

-- One column per local candidate group: a row of its own photo thumbnail(s)
-- (150x150, same size as MergeCandidatesDialog's neighbor columns) with a
-- caption control underneath -- multiple candidates get placed side by
-- side in a single outer row (see resolveClusterManually/confirmNewLink),
-- matching MergeCandidatesDialog's layout, rather than one full-width
-- 200x200 block stacked per candidate, which was overflowing the screen
-- for any cluster with more than a couple of candidates.
local function buildCandidateColumn(f, group, caption)
    local photoColumns = {}
    for _, photo in ipairs(group.photos) do
        local column = {
            f:catalog_photo {
                photo = photo,
                width = 150,
                height = 150,
                frame_width = 1,
            },
        }
        -- Confirmed live this happens for files on a currently-disconnected
        -- external drive (checkPhotoAvailability must be called from an
        -- async task, which this already is).
        if not photo:checkPhotoAvailability() then
            table.insert(column, f:static_text {
                title = "(unavailable)",
                width_in_chars = 22,
            })
        end
        table.insert(photoColumns, f:column(column))
    end
    return f:column {
        f:row(photoColumns),
        caption,
    }
end

-- Downloads and renders the observation's own iNat photo as a `picture`
-- view (a plain file-path image control, unlike catalog_photo which only
-- works for local Lightroom photos) -- lets the user visually compare
-- against the local candidate(s) directly in the dialog, rather than
-- needing "View on iNat" to open a browser for every candidate. Falls
-- back to a text placeholder if the download failed (network, no photos
-- on the observation, etc.) -- never blocks the dialog from showing.
--
-- Returns the view element AND the downloaded temp file's path (or nil if
-- there wasn't one) -- the caller MUST remove that file once the dialog
-- closes (see the cleanupINatThumbnail calls throughout this file), since
-- these are one-shot fetches, not a cache.
--
-- Confirmed live: renders correctly.
local function buildINatThumbnail(f, observation)
    local tempPath = INaturalist.downloadObservationThumbnail(observation)
    if tempPath then
        return f:picture { value = tempPath, width = 150, height = 150, frame_width = 1 }, tempPath
    end
    return f:static_text { title = "(iNat photo unavailable)", width_in_chars = 22 }, nil
end

-- Same idea as buildINatThumbnail, but every photo on the observation, not
-- just the first -- requested specifically for "Recover Missing Photo" and
-- "Confirm New iNaturalist Link" (cheap enough to be worth it: these are
-- already-small "square" thumbnails, not full downloads). Returns the row
-- of views AND every downloaded temp path (for cleanupINatThumbnails) --
-- falls back to a single text placeholder if none downloaded.
local function buildAllINatThumbnails(f, observation)
    local tempPaths = INaturalist.downloadAllObservationThumbnails(observation)
    if #tempPaths == 0 then
        return f:static_text { title = "(iNat photo unavailable)", width_in_chars = 22 }, {}
    end
    local pictures = {}
    for _, path in ipairs(tempPaths) do
        table.insert(pictures, f:picture { value = path, width = 150, height = 150, frame_width = 1 })
    end
    return f:row(pictures), tempPaths
end

-- Best-effort cleanup for buildINatThumbnail's downloaded temp file --
-- wrapped in pcall since a failure to delete a scratch temp file is not
-- worth interrupting a sync run over.
local function cleanupINatThumbnail(tempPath)
    if tempPath then
        pcall(os.remove, tempPath)
    end
end

-- Same, for buildAllINatThumbnails' list of temp paths.
local function cleanupINatThumbnails(tempPaths)
    for _, path in ipairs(tempPaths or {}) do
        pcall(os.remove, path)
    end
end

-- A small "View on iNat" button, reused by every per-observation dialog in
-- this file.
local function viewOnINatButton(f, observationId)
    return f:push_button {
        title = "View on iNat",
        action = function()
            LrHttp.openUrlInBrowser("https://www.inaturalist.org/observations/" .. tostring(observationId))
        end,
    }
end

-- Presents one small dialog per still-ambiguous iNat observation in a
-- collision cluster (more than one candidate group AND more than one
-- candidate observation shared a capture time, with no existing tag to
-- disambiguate automatically -- see INatSync.pullAndMatch). Anchored on
-- the OBSERVATION (its species/common name + photo count, from
-- describeObservation -- reported live that asking "which of these
-- unlabeled iNat ids is this local photo?" was backwards from how the
-- user actually thinks about it: "which of my local photos is THIS iNat
-- post?"). Each dialog offers the remaining candidate LOCAL GROUPS (with
-- thumbnails) as radio choices; picking one removes it from the pool
-- offered to the next observation in the same cluster.
--
-- Returns resolvedPairs, unresolvedObservations, groupLabels, aborted. The
-- second is every observation left over once every candidate group in the
-- cluster has either been claimed or the pool ran out before reaching it --
-- this includes anything skipped via "Skip For Now". The caller MUST feed
-- these into the retry list (INatSync.markRetryOutcome) -- without that, a
-- skipped observation has no local match recorded and the `updated_since`
-- cursor still advances past it, so it would otherwise vanish rather than
-- being offered again next run (confirmed live: this was a real bug, not a
-- hypothetical). `groupLabels` is every local candidate group's filenames
-- (+ existing tag, if any) in the cluster (see describeCandidateGroups),
-- for the caller to fold into the sync log. `aborted` is true if "Abort
-- Sync" was chosen partway through this cluster (2026-07-31, the same
-- confusing-buttons complaint as showNoGoodCandidateNotice) -- the caller
-- is responsible for calling progressScope:cancel() AND for treating every
-- OTHER not-yet-reached cluster the same as this one's own unresolved
-- observations, since resolveClusterManually only sees one cluster at a
-- time. `progressLabel` (optional, e.g. " (Observation 5 of 23)") is
-- appended to the dialog's title as-is.
local function resolveClusterManually(cluster, progressLabel)
    local resolvedPairs = {}
    local remainingGroups = {}
    for _, group in ipairs(cluster.groups) do
        table.insert(remainingGroups, group)
    end

    local groupLabels = describeCandidateGroups(cluster.groups)
    local labelForGroup = {}
    for i, group in ipairs(cluster.groups) do
        labelForGroup[group] = groupLabels[i]
    end
    local unresolvedObservations = {}
    local aborted = false

    for _, obs in ipairs(cluster.observations) do
        if aborted then
            table.insert(unresolvedObservations, obs)
        elseif #remainingGroups == 0 then
            table.insert(unresolvedObservations, obs)
        else
            local chosenIndex = nil

            LrFunctionContext.callWithContext("INatCollisionResolve", function(context)
                local props = LrBinding.makePropertyTable(context)
                props.selectedIndex = 1

                local f = LrView.osFactory()

                local candidateColumns = {}
                for i, group in ipairs(remainingGroups) do
                    -- Radio title is just the filename(s) -- short, and the
                    -- actual selectable label. The species tag (which can
                    -- run long) is a SEPARATE, wrappable line underneath --
                    -- confirmed live: cramming both into one narrow
                    -- single-line radio title truncated badly the moment a
                    -- real species name was present ("IMG_1988.JPG
                    -- (currently tagged:" with nothing after it). Wrapping
                    -- onto a couple of lines keeps the dialog's WIDTH
                    -- exactly as narrow as before -- only adds height.
                    local filenames = {}
                    for _, photo in ipairs(group.photos) do
                        table.insert(filenames, photo:getFormattedMetadata("fileName") or "?")
                    end
                    local radio = f:radio_button {
                        title = table.concat(filenames, ", "),
                        value = LrView.bind("selectedIndex"),
                        checked_value = i,
                        width_in_chars = 22,
                    }
                    local identificationLine = f:static_text {
                        title = describeLocalIdentification(group),
                        width_in_chars = 22,
                        height_in_lines = 2,
                    }
                    table.insert(candidateColumns, buildCandidateColumn(f, group, f:column { radio, identificationLine }))
                end

                local inatThumbnail, inatThumbnailTempPath = buildINatThumbnail(f, obs)

                local contents = f:column {
                    bind_to_object = props,
                    spacing = f:control_spacing(),
                    f:static_text { title = describeObservation(obs) },
                    f:row { inatThumbnail, viewOnINatButton(f, obs.id) },
                    f:static_text {
                        title = "Several photos and iNat observations share a capture time.\n"
                            .. "Which local photo is this?",
                    },
                    -- Confirmed live 2026-08-05: a cluster with enough
                    -- candidates ran the row off the edge of the screen
                    -- entirely, with no way to reach the later ones at
                    -- all. scrolled_view gives a fixed-size viewport with
                    -- a horizontal scroll bar instead of letting the row
                    -- grow unbounded -- Mac OS hides the bar automatically
                    -- when everything already fits, so this is a no-op
                    -- visually for the common, few-candidates case.
                    f:scrolled_view {
                        width = 800,
                        height = 230,
                        horizontal_scroller = true,
                        vertical_scroller = false,
                        f:row(candidateColumns),
                    },
                }

                local result = LrDialogs.presentModalDialog {
                    title = "Match iNat Observation" .. (progressLabel or ""),
                    contents = contents,
                    actionVerb = "Match",
                    cancelVerb = "Skip For Now",
                    otherVerb = "Abort Sync",
                }

                cleanupINatThumbnail(inatThumbnailTempPath)

                if result == "ok" then
                    chosenIndex = props.selectedIndex
                elseif result == "other" then
                    aborted = true
                end
            end)

            if chosenIndex then
                table.insert(resolvedPairs, { group = remainingGroups[chosenIndex], observation = obs })
                table.remove(remainingGroups, chosenIndex)
            else
                table.insert(unresolvedObservations, obs)
            end
        end
    end

    return resolvedPairs, unresolvedObservations, groupLabels, aborted
end

-- Confirms a brand-new iNat link before it's applied, even when the match
-- itself is unambiguous -- requested explicitly ("show the confirmation
-- even if we feel good about the match") so a mistake in the underlying
-- time-correlation logic gets caught before anything is written, not
-- after. The caller is responsible for only calling this for first-time
-- links (group.iNatObservationId == nil) -- an already-linked observation
-- being routinely re-verified every run must stay silent, or every
-- regular Sync would turn back into a full manual review. No bulk-accept
-- escape hatch (unlike the merge-candidates picker's "Skip All
-- Remaining") -- explicitly not wanted; every first-time link gets its
-- own confirmation, every run.
--
-- Returns "confirmed", "skipped", or "abort" (2026-07-31, same
-- confusing-buttons/missing-abort complaint as showNoGoodCandidateNotice
-- and resolveClusterManually). `progressLabel` (optional, e.g.
-- " (Observation 5 of 23)") is appended to the title as-is.
local function confirmNewLink(match, progressLabel)
    local outcome = "skipped"

    LrFunctionContext.callWithContext("INatConfirmNewLink", function(context)
        local f = LrView.osFactory()

        -- Full-width, unconstrained (same as resolveClusterManually's
        -- header) -- NOT the narrow 22-char-wide caption
        -- buildCandidateColumn otherwise uses for a short per-candidate
        -- label sitting next to a thumbnail, which cut this off
        -- mid-sentence when it carried a species name too (confirmed
        -- live: "DSC_0532.NEF  (currently tagged:" with nothing after it).
        local identificationLabel = f:static_text { title = describeLocalIdentification(match.group) }

        local inatThumbnails, inatThumbnailPaths = buildAllINatThumbnails(f, match.observation)

        local contents = f:column {
            spacing = f:control_spacing(),
            -- We're linking a local OBSERVATION (a group of one or more
            -- photos) to an iNat observation, not "a photo" to anything --
            -- worded accordingly.
            f:static_text { title = "Link your local observation to iNat observation " .. describeObservation(match.observation) .. "?" },
            f:row { inatThumbnails, viewOnINatButton(f, match.observation.id) },
            f:row { buildCandidateColumn(f, match.group, identificationLabel) },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Confirm New iNaturalist Link" .. (progressLabel or ""),
            contents = contents,
            actionVerb = "Confirm",
            cancelVerb = "Skip For Now",
            otherVerb = "Abort Sync",
        }

        cleanupINatThumbnails(inatThumbnailPaths)

        if result == "ok" then
            outcome = "confirmed"
        elseif result == "other" then
            outcome = "abort"
        end
    end)

    return outcome
end

-- A single per-observation "download iNat's copy?" prompt, shared by both
-- the total-loss (no local photo at all) and partial-loss (missing SOME
-- photos) cases -- a real, deliberate decision per item, same "no
-- bulk-accept" philosophy as confirmNewLink above, not a batch-level gate
-- the way the old standalone "Recover Missing Photos" command had one.
-- `promptText` carries whichever of the two situations applies.
--
-- Returns "accepted" or "declined". `progressLabel` (optional, e.g.
-- " (Observation 5 of 23)") is appended to the title as-is.
local function offerDownload(observation, promptText, progressLabel)
    local outcome = "declined"

    LrFunctionContext.callWithContext("INatOfferDownload", function(context)
        local f = LrView.osFactory()
        local inatThumbnails, inatThumbnailPaths = buildAllINatThumbnails(f, observation)

        local contents = f:column {
            spacing = f:control_spacing(),
            f:static_text { title = promptText, width_in_chars = 50, height_in_lines = 2 },
            f:row { inatThumbnails, viewOnINatButton(f, observation.id) },
            f:static_text {
                title = "Downloaded photos are capped at 2048px by iNaturalist regardless of the "
                    .. "original resolution, and will be marked as recovered placeholders.",
                width_in_chars = 50,
                height_in_lines = 2,
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Recover Missing Photo" .. (progressLabel or ""),
            contents = contents,
            actionVerb = "Download",
            cancelVerb = "Not Now",
        }

        cleanupINatThumbnails(inatThumbnailPaths)

        if result == "ok" then
            outcome = "accepted"
        end
    end)

    return outcome
end

-- Bucket 4: matching was uncertain rather than confidently empty (a
-- same-species local group existed but fell outside the widening
-- tolerance, or a real candidate was already claimed by another
-- observation this run -- see INatSync.widenCandidatesByScientificName's
-- closestMiss and describeClaimedAway). Rather than guess or auto-offer a
-- download that might create a duplicate of a real local photo just
-- mis-correlated, this only informs -- no decision required in the
-- moment, just a single "OK" to dismiss. Confirmed with the user this is
-- expected to be rare now that legacy-observation matching is mostly
-- caught up; revisit per-item-vs-aggregate notice style if that turns out
-- wrong in practice.
-- Purely informational -- there's no decision to make here (see the
-- design note on bucket 4 in DEVELOPMENT_NOTES.md), so the only real
-- choices are "acknowledge and keep going" or "stop the whole sync run
-- now". Previously used LrDialogs' default OK/Cancel labels, but Cancel's
-- result was never even read -- it did exactly the same thing as OK,
-- which is exactly the confusing-buttons complaint that prompted this
-- (2026-07-31). "Abort Sync" now genuinely stops the run, via
-- progressScope:cancel() -- the SAME mechanism the sync's own progress
-- bar Cancel button already uses (confirmed live via SDK docs: available
-- since SDK 7.5, well within what this plugin's actual host, Lightroom
-- Classic 13.3.1, supports) -- so every existing progressScope:isCanceled()
-- check already scattered through the rest of this run's processing
-- picks it up with no other plumbing needed.
--
-- Returns "ok" or "abort". `progressLabel` (optional, e.g.
-- " (Observation 5 of 23)") is appended to the title as-is.
local function showNoGoodCandidateNotice(observation, reason, progressLabel)
    local outcome = "ok"

    LrFunctionContext.callWithContext("INatNoGoodCandidate", function(context)
        local f = LrView.osFactory()
        local inatThumbnail, inatThumbnailTempPath = buildINatThumbnail(f, observation)

        local contents = f:column {
            spacing = f:control_spacing(),
            f:static_text { title = "Couldn't find a good local candidate for " .. describeObservation(observation) .. "." },
            f:row { inatThumbnail, viewOnINatButton(f, observation.id) },
            f:static_text { title = reason, width_in_chars = 50, height_in_lines = 2 },
            f:static_text { title = "Flagged for retry -- see the Needs Attention report for details." },
        }

        local result = LrDialogs.presentModalDialog {
            title = "No Good Candidate" .. (progressLabel or ""),
            contents = contents,
            actionVerb = "Continue",
            cancelVerb = "Abort Sync",
        }

        if result == "cancel" then
            outcome = "abort"
        end

        cleanupINatThumbnail(inatThumbnailTempPath)
    end)

    return outcome
end

-- Purely informational -- shown after an ALREADY-linked observation's
-- data (species/common/rank, quality grade, or the unresponded-suggestion
-- flag -- see INatSync.applyMatch's `changes`) actually changed on iNat's
-- side and was just applied. Never gates the write (per the user: if
-- matching is already correct, there's no legitimate reason to decline a
-- routine field update) -- just an "OK" to acknowledge, plus a "Skip All
-- Remaining" to mute further such notices for the rest of this run
-- (changes keep applying silently either way -- this only controls
-- whether a dialog interrupts to show them, same "could be dozens in one
-- Full Sync" concern the merge-candidates picker's own skip-all exists
-- for). A first-time link never reaches here -- its own dedicated review
-- (confirmNewLink) already covers that moment.
--
-- The match this notice describes is already applied by the time this
-- dialog shows (see the apply loop below), so unlike confirmNewLink/
-- resolveClusterManually/showNoGoodCandidateNotice there's nothing here
-- to gate -- "Cancel" used to be a no-op, identical to "OK". Repurposed
-- as the Abort Sync button (2026-07-31, matching those other dialogs'
-- convention) since all 3 button slots were already spoken for: aborting
-- here only stops processing further observations, it can't and doesn't
-- undo the change just shown.
--
-- Returns "ok", "skipAll", or "abort". `progressLabel` (optional, e.g.
-- " (Observation 5 of 23)") is appended to the title as-is.
local function showFieldChangeNotice(observation, changes, allowSkipAll, progressLabel)
    local outcome = "ok"

    LrFunctionContext.callWithContext("INatFieldChangeNotice", function(context)
        local f = LrView.osFactory()
        local inatThumbnails, inatThumbnailPaths = buildAllINatThumbnails(f, observation)

        local changeLines = {}
        for _, c in ipairs(changes) do
            table.insert(changeLines, f:static_text { title = "- " .. c })
        end

        local contents = f:column {
            spacing = f:control_spacing(),
            f:static_text { title = "iNaturalist data changed for " .. describeObservation(observation) .. ":" },
            f:row { inatThumbnails, viewOnINatButton(f, observation.id) },
            f:column(changeLines),
        }

        local dialogArgs = {
            title = "iNaturalist Data Changed" .. (progressLabel or ""),
            contents = contents,
            actionVerb = "OK",
            cancelVerb = "Abort Sync",
        }
        if allowSkipAll then
            dialogArgs.otherVerb = "Skip All Remaining"
        end

        local result = LrDialogs.presentModalDialog(dialogArgs)

        cleanupINatThumbnails(inatThumbnailPaths)

        if result == "other" then
            outcome = "skipAll"
        elseif result == "cancel" then
            outcome = "abort"
        end
    end)

    return outcome
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
-- the time of the mismatch -- for the report below, so the user can work
-- through mismatches without re-running the sync or hunting through
-- Lightroom for each one. Uses the raw dateTimeOriginal (Cocoa epoch)
-- formatted via LrDate.timeToW3CDate -- already used elsewhere in this
-- file, rather than guessing at a getFormattedMetadata key for a
-- human-readable date (unverified whether one even exists for this field).
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

-- Human-readable label per needsAttention category, for the report's
-- per-entry badge.
local NEEDS_ATTENTION_LABELS = {
    unresolved_collision = "Unresolved ambiguous match",
    declined_download = "No local photo -- download declined",
    no_good_candidate = "No good local candidate found",
    download_failed = "Download attempted but failed",
    filename_mismatch = "Photo-count mismatch",
}

-- Writes a full HTML report of every observation still needing attention
-- after this run -- a clickable link to the iNat observation, its own
-- thumbnail (loaded directly from iNat's hosted URL, not downloaded by the
-- plugin -- see firstPhotoUrl), which category it's in, and any
-- category-specific detail (e.g. locally-connected photos' filenames/
-- capture dates for a mismatch). Generalizes the old mismatch-only log
-- into one unified work queue covering every deferred/retry-listed
-- outcome from the consolidated sync run (see the 2026-07-29
-- consolidation plan) -- unresolved collisions, declined/failed
-- downloads, and the new "no good candidate" notices, not just filename
-- mismatches.
--
-- Reflects the FULL CURRENT retry-list state, not just this run's own
-- deltas -- every id on the retry list is already force-included in every
-- run's pull (see INatSyncRunner.run's pullIds), so anything still
-- unresolved from a PRIOR run gets re-attempted this run too and, if still
-- unresolved, lands back in this same list -- no separate "read persisted
-- state" step is needed for this to be a real, current work queue.
--
-- HTML (not plain text) specifically so the iNat links (and photo
-- thumbnails) are usable straight from the file -- plain text can't do
-- that. Lives alongside TaxonStore.lua's cache file for consistency. Uses
-- plain io.open, like TaxonStore.lua -- NOT yet confirmed live that
-- writing a brand-new file this way works in Lightroom's Lua sandbox
-- (TaxonStore.lua's own note says the same); wrapped in pcall so a failure
-- here degrades to "couldn't write the report" rather than losing the
-- whole sync summary.
--
-- Returns the file path on success, or nil (with no error) if there was
-- nothing to report or the write failed.
local function writeNeedsAttentionReport(entries)
    if #entries == 0 then
        return nil
    end

    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "local")
    dir = LrPathUtils.child(dir, "WhatIsThisThing")
    local path = LrPathUtils.child(dir, "inat-sync-needs-attention.html")

    local html = {
        "<!doctype html><html><head><meta charset=\"utf-8\">",
        "<title>iNaturalist sync -- needs attention</title>",
        "<style>",
        "body { font-family: -apple-system, sans-serif; margin: 2em; }",
        "h2 { margin-top: 2em; border-bottom: 1px solid #ccc; }",
        ".detail { color: #a33; }",
        ".category { display: inline-block; background: #eef; color: #446; padding: 0.1em 0.5em; "
            .. "border-radius: 0.3em; font-size: 0.85em; vertical-align: middle; }",
        "ul { margin: 0.3em 0; }",
        "code { background: #f0f0f0; padding: 0 0.3em; }",
        "img { display: block; margin: 0.5em 0; }",
        "</style></head><body>",
        "<p>iNaturalist sync -- needs attention -- " .. escapeHtml(LrDate.timeToW3CDate(LrDate.currentTime())) .. "</p>",
        "<p>" .. #entries .. " observation(s) still pending -- to jump to a photo in Lightroom, copy its filename and paste it into "
            .. "the Library Filter bar (or Cmd+F), searching by Filename.</p>",
    }
    for _, e in ipairs(entries) do
        table.insert(html, "<h2>Observation #" .. escapeHtml(e.observationId)
            .. " -- <a href=\"" .. escapeHtml(e.url) .. "\" target=\"_blank\">View on iNat</a> "
            .. "<span class=\"category\">" .. escapeHtml(NEEDS_ATTENTION_LABELS[e.category] or e.category) .. "</span></h2>")
        if e.photoUrl then
            table.insert(html, "<img src=\"" .. escapeHtml(e.photoUrl) .. "\" width=\"150\">")
        end
        if e.detail then
            table.insert(html, "<p class=\"detail\">" .. escapeHtml(e.detail) .. "</p>")
        end
        if e.photos and #e.photos > 0 then
            table.insert(html, "<p>Local photos in this group:</p><ul>")
            for _, p in ipairs(e.photos) do
                table.insert(html, "<li><code>" .. escapeHtml(p.fileName) .. "</code>"
                    .. (p.dateStr and (" (" .. escapeHtml(p.dateStr) .. ")") or " (no capture date)") .. "</li>")
            end
            table.insert(html, "</ul>")
        end
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
-- plain-text, ever-growing log (unlike the Needs Attention HTML report
-- above, which is overwritten each run and only covers currently-pending
-- items). Exists specifically because a run that appears to do "nothing"
-- for some observations previously left NO trace anywhere once the
-- closing dialog was dismissed -- confirmed live as a real diagnosis
-- blocker. Plain text, not HTML, and append-only (not overwritten) --
-- this is a debugging/audit trail across runs, not a work queue.
--
-- Uses plain io.open in append mode, same "not yet confirmed live in
-- Lightroom's Lua sandbox" caveat as writeNeedsAttentionReport/
-- TaxonStore.lua; wrapped in pcall so a failure here never breaks the
-- rest of the summary.
--
-- Returns the file path on success, or nil if there was nothing to log
-- (empty run) or the write failed.
local function writeFullSyncLog(runLog, meta)
    if #runLog == 0 and not (meta.pullDebug and #meta.pullDebug > 0) then
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
    -- Diagnostic trace of the actual pull request(s) -- added 2026-07-24
    -- while chasing a live case where incremental runs kept returning
    -- nothing new despite requests made outside Lightroom, moments later,
    -- against the same window, correctly returning new observations. Logs
    -- exactly what was requested and what iNat said existed, so a repeat
    -- is diagnosable from this file alone rather than guessed at.
    if meta.pullDebug then
        for _, page in ipairs(meta.pullDebug) do
            table.insert(lines, "  [pull] page " .. tostring(page.page) .. " -- " .. tostring(page.resultCount)
                .. " result(s) of " .. tostring(page.totalResults) .. " total -- " .. tostring(page.url))
        end
    end
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

local function formatSummary(counts, needsAttentionCount, reportPath, fullLogPath)
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
    if counts.unresolvedCollisions > 0 then
        table.insert(parts, counts.unresolvedCollisions .. " left unresolved (skipped in the match dialog)")
    end
    if counts.skippedNewLinkConfirmation > 0 then
        table.insert(parts, counts.skippedNewLinkConfirmation .. " new link" .. (counts.skippedNewLinkConfirmation == 1 and "" or "s")
            .. " skipped at confirmation -- will offer again next time")
    end
    if counts.absorbedSiblings > 0 then
        table.insert(parts, counts.absorbedSiblings .. " untagged sibling photo" .. (counts.absorbedSiblings == 1 and "" or "s")
            .. " found elsewhere in the catalog and linked into an existing observation")
    end
    if counts.resolvedViaMergeDialog > 0 then
        table.insert(parts, counts.resolvedViaMergeDialog .. " photo-count mismatch"
            .. (counts.resolvedViaMergeDialog == 1 and "" or "es") .. " resolved via the merge-candidates picker")
    end
    if counts.recoveredTotalLoss > 0 then
        table.insert(parts, counts.recoveredTotalLoss .. " observation" .. (counts.recoveredTotalLoss == 1 and "" or "s")
            .. " recovered (no local photo at all, downloaded from iNat)")
    end
    if counts.recoveredPartialLoss > 0 then
        table.insert(parts, counts.recoveredPartialLoss .. " observation" .. (counts.recoveredPartialLoss == 1 and "" or "s")
            .. " had missing photo(s) downloaded from iNat")
    end
    if counts.declinedDownload > 0 then
        table.insert(parts, counts.declinedDownload .. " download offer" .. (counts.declinedDownload == 1 and "" or "s") .. " declined")
    end
    if counts.downloadFailed > 0 then
        table.insert(parts, counts.downloadFailed .. " download attempt" .. (counts.downloadFailed == 1 and "" or "s") .. " failed")
    end
    if counts.noGoodCandidate > 0 then
        table.insert(parts, counts.noGoodCandidate .. " observation" .. (counts.noGoodCandidate == 1 and "" or "s")
            .. " had no good local candidate (see the Needs Attention report)")
    end
    if counts.fieldChangeNotices > 0 then
        table.insert(parts, counts.fieldChangeNotices .. " already-linked observation" .. (counts.fieldChangeNotices == 1 and "" or "s")
            .. " had iNaturalist data change (quality grade, suggestion, or identification)")
    end
    if counts.removedFromINat > 0 then
        table.insert(parts, counts.removedFromINat .. " previously-pending observation" .. (counts.removedFromINat == 1 and "" or "s")
            .. " no longer exist on iNaturalist (deleted or merged) -- cleared from the retry list")
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

    if needsAttentionCount > 0 then
        message = message .. "\n\n" .. needsAttentionCount .. " observation(s) still need attention"
        if reportPath then
            message = message .. " -- opening the report in your browser now."
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
-- If `options.forceFullPull` is omitted (nil), shows a small pre-flight
-- dialog to ask (see showPreFlightDialog) -- this is now the ONLY entry
-- point for both the old "Sync" and "Full Sync" commands, so the
-- full-vs-incremental choice has to come from somewhere other than "which
-- menu item did you click." Passing it explicitly (true or false) skips
-- the dialog entirely -- used by this file's own mock tests.
function INatSyncRunner.run(options)
    options = options or {}

    LrTasks.startAsyncTask(function()
        local catalog = LrApplication.activeCatalog()
        local username = INatSync.getOrPromptUsername()
        if not username then
            LrDialogs.message("Sync from iNaturalist", "No username provided.", "info")
            return
        end

        local forceFullPull = options.forceFullPull
        if forceFullPull == nil then
            local proceed = false
            LrFunctionContext.callWithContext("INatSyncPreFlight", function(context)
                local props = LrBinding.makePropertyTable(context)
                props.fullSync = false

                local f = LrView.osFactory()

                -- Folds in what used to be the separate "Show iNat Sync
                -- State" one-off diagnostic -- last-sync cursor, pending
                -- retry/mismatch counts, stored username -- as a proper
                -- status section on the one dialog every sync already
                -- shows, rather than a separate menu command nobody
                -- reaches for day to day.
                -- The query cursor (getLastSyncTime) is deliberately shifted
                -- back by a trailing safety margin (see
                -- SYNC_CURSOR_SAFETY_MARGIN_SECONDS) -- displaying that
                -- here always undercounted by up to an hour (confirmed
                -- live 2026-07-31 running syncs back-to-back). Use the
                -- separate, unshifted completion time for this line.
                -- Falls back to the old margin-shifted cursor (undoing the
                -- shift) for installs that synced before this display fix
                -- existed and so don't have lastSyncCompletedAt yet --
                -- otherwise their very next run would wrongly claim "Never
                -- synced before".
                local lastSyncCompletedTime = INatSync.getLastSyncCompletedTime()
                    or (INatSync.getLastSyncTime() and INatSync.getLastSyncTime() + SYNC_CURSOR_SAFETY_MARGIN_SECONDS)
                local lastSyncLine
                if lastSyncCompletedTime then
                    lastSyncLine = "Last synced " .. describeElapsedTime(LrDate.currentTime() - lastSyncCompletedTime)
                else
                    lastSyncLine = "Never synced before"
                end

                local pendingCount = #INatSync.getPendingRetryIds() + #INatSync.getPendingMismatchIds()
                local pendingLine
                if pendingCount > 0 then
                    pendingLine = pendingCount .. " observation" .. (pendingCount == 1 and "" or "s")
                        .. " still pending from a previous run"
                else
                    pendingLine = "Nothing pending"
                end

                local statusBox = f:group_box {
                    title = "Sync Status",
                    fill_horizontal = 1,
                    f:column {
                        spacing = f:control_spacing() / 2,
                        f:static_text { title = lastSyncLine },
                        f:static_text { title = pendingLine },
                        f:static_text { title = "iNat account: " .. tostring(INatSync.getUsername() or "(not set)") },
                    },
                }

                local contents = f:column {
                    bind_to_object = props,
                    spacing = f:control_spacing(),
                    statusBox,
                    f:spacer { height = 8 },
                    f:radio_button {
                        title = "Incremental -- only what's changed since the last sync",
                        value = LrView.bind("fullSync"),
                        checked_value = false,
                    },
                    f:radio_button {
                        title = "Full -- re-pull your entire iNaturalist observation history",
                        value = LrView.bind("fullSync"),
                        checked_value = true,
                    },
                }

                local result = LrDialogs.presentModalDialog {
                    title = "Sync from iNaturalist",
                    contents = contents,
                    actionVerb = "Sync",
                    cancelVerb = "Cancel",
                }

                if result == "ok" then
                    proceed = true
                    forceFullPull = props.fullSync
                end
            end)
            if not proceed then
                return
            end
        end

        local destDir = INatRecovery.recoveryDestDir()
        local lastSyncTime = not forceFullPull and INatSync.getLastSyncTime() or nil
        local updatedSinceStr = lastSyncTime and toUtcW3CDate(lastSyncTime) or nil
        local retryIds = INatSync.getPendingRetryIds()
        local pendingMismatchIds = INatSync.getPendingMismatchIds()
        local syncStartTime = LrDate.currentTime()

        -- Both retryIds and pendingMismatchIds need to be force-included in
        -- the pull regardless of the updated_since cursor (pullAndMatch's
        -- retryIds parameter already does exactly this re-fetch-and-merge,
        -- so both lists just ride along in it, deduplicated). Together
        -- these two lists (now the single retry mechanism every deferred
        -- outcome in this file lands on) are what makes the Needs
        -- Attention report below a genuine CURRENT work queue, not just a
        -- per-run diff -- anything still pending from a previous run gets
        -- re-attempted this run too.
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
        local runLog = {}
        local function logObservation(observation, outcome, detail)
            table.insert(runLog, {
                observationId = observation.id,
                taxonName = observation.taxon and observation.taxon.name,
                outcome = outcome,
                detail = detail,
            })
        end

        -- Every currently-pending outcome (unresolved collisions, declined/
        -- failed downloads, no-good-candidate notices, filename mismatches)
        -- lands here -- one unified list feeding writeNeedsAttentionReport,
        -- instead of the old mismatch-only log. See that function's own
        -- comment for why this is a full current-state work queue, not just
        -- this run's deltas.
        local needsAttention = {}

        local progressDone = false

        local runOk, runErr = LrTasks.pcall(function()
            -- Shows exactly what's being requested -- full history vs. a
            -- cutoff date -- for the whole pull phase (not just a fleeting
            -- initial caption the per-page update below would otherwise
            -- overwrite in under a second). Useful ongoing transparency
            -- either way, and specifically because a consistent "always full
            -- history" total across supposedly-incremental runs was
            -- otherwise invisible until you went looking for it.
            local pullDescription = updatedSinceStr and ("updated since " .. updatedSinceStr)
                or (forceFullPull and "full history (forced)" or "full history (first run)")

            local pullOk, report = LrTasks.pcall(INatSync.pullAndMatch, username, updatedSinceStr, pullIds, function(pulledSoFar)
                progressScope:setCaption("Pulling observations, " .. pullDescription .. "... (" .. pulledSoFar .. " so far)")
            end)

            if not pullOk then
                error("Couldn't pull observations: " .. tostring(report))
            end

            local counts = {
                applied = 0, linkedOnly = 0, repairedAncestry = 0, skippedDisagreement = 0, failed = 0,
                unresolvedCollisions = 0, absorbedSiblings = 0, resolvedViaMergeDialog = 0, skippedNewLinkConfirmation = 0,
                recoveredTotalLoss = 0, recoveredPartialLoss = 0, declinedDownload = 0, downloadFailed = 0, noGoodCandidate = 0,
                fieldChangeNotices = 0, removedFromINat = 0,
            }

            -- An id on the retry/mismatch list that iNat has nothing for
            -- at all (deleted or merged away since it was flagged) would
            -- otherwise stay "pending" forever -- nothing else ever clears
            -- it off the list except a successful match, which can never
            -- happen for an observation that no longer exists (confirmed
            -- live 2026-07-31: a pair of duplicate observations the user
            -- had since cleaned up on iNat stayed silently stuck, with no
            -- trace anywhere, across several incremental runs). Cleared
            -- here, once, with an actual note -- not left to just vanish
            -- from the pending count with no explanation.
            for _, id in ipairs(report.goneObservationIds or {}) do
                INatSync.markRetryOutcome(id, true)
                INatSync.markMismatchOutcome(id, false)
                counts.removedFromINat = counts.removedFromINat + 1
                logObservation({ id = id }, "removed_from_inat",
                    "No longer found on iNaturalist (deleted or merged) -- cleared from the retry list")
            end

            -- Total distinct observations reviewed/applied this run --
            -- used to append "(Observation N of Total)" to each
            -- per-observation dialog's title, so a long run gives some
            -- sense of progress through the batch (2026-07-31, requested
            -- while working through a real 23-observation sync). Computed
            -- once, upfront: noLocalMatchObservations and toResolveManually
            -- are already finalized here; toApply grows later as
            -- collisions resolve, but each of THOSE observations is
            -- already counted via toResolveManually (exactly one entry
            -- per observation, see pullAndMatch), so counting
            -- report.toApply's own starting length avoids double-counting.
            local totalObservationsThisRun =
                #report.noLocalMatchObservations + #report.toResolveManually + #report.toApply
            local observationProgressIndex = 0
            local function nextProgressLabel()
                observationProgressIndex = observationProgressIndex + 1
                return string.format(" (Observation %d of %d)", observationProgressIndex, totalObservationsThisRun)
            end

            -- Bucket 3/4: every observation with NO existing local match at
            -- all. `noLocalMatchUncertain[obs.id]` (see INatSync.pullAndMatch)
            -- is the signal that distinguishes the two buckets: true means
            -- matching was UNCERTAIN (a real candidate existed but got
            -- claimed by another observation this run, or a same-species
            -- closestMiss was close enough in time to plausibly be the same
            -- photo mis-correlated -- bucket 4, notify + retry, never
            -- auto-offer a download that might duplicate a real local photo);
            -- false/nil means confidently nothing local exists at all (bucket
            -- 3, safe to offer a download) -- this INCLUDES a closestMiss
            -- that's too far away in time to be relevant (a coincidental,
            -- unrelated same-species sighting from a different occasion,
            -- confirmed live 2026-07-29: a 64+ hour closestMiss was wrongly
            -- withholding a download offer for a genuinely new photo before
            -- this distinction existed) -- `reason`, if present, is still
            -- threaded through as supplementary log detail either way.
            for _, obs in ipairs(report.noLocalMatchObservations) do
                if progressScope:isCanceled() then
                    logObservation(obs, "canceled_before_apply")
                else
                    local progressLabel = nextProgressLabel()
                    local reason = report.noLocalMatchReasons[obs.id]
                    if reason and report.noLocalMatchUncertain[obs.id] then
                        progressScope:setCaption("Reviewing: " .. tostring(obs.taxon and obs.taxon.name or obs.id))
                        if showNoGoodCandidateNotice(obs, reason, progressLabel) == "abort" then
                            progressScope:cancel()
                        end
                        INatSync.markRetryOutcome(obs.id, false)
                        counts.noGoodCandidate = counts.noGoodCandidate + 1
                        logObservation(obs, "no_good_candidate", reason)
                        table.insert(needsAttention, {
                            observationId = obs.id,
                            url = "https://www.inaturalist.org/observations/" .. tostring(obs.id),
                            category = "no_good_candidate",
                            detail = reason,
                            photoUrl = firstPhotoUrl(obs),
                        })
                    else
                        progressScope:setCaption("Reviewing: " .. tostring(obs.taxon and obs.taxon.name or obs.id))
                        local downloadOutcome = offerDownload(
                            obs, "No local photo found at all for " .. describeObservation(obs) .. ". Download iNat's own copy(s)?",
                            progressLabel
                        )
                        if downloadOutcome == "accepted" then
                            local recoverOk, recoverResult = LrTasks.pcall(INatRecovery.recoverTotalLoss, obs, username, destDir)
                            if recoverOk and recoverResult.applied then
                                -- Clears any prior retry-list entry -- this
                                -- observation may have been declined (or
                                -- failed to download) on an earlier run and
                                -- landed on iNatPendingRetryIds then; a
                                -- successful recovery now needs to clear
                                -- that, same as every other successful-apply
                                -- path in this file already does (the
                                -- markRetryOutcome(..., true) call right
                                -- after a normal applyOk, below).
                                INatSync.markRetryOutcome(obs.id, true)
                                counts.recoveredTotalLoss = counts.recoveredTotalLoss + 1
                                logObservation(obs, "recovered_total_loss",
                                    recoverResult.imported .. " photo(s) downloaded" .. (reason and (" -- note: " .. reason) or ""))
                            else
                                counts.downloadFailed = counts.downloadFailed + 1
                                INatSync.markRetryOutcome(obs.id, false)
                                local detail = recoverOk and "no photos could be downloaded" or tostring(recoverResult)
                                logObservation(obs, "download_failed", detail)
                                table.insert(needsAttention, {
                                    observationId = obs.id,
                                    url = "https://www.inaturalist.org/observations/" .. tostring(obs.id),
                                    category = "download_failed",
                                    detail = detail,
                                    photoUrl = firstPhotoUrl(obs),
                                })
                            end
                        else
                            counts.declinedDownload = counts.declinedDownload + 1
                            INatSync.markRetryOutcome(obs.id, false)
                            logObservation(obs, "declined_download", reason)
                            table.insert(needsAttention, {
                                observationId = obs.id,
                                url = "https://www.inaturalist.org/observations/" .. tostring(obs.id),
                                category = "declined_download",
                                detail = "No local photo found -- download declined." .. (reason and (" (" .. reason .. ")") or ""),
                                photoUrl = firstPhotoUrl(obs),
                            })
                        end
                    end
                end
            end

            local allMatches = {}
            for _, match in ipairs(report.toApply) do
                table.insert(allMatches, match)
            end

            -- Shared by all three "this observation never got resolved"
            -- paths below (skipped/unreached in a normally-processed
            -- cluster, every observation in a cluster reached only after
            -- Abort Sync fired partway through, and every observation in a
            -- cluster never reached at all because the run was already
            -- canceled beforehand) -- each only differs in WHICH
            -- observations and what reason text to use. Deliberately takes
            -- an explicit observation list, not the cluster itself, since
            -- the first case is a SUBSET of cluster.observations, not all
            -- of it.
            local function markUnresolvedCollision(observationsToMark, cluster, groupLabels, reasonPrefix)
                for _, obs in ipairs(observationsToMark) do
                    INatSync.markRetryOutcome(obs.id, false)
                    local detail = reasonPrefix .. " -- candidate local photo(s) in this cluster: "
                        .. table.concat(groupLabels, "; ")
                    if cluster.claimedAwayReason then
                        detail = detail .. " -- also already claimed this run: " .. cluster.claimedAwayReason
                    end
                    logObservation(obs, "unresolved_collision", detail)
                    table.insert(needsAttention, {
                        observationId = obs.id,
                        url = "https://www.inaturalist.org/observations/" .. tostring(obs.id),
                        category = "unresolved_collision",
                        detail = detail,
                        photoUrl = firstPhotoUrl(obs),
                    })
                end
                -- Deliberately #observationsToMark, NOT (#cluster.groups -
                -- #resolved) -- confirmed live 2026-07-30: a cluster can
                -- have more candidate LOCAL GROUPS than colliding
                -- OBSERVATIONS (an extra nearby photo that isn't actually
                -- any of these iNat posts, entirely normal), which left the
                -- group-based count positive even when every observation
                -- the user was actually shown got resolved -- an
                -- "unresolved" count with no corresponding log/report entry
                -- at all, since only observations ever get logged. This
                -- must always match what's actually logged above.
                counts.unresolvedCollisions = counts.unresolvedCollisions + #observationsToMark
            end

            if not progressScope:isCanceled() then
                -- Tracks which local groups the user has already assigned
                -- via the picker earlier in THIS SAME loop (keyed by the
                -- group table itself) -- pullAndMatch computes every
                -- cluster's candidate list in one pass, BEFORE any
                -- interactive picking happens, so two separate
                -- observations of the SAME species can be handed the SAME
                -- overlapping candidate pool. Without this, picking a
                -- photo for an earlier observation doesn't remove it from
                -- a later, same-species observation's own dialog moments
                -- later (confirmed live, 2026-07-31: a photo already
                -- assigned to one observation was still offered as a
                -- choice for a later one).
                local groupsClaimedByPicker = {}

                for clusterIndex, cluster in ipairs(report.toResolveManually) do
                    local remainingGroups = {}
                    for _, g in ipairs(cluster.groups) do
                        if not groupsClaimedByPicker[g] then
                            table.insert(remainingGroups, g)
                        end
                    end
                    -- Diagnostic only: lets the "nothing left" case below
                    -- say WHY, instead of implying a dialog was shown and
                    -- skipped when none ever appeared.
                    local candidatesAllClaimedElsewhere = #remainingGroups == 0 and #cluster.groups > 0
                    cluster.groups = remainingGroups

                    local resolved, unresolvedObservations, groupLabels, aborted =
                        resolveClusterManually(cluster, nextProgressLabel())
                    for _, pair in ipairs(resolved) do
                        -- Picking a specific candidate among several IS the
                        -- confirmation -- the apply loop below must not ask
                        -- again via confirmNewLink for a match that was just
                        -- decided here (2026-07-31, real live complaint:
                        -- confirming the same match twice in a row).
                        pair.resolvedViaPicker = true
                        groupsClaimedByPicker[pair.group] = true
                        table.insert(allMatches, pair)
                    end
                    -- Anything left unresolved (including explicit "Skip For
                    -- Now") goes on the retry list, so it's offered again
                    -- next run regardless of the `updated_since` cursor --
                    -- see the doc comment on resolveClusterManually for why
                    -- this matters.
                    markUnresolvedCollision(unresolvedObservations, cluster, groupLabels,
                        candidatesAllClaimedElsewhere and "every candidate was already assigned to an earlier observation this run"
                            or "skipped in the match dialog")

                    if aborted then
                        progressScope:cancel()
                        -- "Abort Sync" fired partway through THIS cluster --
                        -- every OTHER cluster after it in the list never got
                        -- a chance to run at all, and needs the exact same
                        -- retry-list treatment as the "canceled before
                        -- manual resolution even started" branch below, or
                        -- their observations would silently fall off the
                        -- retry list just because the abort happened
                        -- partway through, not at the very start.
                        for i = clusterIndex + 1, #report.toResolveManually do
                            local laterCluster = report.toResolveManually[i]
                            markUnresolvedCollision(
                                laterCluster.observations, laterCluster, describeCandidateGroups(laterCluster.groups),
                                "run aborted mid-resolution"
                            )
                        end
                        break
                    end
                end
            else
                -- The whole run was canceled before manual resolution even
                -- started -- every observation in every remaining cluster is
                -- unresolved, and needs the same retry-list treatment.
                for _, cluster in ipairs(report.toResolveManually) do
                    markUnresolvedCollision(
                        cluster.observations, cluster, describeCandidateGroups(cluster.groups),
                        "run canceled before manual resolution"
                    )
                end
            end

            local canceledDuringApply = false

            -- Once set (via the picker dialog's "Skip All Remaining" button
            -- -- see MergeCandidatesDialog.lua), no further mismatches this
            -- run trigger the interactive picker -- they just fall through
            -- to the normal Needs Attention report, same as before this
            -- feature existed. Exists specifically because a single Full
            -- Sync can surface dozens of these at once (confirmed live: 101
            -- in one real run) -- popping up that many modal dialogs in a
            -- row with no way out would be worse than just reviewing the
            -- report afterward.
            local skipAllRemainingMismatchDialogs = false

            -- Same "could be dozens in one Full Sync" concern as
            -- skipAllRemainingMismatchDialogs above, for
            -- showFieldChangeNotice's own "Skip All Remaining" button --
            -- separate flag since the two dialogs are independent (a
            -- change notice never gates anything, so muting it has no
            -- bearing on whether mismatch dialogs should also be muted).
            local skipAllRemainingFieldChangeNotices = false

            for i, match in ipairs(allMatches) do
                if progressScope:isCanceled() then
                    canceledDuringApply = true
                    for j = i, #allMatches do
                        -- Already protected from being silently skipped
                        -- forever by canceledDuringApply itself (below,
                        -- prevents the sync cursor from advancing, so the
                        -- next run naturally re-pulls and re-matches these
                        -- regardless) -- but explicitly retry-listing here
                        -- too matches the same belt-and-suspenders style
                        -- already used at the other two Abort Sync points
                        -- (mid-discovery), rather than relying on a single
                        -- mechanism (2026-07-31, consistency fix).
                        INatSync.markRetryOutcome(allMatches[j].observation.id, false)
                        logObservation(allMatches[j].observation, "canceled_before_apply")
                    end
                    break
                end

                progressScope:setCaption("Applying: " .. tostring(match.observation.taxon and match.observation.taxon.name or match.observation.id))
                progressScope:setPortionComplete(i - 1, #allMatches)

                -- Confirming even a "we feel good about it" unambiguous
                -- match, but ONLY the first time a photo is linked to a
                -- given observation -- an already-linked observation being
                -- routinely re-verified every run should stay silent and
                -- fast, or every regular Sync would turn back into a full
                -- manual review. No bulk-accept escape hatch -- explicitly
                -- not wanted; every first-time link gets its own
                -- confirmation, every run -- UNLESS it was already
                -- confirmed moments ago via the collision picker
                -- (resolvedViaPicker, see above) -- picking a specific
                -- candidate among several already IS that confirmation;
                -- asking again here was a real, confirmed-live redundancy
                -- (2026-07-31).
                local progressLabel = nextProgressLabel()
                local shouldApply = true
                if match.group.iNatObservationId == nil and not match.resolvedViaPicker then
                    local confirmOutcome = confirmNewLink(match, progressLabel)
                    if confirmOutcome == "abort" then
                        progressScope:cancel()
                    end
                    if confirmOutcome ~= "confirmed" then
                        shouldApply = false
                        counts.skippedNewLinkConfirmation = counts.skippedNewLinkConfirmation + 1
                        INatSync.markRetryOutcome(match.observation.id, false)
                        logObservation(match.observation,
                            confirmOutcome == "abort" and "aborted_new_link_confirmation" or "skipped_new_link_confirmation")
                    end
                end

                if shouldApply then
                    local forceRecheck = pendingMismatchLookup[match.observation.id]
                    local applyOk, result = LrTasks.pcall(
                        INatSync.applyMatch, match.group, match.observation, username, lastSyncTime,
                        report.photosByFilename, forceRecheck, report.untaggedSingletonsSortedByTime
                    )

                    if applyOk then
                        INatSync.markRetryOutcome(match.observation.id, true)
                        counts[result.status] = (counts[result.status] or 0) + 1
                        counts.absorbedSiblings = counts.absorbedSiblings + (result.absorbedCount or 0)

                        -- Purely informational -- see showFieldChangeNotice's
                        -- own comment. result.changes is always empty for a
                        -- first-time link (match.group.iNatObservationId was
                        -- nil going into applyMatch), so this can't double up
                        -- with confirmNewLink's own review of the same event.
                        if result.changes and #result.changes > 0 and not skipAllRemainingFieldChangeNotices then
                            progressScope:setCaption(
                                "Reviewing data change: " .. tostring(match.observation.taxon and match.observation.taxon.name or match.observation.id)
                            )
                            counts.fieldChangeNotices = counts.fieldChangeNotices + 1
                            local noticeOutcome = showFieldChangeNotice(match.observation, result.changes, true, progressLabel)
                            if noticeOutcome == "skipAll" then
                                skipAllRemainingFieldChangeNotices = true
                            elseif noticeOutcome == "abort" then
                                progressScope:cancel()
                            end
                        end

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

                            -- Bucket 3's second half: the merge-candidates
                            -- search above found nothing to merge (or the
                            -- user declined it) -- offer to download the
                            -- specific missing photo(s) from iNat instead,
                            -- rather than only ever logging a mismatch and
                            -- waiting for a separate command to fix it.
                            local downloadCategory = nil
                            if not resolvedInteractively and worthOffering and not skipAllRemainingMismatchDialogs then
                                local missingCount = result.mismatch.missingLocally and #result.mismatch.missingLocally or nil
                                local promptText = missingCount
                                    and string.format(
                                        "iNat has %d photo(s) not found locally for %s. Download them?",
                                        missingCount, describeObservation(match.observation)
                                    )
                                    or string.format(
                                        "iNat reports more photos than found locally for %s. Download the missing one(s)?",
                                        describeObservation(match.observation)
                                    )
                                local downloadOutcome = offerDownload(match.observation, promptText, progressLabel)
                                if downloadOutcome == "accepted" then
                                    local recoverOk, recoverResult = LrTasks.pcall(
                                        INatRecovery.recoverPartialLoss, match.group, match.observation, username, destDir
                                    )
                                    if recoverOk and recoverResult.applied then
                                        resolvedInteractively = true
                                        counts.recoveredPartialLoss = counts.recoveredPartialLoss + 1
                                        counts.absorbedSiblings = counts.absorbedSiblings + recoverResult.imported
                                    elseif recoverOk and recoverResult.skipped then
                                        -- Couldn't safely correlate iNat's
                                        -- filenames to its download URLs --
                                        -- falls through to the normal
                                        -- mismatch report below, same as if
                                        -- no download had been offered at
                                        -- all.
                                    else
                                        counts.downloadFailed = counts.downloadFailed + 1
                                        downloadCategory = "download_failed"
                                    end
                                else
                                    counts.declinedDownload = counts.declinedDownload + 1
                                    downloadCategory = "declined_download"
                                end
                            end

                            if not resolvedInteractively then
                                table.insert(needsAttention, {
                                    observationId = match.observation.id,
                                    url = "https://www.inaturalist.org/observations/" .. tostring(match.observation.id),
                                    category = downloadCategory or "filename_mismatch",
                                    detail = describeMismatch(match.observation.id, result.mismatch):gsub("^Observation #%d+ %-%- ", ""),
                                    photoUrl = firstPhotoUrl(match.observation),
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
                                resolvedInteractively and "mismatch resolved"
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
            end

            -- Only advance the cursor on a full, uncanceled run -- a partial
            -- run (canceled mid-pull or mid-apply) should re-cover the same
            -- window next time rather than risk skipping anything that
            -- wasn't reached.
            if not progressScope:isCanceled() and not canceledDuringApply then
                INatSync.setLastSyncTime(syncStartTime - SYNC_CURSOR_SAFETY_MARGIN_SECONDS)
                INatSync.setLastSyncCompletedTime(syncStartTime)
            end

            local reportPath = writeNeedsAttentionReport(needsAttention)
            if reportPath then
                LrHttp.openUrlInBrowser("file://" .. reportPath)
            end
            local syncType = forceFullPull and "Full Sync" or "Sync"
            local fullLogPath = writeFullSyncLog(runLog, { syncType = syncType, pullDebug = report.pullDebug })

            -- Clear the progress HUD BEFORE showing the final summary, not
            -- after -- previously this only happened once the modal summary
            -- dialog below had already been closed, and the HUD was
            -- confirmed live (2026-07-31, aborting partway through a
            -- 64-observation run) to still be visible even after dismissing
            -- that dialog. All real work for this run is finished by this
            -- point regardless of how it ended (completed, or Abort Sync
            -- fired earlier), so there's nothing left for the progress bar
            -- to reflect.
            progressScope:done()
            progressDone = true

            LrDialogs.message("Sync from iNaturalist", formatSummary(counts, #needsAttention, reportPath, fullLogPath), "info")
        end)

        -- Safety net for a genuine crash that occurred before the point
        -- above was reached (see the comment on runOk/runErr) -- guarded so
        -- a normal, successful run (which already called progressScope:done()
        -- earlier, right before its own summary dialog) doesn't call it
        -- a second time.
        if not progressDone then
            progressScope:done()
        end

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
