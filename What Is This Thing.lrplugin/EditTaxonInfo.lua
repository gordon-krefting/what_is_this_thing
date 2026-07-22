local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'

local TaxonStore = dofile(LrPathUtils.child(_PLUGIN.path, "TaxonStore.lua"))

-- catalog:findPhotosWithProperty requires the plug-in's toolkit identifier
-- as a plain string (unlike get/setPropertyForPlugin, which also accept
-- the _PLUGIN object) -- must match Info.lua's LrToolkitIdentifier exactly.
local TOOLKIT_ID = "org.krefting.whatisthisthing"

-- Growth Habit and Notes are taxon-level facts (true of the species, not
-- just the selected photo), with no API source for either -- manual only.
-- Unlike Cultivar (scoped to one Observation ID / small photo batch), this
-- fans out to *every* photo of the same species across the whole catalog,
-- since these fields are meant to be true wherever that species shows up,
-- however many times you've photographed it over however long. Both
-- fields are `readOnly` in the Metadata panel (see MetadataDefinition.lua)
-- specifically so this command is the only way they change -- hand-editing
-- one photo would silently drift out of sync with the rest.
local function findAllPhotosOfTaxon(catalog, scientificName)
    local candidates = catalog:findPhotosWithProperty(TOOLKIT_ID, "scientificName")
    local matched = {}
    for _, photo in ipairs(candidates) do
        if photo:getPropertyForPlugin(_PLUGIN, "scientificName") == scientificName then
            table.insert(matched, photo)
        end
    end
    return matched
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Edit Taxon Info", "No photos selected.", "info")
        return
    end

    local scientificName = photos[1]:getPropertyForPlugin(_PLUGIN, "scientificName")
    if not scientificName then
        LrDialogs.message(
            "Edit Taxon Info",
            "This photo hasn't been identified yet -- run \"iNaturalist Identification\" or \"Pl@ntNet Identification\" on it first.",
            "info"
        )
        return
    end

    local existing = TaxonStore.get(scientificName) or {}

    local growthHabitText, notesText = nil, nil

    LrFunctionContext.callWithContext("EditTaxonInfo", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.growthHabitText = existing.growthHabit or ""
        props.notesText = existing.notes or ""

        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text { title = "Taxon: " .. scientificName },
            f:row {
                f:static_text { title = "Growth Habit:", width = 110 },
                f:edit_field { value = LrView.bind("growthHabitText"), width_in_chars = 30 },
            },
            f:row {
                f:static_text { title = "Notes:", width = 110 },
                f:edit_field { value = LrView.bind("notesText"), width_in_chars = 30 },
            },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Edit Taxon Info",
            contents = contents,
            actionVerb = "Save",
        }

        if result == "ok" then
            growthHabitText = props.growthHabitText
            notesText = props.notesText
        end
    end)

    if not growthHabitText and not notesText then
        return -- canceled
    end

    -- An empty box means "clear it" -- write nil rather than a stored
    -- empty string, so it reads as genuinely unset.
    local growthHabitValue = (growthHabitText ~= "") and growthHabitText or nil
    local notesValue = (notesText ~= "") and notesText or nil

    TaxonStore.set(scientificName, { growthHabit = growthHabitValue, notes = notesValue })

    local targetPhotos = findAllPhotosOfTaxon(catalog, scientificName)
    if #targetPhotos == 0 then
        -- Shouldn't normally happen (the selected photo itself should
        -- always match), but fall back to just the selection if it does.
        targetPhotos = photos
    end

    catalog:withWriteAccessDo("Edit taxon info", function()
        for _, photo in ipairs(targetPhotos) do
            photo:setPropertyForPlugin(_PLUGIN, "growthHabit", growthHabitValue)
            photo:setPropertyForPlugin(_PLUGIN, "notes", notesValue)
        end
    end)
end)
