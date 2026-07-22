local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local TaxonStore = {}

-- Lives under ~/Photos/local/ specifically -- confirmed (2026-07-21) that's
-- the one tree the user's own manage_photo_backups.rb script wholesale
-- rsyncs to their NAS/Backblaze; the live Lightroom catalog's own folder
-- is NOT covered (only Lightroom's own periodic catalog-backup snapshots
-- are), and LrPrefs-based storage lives in Lightroom's app-preferences
-- area, outside any photo-focused backup routine entirely.
local function getPath()
    local home = LrPathUtils.getStandardFilePath("home")
    local dir = LrPathUtils.child(LrPathUtils.child(home, "Photos"), "local")
    dir = LrPathUtils.child(dir, "WhatIsThisThing")
    return LrPathUtils.child(dir, "taxon-data.lua")
end

-- Fields are written in this fixed order for stable, diffable output --
-- nice for a human-readable file that's also going through a backup
-- pipeline. Nil-valued fields are omitted entirely rather than written as
-- explicit `nil`.
local FIELD_ORDER = { "conservationStatus", "establishmentMeans", "growthHabit", "wikipediaUrl", "notes" }

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

-- Loads the whole store fresh from disk. Returns an empty table if the
-- file doesn't exist yet (first run) or fails to parse for any reason --
-- never blocks/errors the caller, since this is a cache, not a critical
-- write path.
function TaxonStore.load()
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

-- Writes `data` back out as a plain Lua source file (`return { [name] =
-- {...}, ... }`) -- not JSON. Lightroom's Lua has no built-in JSON
-- encoder, and this codebase already treats "just return a Lua table" as
-- its native config format (Info.lua, MetadataDefinition.lua), so this
-- avoids needing to write/maintain a JSON encoder for a file nothing
-- outside the plugin itself needs to read.
--
-- NOTE: uses plain Lua io.open, not an LrFileUtils call -- LrFileUtils has
-- no write-a-file function (only readFile), and this hasn't been verified
-- against a live Lightroom instance. If io.open turns out not to work in
-- Lightroom's Lua sandbox, this needs to move to a small Python helper
-- script invoked via LrTasks.execute(), same pattern as
-- geotag_from_gpx.py.
function TaxonStore.save(data)
    local path = getPath()
    LrFileUtils.createAllDirectories(LrPathUtils.parent(path))

    local names = {}
    for name in pairs(data) do
        table.insert(names, name)
    end
    table.sort(names)

    local lines = { "return {" }
    for _, name in ipairs(names) do
        table.insert(lines, string.format("    [%s] = %s,", string.format("%q", name), serializeEntry(data[name])))
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

-- Returns the cached entry for `scientificName`, or nil if not yet known.
function TaxonStore.get(scientificName)
    local data = TaxonStore.load()
    return data[scientificName]
end

-- Merges `fields` into whatever entry (if any) already exists for
-- `scientificName` -- only the keys present in `fields` are changed, so
-- e.g. adding a freshly-fetched wikipediaUrl doesn't wipe an
-- already-cached conservationStatus. Persists immediately.
function TaxonStore.set(scientificName, fields)
    local data = TaxonStore.load()
    local entry = data[scientificName] or {}
    for key, value in pairs(fields) do
        entry[key] = value
    end
    data[scientificName] = entry
    TaxonStore.save(data)
    return entry
end

return TaxonStore
