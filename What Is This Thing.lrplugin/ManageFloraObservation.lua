local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'

local TaxonStore = dofile(LrPathUtils.child(_PLUGIN.path, "TaxonStore.lua"))
local SpecimenStore = dofile(LrPathUtils.child(_PLUGIN.path, "SpecimenStore.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))
local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))
local ObservationGroup = dofile(LrPathUtils.child(_PLUGIN.path, "ObservationGroup.lua"))

-- catalog:findPhotosWithProperty requires the plug-in's toolkit identifier
-- as a plain string (unlike get/setPropertyForPlugin, which also accept
-- the _PLUGIN object) -- must match Info.lua's LrToolkitIdentifier exactly.
local TOOLKIT_ID = "org.krefting.whatisthisthing"

-- Consolidates EditTaxonInfo.lua and ManageSpecimen.lua (both retired
-- 2026-08-15) into one dialog -- editing one real-world plant/fungus
-- observation means touching taxon, specimen, and observation-level facts
-- together, not as three separate commands. Scoped to plants/fungi only
-- (see checkScope below), since that's the only domain any of this data
-- serves.

-- A radio button group bound to a Lua string property can't reliably use
-- literal nil as a checked_value (the same "nil must be an explicit,
-- distinguishable choice" gotcha this codebase has hit before with native
-- enum fields -- see approximateLocation's own comment in
-- MetadataDefinition.lua) -- this sentinel stands in for "(unknown)"/unset
-- in the dialog's own property table, translated back to nil (or
-- TaxonStore.CLEAR/SpecimenStore.CLEAR, see the save-time logic below) at
-- save time.
local UNSET = ""

-- Same Plantae/Fungi value set as INaturalist.lua's own KINGDOMS_TO_SHOW
-- (that one filters ancestry display; this one gates which observations
-- this whole dialog will touch at all) -- not shared/exported since it's
-- a one-line table and this codebase's own convention (see LOCATION_TITLES,
-- rebuilt independently in several files) already favors small local
-- duplication over cross-module coupling for lookup tables this size.
local PLANT_FUNGUS_KINGDOMS = { Plantae = true, Fungi = true }

local NO_SPECIMEN_LINK = "__none__"

-- Human-readable titles for the post-save "kept the linked specimen's
-- existing value" summary -- SpecimenStore's own field names aren't
-- display-ready.
local SPECIMEN_FIELD_TITLES = {
    gardenLocation = "Location",
    locationNotes = "Location Notes",
    plantingMethod = "Introduction Method",
    plantingYear = "Introduction Year",
    nickname = "Nickname",
}

-- Every specimen-level field name the save-time algorithm below needs to
-- loop over (merge-fill logic, and each save branch's own field list) --
-- one place to add a new specimen field, rather than four.
local SPECIMEN_FIELD_NAMES = { "gardenLocation", "locationNotes", "plantingMethod", "plantingYear", "nickname" }

-- Reads a declared enum field's `values` list straight from
-- MetadataDefinition.lua (growthHabit, nativity, and -- reused here for
-- both the specimen's own single-select location and the taxon-level
-- Garden Locations checklist -- the same 7-location value set) rather
-- than duplicating the list a second time here -- one source of truth, no
-- drift risk if the schema ever changes.
local function findFieldValues(fieldId)
    local metadataDef = dofile(LrPathUtils.child(_PLUGIN.path, "MetadataDefinition.lua"))
    for _, field in ipairs(metadataDef.metadataFieldsForPhotos) do
        if field.id == fieldId then
            return field.values
        end
    end
    return {}
end

-- Renders one enum field as a vertical radio button group -- the only
-- widget with real precedent in this codebase for a fixed-choice custom-
-- dialog picker. `bindKey` is already seeded in `props` with either UNSET
-- or the field's current value.
local function buildEnumRadioGroup(f, fieldId, bindKey)
    local rows = {}
    for _, entry in ipairs(findFieldValues(fieldId)) do
        table.insert(rows, f:radio_button {
            title = entry.title,
            value = LrView.bind(bindKey),
            checked_value = (entry.value == nil) and UNSET or entry.value,
        })
    end
    return f:column(rows)
end

-- Taxon-level facts (growthHabit/nativity/gardenLocations/notes/
-- commonNames/preferredCommonName) fan out to every photo of the same
-- species (and, when editing a cultivar's own entry, the same cultivar
-- specifically -- never a photo with a DIFFERENT or no cultivar at all)
-- across the whole catalog -- ported verbatim from the retired
-- EditTaxonInfo.lua. Distinct from the specimen-level fan-out below,
-- which only ever touches this OBSERVATION's own photos.
local function findAllPhotosOfTaxon(catalog, scientificName, cultivar)
    local candidates = catalog:findPhotosWithProperty(TOOLKIT_ID, "scientificName")
    local matched = {}
    for _, photo in ipairs(candidates) do
        if photo:getPropertyForPlugin(_PLUGIN, "scientificName") == scientificName
            and photo:getPropertyForPlugin(_PLUGIN, "cultivar") == cultivar then
            table.insert(matched, photo)
        end
    end
    return matched
end

-- "CommonName (ScientificName)", or just ScientificName if there's no
-- common name -- the same caption format KeywordWriter.applyIdentification
-- already uses (its own local formatLabel, not exported on the
-- KeywordWriter table) when a photo is first identified. Duplicated here
-- rather than exporting a one-line function from KeywordWriter.lua,
-- matching this codebase's existing small-duplication convention (see
-- LOCATION_TITLES, rebuilt independently in several files). Needed so
-- editing the preferred common name here keeps Lightroom's own native
-- Caption field in sync -- confirmed live 2026-08-17 that this dialog
-- was updating this plugin's own `commonName` custom field but leaving
-- the actual IPTC Caption stale.
local function formatCaption(commonName, scientificName)
    if commonName then
        return commonName .. " (" .. scientificName .. ")"
    end
    return scientificName
end

