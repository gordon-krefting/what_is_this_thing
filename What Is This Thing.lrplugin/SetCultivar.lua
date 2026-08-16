local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'

local TaxonStore = dofile(LrPathUtils.child(_PLUGIN.path, "TaxonStore.lua"))
local PendingMetadataSave = dofile(LrPathUtils.child(_PLUGIN.path, "PendingMetadataSave.lua"))
local ObservationGroup = dofile(LrPathUtils.child(_PLUGIN.path, "ObservationGroup.lua"))

-- { [value] = title } for the garden-location enum, same pattern
-- KeywordWriter.lua uses -- built once from MetadataDefinition.lua's own
-- declared values, needed to render TaxonStore.formatGardenLocations'
-- display string below.
local LOCATION_TITLES = {}
do
    local metadataDef = dofile(LrPathUtils.child(_PLUGIN.path, "MetadataDefinition.lua"))
    for _, field in ipairs(metadataDef.metadataFieldsForPhotos) do
        if field.id == "gardenLocation" then
            for _, entry in ipairs(field.values) do
                if entry.value then
                    LOCATION_TITLES[entry.value] = entry.title
                end
            end
        end
    end
end

-- Cultivars are manual-only -- no API provides them, and they're orthogonal
-- to automatic identification (a photo can be successfully identified to
-- species and still have a cultivar worth noting). Rather than adding a
-- field to the identify flow's candidate picker, this is its own small,
-- optional command.

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Set Cultivar", "No photos selected.", "info")
        return
    end

    local targetPhotos, groupError = ObservationGroup.expand(catalog, photos)
    if groupError then
        LrDialogs.message("Set Cultivar", groupError, "warning")
        return
    end
    local currentCultivar = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "cultivar")

    local cultivarText = nil

    LrFunctionContext.callWithContext("SetCultivar", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.cultivarText = currentCultivar or ""

        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text {
                title = string.format(
                    "Cultivar name for %d photo%s:",
                    #targetPhotos, #targetPhotos == 1 and "" or "s"
                ),
            },
            f:edit_field {
                value = LrView.bind("cultivarText"),
                width_in_chars = 30,
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Set Cultivar",
            contents = contents,
            actionVerb = "Save",
        }

        if result == "ok" then
            cultivarText = props.cultivarText
        end
    end)

    if not cultivarText then
        return
    end

    -- An empty box means "clear it" -- write nil rather than a stored
    -- empty string, so it reads as genuinely unset (e.g. for searchability).
    local valueToWrite = (cultivarText ~= "") and cultivarText or nil

    -- Changing a photo's cultivar changes its effective TaxonStore key
    -- (see TaxonStore.lua's cultivar-aware get/set) -- its denormalized
    -- growthHabit/nativity/gardenLocations/notes copies need re-resolving
    -- against the (now different, possibly empty) cultivar-keyed entry,
    -- same fields ManageFloraObservation.lua denormalizes, or they'd silently keep
    -- showing whatever the OLD cultivar (or the bare species) had.
    -- commonName is included too, for consistency, even though it's
    -- always bare-species-scoped and so never actually changes here.
    --
    -- Only writes a field when the new entry actually HAS a value for it
    -- (same convention KeywordWriter.lua's own TAXON_LEVEL_FIELDS loop
    -- already uses) -- never clears an existing value to nil just because
    -- the new cultivar-keyed entry happens to be empty. Matters for
    -- species identified before this feature existed, whose commonName
    -- was set the old way without ever populating TaxonStore's
    -- commonNames/preferredCommonName -- blindly overwriting with nil
    -- would erase a perfectly good existing value for no reason.
    local scientificName = targetPhotos[1]:getPropertyForPlugin(_PLUGIN, "scientificName")
    local newTaxonEntry = scientificName and (TaxonStore.get(scientificName, valueToWrite) or {}) or nil
    local gardenLocationsDisplay = newTaxonEntry
        and TaxonStore.formatGardenLocations(newTaxonEntry.gardenLocations, LOCATION_TITLES)
        or nil

    catalog:withWriteAccessDo("Set cultivar", function()
        for _, photo in ipairs(targetPhotos) do
            photo:setPropertyForPlugin(_PLUGIN, "cultivar", valueToWrite)
            if newTaxonEntry then
                if newTaxonEntry.growthHabit then
                    photo:setPropertyForPlugin(_PLUGIN, "growthHabit", newTaxonEntry.growthHabit)
                end
                if newTaxonEntry.nativity then
                    photo:setPropertyForPlugin(_PLUGIN, "nativity", newTaxonEntry.nativity)
                end
                if gardenLocationsDisplay then
                    photo:setPropertyForPlugin(_PLUGIN, "gardenLocations", gardenLocationsDisplay)
                end
                if newTaxonEntry.notes then
                    photo:setPropertyForPlugin(_PLUGIN, "notes", newTaxonEntry.notes)
                end
                if newTaxonEntry.preferredCommonName then
                    photo:setPropertyForPlugin(_PLUGIN, "commonName", newTaxonEntry.preferredCommonName)
                end
            end
            PendingMetadataSave.markIfNeeded(catalog, photo)
        end
    end)
end)
