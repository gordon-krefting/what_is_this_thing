local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrPrefs = import 'LrPrefs'
local LrPathUtils = import 'LrPathUtils'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))
local ColorCode = dofile(LrPathUtils.child(_PLUGIN.path, "ColorCode.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))

-- catalog:findPhotosWithProperty requires the plug-in's toolkit identifier
-- as a plain string (unlike get/setPropertyForPlugin, which also accept
-- the _PLUGIN object) -- must match Info.lua's LrToolkitIdentifier exactly.
local TOOLKIT_ID = "org.krefting.whatisthisthing"

-- Used only by the sibling-absorption time-based fallback in applyMatch,
-- when iNat's original_filename data isn't usable at all for a given
-- observation (confirmed live: a valid, authenticated response can still
-- omit it entirely, unrelated to auth/token expiry -- see
-- getObservationPhotoFilenames). Unlike SPECIES_MATCH_WINDOW_SECONDS
-- below, this isn't derived from a specific confirmed piece of evidence --
-- it's a judgment call that multiple photos of the same (usually
-- stationary/slow) subject,
-- taken in one session, are very likely within a couple of minutes of each
-- other. The real safety net against a false absorption isn't this number
-- being small, it's that the fallback only ever absorbs when the number of
-- candidates found in the window EXACTLY matches the shortfall iNat's own
-- reported photo count reveals -- anything ambiguous is left as a count
-- mismatch instead of guessed.
local SIBLING_TIME_FALLBACK_TOLERANCE_SECONDS = 120

-- Strips a file extension for cross-format filename comparisons -- a local
-- RAW ("DSC_7388.NEF") and whatever iNat has stored (necessarily a JPEG,
-- since iNat doesn't accept RAW uploads) share a base name but never an
-- exact string.
local function stripExtension(filename)
    return filename and filename:match("^(.*)%.[^%.]+$") or filename
end

local INatSync = {}

-- Ranks broad enough that having NO major-rank ancestors is expected and
-- correct, not a sign of a failed ancestry lookup: INaturalist.lua's
-- MAJOR_RANKS only tracks class/order/family/genus, and ancestors are
-- always broader than self, so a photo correctly identified only to Class
-- (or broader -- kingdom/phylum/subphylum) genuinely has nothing to show
-- above it. Without this exclusion, the ancestry-repair check below would
-- misfire on every coarse-rank photo on EVERY future run forever (the flat
-- state is permanent and correct for these, not something a re-fetch would
-- ever change) -- found live: a suspiciously high repair rate on a real
-- sync run prompted double-checking this rather than accepting it at face
-- value.
local RANKS_WHERE_FLAT_ANCESTRY_IS_EXPECTED = {
    kingdom = true, phylum = true, subphylum = true, class = true,
}

-- Converts an iNat-style ISO8601 timestamp ("2008-11-23T12:41:05-08:00")
-- into the same Cocoa-epoch number photo:getRawMetadata('dateTimeOriginal')
-- uses (seconds since midnight UTC, January 1 2001), via
-- LrDate.timeFromComponents's explicit-offset-in-seconds form -- avoids any
-- hand-rolled calendar math (Lua 5.1, Lightroom's runtime, has no reliable
-- UTC-mode os.time). Returns nil if the string doesn't match the expected
-- shape.
local function parseIsoTimestamp(iso)
    if not iso then
        return nil
    end
    local y, mo, d, h, mi, s, offSign, offH, offM = iso:match(
        "^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)([%+%-])(%d+):(%d+)$"
    )
    if not y then
        return nil
    end

    local offsetSeconds = tonumber(offH) * 3600 + tonumber(offM) * 60
    if offSign == "-" then
        offsetSeconds = -offsetSeconds
    end

    return LrDate.timeFromComponents(
        tonumber(y), tonumber(mo), tonumber(d),
        tonumber(h), tonumber(mi), tonumber(s),
        offsetSeconds
    )
end

-- The taxon name to use for MATCHING a local photo's existing tag against
-- an iNat observation -- deliberately the OWNER's OWN FIRST (earliest by
-- created_at) identification, NOT `observation.taxon.name` (iNat's
-- CURRENT identification, which reflects the latest community consensus
-- and can drift after upload for reasons that have nothing to do with
-- which local photo is which). Confirmed live 2026-07-30: a local photo
-- tagged "Charadriiformes" (the order -- what the user's own original ID
-- actually said) failed to auto-resolve against its correct observation
-- because another identifier had since corrected the CURRENT identification
-- to "Charadrius semipalmatus" (species level) -- an exact-string
-- comparison against the current taxon could never match the original tag,
-- even though the original tag is exactly what generated this observation
-- in the first place (via the identify-then-export-then-upload flow). The
-- owner's first identification is the stable anchor for "does this local
-- tag correspond to this iNat post" -- the CURRENT identification remains
-- the right thing to compare against for deciding whether to UPDATE an
-- ALREADY-linked photo's tag (see candidateDiffersFromLocal/applyMatch),
-- a separate concern this does not touch.
--
-- Falls back to observation.taxon.name if the owner has no identification
-- on the observation at all (unusual -- the initial upload's own
-- auto-suggested ID is normally attributed to the owner immediately -- but
-- not impossible for a bare-bones upload).
local function firstIdentificationTaxonName(observation, username)
    local earliest, earliestTime = nil, nil
    for _, ident in ipairs(observation.identifications or {}) do
        if ident.user and ident.user.login == username and ident.taxon and ident.taxon.name then
            local t = parseIsoTimestamp(ident.created_at)
            if t and (not earliestTime or t < earliestTime) then
                earliest = ident.taxon.name
                earliestTime = t
            end
        end
    end
    return earliest or (observation.taxon and observation.taxon.name)
end

-- How far apart (in absolute seconds) a same-named group's capture time
-- and an observation's true instant can be and still count as "the same
-- outing" for findCandidatesByScientificName below. A direct absolute-time
-- comparison, NOT a rendered-calendar-date-string one (an earlier version
-- compared "YYYY-MM-DD" via LrDate.timeToW3CDate on both sides, which had
-- its own midnight-crossing bug -- see DEVELOPMENT_NOTES.md).
--
-- Redesigned 2026-07-31 from a time-first to a species-first matching
-- strategy: live testing repeatedly found the old tight-time-window
-- primary scan (see DEVELOPMENT_NOTES.md) silently claiming a completely
-- unrelated, coincidentally-nearby-in-time photo -- once for a species
-- mismatch on a lone candidate, again for a manual dialog offering the
-- user two candidates that were BOTH the wrong species entirely. The
-- user's own diagnosis, confirmed after discussion: at the volume they
-- actually shoot (a handful of observations per identify session),
-- species alone is almost always enough to find the right local photo,
-- and time proximity is close to noise (as likely off by 2 seconds as 2
-- hours). This constant is now the ONE matching window, applied to every
-- observation via species-first lookup (see findCandidatesByScientificName)
-- -- narrow is fine here specifically BECAUSE species is the hard gate,
-- not a tiered time-first scan with species as a fallback. The user has
-- never seen a real match miss this by more than a day.
local SPECIES_MATCH_WINDOW_SECONDS = 24 * 3600

-- Finds every already-tagged local group sharing the observation's
-- OWNER'S FIRST identification (see firstIdentificationTaxonName --
-- NOT necessarily the observation's current/latest taxon, which can
-- drift after a community correction) within SPECIES_MATCH_WINDOW_SECONDS
-- of its true instant and not already claimed by another observation this
-- run. This is the SOLE local-match discovery mechanism (species-first,
-- not a time-window scan with this as a fallback -- see the redesign note
-- above) -- exact-string comparison only, no rank-aware matching, since a
-- photo identified locally before being uploaded and the owner's own
-- first identification on iNat come from the same event and should match
-- exactly; a rank mismatch there would mean local re-identification drift
-- after upload, a separate, rare problem this doesn't try to solve.
--
-- Returns candidateGroups (every qualifying group, unclaimed), claimedAway
-- (a list of { group, claimedBy } for every qualifying group that WOULD
-- have been a candidate but was already claimed by another observation
-- this run -- so a "no local match" outcome caused by a genuine race for
-- one candidate can say who won it, instead of just reporting "no match"
-- with no way to tell why), and closestMiss (diagnostic only, NOT used
-- for matching -- the closest same-species local group that exists but
-- fell outside the window, or nil if none exists at all). A same-species
-- group outside the window is always treated as confidently unrelated (a
-- different occasion, not a mis-correlated match) -- there is no
-- uncertain/confident distinction here anymore; the only genuinely
-- uncertain outcome is an active claimedAway race.
local function findCandidatesByScientificName(groupsByScientificName, observation, targetTime, claimedGroups, username)
    local candidateGroups = {}
    local claimedAway = {}
    local closestMiss = nil
    local matchName = firstIdentificationTaxonName(observation, username)
    if not (matchName and targetTime) then
        return candidateGroups, claimedAway, closestMiss
    end
    local sameNameGroups = groupsByScientificName[matchName]
    if not sameNameGroups then
        return candidateGroups, claimedAway, closestMiss
    end

    for _, g in ipairs(sameNameGroups) do
        if g.time then
            local delta = math.abs(g.time - targetTime)
            if delta <= SPECIES_MATCH_WINDOW_SECONDS then
                if claimedGroups[g] then
                    table.insert(claimedAway, { group = g, claimedBy = claimedGroups[g] })
                else
                    table.insert(candidateGroups, g)
                end
            elseif not closestMiss or delta < closestMiss.deltaSeconds then
                closestMiss = { deltaSeconds = delta, group = g }
            end
        end
    end

    return candidateGroups, claimedAway, closestMiss
