local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local TaxonStore = {}

-- Sentinel for "explicitly clear this field," distinct from simply
-- omitting it from a `set` call's `fields` table. Necessary because a
-- Lua table CONSTRUCTOR silently drops any key whose value is nil --
-- `{ growthHabit = someNilVariable }` never contains a "growthHabit" key
-- at all, so `pairs(fields)` below would never see it, and a caller
-- trying to clear a field by passing nil for it would silently no-op
-- (found live 2026-08-15, building ManageFloraObservation.lua -- the
-- photo-level property write elsewhere always cleared fine, since a real
-- function call DOES pass nil through; only this table-driven merge
-- couldn't tell "clear" apart from "don't touch"). Any real value
-- (including nil, false, "") is a valid field value; only this exact
-- table identity means "clear."
TaxonStore.CLEAR = {}

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
--
-- Split into two groups for cultivar-aware lookups (see buildTaxonKey/get/
-- set below): BARE_ONLY_FIELDS are genuinely species-wide facts (sourced
-- from iNat's API, or -- for commonNames/preferredCommonName -- curated
-- from multiple sources but still species-wide, confirmed with the user)
-- and are never stored under a cultivar-specific key, even when a
-- cultivar is given; everything else in FIELD_ORDER is cultivar-specific
-- when a cultivar is given (a cultivar's growth habit, nativity, garden
-- locations, and notes can genuinely differ from the bare species').
local FIELD_ORDER = {
    "conservationStatus", "establishmentMeans", "wikipediaUrl", "commonNames", "preferredCommonName",
    "iconicTaxonName", "growthHabit", "nativity", "gardenLocations", "notes",
}
local BARE_ONLY_FIELDS = {
    conservationStatus = true, establishmentMeans = true, wikipediaUrl = true,
    commonNames = true, preferredCommonName = true, iconicTaxonName = true,
}

-- Cultivars are entered like a trinomial (`Genus species 'Cultivar'`) for
-- TaxonStore lookup purposes only -- NEVER written into the real
-- scientificName field callers pass around, which stays the plain,
-- iNat-resolvable name (see KeywordWriter.lua/ManageFloraObservation.lua/
-- SetCultivar.lua). Unlike a genuine subspecies trinomial (a real iNat
-- rank, e.g. "Damaliscus lunatus jimela"), a cultivar is a horticultural
-- concept iNat has never heard of, so this key exists purely as an
-- internal TaxonStore index, distinct from anything ever sent to iNat's
-- API.
local function buildTaxonKey(scientificName, cultivar)
    if cultivar and cultivar ~= "" then
        return scientificName .. " '" .. cultivar .. "'"
    end
    return scientificName
end

local function isValidLuaIdentifier(key)
    return type(key) == "string" and key:match("^[%a_][%w_]*$") ~= nil
end

-- Recursively serializes any value FIELD_ORDER's fields can hold today:
-- plain strings (the original, only case), or -- for gardenLocations (a
-- map keyed by location value) and commonNames (an array of { name,
-- source } records) -- nested tables. Table keys are sorted for stable,
-- diffable output, same reasoning as FIELD_ORDER's own fixed ordering.
local function serializeValue(value)
    local t = type(value)
    if t == "string" then
        return string.format("%q", value)
    elseif t == "boolean" or t == "number" then
        return tostring(value)
    elseif t == "table" then
        local parts = {}
        if #value > 0 then
            for _, v in ipairs(value) do
                table.insert(parts, serializeValue(v))
            end
        else
            local keys = {}
            for k in pairs(value) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                local keyStr = isValidLuaIdentifier(k) and k or string.format("[%q]", tostring(k))
                table.insert(parts, keyStr .. " = " .. serializeValue(value[k]))
            end
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "nil"
end

local function serializeEntry(entry)
    local lines = {}
    for _, field in ipairs(FIELD_ORDER) do
        local value = entry[field]
        if value ~= nil then
            table.insert(lines, string.format("        %s = %s,", field, serializeValue(value)))
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

-- Returns the cached entry for `scientificName`, or nil if neither the
-- bare species nor (when `cultivar` is given) its cultivar-keyed entry is
-- known yet.
--
-- `cultivar` is optional -- omit it (or pass nil) for the original,
-- unchanged behavior: the bare species entry, as-is. When given, returns
-- a MERGED view: the cultivar-keyed entry's own fields (growthHabit,
-- nativity, gardenLocations, notes -- see BARE_ONLY_FIELDS) layered over
-- the bare species entry's BARE_ONLY_FIELDS (conservationStatus,
-- establishmentMeans, wikipediaUrl, commonNames, preferredCommonName) --
-- those are never stored under a cultivar key at all (see buildTaxonKey's
-- own comment for why), so they always come from the bare entry
-- regardless of cultivar.
function TaxonStore.get(scientificName, cultivar)
    local data = TaxonStore.load()
    local bareEntry = data[scientificName]

    if not cultivar or cultivar == "" then
        return bareEntry
    end

    local cultivarEntry = data[buildTaxonKey(scientificName, cultivar)]
    if not bareEntry and not cultivarEntry then
        return nil
    end

    local merged = {}
    if bareEntry then
        for field in pairs(BARE_ONLY_FIELDS) do
            merged[field] = bareEntry[field]
        end
    end
    if cultivarEntry then
        for _, field in ipairs(FIELD_ORDER) do
            if not BARE_ONLY_FIELDS[field] then
                merged[field] = cultivarEntry[field]
            end
        end
    end
    return merged
