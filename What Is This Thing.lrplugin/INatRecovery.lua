-- Recovery logic for "Sync from iNaturalist": downloads iNat's own copy of
-- photos that have no local counterpart at all, or fills in specific
-- photos missing from an already-matched local group -- see the design
-- plan and DEVELOPMENT_NOTES.md for the full rationale (iNat caps every
-- stored photo at 2048px on the long edge regardless of source, so these
-- are accepted placeholders, not a substitute for a real backup).
--
-- Mirrors the INatSync.lua / INatSyncRunner.lua split: this file holds
-- the logic (testable via mocks), INatSyncRunner.lua calls recoverTotalLoss/
-- recoverPartialLoss inline, per observation, during its own sync run --
-- recovery was originally its own separate "Recover Missing Photos from
-- iNaturalist" command/dialog layer, folded into the unified sync run as
-- part of the 2026-07-29 consolidation (DEVELOPMENT_NOTES.md).
local LrApplication = import 'LrApplication'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local INatSync = dofile(LrPathUtils.child(_PLUGIN.path, "INatSync.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))

local INatRecovery = {}

local function stripExtension(filename)
    return filename and filename:match("^(.*)%.[^%.]+$") or filename
end

-- ~/Photos/import/RecoveredFromINat -- user's explicit choice during
-- planning (a labeled subfolder under the normal import root, not mixed
-- into date-based import folders, not under this plugin's own
-- Photos/local/WhatIsThisThing data directory).
function INatRecovery.recoveryDestDir()
    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "import")
    return LrPathUtils.child(dir, "RecoveredFromINat")
end

-- Writes GPS (and the approximateLocation flag when iNat reports the
-- location as obscured/fuzzed) to a freshly-imported photo -- same
-- pattern as GpsPrompt.lua's ensureGpsOnAllPhotos. observation.location
-- is a plain "lat,lng" string (confirmed live during planning); left
-- alone entirely when missing (private geoprivacy under the current
-- unauthenticated pull, or genuinely no location) -- same gap this
-- plugin already tolerates elsewhere, surfaced for manual fixing rather
-- than guessed at.
local function applyLocation(photo, observation)
    if not observation.location then
        return
    end
    local latStr, lngStr = observation.location:match("^(-?[%d%.]+),(-?[%d%.]+)$")
    local lat, lng = tonumber(latStr), tonumber(lngStr)
    if not lat or not lng then
        return
    end
    photo:setRawMetadata("gps", { latitude = lat, longitude = lng })
    if observation.obscured then
        photo:setPropertyForPlugin(_PLUGIN, "approximateLocation", "yes")
    end
end

-- Confirmed live 2026-07-25: recovered photos came in with no capture
-- timestamp at all. iNat's downloaded JPEG is a re-processed/resized copy
-- (see the 2048px-cap note elsewhere) and evidently doesn't reliably
-- carry usable EXIF DateTimeOriginal -- and even if it did, this plugin
-- never wrote anything to guarantee it. `dateTimeOriginal` itself is
-- read-only via the SDK (EXIF-derived, not settable by a plugin) -- the
-- writable counterpart is `dateCreated`, which the SDK docs describe as
-- accepting a plain ISO 8601 string, exactly the shape
-- observation.time_observed_at is already in (e.g.
-- "2008-11-23T12:41:05-08:00"), so no reformatting is needed. Kept as a
-- belt-and-suspenders fallback now that applyEmbeddedExif (below) writes
-- the real EXIF fields too -- this still fires even on a machine with no
-- exiftool available, or if the exiftool write silently no-ops.
local function applyCaptureDate(photo, observation)
    if not observation.time_observed_at then
        return
    end
    photo:setRawMetadata("dateCreated", observation.time_observed_at)
end

-- GUI-launched apps (Lightroom included) don't inherit an interactive
-- shell's PATH, so a bare "exiftool" lookup fails even when it's on the
-- user's normal PATH -- already discovered building geotag_from_gpx.py's
-- own find_exiftool(); same explicit-path fallback list, since there's no
-- Lua equivalent of shutil.which that would fare any better here.
local function findExiftool()
    for _, candidate in ipairs({ "/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool" }) do
        if LrFileUtils.exists(candidate) then
            return candidate
        end
    end
    return nil
end

local function shellQuote(str)
    return "'" .. tostring(str):gsub("'", "'\\''") .. "'"
end

-- Splits an iNat time_observed_at string (e.g.
-- "2026-07-28T10:38:28-04:00") into EXIF's own "YYYY:MM:DD HH:MM:SS"
-- local-clock format and its UTC offset in the "+HH:MM"/"-HH:MM" form
-- EXIF 2.31's OffsetTimeOriginal/OffsetTimeDigitized tags expect -- pure
-- reformatting, no timezone conversion, since both pieces already come
-- straight out of the same source string.
local function splitObservedAt(timeObservedAt)
    local y, mo, d, h, mi, s, offset = timeObservedAt:match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$"
    )
    if not y then
        return nil
    end
    if offset == "Z" or offset == "" then
        offset = "+00:00"
    end
    return string.format("%s:%s:%s %s:%s:%s", y, mo, d, h, mi, s), offset