end

-- Turns a `claimedAway` list ({ group, claimedBy }, from
-- findCandidatesByScientificName) into a single human-readable string for
-- the sync log -- e.g. "IMG_0680.JPG already claimed this run by
-- #170277039 (Sphyrapicus varius)". Dedupes by group identity. Returns
-- nil if there's nothing to report.
local function describeClaimedAway(claimedAway)
    if #claimedAway == 0 then
        return nil
    end
    local parts = {}
    local seenGroups = {}
    for _, entry in ipairs(claimedAway) do
        if not seenGroups[entry.group] then
            seenGroups[entry.group] = true
            local filenames = {}
            for _, photo in ipairs(entry.group.photos) do
                table.insert(filenames, photo:getFormattedMetadata("fileName") or "?")
            end
            local claimLabel = "#" .. tostring(entry.claimedBy.id)
            if entry.claimedBy.taxon then
                claimLabel = claimLabel .. " (" .. entry.claimedBy.taxon.name .. ")"
            end
            -- The delta between this group's own capture time and the
            -- claiming observation's declared time -- both entries here
            -- always share the current observation's own species (see
            -- findCandidatesByScientificName), so this is always a
            -- genuine same-species race for one real photo, e.g. two
            -- separate sightings of the same bird uploaded together --
            -- surfacing the delta explicitly still helps make sense of
            -- which claim actually happened first without a separate
            -- lookup.
            local claimantTime = parseIsoTimestamp(entry.claimedBy.time_observed_at)
            if entry.group.time and claimantTime then
                local deltaSeconds = math.abs(entry.group.time - claimantTime)
                local hours = math.floor(deltaSeconds / 3600)
                local minutes = math.floor((deltaSeconds % 3600) / 60)
                claimLabel = claimLabel .. string.format(", %dh %dm away", hours, minutes)
            end
            table.insert(parts, table.concat(filenames, ", ") .. " already claimed this run by " .. claimLabel)
        end
    end
    return table.concat(parts, "; ")
end

-- Temporary diagnostic (2026-07-31): appends one line per claim decision
-- to a fixed log file, so a recurring "already claimed by an implausible
-- observation" report (confirmed live twice now, both cases NOT
-- reproducible from a clean-slate offline repro against the same
-- observations -- see DEVELOPMENT_NOTES.md) can be traced from an actual
-- live run instead of reconstructed after the fact. Remove once the
-- mechanism behind this is confirmed.
--
-- MUST be LrTasks.pcall, not plain pcall -- plain pcall is a C-call
-- boundary that can't yield in Lightroom's Lua 5.1, and file I/O here
-- does yield. First version used plain pcall and silently produced
-- "Yielding is not allowed within a C or metamethod call" on every
-- single call (confirmed live, 2026-07-31, via the error-fallback path
-- below) -- the same documented failure class as INatSyncRunner.lua's
-- own top-level run wrapper, just not yet learned in this file.
local function logClaim(mechanism, group, observation)
    local ok, err = LrTasks.pcall(function()
        local home = LrPathUtils.getStandardFilePath("home")
        local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "local")
        dir = LrPathUtils.child(dir, "WhatIsThisThing")
        local path = LrPathUtils.child(dir, "inat-sync-claim-trace.log")
        local filenames = {}
        for _, photo in ipairs(group.photos) do
            table.insert(filenames, photo:getFormattedMetadata("fileName") or "?")
        end
        local f = assert(io.open(path, "a"))
        f:write(string.format(
            "[%s] group{%s time=%s species=%s} claimed by #%s (%s observed %s)\n",
            mechanism,
            table.concat(filenames, ","),
            tostring(group.time),
            tostring(group.scientificName),
            tostring(observation.id),
            observation.taxon and observation.taxon.name or "?",
            tostring(observation.time_observed_at)
        ))
        f:close()
    end)
    -- The first version of this silently no-op'd on ANY failure -- turned
    -- out the log file never got written at all (first real live test,
    -- 2026-07-31), with no way to tell why. This fallback writes straight
    -- to $HOME itself (skipping the Photos/local/WhatIsThisThing
    -- subdirectory, in case creating/finding THAT nested path is somehow
    -- the actual problem) via the same LrPathUtils.getStandardFilePath
    -- call already proven to work elsewhere in this file, so a real error
    -- message surfaces somewhere instead of vanishing a second time.
    if not ok then
        LrTasks.pcall(function()
            local home = LrPathUtils.getStandardFilePath("home")
            local f = io.open(LrPathUtils.child(home, "inat-claim-trace-error.txt"), "a")
            if f then
                f:write(tostring(err) .. "\n")
                f:close()
            end
        end)
    end