-- Minor words that stay lowercase mid-name in proper title case, unless
-- they're the first or last word -- articles, short conjunctions, short
-- prepositions. Not an exhaustive style-guide list, just enough to cover
-- what actually shows up in common names ("Charmin of the Woods", not
-- "Charmin Of The Woods").
local MINOR_WORDS = {
    ["a"] = true, ["an"] = true, ["and"] = true, ["as"] = true, ["at"] = true,
    ["but"] = true, ["by"] = true, ["for"] = true, ["in"] = true, ["nor"] = true,
    ["of"] = true, ["on"] = true, ["or"] = true, ["so"] = true, ["the"] = true,
    ["to"] = true, ["up"] = true, ["yet"] = true, ["via"] = true, ["vs"] = true,
}

-- Capitalizes the first letter of every letter/apostrophe run in a single
-- word, lowercasing the rest -- treats hyphens as a word boundary without
-- special-casing them, so "Velvet-Dock" stays "Velvet-Dock" rather than
-- becoming "Velvet-dock".
local function capitalizeWord(word)
    return (word:gsub("(%a)([%a']*)", function(first, rest)
        return first:upper() .. rest:lower()
    end))
end

-- Normalizes a common name to proper Title Case ("great mullein" ->
-- "Great Mullein", "charmin of the woods" -> "Charmin of the Woods") --
-- iNat's own web UI displays names this way, but its raw API data isn't
-- consistently cased, and PlantNet's is all over the place too
-- (lowercase, mixed, occasional ALL CAPS). Minor words (MINOR_WORDS
-- above) stay lowercase unless they're the first or last word. Also the
-- single normalization point new names pass through before being deduped
-- into TaxonStore's commonNames list (KeywordWriter.addName, this file's
-- manual "Add new" path, and the read-time cleanup below all route
-- through this), so two differently-cased spellings of the same name
-- collapse into one entry instead of showing as separate picker options.
local function titleCase(str)
    if not str then
        return str
    end
    local words = {}
    for word in str:gmatch("%S+") do
        table.insert(words, word)
    end
    if #words == 0 then
        return str
    end
    for i, word in ipairs(words) do
        local bare = word:match("^%a+$")
        if i ~= 1 and i ~= #words and bare and MINOR_WORDS[bare:lower()] then
            words[i] = bare:lower()
        else
            words[i] = capitalizeWord(word)
        end
    end
    return table.concat(words, " ")
end

-- Plain "Subtribe"-style display for a raw taxonRank value -- same small
-- helper ObservationReport.lua already has; ported rather than shared,
-- one line, not worth a cross-file dependency.
local function describeRank(rank)
    if not rank then
        return "(unknown)"
    end
    return rank:sub(1, 1):upper() .. rank:sub(2)
end

-- A short label for an existing specimen in the merge picker -- nickname
-- when set (per the user's own goldenrod case: several visually-similar
-- species only identifiable to genus need SOME human label to tell
-- apart), falling back to its earliest observation date otherwise.
--
-- NOT location/planting-year (the retired ManageSpecimen.lua's own
-- fallback, ported here at first) -- confirmed with the user 2026-08-17
-- that this is a genuinely bad differentiator: a specimen is one
-- physical, stationary plant, so EVERY specimen of a species growing in
-- the same bed shares the same location, and multiple specimens easily
-- share a planting year too -- neither tells two specimens apart at all.
-- Earliest observation date does: two different specimens are unlikely
-- to have been first photographed on the exact same day, and it ties
-- directly into what Specimen actually tracks (the same individual
-- across separate sightings over TIME).
local function describeSpecimen(specimenId, entry, earliestDates)
    if entry.nickname then
        return entry.nickname
    end
    local date = earliestDates[specimenId]
    if date then
        return "First seen " .. date
    end
    return "Specimen " .. specimenId:sub(1, 8)
end

