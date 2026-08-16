local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrProgressScope = import 'LrProgressScope'
local LrPathUtils = import 'LrPathUtils'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))
local TaxonStore = dofile(LrPathUtils.child(_PLUGIN.path, "TaxonStore.lua"))
local SpecimenStore = dofile(LrPathUtils.child(_PLUGIN.path, "SpecimenStore.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))

-- One-off migration of PlantBook's tagged photos into this plugin's own
-- schema -- same throwaway-migration-tool pattern as BackfillTaxonId.lua.
-- See the approved plan for the full design rationale; this file follows
-- its three phases: Analysis (read-only), Confirmation (a summary dialog
-- gating the actual metadata migration below it), and Write (order-
-- dependent -- TaxonStore.set must complete before any
-- KeywordWriter.applyIdentification call, since that function now reads
-- TaxonStore's preferredCommonName mid-write -- see "Common name
-- resolution flow" in KeywordWriter.lua). One deliberate exception to
-- "nothing touches the catalog before confirm": the "unresolved species"
-- recovery collection (see UNRESOLVED_COLLECTION_NAME below) is synced
-- BEFORE the confirmation gate, per the user -- they want to see and fix
-- those photos without first committing to the real migration. A
-- collection add/remove is non-destructive and easily reversible, unlike
-- everything else this script writes.
--
-- Cultivar handling (added 2026-08-16, found live): PlantBook embeds a
-- cultivar directly INTO its scientificName field as a quoted suffix
-- ("Genus species 'Cultivar'"), not as a separate field -- confirmed via
-- a real migration run where over a dozen perfectly-real species (Iris x
-- germanica 'Yellow Iris', Prunus avium 'Compact Stella', etc.) failed
-- iNaturalist resolution because the whole quoted string was being fed in
-- as a literal (and obviously unresolvable) species name. Split apart via
-- parseCultivarSuffix below, then threaded through as its own value --
-- see readPlantBookFields, groupByCultivar, and the per-cultivar
-- TaxonStore.set calls in the write phase.
local PLANTBOOK_TOOLKIT_ID = "org.krefting.plant-book"

-- Photos left with no identification at all because PlantBook's own name
-- for them didn't resolve on iNaturalist -- same persistent-collection
-- pattern as PendingMetadataSave.lua (createCollection's 3rd arg =
-- return-existing, so reruns reuse the same collection rather than
-- erroring or creating duplicates). Per the user: fix PlantBook's naming
-- for whatever's still in here, then run this migration again -- kept in
-- sync with the CURRENT run's findings each time (cleared and rebuilt,
-- not accumulated), so a photo that resolves this time no longer lingers
-- from a stale previous run.
local UNRESOLVED_COLLECTION_NAME = "PlantBook Migration - Unresolved Species"

-- PlantBook embeds a cultivar directly INTO scientificName as a quoted
-- suffix ("Genus species 'Cultivar'"), not as a separate field the way
-- this project has one. A cultivar is a horticultural concept iNat has
-- never heard of (same distinction TaxonStore.lua's own cultivar-key
-- design is built on) -- splitting it out here means resolution/
-- grouping/facts-writing all operate on the real, iNat-resolvable base
-- name, with the cultivar carried alongside as its own value instead of
-- silently dooming resolution to fail.
local function parseCultivarSuffix(scientificName)
    if not scientificName then
        return scientificName, nil
    end
    local base, cultivar = scientificName:match("^(.-) '(.+)'$")
    if base and cultivar then
        return base, cultivar
    end
    return scientificName, nil
end

local function readPlantBookFields(photo)
    local scientificName, cultivar = parseCultivarSuffix(
        photo:getPropertyForPlugin(PLANTBOOK_TOOLKIT_ID, "scientificName")
    )
    return {
        scientificName = scientificName,
        cultivar = cultivar,
        commonName = photo:getPropertyForPlugin(PLANTBOOK_TOOLKIT_ID, "commonName"),
        location = photo:getPropertyForPlugin(PLANTBOOK_TOOLKIT_ID, "location"),
        locationDescription = photo:getPropertyForPlugin(PLANTBOOK_TOOLKIT_ID, "locationDescription"),
        notes = photo:getPropertyForPlugin(PLANTBOOK_TOOLKIT_ID, "notes"),
        plantType = photo:getPropertyForPlugin(PLANTBOOK_TOOLKIT_ID, "plantType"),
        nativity = photo:getPropertyForPlugin(PLANTBOOK_TOOLKIT_ID, "nativity"),
        introduced = photo:getPropertyForPlugin(PLANTBOOK_TOOLKIT_ID, "introduced"),
        introductionYear = photo:getPropertyForPlugin(PLANTBOOK_TOOLKIT_ID, "introductionYear"),
    }
end

-- "ScientificName" or "ScientificName 'Cultivar'" -- for disagreement
-- labels in the confirmation summary, so a disagreement specific to one
-- cultivar doesn't read as if it applies to the bare species (or vice
-- versa).
local function taxonLabel(scientificName, cultivar)
    if cultivar then
        return scientificName .. " '" .. cultivar .. "'"
    end
    return scientificName
end

-- Single-valued field agreement check, mirroring book_formatter.py's own
-- _update_plant_type/_update_nativity disagreement logic -- returns the
-- one distinct value found, or nil if none did, plus whether more than
-- one distinct (non-nil) value was seen across `records`.
local function checkAgreement(records, fieldName)
    local value, disagrees = nil, false
    for _, r in ipairs(records) do
        if r[fieldName] then
            if not value then
                value = r[fieldName]
            elseif value ~= r[fieldName] then
                disagrees = true
            end
        end
    end
    return value, disagrees
end

-- commonName needs its own version -- every distinct value seen matters
-- (all get queued into commonNames, per the design), not just whether
-- they agree.
local function collectDistinctCommonNames(records)
    local seen, names = {}, {}
    for _, r in ipairs(records) do
        if r.commonName and not seen[r.commonName] then
            seen[r.commonName] = true
            table.insert(names, r.commonName)
        end
    end
    return names
end

-- Sub-groups a species' records by cultivar (nil = no cultivar, its own
-- group same as any named one) -- growthHabit/nativity/gardenLocations/
-- specimens can genuinely differ by cultivar (see TaxonStore.lua's own
-- cultivar-key design), so agreement-checking, aggregation, and specimen
-- grouping all need to happen PER cultivar sub-group, not once for the
-- whole species. commonNames/preferredCommonName are the exception --
-- BARE_ONLY_FIELDS regardless of cultivar -- computed once per species
-- instead (see the main analysis loop below). Returns a list of
-- { cultivar, records, photos }.
local function groupByCultivar(records, photos)
    local cultivarGroups = {}
    local order = {}
    for i, record in ipairs(records) do
        local key = record.cultivar or ""
        local cg = cultivarGroups[key]
        if not cg then
            cg = { cultivar = record.cultivar, records = {}, photos = {} }
            cultivarGroups[key] = cg
            table.insert(order, key)
        end
        table.insert(cg.records, record)
        table.insert(cg.photos, photos[i])
    end
    local result = {}
    for _, key in ipairs(order) do
        table.insert(result, cultivarGroups[key])
    end
    return result