end

-- Human-readable description of findCandidatesByScientificName's
-- diagnostic-only closestMiss return value -- e.g. "closest same-species
-- local match (DSC_2483.NEF) is 1h 0m away, outside the 24h matching
-- window". Only ever consulted when describeClaimedAway found nothing to
-- say (see pullAndMatch), so this is specifically for the "a same-named
-- local group exists, but not within SPECIES_MATCH_WINDOW_SECONDS" case
-- -- as opposed to "no local group shares this species at all", which
-- stays a bare "no_local_match" with no further detail, since there's
-- nothing more specific to say. Always describes a confidently-unrelated
-- sighting now (a different occasion, not a possible mis-correlation) --
-- see SPECIES_MATCH_WINDOW_SECONDS's own comment for why the
-- uncertain/confident distinction this used to drive was dropped. Returns
-- nil if there's nothing to report.
local function describeClosestMiss(closestMiss)
    if not closestMiss then
        return nil
    end
    local filenames = {}
    for _, photo in ipairs(closestMiss.group.photos) do
        table.insert(filenames, photo:getFormattedMetadata("fileName") or "?")
    end
    local hours = math.floor(closestMiss.deltaSeconds / 3600)
    local minutes = math.floor((closestMiss.deltaSeconds % 3600) / 60)
    return string.format(
        "closest same-species local match (%s) is %dh %dm away, outside the %dh matching window",
        table.concat(filenames, ", "), hours, minutes, SPECIES_MATCH_WINDOW_SECONDS / 3600
    )
end

-- Groups every photo in the catalog by its local `observationId` (photos
-- identified together in one batch, via the normal identify flow) --
-- ungrouped photos (never run through this plugin, e.g. the historical
-- iNat uploads this feature exists to backfill) become their own singleton
-- group. Each group's `time` is its earliest member's capture time; groups
-- with no capture-time metadata at all are dropped (nothing to correlate
-- against). Also builds a fast `byINatId` index for groups that already
-- carry an `iNatObservationId` from a previous sync run.
--
-- Returns byINatId (a table keyed by iNat observation id -> group), photosByFilename (a table keyed by
-- stripped filename -> single photo, for absorbing untagged sibling photos
-- into an already-matched group -- see applyMatch. Ambiguous stems (more
-- than one local photo sharing the same base filename, e.g. a camera that
-- reset its numbering across different cards/years) are deliberately left
-- out rather than guessing, since silently writing to the wrong photo is
-- worse than not absorbing at all), untaggedSingletonsSortedByTime (a list
-- of { time, photo } for every photo that's never been through this
-- plugin's identify flow at all -- no local observationId, no
-- scientificName -- sorted by time, for the time-based sibling-absorption
-- fallback used when iNat's filename data isn't usable -- see applyMatch),
-- groupsByScientificName (a table keyed by scientificName -> list of
-- already-tagged groups sharing that name -- the primary, species-first
-- lookup structure for matching a single observation -- see
-- findCandidatesByScientificName/pullAndMatch).
local function buildLocalIndex(catalog)
    local byLocalObservationId = {}
    local groups = {}
    local photosByFilename = {}
    local ambiguousFilenames = {}

    -- catalog:findPhotos with a custom-field searchDesc was confirmed
    -- non-functional in this environment across 8 tried syntax variants
    -- (see DEVELOPMENT_NOTES.md); findPhotosWithProperty, already relied
    -- on live elsewhere (SetCultivar.lua, EditTaxonInfo.lua), instead
    -- gives the set of photos that have ever been through this plugin's
    -- identify flow directly, without a per-photo property read. Used
    -- here to skip the 4 getPropertyForPlugin calls below (scientificName,
    -- commonName, taxonRank, iNatObservationId) for the vast majority of
    -- a real catalog (~20k of ~21.7k photos, confirmed live) that were
    -- never tagged at all -- these were the dominant cost of the ~50s
    -- delay before a sync's first dialog, confirmed live against a real
    -- catalog and unrelated to how many observations actually changed.
    --
    -- Checks every field this function actually reads below, independently
    -- -- not just observationId -- since they aren't always all written
    -- together in every real code path (e.g. INatSync.applyMatch's
    -- "skippedDisagreement" branch can set iNatObservationId alone, with
    -- no observationId, on a group matched purely by time+filename and
    -- never independently identified). Each findPhotosWithProperty call
    -- replaces thousands of individual property reads with one filtered
    -- list, so checking all 5 fields here is still far cheaper than the
    -- per-photo reads it lets the loop below skip.
    local isTagged = {}
    for _, fieldId in ipairs({ "observationId", "iNatObservationId", "scientificName", "commonName", "taxonRank" }) do
        for _, photo in ipairs(catalog:findPhotosWithProperty(TOOLKIT_ID, fieldId)) do
            isTagged[photo] = true
        end
    end

    for _, photo in ipairs(catalog:getAllPhotos()) do
        local localId = isTagged[photo] and photo:getPropertyForPlugin(_PLUGIN, "observationId") or nil
        local group
        if localId then
            group = byLocalObservationId[localId]
            if not group then
                group = { photos = {} }
                byLocalObservationId[localId] = group
                table.insert(groups, group)
            end
        else
            group = { photos = {} }
            table.insert(groups, group)
        end
        table.insert(group.photos, photo)

        local stem = stripExtension(photo:getFormattedMetadata("fileName"))
        if stem then
            if photosByFilename[stem] and photosByFilename[stem] ~= photo then
                ambiguousFilenames[stem] = true
            else
                photosByFilename[stem] = photo
            end
        end
    end

    for stem in pairs(ambiguousFilenames) do
        photosByFilename[stem] = nil
    end

    local byINatId = {}
    for _, group in ipairs(groups) do
        local earliest = nil
        -- Every photo in a tagged group shares one localId (by construction
        -- above -- an untagged photo always starts its own singleton group),
        -- so checking just the first photo reliably tells whether ANY of
        -- this group's custom fields could possibly be set, without reading
        -- them on every photo to find out.
        local tagged = isTagged[group.photos[1]]
        for _, photo in ipairs(group.photos) do
            local t = photo:getRawMetadata("dateTimeOriginal")
            if t and (not earliest or t < earliest) then
                earliest = t
            end
            if tagged then
                if not group.scientificName then
                    group.scientificName = photo:getPropertyForPlugin(_PLUGIN, "scientificName")
                end
                if not group.commonName then
                    group.commonName = photo:getPropertyForPlugin(_PLUGIN, "commonName")
                end
                if not group.rank then
                    group.rank = photo:getPropertyForPlugin(_PLUGIN, "taxonRank")
                end
                if not group.iNatObservationId then
                    group.iNatObservationId = photo:getPropertyForPlugin(_PLUGIN, "iNatObservationId")
                end
            end
        end
        group.time = earliest
        if group.iNatObservationId then
            byINatId[group.iNatObservationId] = group
        end
    end

    local untaggedSingletonsSortedByTime = {}
    -- Every already-tagged group, keyed by its scientificName -- the
    -- primary, species-first lookup structure for matching a single
    -- observation (see findCandidatesByScientificName/pullAndMatch).
    local groupsByScientificName = {}
    for _, group in ipairs(groups) do
        if group.time and group.scientificName then
            local list = groupsByScientificName[group.scientificName]
            if not list then
                list = {}
                groupsByScientificName[group.scientificName] = list
            end
            table.insert(list, group)
        end
        -- A group with no local observationId is always a singleton (by
        -- construction above -- there's no way for two never-identified
        -- photos to share one), so "#group.photos == 1 and no
        -- scientificName" reliably means "never run through this plugin's
        -- identify flow at all".
        if group.time and #group.photos == 1 and not group.scientificName and not group.iNatObservationId then
            table.insert(untaggedSingletonsSortedByTime, { time = group.time, photo = group.photos[1] })
        end
    end
    table.sort(untaggedSingletonsSortedByTime, function(a, b) return a.time < b.time end)

    return byINatId, photosByFilename, untaggedSingletonsSortedByTime, groupsByScientificName
