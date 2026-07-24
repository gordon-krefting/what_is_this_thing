local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))
local KeywordWriter = dofile(LrPathUtils.child(_PLUGIN.path, "KeywordWriter.lua"))

-- Explicit override: point the selected photo(s) at a SPECIFIC iNat
-- observation, chosen by the user, bypassing the sync's own automatic
-- matching entirely. Exists for two real cases the automatic matching
-- can't fix on its own:
--   - An occasional wrong auto-match (confirmed live: the sync's success
--     rate is very high, but a coincidental timestamp collision can still
--     pick the wrong observation) -- iNatObservationId/Url are read-only
--     in the Metadata panel specifically to prevent accidental edits, but
--     that also means there was previously no way to CORRECT one. Simply
--     clearing the link (Split Observation) doesn't help here, since the
--     same coincidence would likely just reproduce the same wrong guess
--     (or leave it unmatched) on the next sync.
--   - An over-batched local group that should actually be split across
--     TWO OR MORE iNat observations, where the photos share the same
--     species -- so there's nothing in the local data (no differing
--     scientificName) to hint which photos belong together the way
--     Split Observation's normal disambiguation relies on. The only fix
--     is external knowledge (which photos are on which iNat observation),
--     applied by hand: select the subset that belongs to one observation,
--     run this with that observation's id, then repeat for the rest.
--
-- Always assigns a FRESH local Observation ID to exactly the selected
-- photos (ignoring whatever KeywordWriter.applyIdentification would
-- normally reuse from an existing shared id) -- necessary for the
-- over-batched case above: reusing a stale shared id would leave an
-- unselected sibling still wrongly attached to this group.
--
-- Always applies the given observation's CURRENT taxon (no agreement
-- check, unlike the automatic sync) -- choosing this specific observation
-- IS the user's explicit judgment call, there's no "local tag to compare
-- against" the way there is during an automatic match.
local function parseObservationId(text)
    if not text or text == "" then
        return nil
    end
    local digits = text:match("(%d+)%s*$")
    return digits and tonumber(digits) or nil
end

local function promptForObservationIdText()
    local entered = nil

    LrFunctionContext.callWithContext("SetINatObservationPrompt", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.text = ""

        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text { title = "iNat observation id or URL:" },
            f:edit_field { value = LrView.bind("text"), width_in_chars = 40 },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Set iNat Observation",
            contents = contents,
            actionVerb = "Next",
        }

        if result == "ok" and props.text ~= "" then
            entered = props.text
        end
    end)

    return entered
end

LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    if #photos == 0 then
        LrDialogs.message("Set iNat Observation", "No photos selected.", "info")
        return
    end

    local enteredText = promptForObservationIdText()
    if not enteredText then
        return
    end
    local observationId = parseObservationId(enteredText)
    if not observationId then
        LrDialogs.message("Set iNat Observation", "Couldn't find an observation id in that -- paste either the numeric id or the full observation URL.", "info")
        return
    end

    local fetchOk, observations = LrTasks.pcall(INaturalist.getObservationsByIds, { observationId })
    if not fetchOk or not observations or #observations == 0 then
        LrDialogs.message(
            "Set iNat Observation",
            "Couldn't find observation #" .. tostring(observationId) .. " on iNaturalist -- check the id/URL and your network connection.",
            "error"
        )
        return
    end
    local observation = observations[1]
    if not observation.taxon then
        LrDialogs.message("Set iNat Observation", "Observation #" .. tostring(observationId) .. " has no current identification on iNat.", "info")
        return
    end

    -- Soft warning, not a hard block (same "warn, don't block" principle
    -- as the unidentified-photo check on iNaturalist export elsewhere in
    -- this plugin) -- filenames aren't always available/reliable (see
    -- INatSync.lua's own notes on this), so a failure to confirm a match
    -- shouldn't prevent an otherwise-correct override.
    local iNatFilenames = INaturalist.getObservationPhotoFilenames(observationId)
    if iNatFilenames then
        local function stripExtension(filename)
            return filename and filename:match("^(.*)%.[^%.]+$") or filename
        end
        local iNatSet = {}
        for _, fn in ipairs(iNatFilenames) do
            iNatSet[stripExtension(fn)] = true
        end
        local anyMatch = false
        for _, photo in ipairs(photos) do
            if iNatSet[stripExtension(photo:getFormattedMetadata("fileName"))] then
                anyMatch = true
                break
            end
        end
        if not anyMatch then
            local confirmResult = LrDialogs.confirm(
                "Filenames don't match",
                "None of the selected photo(s)' filenames match observation #" .. tostring(observationId)
                    .. "'s photos on iNat (" .. table.concat(iNatFilenames, ", ") .. "). Continue anyway?",
                "Continue", "Cancel"
            )
            if confirmResult ~= "ok" then
                return
            end
        end
    end

    local candidate = {
        id = observation.taxon.id,
        scientificName = observation.taxon.name,
        commonName = observation.taxon.preferred_common_name,
        rank = observation.taxon.rank,
    }
    -- Network call -- must happen before the write transaction, not inside it.
    local ancestry = INaturalist.getMajorAncestry(candidate.id)

    KeywordWriter.applyIdentification(photos, candidate, ancestry)

    local freshObservationId = KeywordWriter.generateUUID()
    local observationUrl = "https://www.inaturalist.org/observations/" .. tostring(observationId)
    catalog:withWriteAccessDo("Set iNat observation", function()
        for _, photo in ipairs(photos) do
            photo:setPropertyForPlugin(_PLUGIN, "observationId", freshObservationId)
            photo:setPropertyForPlugin(_PLUGIN, "iNatObservationId", tostring(observationId))
            photo:setPropertyForPlugin(_PLUGIN, "iNatObservationUrl", observationUrl)
        end
    end)

    LrDialogs.message(
        "Set iNat Observation",
        string.format("%d photo(s) set to observation #%d (%s).", #photos, observationId, candidate.scientificName),
        "info"
    )
end)
