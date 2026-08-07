local PendingMetadataSave = {}

-- Name of the persistent collection this module maintains -- every photo
-- currently flagged (see below) is a member of it, browsable/selectable
-- like any other Lightroom collection.
local COLLECTION_NAME = "Pending Metadata Save"

local function getCollection(catalog)
    return catalog:createCollection(COLLECTION_NAME, nil, true)
end

-- Flags (or clears) a photo's "Pending Metadata Save" custom field
-- (MetadataDefinition.lua) AND its membership in the COLLECTION_NAME
-- collection, based on whether its file is currently reachable on disk --
-- e.g. an external archive drive that's unmounted. Lightroom's own
-- catalog write always succeeds regardless (setRawMetadata/
-- setPropertyForPlugin don't need the file), but the write never reaches
-- the actual file/XMP sidecar until something flushes it, and nothing
-- does that automatically if the file wasn't reachable when the edit was
-- made. There's no reliable NATIVE way to find these later (Lightroom's
-- own "Metadata Status" Smart Collection criterion is a confirmed
-- Lightroom Classic bug; "Edit Date" doesn't work either, since Save
-- Metadata to Files itself bumps it) -- so this plugin tracks it instead.
--
-- The collection (not a plugin command driving an ephemeral selection)
-- is the actual user-facing workflow: whenever convenient, open "Pending
-- Metadata Save" in the Catalog panel, select what's in it, Metadata >
-- Save Metadata to Files, then remove those photos from the collection
-- (or delete it outright) once satisfied -- all native Lightroom actions,
-- no plugin command needed. Deliberately NOT an ephemeral catalog
-- selection (an earlier version of this used
-- catalog:setSelectedPhotos + an optimistic clear-on-select) -- a
-- selection is too easy to lose to a stray click, and clearing the flag
-- at that point (rather than once actually saved) meant an accidentally-
-- lost selection silently dropped a photo from tracking with nothing
-- ever having been saved. A collection survives exactly that.
--
-- Call once per photo, from inside an ALREADY-OPEN catalog:
-- withWriteAccessDo block, right alongside whatever real metadata write
-- that transaction is making -- createCollection/addPhotos/removePhotos
-- all require write access themselves, satisfied by reusing the same
-- transaction rather than opening a second one.
--
-- Clearing happens automatically the next time ANY write touches a photo
-- while its file IS reachable -- correct, not just best-effort: once
-- reachable, the next flush (auto-XMP or a manual save) picks up every
-- pending catalog change at once, old and new alike, so there's nothing
-- uniquely "stuck" about it anymore. This is IN ADDITION to the user's
-- own manual removal once they've verified a save -- either one clears
-- it, whichever happens first.
--
-- The current-value check matters: without it, this would unconditionally
-- write (and touch the collection) on every single metadata change
-- plugin-wide, and since Save Metadata to Files itself was confirmed live
-- to bump a photo's Edit Date, an unconditional write here would
-- contaminate Edit Date on every ordinary write too -- exactly the
-- self-defeating signal this field exists to avoid being. Only called
-- once per photo per transaction (not twice for the same photo in the
-- same transaction) -- getPropertyForPlugin is confirmed NOT to reliably
-- reflect a setPropertyForPlugin call made earlier in the SAME
-- transaction (see ColorCode.lua's own doc comment), so a second call
-- here in one transaction could read back a stale value.
function PendingMetadataSave.markIfNeeded(catalog, photo)
    local available = photo:checkPhotoAvailability()
    -- NOT `available and nil or "yes"` -- that classic and/or idiom
    -- breaks when the "true" branch's value is itself nil/false (`available
    -- and nil` is always falsy, so the `or "yes"` would always win,
    -- flagging every write "yes" regardless of availability -- caught by
    -- a mock test, Case 3, before this ever ran live).
    local desired
    if not available then
        desired = "yes"
    end
    local current = photo:getPropertyForPlugin(_PLUGIN, "pendingMetadataSave")
    if desired ~= current then
        photo:setPropertyForPlugin(_PLUGIN, "pendingMetadataSave", desired)
        local collection = getCollection(catalog)
        if desired == "yes" then
            collection:addPhotos({ photo })
        else
            collection:removePhotos({ photo })
        end
    end
end

return PendingMetadataSave