-- Counts DISTINCT OBSERVATIONS (not raw photos) linked to `specimenId`,
-- excluding `excludeObservationId` (this observation's own) -- the
-- actually meaningful relationship Specimen exists to track is "how many
-- SEPARATE sightings, over time, is this the same individual as," not
-- "how many photos does it have." A raw photo count was tried first and
-- confirmed live 2026-08-17 to be uninteresting/misleading: a specimen
-- with 3 photos all from THIS SAME observation would show "3 photos
-- total" and read as if something else is linked, when really it's just
-- restating what the thumbnail row above already shows -- this
-- observation has 3 photos of it.
local function countOtherObservationsOfSpecimen(catalog, specimenId, excludeObservationId)
    local candidates = catalog:findPhotosWithProperty(TOOLKIT_ID, "specimenId")
    local seen = {}
    for _, photo in ipairs(candidates) do
        if photo:getPropertyForPlugin(_PLUGIN, "specimenId") == specimenId then
            local obsId = photo:getPropertyForPlugin(_PLUGIN, "observationId")
            if obsId and obsId ~= excludeObservationId then
                seen[obsId] = true
            end
        end
    end
    local count = 0
    for _ in pairs(seen) do
        count = count + 1
    end
    return count
end

-- Builds { [specimenId] = earliestObservationDateString } across every
-- specimen-linked photo in the catalog, in ONE scan -- feeds
-- describeSpecimen's fallback label (see its own comment for why
-- location/planting-year don't work as a differentiator).
--
-- "dateCreated" is NOT a valid getRawMetadata/getFormattedMetadata key --
-- confirmed live 2026-08-17 ("Unknown key: 'dateCreated'"). That string
-- only exists as a TAGSET ITEM id (com.adobe.dateCreated, a different SDK
-- surface used in MetadataTagsetFactory.lua) -- conflating the two
-- namespaces was the actual bug. `dateTimeOriginal` is the real,
-- already-proven key for this exact purpose elsewhere in this codebase
-- (GpsPrompt.lua, INatSync.lua, MergeCandidatesDialog.lua all compare
-- photo capture times via it) -- confirmed by INatSync.lua's own comment
-- that its raw value is a plain Cocoa-epoch number, directly comparable
-- with `<`. Can still be nil for some recovered photos (per
-- MetadataTagsetFactory.lua's own note) -- guarded below, such a photo
-- just doesn't contribute to the earliest-date computation rather than
-- erroring.
local function buildSpecimenEarliestDates(catalog)
    local candidates = catalog:findPhotosWithProperty(TOOLKIT_ID, "specimenId")
    local earliestRaw = {}
    local earliestFormatted = {}
    for _, photo in ipairs(candidates) do
        local specimenId = photo:getPropertyForPlugin(_PLUGIN, "specimenId")
        if specimenId then
            local raw = photo:getRawMetadata("dateTimeOriginal")
            if raw and (not earliestRaw[specimenId] or raw < earliestRaw[specimenId]) then
                earliestRaw[specimenId] = raw
                earliestFormatted[specimenId] = photo:getFormattedMetadata("dateTimeOriginal")
            end
        end
    end
    return earliestFormatted
end

-- Refuses if this observation's photos somehow already carry more than
-- one distinct specimenId (shouldn't normally happen -- this dialog and
-- its retired predecessor always write the SAME id to every photo in one
-- observation -- but same fail-fast posture as ObservationGroup.expand's
-- own cross-observation check: refuse rather than guess which one is
-- right and silently overwrite the other).
local function resolveCurrentSpecimenId(targetPhotos)
    local distinctIds, orderedIds = {}, {}
    for _, photo in ipairs(targetPhotos) do
        local id = photo:getPropertyForPlugin(_PLUGIN, "specimenId")
        if id and not distinctIds[id] then
            distinctIds[id] = true
            table.insert(orderedIds, id)
        end
    end
    if #orderedIds > 1 then
        return nil, "This observation's photos are already linked to different specimens -- reconcile that manually before using the Specimen tab."
    end
    return orderedIds[1], nil
end

-- Backfills the FULL taxon-facts fetch (conservationStatus/
-- establishmentMeans/wikipediaUrl/commonNames/iconicTaxonName, all in one
-- iNat call) for a species that predates one or more of these fields --
-- gated on TaxonStore.hasInatCommonNames, NOT just `commonNames` being
-- nil (found live 2026-08-16: commonNames gains an "identify"-tagged
-- entry on EVERY identify run regardless, via KeywordWriter's own
-- unconditional per-run merge -- so a species can have a real, non-nil
-- commonNames list despite the richer iNat fetch never having run; only
-- an "inat"-sourced entry proves it has -- see
-- TaxonStore.hasInatCommonNames's own comment). Called once, early,
-- before checkScope -- so opening this dialog alone is enough to
-- populate the Tab 1 common-name picker with iNat's full name list,
-- without requiring a fresh "Species Identification" run first. Returns
-- nothing; callers re-read TaxonStore.get() themselves afterward.
local function ensureTaxonFactsBackfilled(scientificName, taxonId, photo)
    local bareEntry = TaxonStore.get(scientificName)
    if bareEntry and TaxonStore.hasInatCommonNames(bareEntry.commonNames) then
        return
    end
    if not taxonId then
        return
    end
    local gps = photo:getRawMetadata("gps")
    local facts = INaturalist.getTaxonFacts(taxonId, gps and gps.latitude, gps and gps.longitude)
    TaxonStore.set(scientificName, facts)
end

-- Plant/fungus scope gate. iconicTaxonName is cached on the bare
-- TaxonStore entry once known (species-wide, see TaxonStore.lua's
-- BARE_ONLY_FIELDS) -- captured for free on every species identified from
-- 2026-08-15 onward (INaturalist.getTaxonFacts now returns it), and by
-- ensureTaxonFactsBackfilled above for older species in the common case.
-- Keeps its OWN narrow fallback below too (the cheaper
-- INaturalist.getIconicTaxonName, not a full getTaxonFacts refetch) purely
-- as a defensive no-op-if-already-cached safety net for the rare case
-- where iconicTaxonName is still missing despite commonNames already being
-- populated -- not expected to actually fire in the common path. Returns
-- "ok" (Plantae/Fungi, proceed silently), "refuse" plus the real
-- iconicTaxonName (a known other kingdom -- block), or "unknown" (no
-- cached fact and no taxonId to look one up with, or the lookup failed --
-- ask before proceeding).
local function checkScope(scientificName, taxonId)
    local bareEntry = TaxonStore.get(scientificName)
    local iconicTaxonName = bareEntry and bareEntry.iconicTaxonName
    if not iconicTaxonName and taxonId then
        iconicTaxonName = INaturalist.getIconicTaxonName(taxonId)
        if iconicTaxonName then
            TaxonStore.set(scientificName, { iconicTaxonName = iconicTaxonName })
        end
    end
    if not iconicTaxonName then
        return "unknown"
    end
    if PLANT_FUNGUS_KINGDOMS[iconicTaxonName] then
        return "ok"
    end
    return "refuse", iconicTaxonName
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Manage Local Flora Observation", "No photos selected.", "info")
        return
    end

    local targetPhotos, groupError = ObservationGroup.expand(catalog, photos)
    if groupError then
        LrDialogs.message("Manage Local Flora Observation", groupError, "warning")
        return
    end

    local scientificName = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "scientificName")
    if not scientificName then
        LrDialogs.message(
            "Manage Local Flora Observation",
            "This photo hasn't been identified yet -- run \"Species Identification\" on it first.",
            "info"
        )
        return
    end
    local cultivar = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "cultivar")
    local taxonId = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "taxonId")
    local taxonRank = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "taxonRank")
    local observationNickname = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "observationNickname")
    local observationNotes = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "observationNotes")

    ensureTaxonFactsBackfilled(scientificName, taxonId, targetPhotos[1])

    local scopeResult, refusedKingdom = checkScope(scientificName, taxonId)
    if scopeResult == "refuse" then
        LrDialogs.message(
            "Manage Local Flora Observation",
            scientificName .. " is classified under " .. refusedKingdom .. ", not Plantae/Fungi -- this command is for local flora only.",
            "warning"
        )
        return
    elseif scopeResult == "unknown" then
        local proceed = LrDialogs.confirm(
            "Manage Local Flora Observation",
            "Couldn't determine whether " .. scientificName .. " is a plant or fungus (no cached classification, and no iNat taxon id to look one up with). Continue anyway?",
            "Continue", "Cancel"
        )
        if proceed ~= "ok" then
            return
        end
    end

    local currentSpecimenId, specimenIdError = resolveCurrentSpecimenId(targetPhotos)
    if specimenIdError then
        LrDialogs.message("Manage Local Flora Observation", specimenIdError, "warning")
        return
    end
    local currentObservationId = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "observationId")

    -- ===== Taxon-level read prep (mirrors the retired EditTaxonInfo.lua) =====
    local existing = TaxonStore.get(scientificName, cultivar) or {}
    local existingCommonNames = existing.commonNames or {}
    -- A species identified before commonName started resolving through
    -- TaxonStore has a real commonName already sitting on its photos, but
    -- nothing in TaxonStore's own commonNames list -- without this
    -- backfill, the picker would default to a blank "Add new" with no
    -- existing value shown, and saving would silently overwrite that
    -- perfectly good existing name with nil.
    if #existingCommonNames == 0 then
        local photoCommonName = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "commonName")
        if photoCommonName then
            existingCommonNames = { { name = photoCommonName, source = "existing" } }
        end
    end
    -- Normalize + dedupe for display -- entries stored before Title Case
    -- normalization existed (or merged from sources with inconsistent
    -- casing) can otherwise show up as separate, redundant picker options
    -- that are really the same name ("great mullein" vs "Great mullein").
    -- Re-titlecasing on READ, not just at original ingestion, cleans this
    -- up gradually as each taxon gets touched via this dialog. Doesn't
    -- silently rewrite TaxonStore on its own -- Cancel never calls
    -- TaxonStore.set, so this is display prep only unless the user saves.
    do
        local seen, normalized = {}, {}
        for _, entry in ipairs(existingCommonNames) do
            local name = titleCase(entry.name)
            if name and not seen[name] then
                seen[name] = true
                table.insert(normalized, { name = name, source = entry.source })
            end
        end
        existingCommonNames = normalized
    end
    -- Same reasoning as existingCommonNames above -- preferredCommonName
    -- can predate Title Case normalization too, and it feeds both this
    -- dialog's default radio selection (below) and the fallback value
    -- saved back to TaxonStore if the user doesn't change anything.
    existing.preferredCommonName = titleCase(existing.preferredCommonName)
    local existingLocations = existing.gardenLocations or {}

    -- gardenLocation's value list is shared by both the specimen's own
    -- single-select (keeps the nil "(unknown)" placeholder -- a specimen
    -- can legitimately have no location yet) and the taxon checklist
    -- (filters it out -- a checklist has no sensible "unknown" entry, and
    -- a nil table index/string-concat there is a hard crash).
    local allLocationValues = findFieldValues("gardenLocation")
    local checklistLocationValues = {}
    for _, entry in ipairs(allLocationValues) do
        if entry.value ~= nil then
            table.insert(checklistLocationValues, entry)
        end
    end
    local locationTitles = {}
    for _, entry in ipairs(allLocationValues) do
        if entry.value then
            locationTitles[entry.value] = entry.title
        end
    end

    -- ===== Specimen-level read prep (mirrors the retired ManageSpecimen.lua) =====
    local currentSpecimen = (currentSpecimenId and SpecimenStore.get(currentSpecimenId)) or {}
    local earliestDates = buildSpecimenEarliestDates(catalog)

    -- SpecimenStore has no "find by scientificName" query of its own --
    -- same "load the whole (small, local-file) store and filter" approach
    -- already used for catalog-wide scans elsewhere in this plugin (e.g.
    -- ObservationReport.lua).
    local allSpecimens = SpecimenStore.load()
    -- A specimen is one physical, stationary plant -- it can't move --
    -- so a candidate with a KNOWN, DIFFERENT location can never actually
    -- be the same individual as this observation's specimen. Per the
    -- user: exclude those outright, don't just list every same-species
    -- specimen regardless of where it is. Only filters when THIS
    -- specimen's own location is already known (currentSpecimen.gardenLocation)
    -- -- an unknown location isn't evidence of disagreement either way
    -- (same "don't treat an unknown as meaningfully comparable" principle
    -- already applied elsewhere, see feedback_nil_comparison), so with
    -- nothing yet to compare against, every same-species specimen stays
    -- a candidate. Static, computed once before the dialog opens -- does
    -- NOT live-update if the user changes the Location tab's selection
    -- mid-session (that would need reactive LrView binding this codebase
    -- hasn't proven yet).
    local currentLocation = currentSpecimen.gardenLocation
    local otherSpecimens = {}
    for id, entry in pairs(allSpecimens) do
        if entry.scientificName == scientificName and id ~= currentSpecimenId
            and (not currentLocation or entry.gardenLocation == currentLocation) then
            table.insert(otherSpecimens, { id = id, entry = entry })
        end
    end
    table.sort(otherSpecimens, function(a, b)
        return describeSpecimen(a.id, a.entry, earliestDates) < describeSpecimen(b.id, b.entry, earliestDates)
    end)

    local saved = false
    local props

    LrFunctionContext.callWithContext("ManageFloraObservation", function(context)
        props = LrBinding.makePropertyTable(context)
        props.activeTab = "identification"

        -- Tab 1
        props.cultivarText = cultivar or ""
        props.observationNicknameText = observationNickname or ""
        props.observationNotesText = observationNotes or ""
        props.growthHabit = existing.growthHabit or UNSET
        props.nativity = existing.nativity or UNSET
        props.notesText = existing.notes or ""
        props.newCommonNameText = ""
        -- Falls back to the (possibly backfilled, see above) first
        -- existing name before "__new__", so a legacy species with no
        -- preferredCommonName yet still defaults to its real current name
        -- rather than a blank "Add new".
        props.commonNameChoice = existing.preferredCommonName
            or (existingCommonNames[1] and existingCommonNames[1].name)
            or "__new__"

        -- Tab 2
        props.specimenGardenLocation = currentSpecimen.gardenLocation or UNSET
        props.specimenLocationNotesText = currentSpecimen.locationNotes or ""
        for _, entry in ipairs(checklistLocationValues) do
            local existingValue = existingLocations[entry.value]
            props["taxonLocChecked_" .. entry.value] = existingValue ~= nil
            props["taxonLocDesc_" .. entry.value] = (type(existingValue) == "string") and existingValue or ""
        end

        -- Tab 3
        props.plantingMethod = currentSpecimen.plantingMethod or UNSET
        props.plantingYearText = currentSpecimen.plantingYear or ""

        -- Tab 4
        props.nicknameText = currentSpecimen.nickname or ""
        props.specimenLinkChoice = NO_SPECIMEN_LINK

        local f = LrView.osFactory()

        -- Always-visible thumbnail row, above the tabs -- same row-of-
        -- catalog_photo pattern already proven in MergeCandidatesDialog.lua
        -- and INatSyncRunner.lua, minus their checkbox/interactivity (pure
        -- display here).
        local thumbnailColumns = {}
        for _, photo in ipairs(targetPhotos) do
            table.insert(thumbnailColumns, f:column {
                f:catalog_photo { photo = photo, width = 100, height = 100, frame_width = 1 },
            })
        end

        -- --- Tab 1: Identification ---
        local commonNameRows = {}
        for _, entry in ipairs(existingCommonNames) do
            table.insert(commonNameRows, f:radio_button {
                title = entry.name,
                value = LrView.bind("commonNameChoice"),
                checked_value = entry.name,
            })
        end
        table.insert(commonNameRows, f:row {
            f:radio_button {
                title = "Add new:",
                value = LrView.bind("commonNameChoice"),
                checked_value = "__new__",
            },
            f:edit_field { value = LrView.bind("newCommonNameText"), width_in_chars = 24 },
        })

        local identificationTab = f:column {
            spacing = f:control_spacing(),
            f:static_text {
                title = "Taxon: " .. scientificName .. " (" .. describeRank(taxonRank) .. ")",
            },
            f:row {
                f:static_text { title = "Cultivar:", width_in_chars = 22 },
                f:edit_field { value = LrView.bind("cultivarText"), width_in_chars = 24 },
            },
            f:row {
                f:static_text { title = "Observation Nickname:", width_in_chars = 22 },
                f:edit_field { value = LrView.bind("observationNicknameText"), width_in_chars = 30 },
            },
            f:row {
                f:static_text { title = "Observation Notes:", width_in_chars = 22 },
                f:edit_field { value = LrView.bind("observationNotesText"), width_in_chars = 30 },
            },
            f:group_box {
                title = "Common Name",
                fill_horizontal = 1,
                f:column(commonNameRows),
            },
            -- Each radio group needs its OWN f:group_box -- Lightroom's
            -- native radio buttons group by shared container, not by
            -- which property they're bound to, so two unboxed groups
            -- sitting side by side end up mutually exclusive with EACH
            -- OTHER, not just within themselves (confirmed live
            -- 2026-08-15 in this dialog's two predecessors).
            f:group_box {
                fill_horizontal = 1,
                f:row {
                    f:static_text { title = "Growth Habit:", width_in_chars = 22 },
                    buildEnumRadioGroup(f, "growthHabit", "growthHabit"),
                },
            },
            f:group_box {
                fill_horizontal = 1,
                f:row {
                    f:static_text { title = "Nativity:", width_in_chars = 22 },
                    buildEnumRadioGroup(f, "nativity", "nativity"),
                },
            },
            f:row {
                f:static_text { title = "Species Notes:", width_in_chars = 22 },
                f:edit_field { value = LrView.bind("notesText"), width_in_chars = 30 },
            },
            f:spacer { height = 8 },
            f:static_text { title = "Reference (read-only, from iNaturalist):" },
            f:static_text { title = "Conservation status: " .. (existing.conservationStatus or "(unknown)") },
            f:static_text { title = "Establishment means: " .. (existing.establishmentMeans or "(unknown)") },
            f:row {
                f:static_text { title = "iNat Taxon Page:", width_in_chars = 22 },
                taxonId
                    and f:push_button {
                        title = "Open",
                        action = function()
                            LrHttp.openUrlInBrowser("https://www.inaturalist.org/taxa/" .. tostring(taxonId))
                        end,
                    }
                    or f:static_text { title = "(none)" },
            },
            f:row {
                f:static_text { title = "Wikipedia:", width_in_chars = 22 },
                existing.wikipediaUrl
                    and f:push_button {
                        title = "Open",
                        action = function() LrHttp.openUrlInBrowser(existing.wikipediaUrl) end,
                    }
                    or f:static_text { title = "(none)" },
            },
        }

        -- --- Tab 2: Location ---
        local taxonLocationRows = {}
        for _, entry in ipairs(checklistLocationValues) do
            table.insert(taxonLocationRows, f:row {
                f:checkbox { title = entry.title, value = LrView.bind("taxonLocChecked_" .. entry.value), width_in_chars = 14 },
                f:edit_field {
                    value = LrView.bind("taxonLocDesc_" .. entry.value),
                    enabled = LrView.bind("taxonLocChecked_" .. entry.value),
                    width_in_chars = 24,
                },
            })
        end

        local locationTab = f:column {
            spacing = f:control_spacing(),
            f:group_box {
                title = "This specimen's location",
                fill_horizontal = 1,
                f:column {
                    spacing = f:control_spacing(),
                    buildEnumRadioGroup(f, "gardenLocation", "specimenGardenLocation"),
                    f:row {
                        f:static_text { title = "Notes:", width_in_chars = 8 },
                        f:edit_field { value = LrView.bind("specimenLocationNotesText"), width_in_chars = 30 },
                    },
                },
            },
            f:group_box {
                title = "All locations this species is known to grow in",
                fill_horizontal = 1,
                f:column(taxonLocationRows),
            },
        }

        -- --- Tab 3: Introduction Method ---
        local introductionTab = f:column {
            spacing = f:control_spacing(),
            f:group_box {
                fill_horizontal = 1,
                f:row {
                    f:static_text { title = "Introduction Method:", width_in_chars = 22 },
                    buildEnumRadioGroup(f, "plantingMethod", "plantingMethod"),
                },
            },
            f:row {
                f:static_text { title = "Introduction Year:", width_in_chars = 22 },
                f:edit_field { value = LrView.bind("plantingYearText"), width_in_chars = 20 },
            },
        }

        -- --- Tab 4: Specimen ---
        local specimenRecapText
        if currentSpecimenId then
            local otherObsCount = countOtherObservationsOfSpecimen(catalog, currentSpecimenId, currentObservationId)
            if otherObsCount > 0 then
                specimenRecapText = string.format(
                    "Linked to specimen \"%s\" -- also seen in %d other observation%s.",
                    describeSpecimen(currentSpecimenId, currentSpecimen, earliestDates),
                    otherObsCount, otherObsCount == 1 and "" or "s"
                )
            else
                specimenRecapText = string.format(
                    "Linked to specimen \"%s\" -- no other observations of it yet.",
                    describeSpecimen(currentSpecimenId, currentSpecimen, earliestDates)
                )
            end
        else
            specimenRecapText = "Not yet linked to a specimen -- one will be created automatically if you set any of the fields below."
        end

        -- Wording is context-aware -- confirmed live 2026-08-17 that the
        -- old fixed "No, this is its own specimen" label read as a factual
        -- claim ("this photo's specimen is a singleton") even when
        -- currentSpecimenId already links it to other photos elsewhere --
        -- misleading, since this radio only ever means "don't merge into
        -- a DIFFERENT specimen," not "this has no link at all." The
        -- specimenRecapText line above already states the real link
        -- status; this option's own label just needs to stop contradicting
        -- it.
        local noLinkChangeTitle = currentSpecimenId
            and "No -- keep as currently linked"
            or "No, this is its own specimen"

        local linkRows = {
            f:radio_button {
                title = noLinkChangeTitle,
                value = LrView.bind("specimenLinkChoice"),
                checked_value = NO_SPECIMEN_LINK,
            },
        }
        for _, specimen in ipairs(otherSpecimens) do
            table.insert(linkRows, f:radio_button {
                title = describeSpecimen(specimen.id, specimen.entry, earliestDates),
                value = LrView.bind("specimenLinkChoice"),
                checked_value = specimen.id,
            })
        end

        local specimenTab = f:column {
            spacing = f:control_spacing(),
            f:static_text { title = specimenRecapText },
            f:row {
                f:static_text { title = "Nickname:", width_in_chars = 22 },
                f:edit_field { value = LrView.bind("nicknameText"), width_in_chars = 30 },
            },
            f:spacer { height = 8 },
            f:group_box {
                title = "Is this the same individual as an earlier observation?",
                fill_horizontal = 1,
                f:column {
                    spacing = f:control_spacing() / 2,
                    -- This list is filtered to specimens at the same
                    -- location, computed once when this dialog opened --
                    -- it does NOT live-update if you change the Location
                    -- tab's selection in this same session (see the
                    -- filter's own comment above, in this file's main
                    -- body, for why: would need reactive LrView binding
                    -- this codebase hasn't built yet).
                    f:static_text {
                        title = "(Only same-location specimens are listed. If you just changed Location, save and reopen this dialog for the list to catch up.)",
                        width_in_chars = 60,
                    },
                    f:column(linkRows),
                },
            },
        }

        -- bind_to_object lives on this outer column, a SIBLING of the
        -- tab_view, not nested inside any one tab panel -- confirmed
        -- working structure, ported from CandidatePicker.lua's own
        -- tab_view usage.
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:row(thumbnailColumns),
            f:tab_view {
                value = LrView.bind("activeTab"),
                f:tab_view_item { identifier = "identification", title = "Identification", identificationTab },
                f:tab_view_item { identifier = "location", title = "Location", locationTab },
                f:tab_view_item { identifier = "introduction", title = "Introduction Method", introductionTab },
                f:tab_view_item { identifier = "specimen", title = "Specimen", specimenTab },
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Manage Local Flora Observation",
            contents = contents,
            actionVerb = "Save",
        }

        saved = (result == "ok")
    end)

    if not saved then
        return
    end

    -- Observation-scoped, same mechanism as cultivar -- a plain photo
    -- property, not routed through TaxonStore/SpecimenStore at all.
    local observationNicknameValue = (props.observationNicknameText ~= "") and props.observationNicknameText or nil
    local observationNotesValue = (props.observationNotesText ~= "") and props.observationNotesText or nil

    -- ===== Resolve Tab 1 (taxon-level) values =====
    -- An empty box means "clear it" -- nil for the photo-property write
    -- below (a real function call, passes nil through fine); TaxonStore.CLEAR
    -- for the TaxonStore.set call further down (a plain nil there would be
    -- silently dropped by the table constructor and never actually clear
    -- the stored field -- see TaxonStore.CLEAR's own comment).
    local growthHabitValue = (props.growthHabit ~= UNSET) and props.growthHabit or nil
    local nativityValue = (props.nativity ~= UNSET) and props.nativity or nil
    local notesValue = (props.notesText ~= "") and props.notesText or nil

    local gardenLocationsValue = {}
    for _, entry in ipairs(checklistLocationValues) do
        if props["taxonLocChecked_" .. entry.value] then
            local desc = props["taxonLocDesc_" .. entry.value]
            gardenLocationsValue[entry.value] = (desc ~= "") and desc or false
        end
    end

    -- Resolve the common-name choice: either an existing name was picked,
    -- or "Add new" was picked with real text typed in -- in which case it
    -- both becomes preferred AND gets appended to the list (deduped by
    -- exact string, same as KeywordWriter.applyIdentification's own merge
    -- logic) if it isn't already there somehow.
    local preferredCommonNameValue = existing.preferredCommonName
    local commonNamesValue = existingCommonNames
    if props.commonNameChoice == "__new__" then
        if props.newCommonNameText ~= "" then
            preferredCommonNameValue = titleCase(props.newCommonNameText)
            local alreadyPresent = false
            for _, entry in ipairs(commonNamesValue) do
                if entry.name == preferredCommonNameValue then
                    alreadyPresent = true
                    break
                end
            end
            if not alreadyPresent then
                commonNamesValue = {}
                for _, entry in ipairs(existingCommonNames) do
                    table.insert(commonNamesValue, entry)
                end
                table.insert(commonNamesValue, { name = preferredCommonNameValue, source = "manual" })
            end
        end
    else
        preferredCommonNameValue = props.commonNameChoice
    end
    -- Defensive re-normalization -- every path above should already
    -- resolve to Title Case (existingCommonNames/existing.preferredCommonName
    -- are normalized on read above, and the "Add new" path normalizes
    -- explicitly), but this guarantees the keyword and caption this
    -- dialog actually writes are never the one place a stale casing slips
    -- through, regardless of how preferredCommonNameValue got resolved.
    preferredCommonNameValue = titleCase(preferredCommonNameValue)

    -- Resolved from the dialog's own Cultivar field, not the `cultivar`
    -- read before the dialog opened -- that original value only governs
    -- what was initially SHOWN (existing/existingCommonNames/
    -- existingLocations were all loaded against it). If the user changed
    -- it, every taxon-level field below is written against the NEW
    -- cultivar's entry using whatever's currently in the dialog's own
    -- fields -- there's no live re-fetch/re-populate against the new
    -- cultivar's own pre-existing data mid-dialog (unlike SetCultivar.lua,
    -- which has no editable fields of its own to conflict with). A known,
    -- deliberately simple choice: what's in the dialog at Save time is
    -- what gets written, full stop.
    local newCultivar = (props.cultivarText ~= "") and props.cultivarText or nil

    TaxonStore.set(scientificName, {
        growthHabit = growthHabitValue or TaxonStore.CLEAR,
        nativity = nativityValue or TaxonStore.CLEAR,
        notes = notesValue or TaxonStore.CLEAR,
        gardenLocations = gardenLocationsValue,
        commonNames = commonNamesValue,
        preferredCommonName = preferredCommonNameValue,
    }, newCultivar)

    local taxonTargetPhotos = findAllPhotosOfTaxon(catalog, scientificName, newCultivar)
    if #taxonTargetPhotos == 0 then
        -- Shouldn't normally happen (the selected photo itself should
        -- always match), but fall back to just the observation if it does.
        taxonTargetPhotos = targetPhotos
    end
    local gardenLocationsDisplay = TaxonStore.formatGardenLocations(gardenLocationsValue, locationTitles)

    -- ===== Resolve Tabs 2-3 (this observation's specimen-level "final
    -- intent" -- already pre-populated from currentSpecimen if any, then
    -- possibly edited; there's no separate "old data" to reconcile) =====
    local sourceFields = {
        gardenLocation = (props.specimenGardenLocation ~= UNSET) and props.specimenGardenLocation or nil,
        locationNotes = (props.specimenLocationNotesText ~= "") and props.specimenLocationNotesText or nil,
        plantingMethod = (props.plantingMethod ~= UNSET) and props.plantingMethod or nil,
        plantingYear = (props.plantingYearText ~= "") and props.plantingYearText or nil,
        nickname = (props.nicknameText ~= "") and props.nicknameText or nil,
    }

    -- ===== Tab 4 save-time algorithm =====
    local effectiveSpecimenId
    local resolvedSpecimen
    local keptFromLinkTitles = {}

    if props.specimenLinkChoice == NO_SPECIMEN_LINK then
        local hasAnyValue = sourceFields.gardenLocation or sourceFields.locationNotes
            or sourceFields.plantingMethod or sourceFields.plantingYear or sourceFields.nickname
        if currentSpecimenId then
            -- An ordinary edit of the observation's own specimen --
            -- SpecimenStore.CLEAR (not nil) for any field the user just
            -- blanked, so it's actually removed from the stored entry
            -- rather than silently left as-is.
            effectiveSpecimenId = currentSpecimenId
            resolvedSpecimen = SpecimenStore.set(effectiveSpecimenId, {
                gardenLocation = sourceFields.gardenLocation or SpecimenStore.CLEAR,
                locationNotes = sourceFields.locationNotes or SpecimenStore.CLEAR,
                plantingMethod = sourceFields.plantingMethod or SpecimenStore.CLEAR,
                plantingYear = sourceFields.plantingYear or SpecimenStore.CLEAR,
                nickname = sourceFields.nickname or SpecimenStore.CLEAR,
            })
        elseif hasAnyValue then
            -- Implicit creation -- no explicit "create a specimen" step
            -- exists in this UI; a specimenId is generated silently the
            -- first time any specimen-level field is actually saved with
            -- a real value, matching how TaxonStore already creates
            -- entries implicitly on first write.
            effectiveSpecimenId = KeywordWriter.generateUUID()
            resolvedSpecimen = SpecimenStore.set(effectiveSpecimenId, {
                scientificName = scientificName,
                gardenLocation = sourceFields.gardenLocation,
                locationNotes = sourceFields.locationNotes,
                plantingMethod = sourceFields.plantingMethod,
                plantingYear = sourceFields.plantingYear,
                nickname = sourceFields.nickname,
            })
        else
            -- Nothing to create -- this observation stays unlinked.
            effectiveSpecimenId = nil
            resolvedSpecimen = {}
        end
    else
        -- Linking to an existing specimen X: X's already-set fields are
        -- NEVER overwritten -- only fields X is missing get filled in
        -- from this observation's own data. Per the user: whenever a
        -- field just edited here is about to be discarded because X
        -- already has a value, note it for the post-save summary rather
        -- than silently dropping it.
        local targetSpecimenId = props.specimenLinkChoice
        local targetEntry = SpecimenStore.get(targetSpecimenId) or {}
        local fillFields = {}
        for _, fieldName in ipairs(SPECIMEN_FIELD_NAMES) do
            if targetEntry[fieldName] == nil and sourceFields[fieldName] ~= nil then
                fillFields[fieldName] = sourceFields[fieldName]
            elseif targetEntry[fieldName] ~= nil and sourceFields[fieldName] ~= nil
                and targetEntry[fieldName] ~= sourceFields[fieldName] then
                table.insert(keptFromLinkTitles, SPECIMEN_FIELD_TITLES[fieldName])
            end
        end
        if not targetEntry.scientificName then
            -- Shouldn't normally happen (SpecimenStore entries are never
            -- written without one in this codebase) but cheap to guard.
            fillFields.scientificName = scientificName
        end
        if next(fillFields) then
            SpecimenStore.set(targetSpecimenId, fillFields)
        end
        -- Re-fetch for the fully-resolved entry (fillFields alone may be
        -- a partial view) to fan out below.
        effectiveSpecimenId = targetSpecimenId
        resolvedSpecimen = SpecimenStore.get(targetSpecimenId) or {}
    end

    -- ===== Write transaction =====
    -- Taxon-level fields fan out to every photo of the taxon
    -- (taxonTargetPhotos); specimen-level fields only to this
    -- observation's own photos (targetPhotos) -- the two sets overlap
    -- (targetPhotos is normally a subset of taxonTargetPhotos), so a
    -- single deduplicated loop is used rather than two separate loops --
    -- PendingMetadataSave.markIfNeeded must be called exactly ONCE per
    -- photo per transaction (its own doc comment: a second call in the
    -- same transaction can read back a stale value, since
    -- getPropertyForPlugin isn't guaranteed to reflect a
    -- setPropertyForPlugin made earlier in the same transaction).
    local isInObservation = {}
    for _, photo in ipairs(targetPhotos) do
        isInObservation[photo] = true
    end

    local touchedPhotos = {}
    local seen = {}
    for _, photo in ipairs(taxonTargetPhotos) do
        if not seen[photo] then
            seen[photo] = true
            table.insert(touchedPhotos, photo)
        end
    end
    for _, photo in ipairs(targetPhotos) do
        if not seen[photo] then
            seen[photo] = true
            table.insert(touchedPhotos, photo)
        end
    end

    -- Photos needing their "Species ID" keyword synced to the new common
    -- name -- collected here, actually synced in a SEPARATE, LATER call
    -- below (not inline in the main loop). Confirmed live 2026-08-17
    -- ("assertion failed!" on every save that changed the common name):
    -- keyword mutation isn't safe to interleave with this transaction's
    -- OTHER writes to the same photo -- same class of constraint already
    -- found for catalog:createCollection + getPhotos (see
    -- feedback_verify_sdk_limitations) -- querying/mutating a keyword
    -- tree right alongside unrelated property writes in one transaction
    -- apparently isn't safe either, just a different SDK surface hitting
    -- the same underlying lesson. All entries share the same label (one
    -- common name per observation), so only the photo list needs
    -- collecting -- keywordLabel is set once below.
    local keywordPhotos = {}
    local keywordLabel = nil

    catalog:withWriteAccessDo("Manage local flora observation", function()
        for _, photo in ipairs(touchedPhotos) do
            photo:setPropertyForPlugin(_PLUGIN, "growthHabit", growthHabitValue)
            photo:setPropertyForPlugin(_PLUGIN, "nativity", nativityValue)
            photo:setPropertyForPlugin(_PLUGIN, "gardenLocations", gardenLocationsDisplay)
            photo:setPropertyForPlugin(_PLUGIN, "notes", notesValue)
            -- No "(none)" choice for common name in this dialog -- it's
            -- always either an existing name or freshly typed text, never
            -- an intentional clear -- so a nil here would only mean a
            -- legacy species with no name anywhere; skip the write rather
            -- than risk ever clobbering a real value.
            if preferredCommonNameValue then
                photo:setPropertyForPlugin(_PLUGIN, "commonName", preferredCommonNameValue)
                -- Keeps Lightroom's own native Caption in sync -- see
                -- formatCaption's own comment. Title is left alone: it's
                -- always just the bare scientificName (same convention
                -- KeywordWriter.applyIdentification already uses), which
                -- doesn't change based on common name. The matching
                -- "Species ID" keyword is queued for its own later sync
                -- call, not touched here -- see keywordPhotos' own
                -- comment above.
                local newCaption = formatCaption(preferredCommonNameValue, scientificName)
                photo:setRawMetadata("caption", newCaption)
                table.insert(keywordPhotos, photo)
                keywordLabel = newCaption
            end

            if isInObservation[photo] then
                photo:setPropertyForPlugin(_PLUGIN, "cultivar", newCultivar)
                photo:setPropertyForPlugin(_PLUGIN, "observationNickname", observationNicknameValue)
                photo:setPropertyForPlugin(_PLUGIN, "observationNotes", observationNotesValue)
                photo:setPropertyForPlugin(_PLUGIN, "specimenId", effectiveSpecimenId)
                photo:setPropertyForPlugin(_PLUGIN, "gardenLocation", resolvedSpecimen.gardenLocation)
                photo:setPropertyForPlugin(_PLUGIN, "locationNotes", resolvedSpecimen.locationNotes)
                photo:setPropertyForPlugin(_PLUGIN, "plantingMethod", resolvedSpecimen.plantingMethod)
                photo:setPropertyForPlugin(_PLUGIN, "plantingYear", resolvedSpecimen.plantingYear)
                photo:setPropertyForPlugin(_PLUGIN, "nickname", resolvedSpecimen.nickname)
            end

            PendingMetadataSave.markIfNeeded(catalog, photo)
        end
    end)

    -- Mirrors applyIdentification's own proven keyword-swap pattern (see
    -- KeywordWriter.syncSpeciesKeyword's own doc comment for the full
    -- history) -- one shared keyword created once and applied across the
    -- whole batch in ONE transaction, rather than the earlier
    -- per-photo/per-transaction/verify-then-remove design that caused
    -- real, repeated keyword loss in live testing (confirmed 2026-08-17)
    -- across several different mitigation attempts. One pcall for the
    -- whole batch, matching how confidently applyIdentification itself is
    -- already called elsewhere -- every OTHER write in this dialog
    -- (caption, specimen fields, etc.) already committed in the
    -- transaction above regardless of what happens here.
    local keywordSyncFailed = false
    local keywordSyncError = nil
    if #keywordPhotos > 0 then
        local ok, err = LrTasks.pcall(KeywordWriter.syncSpeciesKeyword, keywordPhotos, keywordLabel)
        if not ok then
            keywordSyncFailed = true
            keywordSyncError = tostring(err)
        end
    end

    local summaryParts = {
        string.format("%d photo%s updated.", #touchedPhotos, #touchedPhotos == 1 and "" or "s"),
    }
    if keywordSyncFailed then
        table.insert(
            summaryParts,
            string.format("Caption updated, but the matching keyword failed to sync: %s", keywordSyncError)
        )
    end
    if #keptFromLinkTitles > 0 then
        table.insert(
            summaryParts,
            "Kept the linked specimen's existing value for: " .. table.concat(keptFromLinkTitles, ", ")
                .. " -- your edits to those fields on this observation were not applied."
        )
    end
    LrDialogs.message("Manage Local Flora Observation", table.concat(summaryParts, "\n\n"), "info")
end)
