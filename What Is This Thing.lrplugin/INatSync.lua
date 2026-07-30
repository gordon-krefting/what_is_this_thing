local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrPrefs = import 'LrPrefs'
local LrPathUtils = import 'LrPathUtils'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))

-- How close two capture-time values need to be to count as "the same
-- moment" for matching a local photo to an iNat observation -- tiered,
-- not a single blanket number, because widening the search for EVERY
-- observation has a real cost: it directly increases how often two
-- genuinely unrelated subjects (photographed close together during one
-- outing, not the same thing at all) coincidentally land inside the
-- window and get misread as a candidate match (confirmed live: a frog
-- photo and an unrelated skipper-butterfly observation, 87.77s apart --
-- see the "frog vs. skipper" note further down). Reducing a single
-- blanket tolerance (90 -> 60) only shrinks that coincidence window by a
-- third; it doesn't address why it's applied to every observation in the
-- first place.
--
-- TIGHT_TOLERANCE_SECONDS (2): clock-drift-only headroom, used for the
-- vast majority of observations, which carry genuine sub-minute capture
-- precision.
--
-- TRUNCATED_TOLERANCE_SECONDS (60): only applied to observations whose
-- time_observed_at LOOKS truncated (see looksTimeTruncated below) --
-- confirmed live that iNat sometimes floors (not rounds -- 8:43:56.81
-- showed up as exactly 8:43:00, the same minute) to whole-minute
-- precision, which bounds the worst case at just under 60 seconds. Since
-- truncation always produces exactly :00 seconds, checking for that
-- signature lets the wide window apply only where it's actually needed,
-- instead of blanket-widening the search for every observation and
-- inflating the coincidental-false-collision rate along the way.
local TIGHT_TOLERANCE_SECONDS = 2
local TRUNCATED_TOLERANCE_SECONDS = 60

-- Used only by the sibling-absorption time-based fallback in applyMatch,
-- when iNat's original_filename data isn't usable at all for a given
-- observation (confirmed live: a valid, authenticated response can still
-- omit it entirely, unrelated to auth/token expiry -- see
-- getObservationPhotoFilenames). Unlike the tolerances above, this isn't
-- derived from a specific confirmed piece of evidence -- it's a judgment
-- call that multiple photos of the same (usually stationary/slow) subject,
-- taken in one session, are very likely within a couple of minutes of each
-- other. The real safety net against a false absorption isn't this number
-- being small, it's that the fallback only ever absorbs when the number of
-- candidates found in the window EXACTLY matches the shortfall iNat's own
-- reported photo count reveals -- anything ambiguous is left as a count
-- mismatch instead of guessed.
local SIBLING_TIME_FALLBACK_TOLERANCE_SECONDS = 120

-- True if `isoTimestamp`'s seconds component is exactly zero -- the
-- signature of iNat's whole-minute truncation. A genuine (non-truncated)
-- observation could coincidentally land on a whole minute too (about a
-- 1/60 chance), in which case it gets the wider tolerance for no real
-- reason -- an acceptable, much narrower residual risk compared to
-- widening the search for every single observation regardless.
local function looksTimeTruncated(isoTimestamp)
    local seconds = isoTimestamp and isoTimestamp:match("T%d%d:%d%d:(%d%d)")
    return seconds == "00"
end

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
-- outing" for widenCandidatesByScientificName below. A direct absolute-time
-- comparison, NOT a rendered-calendar-date-string one (an earlier version
-- compared "YYYY-MM-DD" via LrDate.timeToW3CDate on both sides, which had
-- its own midnight-crossing bug -- see DEVELOPMENT_NOTES.md). Briefly
-- removed entirely (unbounded), then reintroduced at 12 hours: unbounded
-- matching is more permissive than needed for the actual clock-skew
-- magnitudes confirmed live (2-6 hours) and risks a large, unwieldy
-- candidate list for a species photographed many times across the whole
-- catalog's history. 12 hours comfortably covers real clock-skew cases
-- while still being narrow enough that two genuinely different sightings
-- of a common species on different days won't usually both qualify.
local WIDENING_TIME_TOLERANCE_SECONDS = 12 * 3600

