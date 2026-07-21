local LrHttp = import 'LrHttp'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

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
-- `computeCommonAncestor`, if given, adds a "Find Common Ancestor" button
-- that calls it (with no arguments) on demand -- not automatically, since
-- it's expected to make its own network calls and shouldn't slow down the
-- common case. Should return candidate, ancestry (same shapes as
-- INaturalist.resolveByName), or nil if none could be computed. The result
-- becomes an extra selectable row.
--
-- `otherServiceButtonLabel`, if given (e.g. "Also try Pl@ntNet"), adds a
-- button with that label. Clicking it closes the dialog early (via
-- LrDialogs.stopModalWithResult) and CandidatePicker.choose returns
-- wantOtherService = true -- the caller is expected to fetch the other
-- service's results itself (it has the exported photo paths/GPS context
-- this module doesn't) and re-invoke choose() with a combined candidate
-- list. A dialog can't have new rows injected into it after it's already
-- showing, so "reload with both sets" means literally closing and
-- reopening with the combined list, not mutating this one in place.
--
-- `sectionLabelForIndex`, if given, is called as `sectionLabelForIndex(i)`
-- before rendering row i; a non-nil return inserts a plain header line
-- above that row (e.g. distinguishing "iNaturalist" results from
-- "Pl@ntNet" results in a combined list after a reload). Candidates from
-- different services are never merged/deduped by this module -- they're
-- just shown as separate labeled groups in one flat, still-indexed list.
--
-- Returns selected, wantManualEntry, wantOtherService:
--   - a candidate was picked: selected = that candidate, others false
--   - "Enter Manually" was clicked: wantManualEntry = true, others nil/false
--   - the other-service button was clicked: wantOtherService = true
--   - canceled: all nil/false
function CandidatePicker.choose(title, candidates, defaultIndex, hint, linksForCandidate, countForCandidate, computeCommonAncestor, otherServiceButtonLabel, sectionLabelForIndex)
    local selected = nil
    local wantManualEntry = false
    local wantOtherService = false

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
            local sectionLabel = sectionLabelForIndex and sectionLabelForIndex(i)
            if sectionLabel then
                table.insert(args, f:static_text { title = sectionLabel .. ":" })
            end

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

        if otherServiceButtonLabel then
            local otherServiceButton
            otherServiceButton = f:push_button {
                title = otherServiceButtonLabel,
                action = function()
                    LrDialogs.stopModalWithResult(otherServiceButton, "tryOtherService")
                end,
            }
            table.insert(args, otherServiceButton)
        end

        -- Computed on demand, not automatically -- see doc comment above.
        -- The result's title/enabled state is set by directly mutating
        -- these view objects (not via bind_to_object/LrView.bind reactivity,
        -- which doesn't reliably refresh a control's title after the
        -- dialog is already showing -- confirmed the hard way in
        -- DialogTest.lua; Adobe's own CustomDialogWithObserver.lua sample
        -- does the same direct-mutation thing).
        local commonAncestorCandidate = nil
        if computeCommonAncestor then
            local commonAncestorIndex = #candidates + 1
            -- Fixed width up front -- like the static_text bug in
            -- DialogTest.lua, a control doesn't grow to fit .title changes
            -- made after creation, so sizing to the short placeholder here
            -- would clip the real (longer) label once computed.
            local commonAncestorRadio = f:radio_button {
                title = "(not yet computed)",
                value = LrView.bind("selectedIndex"),
                checked_value = commonAncestorIndex,
                enabled = false,
                width_in_chars = 60,
            }
            local commonAncestorButton
            commonAncestorButton = f:push_button {
                title = "Find Common Ancestor",
                -- Button actions run on Lightroom's main task, same as
                -- selectionChangeObserver -- not inside whatever async task
                -- launched this dialog. computeCommonAncestor makes network
                -- calls (which need to yield), so it must run inside its
                -- own LrTasks-started task or it can hang indefinitely
                -- instead of failing cleanly -- the exact bug already found
                -- and fixed in DialogTest.lua.
                action = function()
                    commonAncestorButton.enabled = false
                    commonAncestorRadio.title = "Looking up..."

                    LrTasks.startAsyncTask(function()
                        local ok, candidate, ancestry = LrTasks.pcall(computeCommonAncestor)
                        if ok and candidate then
                            commonAncestorCandidate = { candidate = candidate, ancestry = ancestry }
                            commonAncestorRadio.title = formatEntry(candidate)
                            commonAncestorRadio.enabled = true
                            props.selectedIndex = commonAncestorIndex
                        else
                            commonAncestorRadio.title = "No common ancestor found"
                        end
                    end)
                end,
            }
            table.insert(args, f:row { commonAncestorRadio, commonAncestorButton })
        end

        local contents = f:column(args)

        local result = LrDialogs.presentModalDialog {
            title = title,
            contents = contents,
            actionVerb = "Tag Photos",
            otherVerb = "None of These (Enter Manually)",
        }

        if result == "ok" then
            if commonAncestorCandidate and props.selectedIndex == #candidates + 1 then
                selected = commonAncestorCandidate.candidate
            else
                selected = candidates[props.selectedIndex]
            end
        elseif result == "other" then
            wantManualEntry = true
        elseif result == "tryOtherService" then
            wantOtherService = true
        end
    end)

    return selected, wantManualEntry, wantOtherService
end

return CandidatePicker