end

-- Writes REAL embedded EXIF DateTimeOriginal/DateTimeDigitized (plus their
-- Offset* companions) directly into the downloaded JPEG, on disk, BEFORE
-- catalog:addPhoto ever sees it -- dateTimeOriginal is read-only via the
-- SDK (see applyCaptureDate's comment above), so the only way for a
-- recovered photo to ever show a real "Date Time Original"/"Date Time
-- Digitized" in Lightroom's own metadata panel (not just the SDK-level
-- dateCreated field) is to put it in the file's own EXIF before import.
-- Uses observation.time_observed_at for both fields -- iNat only exposes
-- one combined timestamp per observation, not separate taken/digitized
-- moments. Deliberately does NOT touch ModifyDate/DateTime -- that field
-- means "last modified," which downloading+writing right now genuinely is.
-- Uses -overwrite_original (unlike geotag_from_gpx.py's GPX pass, which
-- deliberately keeps a backup of irreplaceable camera originals) since
-- this is a disposable placeholder copy, not the only copy of anything --
-- an "_original" backup here would just be clutter.
-- Confirmed live 2026-07-28: a real recovery run produced a file with
-- correct DateTimeOriginal/CreateDate/Offset* values (checked directly
-- with exiftool). Same run also confirmed exiftool is found at
-- /opt/homebrew/bin/exiftool on this machine.
local function applyEmbeddedExif(destPath, observation)
    if not observation.time_observed_at then
        return
    end
    local exifDateTime, offset = splitObservedAt(observation.time_observed_at)
    if not exifDateTime then
        return
    end

    local exiftool = findExiftool()
    if not exiftool then
        return
    end

    local cmd = table.concat({
        shellQuote(exiftool),
        "-overwrite_original",
        "-DateTimeOriginal=" .. shellQuote(exifDateTime),
        "-OffsetTimeOriginal=" .. shellQuote(offset),
        "-CreateDate=" .. shellQuote(exifDateTime),
        "-OffsetTimeDigitized=" .. shellQuote(offset),
        shellQuote(destPath),
        "> /dev/null 2>&1",
    }, " ")
    LrTasks.execute(cmd)
end

-- Recovered photos otherwise carry NO copyright metadata at all, unlike
-- a normal camera import -- iNat's per-photo `attribution` field
-- (confirmed live to already be present on every photo in the standard
-- pull, no extra API call needed) is a ready-made string, e.g. "(c)
-- Gordon Krefting, some rights reserved (CC BY-NC)".
local function applyCopyright(photo, photoEntry)
    if not photoEntry.attribution or photoEntry.attribution == "" then
        return
    end
    photo:setRawMetadata("copyright", photoEntry.attribution)
end

