local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local TaxonStore = dofile(LrPathUtils.child(_PLUGIN.path, "TaxonStore.lua"))

local SpecimenStore = {}

-- Sentinel for "explicitly clear this field" -- same fix, same reasoning
-- as TaxonStore.CLEAR (see its own comment): a table constructor silently
-- drops any key whose value is nil, so `set` couldn't otherwise tell
-- "clear this field" apart from "don't touch it."
SpecimenStore.CLEAR = {}

-- Same directory as TaxonStore's own cache file, for the same reason
-- (confirmed 2026-07-21 that ~/Photos/local/ is the one tree
-- manage_photo_backups.rb wholesale rsyncs to the NAS/Backblaze).
local function getPath()
    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "local")
    dir = LrPathUtils.child(dir, "WhatIsThisThing")
    return LrPathUtils.child(dir, "specimen-data.lua")
end

-- Unlike TaxonStore, every field here is a plain scalar string -- a
-- specimen's own gardenLocation is single-valued (one physical,
-- stationary plant, one location), not the map-shaped multi-select
-- TaxonStore's taxon-level gardenLocations uses -- so no non-scalar
-- serialization is needed here.
local FIELD_ORDER = { "scientificName", "gardenLocation", "locationNotes", "plantingMethod", "plantingYear", "nickname" }

local function serializeEntry(entry)
    local lines = {}
    for _, field in ipairs(FIELD_ORDER) do
        local value = entry[field]
        if value ~= nil then
            table.insert(lines, string.format("        %s = %s,", field, string.format("%q", value)))
        end
    end
    return "{\n" .. table.concat(lines, "\n") .. "\n    }"
end

function SpecimenStore.load()
    local path = getPath()
    if not LrFileUtils.exists(path) then
        return {}
    end

    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" then
        return {}
    end
    return data
end

function SpecimenStore.save(data)
    local path = getPath()
    LrFileUtils.createAllDirectories(LrPathUtils.parent(path))

    local ids = {}
    for id in pairs(data) do
        table.insert(ids, id)
    end
    table.sort(ids)

    local lines = { "return {" }
    for _, id in ipairs(ids) do
        table.insert(lines, string.format("    [%s] = %s,", string.format("%q", id), serializeEntry(data[id])))
    end
    table.insert(lines, "}")
    table.insert(lines, "")

    local file = io.open(path, "w")
    if not file then
        return false
    end
    file:write(table.concat(lines, "\n"))
    file:close()
    return true
end

-- Returns the cached entry for `specimenId`, or nil if not yet known.
function SpecimenStore.get(specimenId)
    local data = SpecimenStore.load()
    return data[specimenId]
end

-- Merges `fields` into whatever entry (if any) already exists for
-- `specimenId` -- only the keys present in `fields` are changed. Persists
-- immediately.
--
-- Auto-sync, per the user: whenever `fields.gardenLocation` is set (a
-- specimen created or its location edited), also ensure that location is
-- checked in its species' taxon-level `gardenLocations` map (see
-- TaxonStore.lua) -- adds the key if not already present, but never
-- clobbers an existing per-location description already there (only sets
-- a bare "checked, no description" entry when the location wasn't
-- present at all). Requires `scientificName` to already be known for
-- this specimen (either just passed in this same call, or already set by
-- an earlier one) -- silently skipped if not, since there's no species to
-- sync against yet.
function SpecimenStore.set(specimenId, fields)
    local data = SpecimenStore.load()
    local entry = data[specimenId] or {}
    for key, value in pairs(fields) do
        -- NOT `(value == SpecimenStore.CLEAR) and nil or value` -- see
        -- TaxonStore.set's own comment on this exact and/or idiom pitfall
        -- (caught live by a mock test on this file's twin fix).
        if value == SpecimenStore.CLEAR then
            entry[key] = nil
        else
            entry[key] = value
        end
    end
    data[specimenId] = entry
    SpecimenStore.save(data)

    -- fields.gardenLocation == SpecimenStore.CLEAR is truthy (it's a real
    -- table, not nil) but is NOT a real location to sync -- must be
    -- excluded explicitly, or clearing a specimen's location would sync a
    -- garbage table-keyed entry into the taxon's gardenLocations map.
    if fields.gardenLocation and fields.gardenLocation ~= SpecimenStore.CLEAR and entry.scientificName then
        local taxonEntry = TaxonStore.get(entry.scientificName) or {}
        local locations = taxonEntry.gardenLocations or {}
        if locations[fields.gardenLocation] == nil then
            locations[fields.gardenLocation] = false
            TaxonStore.set(entry.scientificName, { gardenLocations = locations })
        end
    end

    return entry
end

return SpecimenStore
