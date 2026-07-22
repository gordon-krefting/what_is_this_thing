local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

-- catalog:findPhotosWithProperty requires the plug-in's toolkit identifier
-- as a plain string (unlike get/setPropertyForPlugin, which also accept
-- the _PLUGIN object) -- must match Info.lua's LrToolkitIdentifier exactly.
local TOOLKIT_ID = "org.krefting.whatisthisthing"

-- Cultivars are manual-only -- no API provides them, and they're orthogonal
-- to automatic identification (a photo can be successfully identified to
-- species and still have a cultivar worth noting). Rather than adding a
-- field to the identify flow's candidate picker, this is its own small,
-- optional command.
--
-- Finds every photo sharing the same Observation ID as any of `photos` --
-- not just the literally-selected ones -- so adding a cultivar note later
-- doesn't require reselecting the whole original identify batch. Falls
-- back to just `photos` if none of them have an Observation ID yet (e.g.
-- identified before this field existed).
--
-- Returns targetPhotos, errorMessage. If the selection spans more than one
-- distinct Observation ID (photos identified in separate batches), that's
-- an error, not something to silently resolve by picking one and dropping
-- the rest -- returns nil, errorMessage in that case.
local function expandToObservationGroup(catalog, photos)
    local distinctIds = {}
    local orderedIds = {}
    for _, photo in ipairs(photos) do
        local id = photo:getPropertyForPlugin(_PLUGIN, "observationId")
        if id and not distinctIds[id] then
            distinctIds[id] = true
            table.insert(orderedIds, id)
        end
    end

    if #orderedIds > 1 then
        return nil, "The selected photos are from different observations (identified in separate batches) -- select photos from just one observation at a time."
    end

    if #orderedIds == 0 then
        return photos, nil
    end

    local observationId = orderedIds[1]
    local candidates = catalog:findPhotosWithProperty(TOOLKIT_ID, "observationId")
    local matched = {}
    for _, photo in ipairs(candidates) do
        if photo:getPropertyForPlugin(_PLUGIN, "observationId") == observationId then
            table.insert(matched, photo)
        end
    end
    return matched, nil
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Set Cultivar", "No photos selected.", "info")
        return
    end

    local targetPhotos, groupError = expandToObservationGroup(catalog, photos)
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

    catalog:withWriteAccessDo("Set cultivar", function()
        for _, photo in ipairs(targetPhotos) do
            photo:setPropertyForPlugin(_PLUGIN, "cultivar", valueToWrite)
        end
    end)
end)