-- Downloads one iNat photo, adds it to the catalog at a deterministic
-- path under destDir (NOT derived from iNat's own original_filename,
-- already established elsewhere in this codebase as frequently a
-- placeholder/unreliable), and writes GPS + capture date + copyright +
-- the recovered-placeholder flag -- all in one write transaction (no
-- network call needed mid-transaction, unlike
-- KeywordWriter.applyIdentification's taxon-facts fetch, so these are
-- safe to combine here). Returns the new LrPhoto, or nil if the download
-- or catalog add failed -- callers treat nil as "couldn't recover this
-- one," not an error worth aborting the batch.
--
-- catalog:addPhoto itself is NOT yet confirmed live -- genuinely new SDK
-- surface for this project (see DEVELOPMENT_NOTES.md).
local function importOnePhoto(catalog, observation, photoEntry, destDir)
    LrFileUtils.createAllDirectories(destDir)
    local filename = "iNat_" .. tostring(observation.id) .. "_" .. tostring(photoEntry.id) .. ".jpg"
    local destPath = LrPathUtils.child(destDir, filename)

    if not INaturalist.downloadOriginalPhoto(photoEntry.url, destPath) then
        return nil
    end

    -- Runs before catalog:addPhoto, and outside withWriteAccessDo below --
    -- this is a blocking external-process call on a file not yet in the
    -- catalog, not a catalog mutation, and has no business holding a write
    -- transaction open while it runs.
    applyEmbeddedExif(destPath, observation)

    local newPhoto
    catalog:withWriteAccessDo("Import recovered iNat photo", function()
        newPhoto = catalog:addPhoto(destPath)
        if newPhoto then
            applyLocation(newPhoto, observation)
            applyCaptureDate(newPhoto, observation)
            applyCopyright(newPhoto, photoEntry)
            newPhoto:setPropertyForPlugin(_PLUGIN, "iNatRecoveredPlaceholder", "yes")
            PendingMetadataSave.markIfNeeded(catalog, newPhoto)
        end
    end)
    return newPhoto
end

