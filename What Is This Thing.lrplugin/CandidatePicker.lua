local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

local CandidatePicker = {}

local function formatEntry(r)
    local label = r.scientificName
    if r.commonName then
        label = r.commonName .. " (" .. r.scientificName .. ")"
    end
    if r.rank and r.rank ~= "species" then
        label = label .. " [" .. r.rank .. "]"
    end
    return string.format("%5.1f%%  %s", r.score, label)
end

-- Shows a modal dialog listing `candidates` (each a
-- { score, scientificName, commonName, rank } table) as a radio-button
-- group, preselecting `defaultIndex` (1 if omitted). `hint`, if given,
-- replaces the default header text -- useful for explaining why a
-- particular entry was preselected.
--
-- Returns the chosen candidate table, or nil if the user canceled.
function CandidatePicker.choose(title, candidates, defaultIndex, hint)
    local selected = nil

    LrFunctionContext.callWithContext("CandidatePicker", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.selectedIndex = defaultIndex or 1

        local f = LrView.osFactory()

        local args = {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text { title = hint or "Which one is it?" },
        }
        for i, r in ipairs(candidates) do
            table.insert(args, f:radio_button {
                title = formatEntry(r),
                value = LrView.bind("selectedIndex"),
                checked_value = i,
            })
        end

        local contents = f:column(args)

        local result = LrDialogs.presentModalDialog {
            title = title,
            contents = contents,
            actionVerb = "Tag Photos",
        }

        if result == "ok" then
            selected = candidates[props.selectedIndex]
        end
    end)

    return selected
end

return CandidatePicker