end

-- Unions every distinct `location` across `records` into a gardenLocations
-- map, concatenating multiple distinct descriptions for the same location
-- (matching get_location_csv_old's own comma-join) rather than picking one
-- arbitrarily. Mirrors book_formatter.py's own _update_location.
local function aggregateGardenLocations(records)
    local descriptionsByLocation = {}
    for _, r in ipairs(records) do
        if r.location then
            local list = descriptionsByLocation[r.location]
            if not list then
                list = {}
                descriptionsByLocation[r.location] = list
            end
            if r.locationDescription then
                local alreadyPresent = false
                for _, d in ipairs(list) do
                    if d == r.locationDescription then
                        alreadyPresent = true
                        break
                    end
                end
                if not alreadyPresent then
                    table.insert(list, r.locationDescription)
                end
            end
        end
    end

    local result = {}
    for location, descriptions in pairs(descriptionsByLocation) do
        result[location] = (#descriptions > 0) and table.concat(descriptions, ", ") or false
    end
    return result
end

-- Best-effort specimen grouping: photos sharing the exact (location,
-- introduced, introductionYear) combination almost certainly represent
-- the same physical individual -- not a guarantee (two genuinely
-- different individuals could share all three), flagged in the summary
-- as an assumption worth spot-checking. Photos with NONE of the three set
-- get no specimen at all. Called once per cultivar sub-group (see
-- groupByCultivar above), so a specimen never spans cultivars -- correct,
-- since a specimen is one physical plant with one identity.
--
-- locationDescription flows into the specimen's own locationNotes -- a
-- better semantic home than only the taxon-level gardenLocations
-- aggregate (aggregateGardenLocations above), since it describes ONE
-- physical plant's spot ("near the big oak"), not the species in general.
-- Multiple distinct descriptions within one specimen group get
-- concatenated, same comma-join reasoning as aggregateGardenLocations --
-- nothing worth discarding.
--
-- Takes a { records, photos } table (a cultivar sub-group from
-- groupByCultivar). Returns a list of { photos, gardenLocation,
-- locationNotes, plantingMethod, plantingYear }.
local function groupIntoSpecimens(group)
    local specimenGroups = {}
    local order = {}
    for i, record in ipairs(group.records) do
        if record.location or record.introduced or record.introductionYear then
            local key = tostring(record.location) .. "|" .. tostring(record.introduced) .. "|" .. tostring(record.introductionYear)
            local sg = specimenGroups[key]
            if not sg then
                sg = {
                    photos = {},
                    gardenLocation = record.location,
                    plantingMethod = record.introduced,
                    plantingYear = record.introductionYear,
                    descriptions = {},
                }
                specimenGroups[key] = sg
                table.insert(order, key)
            end
            table.insert(sg.photos, group.photos[i])
            if record.locationDescription then
                local alreadyPresent = false
                for _, d in ipairs(sg.descriptions) do
                    if d == record.locationDescription then
                        alreadyPresent = true
                        break
                    end
                end
                if not alreadyPresent then
                    table.insert(sg.descriptions, record.locationDescription)
                end
            end
        end
    end

    local result = {}
    for _, key in ipairs(order) do
        local sg = specimenGroups[key]
        if #sg.descriptions > 0 then
            sg.locationNotes = table.concat(sg.descriptions, ", ")
        end
        sg.descriptions = nil
        table.insert(result, sg)
    end
    return result
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()

    ----------------------------------------------------------------------
    -- Analysis phase (read-only -- nothing here touches the catalog or
    -- either store)
    ----------------------------------------------------------------------

    -- Step 1: find every PlantBook-tagged photo. This is the one piece of
    -- real technical uncertainty in this whole script -- a raw toolkit-id
    -- string for a plugin that may not currently be enabled/installed has
    -- not been confirmed live before now.
    local ok, candidates = LrTasks.pcall(function()
        return catalog:findPhotosWithProperty(PLANTBOOK_TOOLKIT_ID, "scientificName")
    end)
    if not ok then
        LrDialogs.message(
            "Migrate PlantBook Metadata",
            "Couldn't read PlantBook's data (" .. tostring(candidates)
                .. "). Make sure the PlantBook plugin is still installed and enabled in Lightroom, then try again.",
            "critical"
        )
        return
    end

    if #candidates == 0 then
        LrDialogs.message("Migrate PlantBook Metadata", "No PlantBook-tagged photos found.", "info")
        return
    end

    -- Step 2: read all of PlantBook's fields per photo (cultivar suffix
    -- already split out by readPlantBookFields), grouped by the BASE
    -- scientificName -- a species with both bare and cultivar-tagged
    -- photos correctly lands in ONE group here (they share taxonId
    -- resolution and species-wide common names regardless of cultivar).
    local groups = {}
    local speciesOrder = {}
    for _, photo in ipairs(candidates) do
        local record = readPlantBookFields(photo)
        if record.scientificName then
            local group = groups[record.scientificName]
            if not group then
                group = { photos = {}, records = {} }
                groups[record.scientificName] = group
                table.insert(speciesOrder, record.scientificName)
            end
            table.insert(group.photos, photo)
            table.insert(group.records, record)
        end
    end

    -- Steps 3-4: per-species taxon-level analysis. commonName agreement
    -- is species-wide (commonNames/preferredCommonName are
    -- BARE_ONLY_FIELDS regardless of cultivar). growthHabit/nativity/
    -- gardenLocations/specimens are computed PER CULTIVAR sub-group
    -- instead (group.cultivarGroups, see groupByCultivar's own comment
    -- for why).
    local disagreements = { growthHabit = {}, nativity = {}, commonName = {} }
    local cultivarPhotoCount = 0
    local notesPhotoCount = 0
    for _, scientificName in ipairs(speciesOrder) do
        local group = groups[scientificName]

        for _, record in ipairs(group.records) do
            if record.notes then
                notesPhotoCount = notesPhotoCount + 1
            end
        end

        local distinctCommonNames = collectDistinctCommonNames(group.records)
        group.commonNames = {}
        for _, name in ipairs(distinctCommonNames) do
            table.insert(group.commonNames, { name = name, source = "migrated" })
        end
        if #distinctCommonNames > 1 then
            table.insert(disagreements.commonName, scientificName)
        elseif #distinctCommonNames == 1 then
            group.preferredCommonName = distinctCommonNames[1]
        end

        group.cultivarGroups = groupByCultivar(group.records, group.photos)
        for _, cg in ipairs(group.cultivarGroups) do
            if cg.cultivar then
                cultivarPhotoCount = cultivarPhotoCount + #cg.photos
            end
            local label = taxonLabel(scientificName, cg.cultivar)

            local plantTypeValue, plantTypeDisagrees = checkAgreement(cg.records, "plantType")
            if plantTypeDisagrees then
                table.insert(disagreements.growthHabit, label)
            else
                cg.growthHabit = plantTypeValue
            end

            local nativityValue, nativityDisagrees = checkAgreement(cg.records, "nativity")
            if nativityDisagrees then
                table.insert(disagreements.nativity, label)
            else
                cg.nativity = nativityValue
            end

            cg.gardenLocations = aggregateGardenLocations(cg.records)

            -- Step 5: specimen grouping (analysis only -- SpecimenStore.set
            -- happens in the write phase, step 10).
            cg.specimens = groupIntoSpecimens(cg)
        end

        -- Step 6/7 setup: does this species need a fresh taxonId
        -- resolution at all? Only if at least one of its photos lacks
        -- this plugin's OWN scientificName already (a mixed group -- some
        -- photos already identified via this plugin, some not -- still
        -- needs resolution, so the still-unidentified ones have a
        -- candidate to apply). Bare-species-wide, cultivar-agnostic --
        -- iNat has no concept of cultivars at all, so resolving the base
        -- name once covers every cultivar sub-group.
        local allAlreadyIdentified = true
        for _, photo in ipairs(group.photos) do
            if not photo:getPropertyForPlugin(_PLUGIN, "scientificName") then
                allAlreadyIdentified = false
                break
            end
        end
        group.needsResolution = not allAlreadyIdentified
    end

    -- Step 6: attempt taxonId resolution for every species that needs it.
    -- Same retry-after-a-pause pattern as BackfillTaxonId.lua -- confirmed
    -- live there that this class of resolution call has a real transient
    -- failure rate under back-to-back requests.
    local needingResolution = {}
    for _, scientificName in ipairs(speciesOrder) do
        if groups[scientificName].needsResolution then
            table.insert(needingResolution, scientificName)
        end
    end

    local unresolvedSpecies = {}
    if #needingResolution > 0 then
        local progressScope = LrProgressScope({ title = "Migrate PlantBook Metadata" })
        progressScope:setCancelable(true)

        for i, scientificName in ipairs(needingResolution) do
            if progressScope:isCanceled() then
                break
            end
            progressScope:setCaption("Resolving " .. scientificName .. "...")
            progressScope:setPortionComplete(i - 1, #needingResolution)

            local resolveOk, candidate, ancestry = LrTasks.pcall(INaturalist.resolveByName, scientificName)
            if not (resolveOk and candidate) then
                LrTasks.sleep(2.0)
                resolveOk, candidate, ancestry = LrTasks.pcall(INaturalist.resolveByName, scientificName)
            end
            if resolveOk and candidate then
                groups[scientificName].resolvedCandidate = candidate
                groups[scientificName].resolvedAncestry = ancestry
            else
                table.insert(unresolvedSpecies, scientificName)
            end

            if i < #needingResolution then
                LrTasks.sleep(1.0)
            end
        end

        progressScope:done()
    end

    -- Photos genuinely left with no identification at all after this run
    -- -- specifically the STILL-unidentified photos of an unresolved
    -- species, not every photo of that species (an "overlap" photo
    -- already has a working identification from elsewhere in this
    -- plugin, so it isn't actually stuck even if PlantBook's own name for
    -- it never resolves).
    local unresolvedPhotos = {}
    for _, scientificName in ipairs(unresolvedSpecies) do
        local group = groups[scientificName]
        for _, photo in ipairs(group.photos) do
            if not photo:getPropertyForPlugin(_PLUGIN, "scientificName") then
                table.insert(unresolvedPhotos, photo)
            end
        end
    end

    -- Sync the "unresolved species" recovery collection to THIS run's
    -- findings -- deliberately BEFORE the confirmation gate below (unlike
    -- every other write in this script), per the user: they want to see
    -- and fix these photos without first having to commit to the actual
    -- metadata migration. A collection add/remove is non-destructive and
    -- easily reversible, unlike the taxon/specimen/identification writes
    -- below -- worth the one exception to "nothing touches the catalog
    -- before confirm." Cleared and rebuilt every run rather than
    -- accumulated, so a photo that resolves this time (after the user
    -- fixes PlantBook's naming for it) doesn't linger from a stale
    -- earlier run -- including clearing it back to empty on a fully clean
    -- run, so nothing stale survives from an earlier, less-successful pass.
    -- Split into TWO transactions, not one -- confirmed live 2026-08-17:
    -- Lightroom refuses to query a collection's own info (getPhotos)
    -- inside the SAME withWriteAccessDo call that created it
    -- ("Can't get collection information after creating collection
    -- inside the same withWriteAccessDo function"). createCollection's
    -- own 3rd arg (return-existing) means this is still safe/idempotent
    -- to call every run.
    local collection
    catalog:withWriteAccessDo("Migrate PlantBook unresolved collection (create)", function()
        collection = catalog:createCollection(UNRESOLVED_COLLECTION_NAME, nil, true)
    end)

    catalog:withWriteAccessDo("Migrate PlantBook unresolved collection (sync)", function()
        -- removePhotos with the collection's own current members, not
        -- removeAllPhotos -- that method isn't otherwise proven live in
        -- this codebase, and removePhotos already is (see
        -- PendingMetadataSave.lua), so this sticks to a verified path
        -- rather than a plausible-but-unconfirmed one.
        local existingMembers = collection:getPhotos()
        if #existingMembers > 0 then
            collection:removePhotos(existingMembers)
        end
        if #unresolvedPhotos > 0 then
            collection:addPhotos(unresolvedPhotos)
        end
    end)

    ----------------------------------------------------------------------
    -- Confirmation
    ----------------------------------------------------------------------

    local totalSpecimens = 0
    local overlapPhotoCount = 0
    for _, scientificName in ipairs(speciesOrder) do
        local group = groups[scientificName]
        for _, cg in ipairs(group.cultivarGroups) do
            totalSpecimens = totalSpecimens + #cg.specimens
        end
        for _, photo in ipairs(group.photos) do
            if photo:getPropertyForPlugin(_PLUGIN, "scientificName") then
                overlapPhotoCount = overlapPhotoCount + 1
            end
        end
    end

    local summaryLines = {
        string.format("%d PlantBook photo%s across %d species.", #candidates, #candidates == 1 and "" or "s", #speciesOrder),
        string.format("%d specimen%s identified from location/planting-history groupings.", totalSpecimens, totalSpecimens == 1 and "" or "s"),
    }
    if cultivarPhotoCount > 0 then
        table.insert(summaryLines, string.format(
            "%d photo%s had a cultivar embedded in PlantBook's scientific name (e.g. \"Genus species 'Cultivar'\") -- split out and written to the Cultivar field separately.",
            cultivarPhotoCount, cultivarPhotoCount == 1 and "" or "s"
        ))
    end
    if notesPhotoCount > 0 then
        table.insert(summaryLines, string.format(
            "%d photo%s have PlantBook notes -- migrated to the new Observation Notes field.",
            notesPhotoCount, notesPhotoCount == 1 and "" or "s"
        ))
    end
    if overlapPhotoCount > 0 then
        table.insert(summaryLines, string.format(
            "%d photo%s already identified in this plugin -- left untouched, only specimen links added.",
            overlapPhotoCount, overlapPhotoCount == 1 and "" or "s"
        ))
    end
    if #unresolvedSpecies > 0 then
        table.insert(summaryLines, string.format(
            "%d species couldn't be resolved on iNaturalist (renamed/misspelled?) -- skipped: %s",
            #unresolvedSpecies, table.concat(unresolvedSpecies, ", ")
        ))
        table.insert(summaryLines, string.format(
            "%d still-unidentified photo%s from those species %s already been placed in the \"%s\" collection -- feel free to cancel below, fix PlantBook's naming for them, and run this migration again.",
            #unresolvedPhotos, #unresolvedPhotos == 1 and "" or "s", #unresolvedPhotos == 1 and "has" or "have", UNRESOLVED_COLLECTION_NAME
        ))
    end
    if #disagreements.growthHabit > 0 then
        table.insert(summaryLines, string.format(
            "%d %s disagreeing Plant Type across photos -- Growth Habit left unset, resolve via Manage Local Flora Observation: %s",
            #disagreements.growthHabit, #disagreements.growthHabit == 1 and "taxon has" or "taxa have", table.concat(disagreements.growthHabit, ", ")
        ))
    end
    if #disagreements.nativity > 0 then
        table.insert(summaryLines, string.format(
            "%d %s disagreeing Nativity across photos -- left unset, resolve via Manage Local Flora Observation: %s",
            #disagreements.nativity, #disagreements.nativity == 1 and "taxon has" or "taxa have", table.concat(disagreements.nativity, ", ")
        ))
    end
    if #disagreements.commonName > 0 then
        table.insert(summaryLines, string.format(
            "%d species have multiple different common names across photos -- all kept as options, none set preferred yet: %s",
            #disagreements.commonName, table.concat(disagreements.commonName, ", ")
        ))
    end
    table.insert(summaryLines, "\nThis cannot be easily undone. Proceed?")

    local confirmResult = LrDialogs.confirm(
        "Migrate PlantBook Metadata",
        table.concat(summaryLines, "\n"),
        "Migrate", "Cancel"
    )
    if confirmResult ~= "ok" then
        return
    end

    ----------------------------------------------------------------------
    -- Write phase (order matters: TaxonStore.set before any
    -- applyIdentification call)
    ----------------------------------------------------------------------

    -- Step 8: taxon-level facts. Bare-species-wide fields (commonNames/
    -- preferredCommonName) once per species; growthHabit/nativity/
    -- gardenLocations once per cultivar sub-group, written against that
    -- cultivar's own TaxonStore key (nil cultivar = the bare species
    -- entry, same as today for anything PlantBook never cultivar-tagged).
    -- Fields with a disagreement (or nothing found at all) are simply
    -- omitted from `fields` -- never written as an explicit nil
    -- overwrite, same "don't clobber an unrelated existing value"
    -- reasoning already applied in SetCultivar.lua.
    for _, scientificName in ipairs(speciesOrder) do
        local group = groups[scientificName]

        local bareFields = {}
        if #group.commonNames > 0 then
            bareFields.commonNames = group.commonNames
        end
        if group.preferredCommonName then
            bareFields.preferredCommonName = group.preferredCommonName
        end
        if next(bareFields) then
            TaxonStore.set(scientificName, bareFields)
        end

        for _, cg in ipairs(group.cultivarGroups) do
            local fields = {}
            if cg.growthHabit then
                fields.growthHabit = cg.growthHabit
            end
            if cg.nativity then
                fields.nativity = cg.nativity
            end
            if next(cg.gardenLocations) then
                fields.gardenLocations = cg.gardenLocations
            end
            if next(fields) then
                TaxonStore.set(scientificName, fields, cg.cultivar)
            end
        end
    end

    -- Step 8.5: cultivar backfill -- covers EVERY photo in a cultivar
    -- sub-group, not just ones about to be freshly identified, and
    -- independent of whether this species even resolved on iNat (an
    -- "overlap" photo already has its own working identification from
    -- this plugin, so it doesn't need iNat resolution to still benefit
    -- from PlantBook's cultivar data). Never overwrites a cultivar a
    -- photo already has (e.g. set directly via Set Cultivar since being
    -- identified here) -- same "don't clobber an existing value"
    -- convention this migration already follows elsewhere. Written
    -- BEFORE step 9's identification pass, so applyIdentification's own
    -- cultivar-aware TaxonStore lookup (KeywordWriter.lua's
    -- `existingCultivar`) picks it up correctly for newly-identified
    -- photos too -- applyIdentification takes no cultivar parameter of
    -- its own, it only ever reads whatever's already on the photo.
    for _, scientificName in ipairs(speciesOrder) do
        local group = groups[scientificName]
        for _, cg in ipairs(group.cultivarGroups) do
            if cg.cultivar then
                local photosNeedingCultivar = {}
                for _, photo in ipairs(cg.photos) do
                    if not photo:getPropertyForPlugin(_PLUGIN, "cultivar") then
                        table.insert(photosNeedingCultivar, photo)
                    end
                end
                if #photosNeedingCultivar > 0 then
                    catalog:withWriteAccessDo("Migrate PlantBook cultivar", function()
                        for _, photo in ipairs(photosNeedingCultivar) do
                            photo:setPropertyForPlugin(_PLUGIN, "cultivar", cg.cultivar)
                            PendingMetadataSave.markIfNeeded(catalog, photo)
                        end
                    end)
                end
            end
        end
    end

    -- Step 8.6: taxon-level facts backfill for overlap photos. growthHabit/
    -- nativity/gardenLocations/notes/commonName only ever get denormalized
    -- onto a photo's own properties via applyIdentification (step 9),
    -- which -- like the cultivar write before it -- only ever touches
    -- not-yet-identified photos. An overlap photo (already identified in
    -- this plugin, left untouched by step 9) would otherwise show none of
    -- this even though TaxonStore already has it correctly cached from
    -- step 8. Uses the PHOTO'S OWN scientificName/cultivar for the
    -- TaxonStore lookup -- NOT PlantBook's -- since an overlap photo's
    -- existing identification (established independently of this
    -- migration) might not actually agree with what PlantBook thought it
    -- was; forcing PlantBook's facts onto a photo identified as something
    -- else would be a real correctness bug, not a fix. In the common case
    -- (the same photo, consistently identified both places) this is
    -- exactly the data step 8 just wrote. Unconditionally overwrites
    -- whatever the photo currently shows for these fields -- same "every
    -- photo of a taxon shows the SAME current value" invariant every
    -- other taxon-level fan-out in this codebase already enforces (not a
    -- "PlantBook guess clobbering something better" risk -- it's always
    -- reading back the photo's OWN taxon's current TaxonStore state).
    local locationTitles = {}
    do
        local metadataDef = dofile(LrPathUtils.child(_PLUGIN.path, "MetadataDefinition.lua"))
        for _, field in ipairs(metadataDef.metadataFieldsForPhotos) do
            if field.id == "gardenLocation" then
                for _, entry in ipairs(field.values) do
                    if entry.value then
                        locationTitles[entry.value] = entry.title
                    end
                end
            end
        end
    end

    local overlapFactsCount = 0
    catalog:withWriteAccessDo("Migrate PlantBook taxon facts (overlap photos)", function()
        for _, scientificName in ipairs(speciesOrder) do
            local group = groups[scientificName]
            for _, photo in ipairs(group.photos) do
                local photoScientificName = photo:getPropertyForPlugin(_PLUGIN, "scientificName")
                if photoScientificName then
                    local photoCultivar = photo:getPropertyForPlugin(_PLUGIN, "cultivar")
                    local taxonEntry = TaxonStore.get(photoScientificName, photoCultivar)
                    if taxonEntry then
                        if taxonEntry.growthHabit then
                            photo:setPropertyForPlugin(_PLUGIN, "growthHabit", taxonEntry.growthHabit)
                        end
                        if taxonEntry.nativity then
                            photo:setPropertyForPlugin(_PLUGIN, "nativity", taxonEntry.nativity)
                        end
                        if taxonEntry.notes then
                            photo:setPropertyForPlugin(_PLUGIN, "notes", taxonEntry.notes)
                        end
                        local gardenLocationsDisplay = TaxonStore.formatGardenLocations(taxonEntry.gardenLocations, locationTitles)
                        if gardenLocationsDisplay then
                            photo:setPropertyForPlugin(_PLUGIN, "gardenLocations", gardenLocationsDisplay)
                        end
                        if taxonEntry.preferredCommonName then
                            photo:setPropertyForPlugin(_PLUGIN, "commonName", taxonEntry.preferredCommonName)
                        end
                        overlapFactsCount = overlapFactsCount + 1
                        PendingMetadataSave.markIfNeeded(catalog, photo)
                    end
                end
            end
        end
    end)

    -- Step 9: apply real identification for photos that need one -- one
    -- at a time, NOT batched per species -- batching would give every
    -- photo of a species the same observationId, fabricating a false
    -- "these are all one sighting" grouping that specimen grouping (step
    -- 5/10) exists specifically to avoid.
    local identifiedCount, skippedUnresolvedCount = 0, 0
    for _, scientificName in ipairs(speciesOrder) do
        local group = groups[scientificName]
        if group.resolvedCandidate then
            for _, cg in ipairs(group.cultivarGroups) do
                for _, photo in ipairs(cg.photos) do
                    if not photo:getPropertyForPlugin(_PLUGIN, "scientificName") then
                        KeywordWriter.applyIdentification({ photo }, group.resolvedCandidate, group.resolvedAncestry or {})
                        identifiedCount = identifiedCount + 1
                    end
                end
            end
        elseif group.needsResolution then
            skippedUnresolvedCount = skippedUnresolvedCount + #group.photos
        end
    end

    -- Step 9.5: observation-level notes. PlantBook's per-photo `notes`
    -- maps directly onto this project's own observationNotes field --
    -- independent of specimen grouping (unlike step 10 below, this
    -- covers EVERY PlantBook photo with a note, including ones with none
    -- of location/introduced/introductionYear set, which
    -- groupIntoSpecimens deliberately excludes from getting a specimen at
    -- all) and independent of whether the photo needed fresh
    -- identification -- an "overlap" photo already identified in this
    -- plugin still gets its PlantBook note preserved, same as any other.
    local notesWrittenCount = 0
    catalog:withWriteAccessDo("Migrate PlantBook notes", function()
        for _, scientificName in ipairs(speciesOrder) do
            local group = groups[scientificName]
            for i, record in ipairs(group.records) do
                if record.notes then
                    local photo = group.photos[i]
                    photo:setPropertyForPlugin(_PLUGIN, "observationNotes", record.notes)
                    notesWrittenCount = notesWrittenCount + 1
                    PendingMetadataSave.markIfNeeded(catalog, photo)
                end
            end
        end
    end)

    -- Step 10: specimen-level facts, once per distinct specimen (within
    -- each cultivar sub-group -- a specimen never spans cultivars),
    -- fanned out to that specimen's photos.
    local specimenCount = 0
    catalog:withWriteAccessDo("Migrate PlantBook specimens", function()
        for _, scientificName in ipairs(speciesOrder) do
            local group = groups[scientificName]
            for _, cg in ipairs(group.cultivarGroups) do
                for _, specimen in ipairs(cg.specimens) do
                    local specimenId = KeywordWriter.generateUUID()
                    local fields = { scientificName = scientificName }
                    if specimen.gardenLocation then
                        fields.gardenLocation = specimen.gardenLocation
                    end
                    if specimen.locationNotes then
                        fields.locationNotes = specimen.locationNotes
                    end
                    if specimen.plantingMethod then
                        fields.plantingMethod = specimen.plantingMethod
                    end
                    if specimen.plantingYear then
                        fields.plantingYear = specimen.plantingYear
                    end
                    -- SpecimenStore.set's own auto-sync checks this
                    -- location in the species' taxon-level gardenLocations
                    -- map for free, if one was given (see SpecimenStore.lua).
                    SpecimenStore.set(specimenId, fields)
                    specimenCount = specimenCount + 1

                    for _, photo in ipairs(specimen.photos) do
                        photo:setPropertyForPlugin(_PLUGIN, "specimenId", specimenId)
                        if specimen.gardenLocation then
                            photo:setPropertyForPlugin(_PLUGIN, "gardenLocation", specimen.gardenLocation)
                        end
                        if specimen.locationNotes then
                            photo:setPropertyForPlugin(_PLUGIN, "locationNotes", specimen.locationNotes)
                        end
                        if specimen.plantingMethod then
                            photo:setPropertyForPlugin(_PLUGIN, "plantingMethod", specimen.plantingMethod)
                        end
                        if specimen.plantingYear then
                            photo:setPropertyForPlugin(_PLUGIN, "plantingYear", specimen.plantingYear)
                        end
                        PendingMetadataSave.markIfNeeded(catalog, photo)
                    end
                end
            end
        end
    end)

    LrDialogs.message(
        "Migrate PlantBook Metadata",
        string.format(
            "%d photo%s identified, %d overlap photo%s refreshed with taxon facts, %d note%s migrated, %d specimen%s created, %d photo%s skipped and placed in the \"%s\" collection (species unresolved) -- fix PlantBook's naming for those and run this migration again.",
            identifiedCount, identifiedCount == 1 and "" or "s",
            overlapFactsCount, overlapFactsCount == 1 and "" or "s",
            notesWrittenCount, notesWrittenCount == 1 and "" or "s",
            specimenCount, specimenCount == 1 and "" or "s",
            skippedUnresolvedCount, skippedUnresolvedCount == 1 and "" or "s",
            UNRESOLVED_COLLECTION_NAME
        ),
        "info"
    )
end)