-- Downloads every photo on an observation with NO local match at all,
-- imports each into the catalog, then hands off to the existing,
-- already-tested INatSync.applyMatch for species/keywords/link fields.
-- applyMatch has no hidden dependency on the group pre-existing -- a
-- synthetic { photos = imported } group is all it needs (nil
-- scientificName/commonName/rank/iNatObservationId just makes it
-- correctly treat everything as new) -- so no species/keyword/link-field
-- logic needs reimplementing here.
function INatRecovery.recoverTotalLoss(observation, username, destDir)
    local catalog = LrApplication.activeCatalog()
    local imported = {}
    for _, photoEntry in ipairs(observation.photos or {}) do
        local photo = importOnePhoto(catalog, observation, photoEntry, destDir)
        if photo then
            table.insert(imported, photo)
        end
    end

    if #imported == 0 then
        return { imported = 0, applied = false }
    end

    -- Mirrors the same markMismatchOutcome handling as recoverPartialLoss
    -- below -- applyMatch always mismatch-checks a freshly-synthesized
    -- group (wasAlreadyLinked is false since it has no iNatObservationId
    -- yet), so if some of this observation's photos failed to download
    -- above, that shortfall needs to actually land on the durable
    -- pending-mismatch list -- otherwise it's silently untracked forever
    -- (the observation now has iNatObservationId set, so it no longer
    -- shows up as a "no local match" candidate either, on top of never
    -- appearing as a "missing some photos" one).
    local result = INatSync.applyMatch({ photos = imported }, observation, username, nil)
    if result.checkedMismatch then
        INatSync.markMismatchOutcome(observation.id, result.mismatch ~= nil)
    end
    return { imported = #imported, applied = true }
end

-- Downloads only the photos genuinely missing from an already-matched
-- group, appends them to it, then re-runs applyMatch so species/keywords/
-- link fields and the mismatch state all refresh together.
--
-- Correlates INaturalist.getObservationPhotoFilenames's result (v2,
-- authenticated -- the only source of filenames at all, since the
-- standard v1 pull never includes original_filename) against
-- observation.photos (v1 -- the only source of download URLs) by ARRAY
-- POSITION, since neither endpoint's photo entries carry a field that
-- directly cross-references the other. This assumes both endpoints
-- return an observation's photos in the same order -- a reasonable but
-- NOT live-verified assumption (the v2 endpoint requires an authenticated
-- fetch this session couldn't script standalone) -- so this only
-- proceeds when the two lists are even the same LENGTH, and skips
-- entirely otherwise (reported, not guessed at) to avoid risking a
-- duplicate import of a photo already present locally under a different
-- synthetic filename. Spot-check a multi-photo partial-loss recovery
-- first, same as the catalog:addPhoto caveat above.
function INatRecovery.recoverPartialLoss(group, observation, username, destDir)
    local iNatFilenames = INaturalist.getObservationPhotoFilenames(observation.id)
    local rawPhotos = observation.photos or {}
    if not iNatFilenames or #iNatFilenames ~= #rawPhotos then
        return { imported = 0, applied = false, skipped = "unreliable filename data" }
    end

    local catalog = LrApplication.activeCatalog()
    local localFilenames = {}
    for _, photo in ipairs(group.photos) do
        localFilenames[stripExtension(photo:getFormattedMetadata("fileName"))] = true
    end

    local imported = {}
    for i, photoEntry in ipairs(rawPhotos) do
        local stem = stripExtension(iNatFilenames[i])
        if not localFilenames[stem] then
            local photo = importOnePhoto(catalog, observation, photoEntry, destDir)
            if photo then
                table.insert(group.photos, photo)
                table.insert(imported, photo)
            end
        end
    end

    if #imported == 0 then
        return { imported = 0, applied = false }
    end

    -- applyMatch's own "does the species need updating" check only fires
    -- when ITS OWN absorption logic found something (via photosByFilename,
    -- not passed here) or the group's already-recorded scientificName
    -- disagrees with iNat's current taxon. Since the recovered photo was
    -- appended to group.photos above, BEFORE applyMatch ever sees it, an
    -- already-correctly-tagged group looks completely unchanged to that
    -- check -- confirmed live: the recovered photo got its iNatObservationId
    -- link fields (applyMatch's own unconditional write, below) but no
    -- local observationId/species/keywords at all, since
    -- KeywordWriter.applyIdentification was never reached. Apply
    -- identification directly to the whole (now-updated) group here,
    -- reusing the same agrees-gate applyMatch itself uses so a genuine
    -- disagreement is still respected. Safe/idempotent for the
    -- already-correctly-tagged sibling(s) too -- applyIdentification
    -- reuses their existing local observationId (findExistingObservationId)
    -- and no-ops the keyword re-add.
    if observation.taxon and INaturalist.observationAgreesWithMe(observation, username) then
        local candidate = {
            id = observation.taxon.id,
            scientificName = observation.taxon.name,
            commonName = observation.taxon.preferred_common_name,
            rank = observation.taxon.rank,
        }
        local ancestry = INaturalist.getMajorAncestry(observation.taxon.id)
        KeywordWriter.applyIdentification(group.photos, candidate, ancestry)
    end

    -- applyMatch does NOT clear the durable pending-mismatch list itself --
    -- INatSyncRunner.lua's own apply loop is what calls markMismatchOutcome
    -- based on the returned result, and this code path bypassed that
    -- entirely. Confirmed live: a successfully-recovered partial-loss
    -- observation kept reappearing as a "missing some of its photos"
    -- candidate on every subsequent recovery run, forever, because
    -- iNatPendingMismatchIds was never updated after the fix above
    -- actually resolved it. Mirrors INatSyncRunner.lua's own (simpler,
    -- non-interactive) handling of this same result field.
    --
    -- forceRecheck=true is NOT optional here -- this group's
    -- iNatObservationId was already set before recoverPartialLoss ran (by
    -- definition -- that's what made it a "partial loss" candidate rather
    -- than a "total loss" one), so applyMatch's own shouldCheckMismatch
    -- (`forceRecheck or not wasAlreadyLinked or ...`) would otherwise
    -- evaluate to false and skip the mismatch check entirely -- silently
    -- making the markMismatchOutcome call below a no-op even with the fix
    -- above in place, despite the photo set having just genuinely changed.
    local result = INatSync.applyMatch(group, observation, username, nil, nil, true)
    if result.checkedMismatch then
        INatSync.markMismatchOutcome(observation.id, result.mismatch ~= nil)
    end
    return { imported = #imported, applied = true }
end

return INatRecovery
