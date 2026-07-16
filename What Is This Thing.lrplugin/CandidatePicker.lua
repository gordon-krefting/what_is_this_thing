local LrHttp = import 'LrHttp'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'

local CandidatePicker = {}

local function formatEntry(r, existingCount)
    local label = r.scientificName
    if r.commonName then
        label = r.commonName .. " (" .. r.scientificName .. ")"
    end
    if r.rank and r.rank ~= "species" then
        label = label .. " [" .. r.rank .. "]"
    end
    local text = string.format("%5.1f%%  %s", r.score, label)
    if existingCount and existingCount > 0 then
        text = text .. string.format("  [%d photo%s already tagged]", existingCount, existingCount == 1 and "" or "s")
    end
    return text
end

-- Shows a modal dialog listing `candidates` (each a
-- { score, scientificName, commonName, rank } table) as a radio-button
-- group, preselecting `defaultIndex` (1 if omitted). `hint`, if given,
-- replaces the default header text -- useful for explaining why a
-- particular entry was preselected. `linksForCandidate`, if given, is
-- called as `linksForCandidate(candidate)` for each row and should return a
-- list of { label, url } (or nil/empty for no links); each entry becomes
-- its own button next to that row, opening the URL in the system browser.
--
-- `countForCandidate`, if given, is called as `countForCandidate(candidate)`
-- for each row and should return the number of photos already tagged with
-- that candidate's identification (or nil/0 to show nothing extra) --
-- appended to the row's label, e.g. "[12 photos already tagged]".
--
-- Returns selected, wantManualEntry:
--   - a candidate was picked: selected = that candidate, wantManualEntry = false
--   - "Enter Manually" was clicked: selected = nil, wantManualEntry = true
--   - canceled: selected = nil, wantManualEntry = false
function CandidatePicker.choose(title, candidates, defaultIndex, hint, linksForCandidate, countForCandidate)
    local selected = nil
    local wantManualEntry = false

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
            local count = countForCandidate and countForCandidate(r)
            local radio = f:radio_button {
                title = formatEntry(r, count),
                value = LrView.bind("selectedIndex"),
                checked_value = i,
            }

            local links = linksForCandidate and linksForCandidate(r)
            if links and #links > 0 then
                local rowArgs = { radio }
                for _, link in ipairs(links) do
                    table.insert(rowArgs, f:push_button {
                        title = link.label,
                        action = function()
                            LrHttp.openUrlInBrowser(link.url)
                        end,
                    })
                end
                table.insert(args, f:row(rowArgs))
            else
                table.insert(args, radio)
            end
        end

        local contents = f:column(args)

        local result = LrDialogs.presentModalDialog {
            title = title,
            contents = contents,
            actionVerb = "Tag Photos",
            otherVerb = "None of These (Enter Manually)",
        }

        if result == "ok" then
            selected = candidates[props.selectedIndex]
        elseif result == "other" then
            wantManualEntry = true
        end
    end)

    return selected, wantManualEntry
end

return CandidatePicker