end

-- Merges `fields` into whatever entry (if any) already exists -- only the
-- keys present in `fields` are changed, so e.g. adding a freshly-fetched
-- wikipediaUrl doesn't wipe an already-cached conservationStatus.
-- Persists immediately.
--
-- `cultivar` is optional (third param, so every existing 2-arg call site
-- keeps working unchanged, always against the bare species entry). When
-- given, any key in `fields` that's one of BARE_ONLY_FIELDS still writes
-- to the BARE species entry (never duplicated/stored under the cultivar
-- key -- see buildTaxonKey's own comment); every other key writes to the
-- cultivar-keyed entry instead.
--
-- Returns the resulting merged view, same shape TaxonStore.get(
-- scientificName, cultivar) would return.
function TaxonStore.set(scientificName, fields, cultivar)
    local data = TaxonStore.load()
    local bareEntry = data[scientificName] or {}
    local taxonKey = (cultivar and cultivar ~= "") and buildTaxonKey(scientificName, cultivar) or nil
    local cultivarEntry = taxonKey and (data[taxonKey] or {}) or nil

    local bareChanged, cultivarChanged = false, false
    for key, value in pairs(fields) do
        -- NOT `(value == TaxonStore.CLEAR) and nil or value` -- that
        -- classic and/or idiom breaks exactly when the "true" branch's
        -- own value is nil: `true and nil` is always nil, so `nil or
        -- value` falls through and evaluates to `value` (the CLEAR
        -- sentinel itself) instead -- caught by a mock test before this
        -- ever ran live (same bug class PendingMetadataSave.lua's own
        -- doc comment already warns about).
        local resolvedValue = value
        if value == TaxonStore.CLEAR then
            resolvedValue = nil
        end
        if BARE_ONLY_FIELDS[key] or not cultivarEntry then
            bareEntry[key] = resolvedValue
            bareChanged = true
        else
            cultivarEntry[key] = resolvedValue
            cultivarChanged = true
        end
    end

    if bareChanged then
        data[scientificName] = bareEntry
    end
    if cultivarChanged then
        data[taxonKey] = cultivarEntry
    end
    TaxonStore.save(data)

    return TaxonStore.get(scientificName, cultivar)
end

-- Renders a `gardenLocations` map (see `set`'s own field-shape comment
-- for the taxon-level entry) as a single display string, for the
-- read-only, panel-facing `gardenLocations` custom metadata field --
-- Lightroom's metadata dataTypes have no native multi-select/map shape
-- (see MetadataDefinition.lua's own comment on that field), so every
-- caller that denormalizes this onto a photo (KeywordWriter.lua,
-- ManageFloraObservation.lua, SetCultivar.lua) needs the SAME rendering,
-- not three separately-maintained copies.
--
-- `locationTitles` (a plain { [value] = title } map, built by the caller
-- from the specimen-level gardenLocation field's own MetadataDefinition.lua
-- `values` list) translates each raw location value into its display
-- title -- passed in rather than dofile'd here, to keep this module free
-- of any dependency on _PLUGIN/MetadataDefinition.lua. Falls back to the
-- raw value itself if a title isn't found (shouldn't normally happen).
--
-- Returns nil (not an empty string) when there's nothing checked, so
-- callers can treat it the same as any other "clear this field" value.
function TaxonStore.formatGardenLocations(gardenLocations, locationTitles)
    if not gardenLocations then
        return nil
    end

    local keys = {}
    for key in pairs(gardenLocations) do
        table.insert(keys, key)
    end
    table.sort(keys)

    local parts = {}
    for _, key in ipairs(keys) do
        local title = locationTitles[key] or key
        local description = gardenLocations[key]
        if type(description) == "string" and description ~= "" then
            table.insert(parts, title .. " (" .. description .. ")")
        else
            table.insert(parts, title)
        end
    end

    if #parts == 0 then
        return nil
    end
    return table.concat(parts, "; ")
end

-- True if `commonNames` (a species' cached array of { name, source }
-- records) already includes at least one entry sourced from iNat's own
-- &all_names=true fetch -- the signal callers need for "has the BULK
-- multi-name fetch (INaturalist.getTaxonFacts) ever actually run for this
-- species," which is NOT the same question as "is commonNames non-nil."
-- commonNames gains an "identify"-tagged entry on literally every
-- identify run regardless (KeywordWriter.applyIdentification's own
-- per-run merge, unconditional), so a species can easily have one or more
-- commonNames entries -- and TaxonStore.get(...).commonNames be
-- perfectly non-nil -- despite the richer iNat fetch never having run at
-- all (confirmed live 2026-08-16: "Daucus carota" had exactly one
-- "identify"-sourced entry and nothing else, so a plain "is commonNames
-- set" check incorrectly treated the fetch as already done).
function TaxonStore.hasInatCommonNames(commonNames)
    for _, entry in ipairs(commonNames or {}) do
        if entry.source == "inat" then
            return true
        end
    end
    return false
end

return TaxonStore
