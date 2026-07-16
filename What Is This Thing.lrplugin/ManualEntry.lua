local LrPathUtils = import 'LrPathUtils'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))

local ManualEntry = {}

-- Prompts for a scientific name typed by the user (for the case where
-- neither iNaturalist's nor Pl@ntNet's own identification found the right
-- match, but the user already knows what it is), resolving it through
-- iNaturalist's taxonomy -- same source both plugins already use for the
-- keyword tree, so a manually-entered ID ends up filed under the same
-- shared tree as an automatically-identified one. Reprompts (with an
-- error) if the name doesn't resolve to an exact match, rather than
-- silently treating a typo as a cancel.
--
-- Returns candidate, ancestry (see INaturalist.resolveByName), or nil, {}
-- if the user canceled.
function ManualEntry.promptAndResolve()
    local errorText = nil

    while true do
        local nameText, canceled

        LrFunctionContext.callWithContext("ManualEntryPrompt", function(context)
            local props = LrBinding.makePropertyTable(context)
            props.nameText = ""

            local f = LrView.osFactory()
            local args = {
                bind_to_object = props,
                spacing = f:control_spacing(),
            }
            if errorText then
                table.insert(args, f:static_text { title = errorText })
            end
            table.insert(args, f:static_text { title = "Enter the scientific name:" })
            table.insert(args, f:edit_field {
                value = LrView.bind("nameText"),
                placeholder_string = "e.g. Photinus pyralis",
                width_in_chars = 30,
            })

            local result = LrDialogs.presentModalDialog {
                title = "Enter Scientific Name",
                contents = f:column(args),
                actionVerb = "Look Up",
                cancelVerb = "Cancel",
            }

            if result == "ok" and props.nameText ~= "" then
                nameText = props.nameText
            else
                canceled = true
            end
        end)

        if canceled then
            return nil, {}
        end

        local candidate, ancestry = INaturalist.resolveByName(nameText)
        if candidate then
            return candidate, ancestry
        end

        errorText = "Couldn't find an exact match for \"" .. nameText
            .. "\" in iNaturalist's taxonomy -- check spelling, or Cancel."
    end
end

return ManualEntry