end

-- Binary-searches a time-sorted list (e.g. untaggedSingletonsSortedByTime)
-- for every entry within `tolerance` seconds of `targetTime`. Used only by
-- applyMatch's sibling-absorption time-based fallback (see
-- SIBLING_TIME_FALLBACK_TOLERANCE_SECONDS) -- the primary match discovery
-- in pullAndMatch is species-first now (see findCandidatesByScientificName)
-- and no longer needs a time-sorted scan of ALL groups.
local function findCandidateGroups(sortedByTime, targetTime, tolerance)
    local lo, hi = 1, #sortedByTime
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if sortedByTime[mid].time < targetTime - tolerance then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    local candidates = {}
    local i = lo
    while sortedByTime[i] and sortedByTime[i].time <= targetTime + tolerance do
        table.insert(candidates, sortedByTime[i])
        i = i + 1
    end
    return candidates
end

-- Pulls observations (all of them if `updatedSince` is nil, i.e. a
-- first-ever run; only changed ones since then otherwise) plus anything
-- still on the retry list (see markRetryOutcome below), and matches each
-- to a local photo group. Species-first (see findCandidatesByScientificName's
-- own comment for the 2026-07-31 redesign rationale): for each observation
-- not already linked (see the fast-path check below), every already-tagged
-- local group sharing its OWNER'S FIRST identification within
-- SPECIES_MATCH_WINDOW_SECONDS is a candidate. Untagged groups (never been
-- through this plugin's identify flow) are never candidates at all -- the
-- actual workflow this plugin is built around always identifies a photo
-- BEFORE exporting it to iNat, so a freshly-created observation's real
-- local match is always already tagged.
--
-- Returns { toApply = { {group, observation}, ... }, toResolveManually =
-- { {groups, observations, claimedAwayReason}, ... }, noLocalMatchObservations
-- = { observation, ... }, noLocalMatchReasons, noLocalMatchUncertain,
-- photosByFilename, untaggedSingletonsSortedByTime = (both see
-- buildLocalIndex) }. `toApply` entries are unambiguous and ready for
-- applyMatch() (photosByFilename and untaggedSingletonsSortedByTime should
-- both be passed through to each call, to absorb untagged sibling photos);
-- `toResolveManually` entries need a user decision (more than one
-- same-species local group within the window, no time signal reliable
-- enough to auto-pick) -- always exactly one observation per entry now
-- (species-first matching means two DIFFERENT-species observations can
-- never compete for the same local group, so there's no more
-- multi-observation collision to gather -- see the redesign note above).
-- `claimedAwayReason` (a string, or nil) explains any candidate that would
-- ALSO have been offered here but was already claimed by another
-- observation this run, so a collision missing its obviously-correct
-- candidate is traceable rather than just showing whichever wrong
-- candidates remain (confirmed live: observation #384538787's real match,
-- already tagged with the right species, was entirely absent from its own
-- collision's candidate list). `noLocalMatchObservations` is the FULL
-- observation list (not just a count) specifically so a full per-run log
-- can record which observations these were, not just how many.
-- `noLocalMatchReasons` (keyed by observation id) is the same claimed-away
-- explanation for the #candidateGroups == 0 case specifically (confirmed
-- live: a real, otherwise untraceable case where the right local group
-- existed but had already been claimed by an unrelated, earlier-processed
-- observation). `noLocalMatchUncertain` (keyed by observation id -> true/
-- nil) is the caller-facing signal for whether that reason is genuinely
-- uncertain (an active race this run for a real candidate -- claimedAway)
-- vs. confidently empty (nothing within the window at all, or a
-- same-species match too far away to be relevant -- closestMiss is always
-- confident now, see findCandidatesByScientificName's own comment).
-- `goneObservationIds` lists any id from `retryIds` that iNat had nothing
-- for at all (deleted or merged away since it was flagged) -- the caller
-- should clear these off both the retry and mismatch lists, since nothing
-- else ever will.
function INatSync.pullAndMatch(username, updatedSince, retryIds, onProgress)
    local catalog = LrApplication.activeCatalog()
    local byINatId, photosByFilename, untaggedSingletonsSortedByTime, groupsByScientificName =
        buildLocalIndex(catalog)

    local observations, pullDebug = INaturalist.getMyObservations(username, updatedSince, onProgress)

    -- Any id on the retry/mismatch list that iNat has genuinely nothing
    -- for anymore (deleted or merged away since it was flagged, confirmed
    -- live 2026-07-31 for a pair of accidentally-duplicated observations)
    -- would otherwise sit on that list FOREVER -- getObservationsByIds
    -- just silently returns fewer results than requested, nothing else
    -- ever clears an id off the list except a successful match. Tracked
    -- here so the caller can clear it and actually tell the user, instead
    -- of an unresolvable id being invisibly retried, forever, every run.
    local goneObservationIds = {}
    if retryIds and #retryIds > 0 then
        local seen = {}
        for _, obs in ipairs(observations) do
            seen[obs.id] = true
        end
        for _, obs in ipairs(INaturalist.getObservationsByIds(retryIds)) do
            if not seen[obs.id] then
                table.insert(observations, obs)
                seen[obs.id] = true
            end
        end
        for _, id in ipairs(retryIds) do
            if not seen[id] then
                table.insert(goneObservationIds, id)
            end
        end
    end

    local toApply = {}
    local toResolveManually = {}
    local noLocalMatchObservations = {}
    -- Keyed by observation id -> a human-readable explanation, populated
    -- ONLY when a "no local match" outcome was caused by a genuine race for
    -- one candidate group that got claimed by another observation first
    -- (see claimedGroups below) -- otherwise there's no way to tell "truly
    -- nothing nearby" apart from "the right photo existed but something
    -- else grabbed it first," confirmed live as a real, hard-to-diagnose
    -- case (observation #384538806's candidate group went to an earlier-
    -- processed, unrelated observation purely by coincidental time
    -- proximity).
    local noLocalMatchReasons = {}
    -- Keyed by observation id -> true only when the "no local match"
    -- outcome above should be treated as UNCERTAIN (worth a cautious
    -- notice, never an auto-download offer) rather than confidently empty
    -- (safe to offer a download). Only ever true for a claimedAway reason
    -- (a real, within-window candidate exists RIGHT NOW, just already
    -- assigned to another observation this run -- downloading over that
    -- risks a genuine duplicate); a closestMiss reason is always
    -- confident now -- see findCandidatesByScientificName's own comment
    -- for why that distinction was dropped.
    local noLocalMatchUncertain = {}
    local handled = {}

    -- Tracks which local groups have already been assigned to some
    -- observation THIS run (keyed by the group table itself), so a group
    -- claimed early doesn't keep showing up as an available candidate for
    -- a later observation of the same species. Confirmed live as a real
    -- bug (pre-dating the species-first redesign): a photo already
    -- unambiguously matched to one observation was still being offered as
    -- a candidate to a later, unrelated one, purely because nothing ever
    -- marked it as spoken for.
    local claimedGroups = {}

    for _, observation in ipairs(observations) do
        if not handled[observation.id] then
            handled[observation.id] = true

            -- iNatObservationId is stored (and looked up) as a string --
            -- observation.id comes back from JSON.decode as a number, and
            -- would never match a string-keyed table otherwise. Found via
            -- the mock test never matching on a second sync run.
            local fastGroup = byINatId[tostring(observation.id)]
            if fastGroup then
                table.insert(toApply, { group = fastGroup, observation = observation })
                claimedGroups[fastGroup] = observation
                logClaim("fastpath", fastGroup, observation)
            else
                local time = parseIsoTimestamp(observation.time_observed_at)
                local candidateGroups, claimedAway, closestMiss =
                    findCandidatesByScientificName(groupsByScientificName, observation, time, claimedGroups, username)

                if #candidateGroups == 0 then
                    table.insert(noLocalMatchObservations, observation)
                    local claimedAwayText = describeClaimedAway(claimedAway)
                    noLocalMatchReasons[observation.id] = claimedAwayText or describeClosestMiss(closestMiss)
                    if claimedAwayText then
                        noLocalMatchUncertain[observation.id] = true
                    end
                elseif #candidateGroups == 1 then
                    table.insert(toApply, { group = candidateGroups[1], observation = observation })
                    claimedGroups[candidateGroups[1]] = observation
                    logClaim("species-match", candidateGroups[1], observation)
                else
                    -- More than one same-species local group within the
                    -- window -- no time signal reliable enough to auto-pick
                    -- (see SPECIES_MATCH_WINDOW_SECONDS's own comment), so
                    -- this always goes to manual review. Always exactly one
                    -- observation per entry -- species-first matching means
                    -- two DIFFERENT-species observations can never compete
                    -- for the same local group, so there is no more
                    -- multi-observation collision to gather here. Sorted
                    -- closest-in-time first -- time is no longer trusted
                    -- enough to auto-pick, but it's still the best available
                    -- hint for which candidate to default to/consider first.
                    table.sort(candidateGroups, function(a, b)
                        return math.abs(a.time - time) < math.abs(b.time - time)
                    end)
                    table.insert(toResolveManually, {
                        groups = candidateGroups,
                        observations = { observation },
                        claimedAwayReason = describeClaimedAway(claimedAway),
                    })
                end
            end
        end
    end

    return {
        toApply = toApply,
        toResolveManually = toResolveManually,
        noLocalMatchObservations = noLocalMatchObservations,
        noLocalMatchReasons = noLocalMatchReasons,
        noLocalMatchUncertain = noLocalMatchUncertain,
        photosByFilename = photosByFilename,
        untaggedSingletonsSortedByTime = untaggedSingletonsSortedByTime,
        pullDebug = pullDebug,
        goneObservationIds = goneObservationIds,
    }
end

-- True if `observation`'s taxon differs from the local group's current
-- tag in any way that matters -- scientific name, common name, OR rank --
-- not just scientific name. Found live as a real gap: a photo whose
-- scientific name already matched but whose COMMON NAME had drifted stale
-- (e.g. from an earlier resolution path picking a different common name
-- than iNat's current preferred_common_name) was silently never corrected,
-- since the old scientific-name-only check saw nothing to update and
-- applyIdentification never ran. Rank compares with the same
-- nil-means-species convention used elsewhere in this codebase (see
-- KeywordWriter.applyIdentification).
local function candidateDiffersFromLocal(observation, group)
    if not observation.taxon then
        return false
    end
    if observation.taxon.name ~= group.scientificName then
        return true
    end
    if observation.taxon.preferred_common_name ~= group.commonName then
        return true
    end
    local observedRank = observation.taxon.rank or "species"
    local localRank = group.rank or "species"
    return observedRank ~= localRank
end

-- Human-readable label for iNat's quality_grade values, matching iNat's
-- own UI terminology -- confirmed live 2026-07-30: showing the raw API
-- value ("needs_id") in the field-change notice (INatSyncRunner.lua) read
-- oddly next to the expected "Research Grade"-style wording. Falls back
-- to the raw value for anything unrecognized (iNat has only ever exposed
-- these three), rather than guessing at a new label.
local QUALITY_GRADE_LABELS = {
    casual = "Casual",
    needs_id = "Needs ID",
    research = "Research Grade",
}
local function describeQualityGrade(grade)
    if not grade then
        return "(none)"
    end
    return QUALITY_GRADE_LABELS[grade] or grade
end

-- Detects a "someone suggested a different ID and I haven't responded"
-- state -- distinct from INaturalist.observationAgreesWithMe, which only
-- asks whether the OWNER's own current identification (if any) agrees
-- with the community. This instead looks for another identifier's CURRENT
-- identification, dated after the owner's own most recent identification
-- on this observation (or the owner never having identified it at all),
-- whose taxon differs from what the owner last said -- i.e. someone moved
-- the ID since the owner last looked, and the owner hasn't followed up.
-- Needs actual chronological comparison, not lexicographic string
-- comparison of the raw `created_at` values -- confirmed live these carry
-- different per-identifier UTC offsets (e.g. "+05:30" vs "-04:00"), which
-- a plain string comparison can't reliably order -- so this reuses
-- parseIsoTimestamp (already relied on elsewhere in this file for exactly
-- that reason) rather than comparing strings directly.
-- Returns a short human-readable summary ("escol suggests Florilinus
-- (leading)"), or nil if there's nothing unreviewed.
local function describeUnrespondedSuggestion(observation, username)
    local ownLatestTaxonName, ownLatestTime = nil, nil
    for _, ident in ipairs(observation.identifications or {}) do
        if ident.user and ident.user.login == username then
            local t = parseIsoTimestamp(ident.created_at)
            if t and (not ownLatestTime or t > ownLatestTime) then
                ownLatestTime = t
                ownLatestTaxonName = ident.taxon and ident.taxon.name
            end
        end
    end

    local best, bestTime = nil, nil
    for _, ident in ipairs(observation.identifications or {}) do
        if ident.current and ident.user and ident.user.login ~= username
            and ident.taxon and ident.taxon.name ~= ownLatestTaxonName then
            local t = parseIsoTimestamp(ident.created_at)
            if t and (not ownLatestTime or t > ownLatestTime) and (not bestTime or t > bestTime) then
                best = ident
                bestTime = t
            end
        end
    end

    if not best then
        return nil
    end
    return (best.user.login or "someone") .. " suggests " .. best.taxon.name
        .. " (" .. tostring(best.category) .. ")"
end

-- Applies one resolved { group, observation } match: first absorbs any
-- untagged sibling photos (see below), always writes the iNat link fields,
-- and applies the metadata update via the existing
-- KeywordWriter.applyIdentification write path if the user agrees with
-- iNat's current ID (see INaturalist.observationAgreesWithMe) and either
-- the local tag differs in scientific name, common name, or rank (see
-- candidateDiffersFromLocal), a sibling was just absorbed, OR the local tag
-- is right but its keyword ancestry chain is flat/incomplete (see
-- KeywordWriter.hasFullAncestry -- repairs photos whose ancestry lookup
-- silently failed during an earlier bulk operation, confirmed live as a
-- real issue with some backfilled photos); checks for a group-membership
-- mismatch (and therefore sibling absorption, see below) only on a
-- first-time link or when the observation has changed since last sync (to
-- avoid re-checking every historical group on every run otherwise).
--
-- Untagged sibling absorption: the matching unit is one local "group"
-- (photos sharing a local observationId) per iNat observation, so if only
-- ONE of several local photos of the same subject was ever run through
-- this plugin's identify flow, the others have no local observationId at
-- all and are invisible to matching -- confirmed live (two untagged onion
-- photos, same iNat observation as an already-linked third, never got
-- linked no matter how many times sync ran). Since the mismatch check
-- below already fetches iNat's photo filenames for the SAME observation,
-- that one fetch is reused for both purposes rather than doubling the API
-- call. A candidate is only absorbed if it's genuinely untagged (no
-- existing scientificName or observationId of its own) -- a photo that's
-- already been deliberately identified as something else is left alone
-- and still reported as a mismatch, never silently merged.
--
-- `forceRecheck` previously existed, wired to Full Sync so it would
-- re-examine EVERY already-linked group on EVERY run (built to fix the
-- "onion" case above, where the group had already been linked before
-- absorption existed) -- removed 2026-07-24 once confirmed live that it
-- made Full Sync's cost scale with the user's ENTIRE observation history,
-- every single run, forever (the direct cause of Full Sync taking
-- noticeably longer each time as the account grew). Reintroduced the same
-- day in a much narrower form: callers now pass `forceRecheck = true` only
-- for a specific observation id already known to be mismatched (a
-- persisted, bounded list -- see getPendingMismatchIds/markMismatchOutcome
-- below, same pattern as the retry list), not as a blanket "is this Full
-- Sync" flag. This keeps the cost proportional to the CURRENT mismatch
-- backlog (which should shrink over time as things get resolved), not the
-- user's entire history -- while still letting a previously-flagged group
-- get a fresh look every run until it's actually fixed, e.g. after a
-- comparison-logic bug fix like the filename-count-gate one below.
--
-- May error (network failure, etc.) -- callers should wrap this in
-- LrTasks.pcall and drive the retry-list bookkeeping (markRetryOutcome)
-- off whether it succeeded, since this function does not swallow errors
-- itself.
--
-- Returns { status = "applied" | "repairedAncestry" | "linkedOnly" |
-- "skippedDisagreement", mismatch = nil or { missingLocally, missingOnINat }
-- (lists of filenames) or { countMismatch = { localCount, iNatCount,
-- candidatesFoundNearby } } (when filenames weren't usable at all -- see
-- the time-based fallback below), absorbedCount = N, checkedMismatch =
-- true/false (whether a mismatch check was actually attempted this call --
-- callers should only update the pending-mismatch list off this, not off
-- `mismatch == nil` alone, since that's also true when no check ran at
-- all), changes = a list of human-readable "Field: old -> new" strings,
-- purely informational (never gates the write above -- if matching is
-- already correct there's no legitimate reason to decline a routine field
-- update, so callers should just show these as an FYI, not a
-- confirmation), always empty for a first-time link (group.iNatObservationId
-- was nil going in -- that already gets its own dedicated review
-- elsewhere, showing this too would be redundant) }.
function INatSync.applyMatch(group, observation, username, lastSyncAt, photosByFilename, forceRecheck, untaggedSingletonsSortedByTime)
    local catalog = LrApplication.activeCatalog()
    local photos = group.photos
    local wasAlreadyLinked = group.iNatObservationId ~= nil
    local observationUrl = "https://www.inaturalist.org/observations/" .. tostring(observation.id)

    local observationUpdatedAt = parseIsoTimestamp(observation.updated_at)
    local shouldCheckMismatch = forceRecheck or not wasAlreadyLinked
        or (lastSyncAt and observationUpdatedAt and observationUpdatedAt > lastSyncAt)

    local iNatFilenames = shouldCheckMismatch and INaturalist.getObservationPhotoFilenames(observation.id) or nil

    local absorbedCount = 0
    if iNatFilenames and photosByFilename then
        local currentFilenames = {}
        for _, photo in ipairs(photos) do
            currentFilenames[stripExtension(photo:getFormattedMetadata("fileName"))] = true
        end
        for _, fn in ipairs(iNatFilenames) do
            local stem = stripExtension(fn)
            if not currentFilenames[stem] then
                local candidatePhoto = photosByFilename[stem]
                if candidatePhoto
                    and not candidatePhoto:getPropertyForPlugin(_PLUGIN, "observationId")
                    and not candidatePhoto:getPropertyForPlugin(_PLUGIN, "scientificName") then
                    table.insert(photos, candidatePhoto)
                    currentFilenames[stem] = true
                    absorbedCount = absorbedCount + 1
                end
            end
        end
    end

    -- Fallback when iNat's filename data isn't usable at all for this
    -- observation (see getObservationPhotoFilenames -- confirmed live this
    -- can happen on an otherwise-valid, authenticated response, unrelated
    -- to auth/token expiry). The photo COUNT is still reliable even then,
    -- so if iNat reports more photos than the group currently has, fall
    -- back to a tight time-window search against the group's own capture
    -- time instead of a filename match. Only absorbs when the number of
    -- untagged candidates found in the window EXACTLY matches the
    -- shortfall -- anything else is ambiguous (could easily include an
    -- unrelated nearby photo, the same false-collision risk as the
    -- frog/skipper case elsewhere in this file) and is left as a count
    -- mismatch for manual attention instead of guessed.
    --
    -- Only a POSITIVE shortfall (iNat has more than local) is ever worth
    -- flagging -- the local group having MORE photos than iNat is normal,
    -- not a problem (confirmed by the user: not every photo taken gets
    -- uploaded), so that direction is never reported as a mismatch.
    local countMismatch = nil
    if shouldCheckMismatch and not iNatFilenames and untaggedSingletonsSortedByTime and group.time then
        local iNatCount = INaturalist.getObservationPhotoCount(observation.id)
        if iNatCount then
            local shortfall = iNatCount - #photos
            if shortfall > 0 then
                local rawCandidates = findCandidateGroups(
                    untaggedSingletonsSortedByTime, group.time, SIBLING_TIME_FALLBACK_TOLERANCE_SECONDS
                )
                -- untaggedSingletonsSortedByTime is built ONCE at the start
                -- of the run, before this observation's own match (if it
                -- started as a genuinely untagged singleton -- the common
                -- first-time-sync case) gets identified -- so the group's
                -- OWN photo(s) can still appear in that list and, since
                -- group.time IS exactly their own capture time (delta 0),
                -- can match as a "candidate for themselves". Confirmed live
                -- via a real bug: this silently self-absorbed (duplicate
                -- insert, no real fix) instead of ever reporting the
                -- genuine mismatch, or wrongly inflated the candidate count
                -- past a real sibling's own exact-shortfall match. Must
                -- exclude anything already in `photos` before comparing
                -- against the shortfall.
                local candidates = {}
                for _, candidate in ipairs(rawCandidates) do
                    local alreadyInGroup = false
                    for _, p in ipairs(photos) do
                        if p == candidate.photo then
                            alreadyInGroup = true
                            break
                        end
                    end
                    if not alreadyInGroup then
                        table.insert(candidates, candidate)
                    end
                end
                if #candidates == shortfall then
                    for _, candidate in ipairs(candidates) do
                        table.insert(photos, candidate.photo)
                        absorbedCount = absorbedCount + 1
                    end
                else
                    countMismatch = { localCount = #photos, iNatCount = iNatCount, candidatesFoundNearby = #candidates }
                end
            end
        end
    end

    local agrees = INaturalist.observationAgreesWithMe(observation, username)
    local status

    local needsSpeciesUpdate = agrees and (candidateDiffersFromLocal(observation, group) or absorbedCount > 0)
    local needsAncestryRepair = agrees and observation.taxon and not needsSpeciesUpdate
        and not RANKS_WHERE_FLAT_ANCESTRY_IS_EXPECTED[observation.taxon.rank]
        and not KeywordWriter.hasFullAncestry(photos[1])

    if needsSpeciesUpdate or needsAncestryRepair then
        local ancestry = INaturalist.getMajorAncestry(observation.taxon.id)
        local candidate = {
            id = observation.taxon.id,
            scientificName = observation.taxon.name,
            commonName = observation.taxon.preferred_common_name,
            rank = observation.taxon.rank,
        }
        KeywordWriter.applyIdentification(photos, candidate, ancestry)
        status = needsSpeciesUpdate and "applied" or "repairedAncestry"
    elseif not agrees then
        status = "skippedDisagreement"
    else
        status = "linkedOnly"
    end

    local suggestedId = describeUnrespondedSuggestion(observation, username)

    -- Purely informational diff of what's about to change on an
    -- ALREADY-linked observation -- never gates the write below (per the
    -- user: if matching is already correct, there's no legitimate reason
    -- to decline a routine field update, so this is an FYI notice, not a
    -- confirmation). Read BEFORE the write below overwrites them. Only
    -- populated for already-linked groups -- a first-time link already
    -- gets its own dedicated review (confirmNewLink, INatSyncRunner.lua),
    -- so showing this too on the very same run would be redundant.
    local changes = {}
    if wasAlreadyLinked then
        if needsSpeciesUpdate then
            if observation.taxon.name ~= group.scientificName then
                table.insert(changes, string.format("Species: %s -> %s", group.scientificName or "(none)", observation.taxon.name))
            end
            if observation.taxon.preferred_common_name ~= group.commonName then
                table.insert(changes, string.format(
                    "Common name: %s -> %s", group.commonName or "(none)", observation.taxon.preferred_common_name or "(none)"
                ))
            end
            local observedRank = observation.taxon.rank or "species"
            local localRank = group.rank or "species"
            if observedRank ~= localRank then
                table.insert(changes, string.format("Rank: %s -> %s", localRank, observedRank))
            end
        end
        local oldQualityGrade = photos[1]:getPropertyForPlugin(_PLUGIN, "iNatQualityGrade")
        if oldQualityGrade ~= observation.quality_grade then
            table.insert(changes, string.format(
                "Quality grade: %s -> %s", describeQualityGrade(oldQualityGrade), describeQualityGrade(observation.quality_grade)
            ))
        end
        local oldSuggestedId = photos[1]:getPropertyForPlugin(_PLUGIN, "iNatSuggestedId")
        if oldSuggestedId ~= suggestedId then
            table.insert(changes, string.format("Suggested ID: %s -> %s", oldSuggestedId or "(none)", suggestedId or "(none)"))
        end
    end

    catalog:withWriteAccessDo("Link iNaturalist observation", function()
        for _, photo in ipairs(photos) do
            photo:setPropertyForPlugin(_PLUGIN, "iNatObservationId", tostring(observation.id))
            photo:setPropertyForPlugin(_PLUGIN, "iNatObservationUrl", observationUrl)
            photo:setPropertyForPlugin(_PLUGIN, "iNatQualityGrade", observation.quality_grade)
            photo:setPropertyForPlugin(_PLUGIN, "iNatSuggestedId", suggestedId)
            PendingMetadataSave.markIfNeeded(catalog, photo)
        end
        -- Keeps the color label current every time sync touches a group --
        -- covers plain quality-grade changes (e.g. Needs ID -> Research
        -- Grade) that never go through KeywordWriter.applyIdentification
        -- at all, not just first-time links. See ColorCode.lua. Both
        -- fields passed explicitly (just written above, in THIS same
        -- transaction) -- confirmed live 2026-08-02: reading them back via
        -- getPropertyForPlugin here returned the STALE pre-sync grade, so
        -- a photo that just became Research Grade came out blue instead
        -- of purple.
        ColorCode.applyToPhotos(photos, {
            iNatObservationId = tostring(observation.id),
            iNatQualityGrade = observation.quality_grade,
        })
    end)

    -- Compare base filenames (extension stripped), not exact strings --
    -- confirmed live this was producing a mismatch on essentially EVERY
    -- first-time-linked group: the local file is a RAW (e.g.
    -- "DSC_7388.NEF"), but whatever uploaded it to iNat necessarily
    -- converted it to a JPEG first (iNat doesn't accept RAW), so the
    -- observation's own stored filename is the same base name with a
    -- different extension (e.g. "DSC_7388.jpg") -- an exact-string
    -- comparison could never match those, regardless of whether the photos
    -- actually correspond. Any filename absorbed above is, by construction,
    -- already accounted for on both sides, so it never shows up here.
    --
    -- Only iNat having a photo missing LOCALLY is ever reported -- the
    -- local group having a photo not on iNat is normal, not a mismatch
    -- (confirmed by the user: not every photo taken gets uploaded), so
    -- missingOnINat is tracked for context only and never triggers a
    -- report on its own.
    local mismatch = nil
    if iNatFilenames then
        local localFilenames = {}
        for _, photo in ipairs(photos) do
            localFilenames[stripExtension(photo:getFormattedMetadata("fileName"))] = true
        end
        local iNatSet = {}
        for _, fn in ipairs(iNatFilenames) do
            iNatSet[stripExtension(fn)] = true
        end

        local missingLocally, missingOnINat = {}, {}
        for fn in pairs(iNatSet) do
            if not localFilenames[fn] then
                table.insert(missingLocally, fn)
            end
        end
        for fn in pairs(localFilenames) do
            if not iNatSet[fn] then
                table.insert(missingOnINat, fn)
            end
        end
        -- A name that doesn't match anything locally is only a REAL gap if
        -- iNat genuinely reports MORE photos than the local group has --
        -- confirmed live against a real account: iNat's original_filename
        -- is very often not the real camera filename at all (a literal
        -- "original" placeholder, or a name from an entirely different
        -- source -- Instagram cross-posts, phone-app uploads, hand-typed
        -- descriptive names like "sapsucker"), so a string mismatch alone
        -- proves nothing when the counts already reconcile (every iNat
        -- photo could just be one of the local ones under a different
        -- reported name). Only trust "something's missing locally" when
        -- the count itself confirms there's nowhere for it to be hiding.
        --
        -- Deliberately uses raw counts (#iNatFilenames, #photos), NOT the
        -- deduplicated-by-name set sizes -- confirmed live as a second,
        -- distinct false-positive: virtual copies of the same source photo
        -- share the exact same underlying filename (they're the same
        -- file, different Develop edits), so 3 local photos where 2 are
        -- virtual copies of the first collapse to just 1 unique local
        -- name in the set, even though all 3 genuinely correspond to 3
        -- real, distinct uploads on iNat. Comparing actual photo counts
        -- instead sidesteps name-deduplication entirely on both sides.
        if #missingLocally > 0 and #iNatFilenames > #photos then
            mismatch = { missingLocally = missingLocally, missingOnINat = missingOnINat }
        end
    elseif countMismatch then
        mismatch = { countMismatch = countMismatch }
    end

    return { status = status, mismatch = mismatch, absorbedCount = absorbedCount, checkedMismatch = shouldCheckMismatch, changes = changes }
end

-- The observation ids that failed to apply on a previous run, to retry
-- this run regardless of whether `updated_since` would otherwise surface
-- them again -- see the plan's "external drive isn't always connected"
-- discussion. An id only comes off this list once it actually applies
-- successfully.
function INatSync.getPendingRetryIds()
    local prefs = LrPrefs.prefsForPlugin()
    return prefs.iNatPendingRetryIds or {}
end

function INatSync.markRetryOutcome(observationId, succeeded)
    local existing = INatSync.getPendingRetryIds()
    local updated = {}
    local wasPresent = false
    for _, id in ipairs(existing) do
        if id == observationId then
            wasPresent = true
        else
            table.insert(updated, id)
        end
    end
    if not succeeded then
        table.insert(updated, observationId)
    end
    if succeeded or not wasPresent then
        local prefs = LrPrefs.prefsForPlugin()
        prefs.iNatPendingRetryIds = updated
    end
end

-- The observation ids currently known to have a mismatch (see applyMatch),
-- so future runs keep re-examining just this bounded backlog -- regardless
-- of whether the observation itself has changed on iNat's side -- instead
-- of either (a) never rechecking them again (what happens by default once
-- a group is linked and unchanged) or (b) rechecking the user's ENTIRE
-- history every run (the removed `forceRecheck`-on-Full-Sync behavior).
-- An id only comes off this list once applyMatch actually confirms it's
-- no longer mismatched.
function INatSync.getPendingMismatchIds()
    local prefs = LrPrefs.prefsForPlugin()
    return prefs.iNatPendingMismatchIds or {}
end

-- Callers should only invoke this when the result's `checkedMismatch` was
-- true -- i.e. a check actually ran this call -- never based on
-- `mismatch == nil` alone, since that's also true when applyMatch never
-- looked at all (shouldCheckMismatch false).
function INatSync.markMismatchOutcome(observationId, hasMismatch)
    local existing = INatSync.getPendingMismatchIds()
    local updated = {}
    local wasPresent = false
    for _, id in ipairs(existing) do
        if id == observationId then
            wasPresent = true
        else
            table.insert(updated, id)
        end
    end
    if hasMismatch then
        table.insert(updated, observationId)
    end
    if hasMismatch ~= wasPresent then
        local prefs = LrPrefs.prefsForPlugin()
        prefs.iNatPendingMismatchIds = updated
    end
end

-- iNat username (for the user_id= query param -- not the same as the API
-- token, which authenticates but doesn't by itself identify whose
-- observations to pull). Prompted once, same LrPrefs-backed pattern as the
-- home location / API token elsewhere in this plugin.
function INatSync.getUsername()
    local prefs = LrPrefs.prefsForPlugin()
    return prefs.iNatUsername
end

local function promptForUsername()
    local username = nil

    LrFunctionContext.callWithContext("INatUsernamePrompt", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.username = ""

        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text { title = "Enter your iNaturalist username (used to pull your own observations):" },
            f:edit_field {
                value = LrView.bind("username"),
                width_in_chars = 30,
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "iNaturalist Username",
            contents = contents,
            actionVerb = "Save",
        }

        if result == "ok" and props.username ~= "" then
            username = props.username
        end
    end)

    if username then
        local prefs = LrPrefs.prefsForPlugin()
        prefs.iNatUsername = username
    end
    return username
end

function INatSync.getOrPromptUsername()
    return INatSync.getUsername() or promptForUsername()
end

-- Last-sync cursor, stored as a Cocoa-epoch number (comparable directly
-- against parsed observation timestamps) -- converted to a W3C/ISO8601
-- string via LrDate.timeToW3CDate only at the point of building the
-- `updated_since` query parameter. This is deliberately NOT "the last time
-- you synced" -- INatSyncRunner subtracts a trailing safety margin before
-- storing it here, to re-cover a window iNat's search index might not have
-- caught up on yet (see SYNC_CURSOR_SAFETY_MARGIN_SECONDS there). Use
-- getLastSyncCompletedTime/setLastSyncCompletedTime below for anything
-- human-facing.
function INatSync.getLastSyncTime()
    local prefs = LrPrefs.prefsForPlugin()
    return prefs.lastINatSyncAt
end

function INatSync.setLastSyncTime(time)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.lastINatSyncAt = time
end

-- The actual moment the last sync run completed, unshifted by the query
-- cursor's trailing safety margin -- kept as a separate pref so the
-- pre-flight dialog's "Last synced X ago" line reflects reality rather
-- than always undercounting by up to an hour (confirmed live 2026-07-31:
-- the margin-shifted cursor was being reused for that display text too).
function INatSync.getLastSyncCompletedTime()
    local prefs = LrPrefs.prefsForPlugin()
    return prefs.lastSyncCompletedAt
end

function INatSync.setLastSyncCompletedTime(time)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.lastSyncCompletedAt = time
end

return INatSync
