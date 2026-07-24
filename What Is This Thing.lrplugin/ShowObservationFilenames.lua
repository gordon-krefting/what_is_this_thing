local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))

-- One-off diagnostic: prompts for an iNat observation id and shows exactly
-- what INaturalist.getObservationPhotoFilenames() returns for it, raw --
-- to root-cause a suspiciously uniform "145 mismatches, every single one
-- flagged on both sides" result from a real sync run. Either
-- original_filename isn't coming back at all (auth/query issue) or it's
-- coming back as something unexpected (blank strings, etc.) -- this shows
-- the raw values so that's no longer a guess.
LrTasks.startAsyncTask(function()
    local observationId = nil

    LrFunctionContext.callWithContext("ShowObservationFilenamesPrompt", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.observationId = "170151797"

        local f = LrView.osFactory()
        local contents = f:column {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text { title = "iNat observation id to check:" },
            f:edit_field { value = LrView.bind("observationId"), width_in_chars = 20 },
        }

        local result = LrDialogs.presentModalDialog {
            title = "Show Observation Filenames",
            contents = contents,
            actionVerb = "Check",
        }

        if result == "ok" and props.observationId ~= "" then
            observationId = tonumber(props.observationId)
        end
    end)

    if not observationId then
        return
    end

    local filenames = INaturalist.getObservationPhotoFilenames(observationId)

    local lines = {}
    if filenames == nil then
        table.insert(lines, "getObservationPhotoFilenames returned nil (request failed outright -- see nothing to compare against).")
    elseif #filenames == 0 then
        table.insert(lines, "getObservationPhotoFilenames returned an EMPTY list (0 entries) -- either the observation has no photos, or original_filename came back missing/empty for all of them.")
    else
        table.insert(lines, "Got " .. #filenames .. " filename(s):")
        for i, fn in ipairs(filenames) do
            table.insert(lines, i .. ". \"" .. tostring(fn) .. "\" (length " .. #tostring(fn) .. ")")
        end
    end

    -- Raw detail on WHY it failed, if it did -- added after the 401-retry
    -- fix didn't visibly change anything live, to see the actual status
    -- code/error instead of just "request failed" with nothing else to
    -- go on.
    local debugInfo = INaturalist.debugObservationPhotoFetch(observationId)
    table.insert(lines, "")
    table.insert(lines, "--- Raw diagnostic ---")
    table.insert(lines, "URL: " .. tostring(debugInfo.url))
    table.insert(lines, "First attempt: ok=" .. tostring(debugInfo.first.ok) .. ", status=" .. tostring(debugInfo.first.status))
    if debugInfo.first.errorMessage then
        table.insert(lines, "First attempt error: " .. debugInfo.first.errorMessage)
    end
    if debugInfo.first.responseSnippet then
        table.insert(lines, "First attempt response: " .. debugInfo.first.responseSnippet)
    end
    if debugInfo.first.status == 401 then
        table.insert(lines, "Retried with fresh token: " .. tostring(debugInfo.retriedWithFreshToken))
        if debugInfo.retry then
            table.insert(lines, "Retry: ok=" .. tostring(debugInfo.retry.ok) .. ", status=" .. tostring(debugInfo.retry.status))
            if debugInfo.retry.errorMessage then
                table.insert(lines, "Retry error: " .. debugInfo.retry.errorMessage)
            end
            if debugInfo.retry.responseSnippet then
                table.insert(lines, "Retry response: " .. debugInfo.retry.responseSnippet)
            end
        end
    end

    LrDialogs.message("Observation " .. tostring(observationId) .. " Filenames", table.concat(lines, "\n"), "info")
end)