-- How much further beyond WIDENING_TIME_TOLERANCE_SECONDS a same-species
-- closestMiss can be and still plausibly be the SAME photo, just
-- mis-correlated (e.g. a timezone bug), rather than an unrelated sighting
-- of the same species on a completely different occasion -- used by
-- pullAndMatch to decide whether a "no local match" outcome is genuinely
-- uncertain (worth a cautious notice, never an auto-download offer) or
-- confidently empty (safe to offer a download). Confirmed live 2026-07-29:
-- a closestMiss 64+ hours away was being treated as "uncertain" even
-- though it was obviously just a coincidental same-species photo from
-- days earlier -- every real clock-skew/timezone case actually
-- investigated this session (see the #385810257 writeup) was at most a
-- few hours, nowhere near this. Kept generous enough (24h) to allow for a
-- same-day-but-badly-timezoned mistake without swallowing every unrelated
-- same-species sighting from a different day into "uncertain."
local CLOSEST_MISS_STILL_UNCERTAIN_SECONDS = 24 * 3600

-- Widens a single observation's candidate pool beyond the time window: any
-- already-tagged group sharing the observation's OWNER'S FIRST identification
-- (see firstIdentificationTaxonName -- NOT necessarily the observation's
-- current/latest taxon, which can drift after a community correction)
-- AND within WIDENING_TIME_TOLERANCE_SECONDS of its true instant, not
-- already a candidate and not already claimed by another observation this
-- run, gets added too. Exists specifically for the camera-clock-skew case
-- -- a photo whose true capture time is off by hours never falls inside
-- even the widest time tolerance, so without this it silently becomes "no
-- local match" (or, worse, some UNRELATED photo's mismatched suggestion)
-- despite already carrying the exact right identification. Deliberately
-- only a fallback (not applied when the time window already found
-- something), so it can't turn an already-clean match into an unnecessary
-- collision with some unrelated same-species group elsewhere in the
-- catalog. If more than one same-named group qualifies, they surface
-- together as a normal manual-resolution collision (see
-- pairByScientificName's groupCountByName check) rather than one of them
-- being silently and wrongly auto-applied -- the user picks.
--
-- Mutates and returns `candidateGroups` -- purely additive, so anything
-- the time window already found is untouched. Also returns `claimedAway`
-- (a list of { group, claimedBy } for every qualifying same-named group
-- that WOULD have been a candidate but was already claimed by another
-- observation this run) -- purely diagnostic, so a "no local match"
-- outcome caused by a genuine race for one candidate group (see
-- pullAndMatch's `claimedGroups`) can say who won it, instead of just
-- silently reporting "no match" with no way to tell why.
-- Third return value: diagnostic only, NOT used for matching -- the
-- closest same-scientific-name local group that was found but fell
-- OUTSIDE even the widened tolerance (nil if no same-named group exists
-- locally at all, or if every same-named group already qualified/got
-- claimed). Confirmed live as necessary 2026-07-27: a "no_local_match"
-- outcome with an empty claimedAway (so describeClaimedAway had nothing
-- to say) left no way to tell whether NO local group shared the
-- observation's species at all, or one existed but was just outside the
-- window -- exactly the "camera-clock-skew rescue" case this widening
-- exists for, silently not firing with no trace. Real live case: iNat's
-- own `time_observed_at` for observation #385810257 carried an internal
-- inconsistency (embedded "-04:00" offset vs. its own separately-
-- reported `time_zone_offset` of "-05:00", the latter matching the
-- camera's actual GPS-verified capture instant) -- so the observation's
-- parsed target time was already off by over an hour before local
-- matching even started.
local function widenCandidatesByScientificName(candidateGroups, groupsByScientificName, observation, targetTime, claimedGroups, username)
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

    local alreadyCandidate = {}
    for _, g in ipairs(candidateGroups) do
        alreadyCandidate[g] = true
    end

    for _, g in ipairs(sameNameGroups) do
        if not alreadyCandidate[g] and g.time then
            local delta = math.abs(g.time - targetTime)
            if delta <= WIDENING_TIME_TOLERANCE_SECONDS then
                if claimedGroups[g] then
                    table.insert(claimedAway, { group = g, claimedBy = claimedGroups[g] })
                else
                    table.insert(candidateGroups, g)
                    alreadyCandidate[g] = true
                end
            elseif not closestMiss or delta < closestMiss.deltaSeconds then
                closestMiss = { deltaSeconds = delta, group = g }
            end
        end
    end

    return candidateGroups, claimedAway, closestMiss
end

-- Turns a `claimedAway` list ({ group, claimedBy }, from the primary
-- time-window filter and/or widenCandidatesByScientificName) into a single
-- human-readable string for the sync log -- e.g. "IMG_0680.JPG already
-- claimed this run by #170277039 (Sphyrapicus varius)". Dedupes by group
-- identity (the SAME group can appear twice if it was excluded from the
-- primary window and then found again by the widening scan). Returns nil
-- if there's nothing to report.
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
            table.insert(parts, table.concat(filenames, ", ") .. " already claimed this run by " .. claimLabel)
        end
    end
    return table.concat(parts, "; ")
end

-- Human-readable description of widenCandidatesByScientificName's
-- diagnostic-only closestMiss return value -- e.g. "closest same-species
-- local match (DSC_2483.NEF) is 1h 0m away, outside the 12h widening
-- tolerance". Only ever consulted when describeClaimedAway found nothing
-- to say (see pullAndMatch), so this is specifically for the "a same-
-- named local group exists, but even widening didn't reach it" case --
-- as opposed to "no local group shares this species at all", which
-- stays a bare "no_local_match" with no further detail, since there's
-- nothing more specific to say. Returns nil if there's nothing to
-- report.
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
        "closest same-species local match (%s) is %dh %dm away, outside the %dh widening tolerance",
        table.concat(filenames, ", "), hours, minutes, WIDENING_TIME_TOLERANCE_SECONDS / 3600
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
-- Returns sortedGroups (a list of { photos, time, scientificName,
-- commonName, rank, iNatObservationId }, sorted by time), byINatId (a
-- table keyed by iNat observation id), photosByFilename (a table keyed by
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
-- already-tagged groups sharing that name, for widening a single
-- observation's candidate search beyond the time window -- see
-- pullAndMatch).
local function buildLocalIndex(catalog)
    local byLocalObservationId = {}
    local groups = {}
    local photosByFilename = {}
    local ambiguousFilenames = {}

    for _, photo in ipairs(catalog:getAllPhotos()) do
        local localId = photo:getPropertyForPlugin(_PLUGIN, "observationId")
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
        for _, photo in ipairs(group.photos) do
            local t = photo:getRawMetadata("dateTimeOriginal")
            if t and (not earliest or t < earliest) then
                earliest = t
            end
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
        group.time = earliest
        if group.iNatObservationId then
            byINatId[group.iNatObservationId] = group
        end
    end

    local sortedGroups = {}
    local untaggedSingletonsSortedByTime = {}
    -- Every already-tagged group, keyed by its scientificName -- lets
    -- pullAndMatch widen a single observation's candidate search beyond the
    -- time window (see the "same scientific name and date" widening there)
    -- without a linear scan over every group in the catalog per observation.
    local groupsByScientificName = {}
    for _, group in ipairs(groups) do
        if group.time then
            table.insert(sortedGroups, group)
            if group.scientificName then
                local list = groupsByScientificName[group.scientificName]
                if not list then
                    list = {}
                    groupsByScientificName[group.scientificName] = list
                end
                table.insert(list, group)
            end
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
    table.sort(sortedGroups, function(a, b) return a.time < b.time end)
    table.sort(untaggedSingletonsSortedByTime, function(a, b) return a.time < b.time end)

    return sortedGroups, byINatId, photosByFilename, untaggedSingletonsSortedByTime, groupsByScientificName
end

-- Binary-searches `sortedGroups` (sorted by .time) for every group within
-- `tolerance` seconds of `targetTime`.
local function findCandidateGroups(sortedGroups, targetTime, tolerance)
    local lo, hi = 1, #sortedGroups
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if sortedGroups[mid].time < targetTime - tolerance then
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    local candidates = {}
    local i = lo
    while sortedGroups[i] and sortedGroups[i].time <= targetTime + tolerance do
        table.insert(candidates, sortedGroups[i])
        i = i + 1
    end
    return candidates
end

-- Tries to uniquely pair each candidate local group against one of the
-- colliding iNat observations by comparing the group's existing
-- `scientificName` against each observation's OWNER'S FIRST identification
-- (see firstIdentificationTaxonName -- deliberately NOT each observation's
-- current/latest `taxon.name`, which can drift after a community
-- correction and then never exact-match the local tag that actually
-- generated the upload in the first place -- confirmed live 2026-07-30: a
-- local "Charadriiformes" tag failed to auto-resolve against its own
-- observation once another identifier had since corrected it to
-- "Charadrius semipalmatus"). This is what lets a virtual-copy timestamp
-- collision resolve itself automatically. `candidateGroups` is always
-- already tagged by the time it reaches here (pullAndMatch filters out
-- untagged groups entirely before calling this -- see the comment there),
-- so every group passed in has a name to compare; a group only ends up in
-- leftoverGroups here because its name doesn't uniquely match any of the
-- colliding observations, not because it has no name at all.
--
-- Returns resolved (a list of { group, observation }), leftoverGroups,
-- leftoverObservations.
local function pairByScientificName(candidateGroups, candidateObservations, username)
    local resolved = {}
    local usedGroups, usedObservationIndexes = {}, {}

    -- A group's name is only trusted for auto-resolution when it's ALSO
    -- unique among the other candidate groups -- otherwise (multiple
    -- same-species candidates for one observation, e.g. via the
    -- same-day/same-name widening in pullAndMatch) the loop below would
    -- greedily pair the single observation with whichever group happened
    -- to come first in iteration order and silently drop the other,
    -- equally-plausible candidates instead of surfacing them for manual
    -- review.
    local groupCountByName = {}
    for _, group in ipairs(candidateGroups) do
        if group.scientificName then
            groupCountByName[group.scientificName] = (groupCountByName[group.scientificName] or 0) + 1
        end
    end

    for _, group in ipairs(candidateGroups) do
        if group.scientificName and groupCountByName[group.scientificName] == 1 then
            local matchIndex, matchCount = nil, 0
            for i, obs in ipairs(candidateObservations) do
                if not usedObservationIndexes[i] and firstIdentificationTaxonName(obs, username) == group.scientificName then
                    matchIndex = i
                    matchCount = matchCount + 1
                end
            end
            if matchCount == 1 then
                table.insert(resolved, { group = group, observation = candidateObservations[matchIndex] })
                usedGroups[group] = true
                usedObservationIndexes[matchIndex] = true
            end
        end
    end

    local leftoverGroups, leftoverObservations = {}, {}
    for _, group in ipairs(candidateGroups) do
        if not usedGroups[group] then
            table.insert(leftoverGroups, group)
        end
    end
    for i, obs in ipairs(candidateObservations) do
        if not usedObservationIndexes[i] then
            table.insert(leftoverObservations, obs)
        end
    end

    return resolved, leftoverGroups, leftoverObservations
end

-- Pulls observations (all of them if `updatedSince` is nil, i.e. a
-- first-ever run; only changed ones since then otherwise) plus anything
-- still on the retry list (see markRetryOutcome below), and matches each
-- to a local photo group. Untagged groups (never been through this
-- plugin's identify flow) are never candidates at all -- see the comment
-- at the candidateGroups filter below for why. If the primary time-window
-- search finds nothing at all, the candidate pool falls back to any
-- already-tagged group
-- sharing the observation's scientific name within
-- WIDENING_TIME_TOLERANCE_SECONDS (see widenCandidatesByScientificName)
-- -- specifically for a camera whose clock (or Lightroom's interpretation
-- of it) is off by a few hours, so its true capture time falls outside
-- even the widest time tolerance despite the photo already carrying the
-- exact right identification. Deliberately only a fallback (not applied
-- when the time window already found something), so it can't turn an
-- already-clean match into an unnecessary collision with some unrelated
-- same-species group elsewhere in the catalog.
--
-- Returns { toApply = { {group, observation}, ... }, toResolveManually =
-- { {groups, observations, claimedAwayReason}, ... }, noLocalMatchObservations
-- = { observation, ... }, noLocalMatchReasons, noLocalMatchUncertain,
-- photosByFilename, untaggedSingletonsSortedByTime = (both see
-- buildLocalIndex) }. `toApply` entries are unambiguous and ready for
-- applyMatch() (photosByFilename and untaggedSingletonsSortedByTime should
-- both be passed through to each call, to absorb untagged sibling photos);
-- `toResolveManually` entries need a user decision (more than one plausible
-- local group AND more than one plausible observation collided at the same
-- timestamp, with no existing tag to disambiguate automatically) --
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
-- uncertain (a real candidate exists but is claimed away or plausibly the
-- same photo mis-correlated) vs. safely confident (nothing local at all,
-- or a same-species match too far away in time to be relevant) -- see
-- CLOSEST_MISS_STILL_UNCERTAIN_SECONDS.
function INatSync.pullAndMatch(username, updatedSince, retryIds, onProgress)
    local catalog = LrApplication.activeCatalog()
    local sortedGroups, byINatId, photosByFilename, untaggedSingletonsSortedByTime, groupsByScientificName =
        buildLocalIndex(catalog)

    local observations, pullDebug = INaturalist.getMyObservations(username, updatedSince, onProgress)

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
    -- (safe to offer a download) -- see CLOSEST_MISS_STILL_UNCERTAIN_SECONDS.
    -- Always true for a claimedAway reason (a real, within-tolerance
    -- candidate exists RIGHT NOW, just already assigned elsewhere this
    -- run -- downloading over that risks a genuine duplicate); for a
    -- closestMiss reason, only true when the gap is small enough to
    -- plausibly be the same photo mis-correlated, not just a coincidental
    -- same-species sighting from a different occasion entirely.
    local noLocalMatchUncertain = {}
    local handled = {}

    -- Tracks which local groups have already been assigned to some
    -- observation THIS run (keyed by the group table itself), so a group
    -- claimed early doesn't keep showing up as an available candidate for
    -- later observations -- findCandidateGroups has no memory of this on
    -- its own, it just returns every group within the time window every
    -- time it's called. Confirmed live as a real bug: a photo already
    -- unambiguously matched to one observation was still being offered as
    -- a candidate in a LATER, unrelated collision a minute or two away in
    -- time, purely because nothing ever marked it as spoken for.
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
            else
                local time = parseIsoTimestamp(observation.time_observed_at)
                -- Wide tolerance only for observations that actually show
                -- the truncation signature -- see the tolerance comment
                -- up top for why this isn't just a single blanket number.
                local tolerance = looksTimeTruncated(observation.time_observed_at)
                    and TRUNCATED_TOLERANCE_SECONDS or TIGHT_TOLERANCE_SECONDS
                local rawCandidateGroups = time and findCandidateGroups(sortedGroups, time, tolerance) or {}
                local candidateGroups = {}
                local claimedAway = {}
                for _, g in ipairs(rawCandidateGroups) do
                    -- An untagged group (never been through this plugin's
                    -- identify flow) is never a viable match candidate --
                    -- per the actual workflow this plugin is built around,
                    -- a photo is always identified BEFORE it's exported to
                    -- iNat, so a freshly-created observation's real local
                    -- match is always already tagged (its species might
                    -- still get corrected by iNat's own identification
                    -- process after upload, but SOME tag was always
                    -- present pre-upload). Confirmed live as real noise,
                    -- not just a hypothetical: several genuine collisions
                    -- were offering nothing but unrelated untagged photos
                    -- as "candidates" -- options that could never actually
                    -- be correct, cluttering the dialog and masking that
                    -- the real answer was simply missing (not yet
                    -- matched). Untagged photos remain eligible for the
                    -- SEPARATE sibling-absorption mechanism in applyMatch
                    -- (an untagged sibling of an ALREADY-matched group is a
                    -- different, still-valid case) -- this only excludes
                    -- them from being treated as the primary match for an
                    -- observation.
                    if g.scientificName then
                        if claimedGroups[g] then
                            table.insert(claimedAway, { group = g, claimedBy = claimedGroups[g] })
                        else
                            table.insert(candidateGroups, g)
                        end
                    end
                end
                -- Only a FALLBACK for observations the time window found
                -- nothing for -- an observation that already has a clean
                -- time-based match (unambiguous or a genuine multi-way
                -- collision) is left alone, so this can't turn an
                -- already-working match into an unnecessary collision with
                -- some unrelated same-species-same-day group elsewhere in
                -- the catalog.
                local closestMiss = nil
                if #candidateGroups == 0 then
                    local widenedGroups, widenedClaimedAway, widenedClosestMiss = widenCandidatesByScientificName(
                        candidateGroups, groupsByScientificName, observation, time, claimedGroups, username
                    )
                    candidateGroups = widenedGroups
                    closestMiss = widenedClosestMiss
                    for _, entry in ipairs(widenedClaimedAway) do
                        table.insert(claimedAway, entry)
                    end
                end

                if #candidateGroups == 0 then
                    table.insert(noLocalMatchObservations, observation)
                    local claimedAwayText = describeClaimedAway(claimedAway)
                    noLocalMatchReasons[observation.id] = claimedAwayText or describeClosestMiss(closestMiss)
                    if claimedAwayText then
                        noLocalMatchUncertain[observation.id] = true
                    elseif closestMiss then
                        noLocalMatchUncertain[observation.id] = closestMiss.deltaSeconds <= CLOSEST_MISS_STILL_UNCERTAIN_SECONDS
                    end
                elseif #candidateGroups == 1 then
                    table.insert(toApply, { group = candidateGroups[1], observation = observation })
                    claimedGroups[candidateGroups[1]] = observation
                else
                    -- Genuine collision: gather every other not-yet-handled
                    -- pulled observation within tolerance of this same
                    -- moment, so a multi-way collision is resolved (or
                    -- queued) once, not once per colliding observation.
                    local collisionObservations = { observation }
                    for _, other in ipairs(observations) do
                        if other ~= observation and not handled[other.id] then
                            local otherTime = parseIsoTimestamp(other.time_observed_at)
                            if otherTime and math.abs(otherTime - time) <= tolerance then
                                table.insert(collisionObservations, other)
                                handled[other.id] = true
                            end
                        end
                    end

                    local resolved, leftoverGroups, leftoverObservations =
                        pairByScientificName(candidateGroups, collisionObservations, username)

                    for _, pair in ipairs(resolved) do
                        table.insert(toApply, pair)
                        claimedGroups[pair.group] = pair.observation
                    end

                    if #leftoverGroups > 0 and #leftoverObservations > 0 then
                        table.insert(toResolveManually, {
                            groups = leftoverGroups,
                            observations = leftoverObservations,
                            -- A candidate that would have been available
                            -- here was already claimed by another
                            -- observation before this one got its turn --
                            -- surfaced live: a genuine, otherwise correct
                            -- match (#384538787's actual photo) can be
                            -- missing from a collision's candidate list
                            -- for exactly this reason, with no clue why
                            -- unless this is threaded through (the
                            -- noLocalMatchReasons diagnostic only covered
                            -- the #candidateGroups == 0 case, not "some
                            -- candidates remain, but a better one is gone").
                            claimedAwayReason = describeClaimedAway(claimedAway),
                        })
                    elseif #leftoverObservations > 0 then
                        -- More colliding observations than candidate local
                        -- groups -- the extras have no local photo at all.
                        for _, leftoverObs in ipairs(leftoverObservations) do
                            table.insert(noLocalMatchObservations, leftoverObs)
                        end
                    end
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
        end
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
-- `updated_since` query parameter.
function INatSync.getLastSyncTime()
    local prefs = LrPrefs.prefsForPlugin()
    return prefs.lastINatSyncAt
end

function INatSync.setLastSyncTime(time)
    local prefs = LrPrefs.prefsForPlugin()
    prefs.lastINatSyncAt = time
end

return INatSync
