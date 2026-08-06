local LrHttp = import 'LrHttp'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local CandidatePicker = {}

-- How many "Find Common Ancestor" rollup options to show at once -- a
-- dialog can't have new rows injected into it after it's already showing
-- (see the doc comment below), so this many placeholder rows are always
-- pre-created and only some of them may end up populated.
local MAX_COMMON_ANCESTOR_OPTIONS = 3

-- Fixed viewport for the scrollable candidate list -- bounds the dialog's
-- height regardless of how many candidates/rollup options there are (a
-- combined iNaturalist + Pl@ntNet run with several rollup groups each can
-- otherwise run past the screen). Wide enough to comfortably fit
-- RADIO_WIDTH_IN_CHARS plus a trailing link button without triggering the
-- horizontal scrollbar in the common case -- Mac auto-hides it when the
-- content fits (per scrolled_view's own SDK docs), so an occasional wider
-- row just gets one instead of being clipped.
--
-- Confirmed live (2026-08-06): at 750, a radio fixed to RADIO_WIDTH_IN_
-- CHARS plus its trailing button came out a few pixels wider than the
-- viewport -- content itself was fine (fully readable, nothing clipped),
-- just short on room, so this only widens the viewport rather than
-- touching the radio width again.
local CANDIDATE_LIST_WIDTH = 900
local CANDIDATE_LIST_HEIGHT = 500

-- Every radio in the list -- regular candidates and common-ancestor
-- rollups alike -- gets this same fixed width, so a row's link button(s)
-- always land at the same x position regardless of how long that row's
-- own label happens to be, without relying on fill_horizontal/spacer
-- stretching against a scrolled_view's declared width. Confirmed live
-- (2026-08-06) that the stretch approach doesn't reliably fill to the
-- viewport's actual visible width inside a scrolled_view -- it either
-- overflows (triggering an unwanted horizontal scrollbar) or, once
-- shrunk to compensate, clips content instead. A fixed width sidesteps
-- that uncertainty entirely: alignment no longer depends on how
-- scrolled_view sizes its child.
--
-- 60 was confirmed live as a safe base value (the common-ancestor rows
-- already used it successfully before scrolling was added -- see below
-- for why something much larger, like 80, isn't safe). Nudged up from
-- there, rather than via a spacer between the radio and its button: an
-- f:spacer{width=...} placed inline in a row was confirmed live to have
-- no visible effect (per LrView's own docs, spacer's width is meant to be
-- shared across sibling *rows* via LrView.share() to align columns, not
-- used as an inline horizontal gap within a single row) -- widening the
-- radio itself is a mechanism already proven to reliably shift the
-- button's position, so reusing it is safer than a second guess at
-- something spacer-shaped.
--
-- width_in_chars is calibrated in widths of the letter 'm' (one of the
-- widest glyphs in the font) and sets a MINIMUM, not a cap (per LrView
-- text properties' own docs) -- 80 of those is roughly 130-150 normal
-- characters, which is why that value (tried first) blew every row -- and
-- the dialog itself -- far wider than the screen.
local RADIO_WIDTH_IN_CHARS = 70

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
-- common case. Should return a list of up to 2 groups (one per candidate
-- service currently on screen -- see `sectionLabelForIndex` below), each
-- { label, options }: `label` (e.g. "iNaturalist") headers that group's
-- rows, and `options` is a list of up to MAX_COMMON_ANCESTOR_OPTIONS
-- { candidate, ancestry, memberCount } entries (same shape as
-- INaturalist.commonAncestorOptions), best first. Empty list/nil if none
-- could be computed. Each option becomes its own extra selectable row, so
-- more than one useful rollup can be offered at once instead of forcing a
-- single ancestor across every candidate -- see commonAncestorOptions' own
-- doc comment for why that matters, and why its groups must never be
-- merged: two services' candidate scores aren't comparable, so their
-- rollups are always shown (and computed) as separate groups, never
-- combined into one.
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
-- `photos`, the photos being identified (non-empty -- both real callers
-- already refuse to reach this point with none selected), shows
-- photos[1] as a large 400x400 reference image alongside the candidate
-- list -- these ID commands work on a small batch of angles of the same
-- organism, so one representative image is enough. Added 2026-08-05,
-- since this dialog previously had no image at all, unlike the
-- merge/sync collision pickers.
--
-- Returns selected, wantManualEntry, wantOtherService:
--   - a candidate was picked: selected = that candidate, others false
--   - "Enter Manually" was clicked: wantManualEntry = true, others nil/false
--   - the other-service button was clicked: wantOtherService = true
--   - canceled: all nil/false
function CandidatePicker.choose(
    title, candidates, defaultIndex, hint, linksForCandidate, countForCandidate, computeCommonAncestor,
    otherServiceButtonLabel, sectionLabelForIndex, photos
)
    local selected = nil
    local wantManualEntry = false
    local wantOtherService = false

    LrFunctionContext.callWithContext("CandidatePicker", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.selectedIndex = defaultIndex or 1

        local f = LrView.osFactory()

        -- Everything selectable (candidates + common-ancestor rollup rows)
        -- lives in this scrollable column, bound to props so radios in it
        -- can use LrView.bind -- kept separate from `args` below (the
        -- hint text and footer buttons, which stay fixed/always visible
        -- regardless of list length) so the scroll viewport wraps only the
        -- list itself.
        local scrollArgs = {
            bind_to_object = props,
            spacing = f:control_spacing(),
        }
        -- Both set further down (if applicable) but declared here so the
        -- fixed footer built after the scroll view can reference them
        -- regardless of which blocks below actually run.
        local otherServiceFooterButton = nil
        local commonAncestorFooterButton = nil

        for i, r in ipairs(candidates) do
            local sectionLabel = sectionLabelForIndex and sectionLabelForIndex(i)
            if sectionLabel then
                table.insert(scrollArgs, f:static_text { title = sectionLabel .. ":" })
            end

            local count = countForCandidate and countForCandidate(r)
            local radio = f:radio_button {
                title = formatEntry(r, count),
                value = LrView.bind("selectedIndex"),
                checked_value = i,
                width_in_chars = RADIO_WIDTH_IN_CHARS,
            }

            local links = linksForCandidate and linksForCandidate(r)
            if links and #links > 0 then
                -- Every radio shares the same fixed width (see
                -- RADIO_WIDTH_IN_CHARS above), so the button(s) trailing
                -- right after it land at the same x position on every row
                -- with no extra alignment trick needed.
                local rowArgs = { radio }
                for _, link in ipairs(links) do
                    table.insert(rowArgs, f:push_button {
                        title = link.label,
                        action = function()
                            LrHttp.openUrlInBrowser(link.url)
                        end,
                    })
                end
                table.insert(scrollArgs, f:row(rowArgs))
            else
                table.insert(scrollArgs, radio)
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
            otherServiceFooterButton = otherServiceButton
        end

        -- Computed on demand, not automatically -- see doc comment above.
        -- Each row's title/enabled state is set by directly mutating these
        -- view objects (not via bind_to_object/LrView.bind reactivity,
        -- which doesn't reliably refresh a control's title after the
        -- dialog is already showing -- confirmed the hard way in
        -- DialogTest.lua; Adobe's own CustomDialogWithObserver.lua sample
        -- does the same direct-mutation thing). All rows -- one header +
        -- MAX_COMMON_ANCESTOR_OPTIONS radios per source group -- are
        -- pre-created up front (a dialog can't have new rows injected
        -- after it's already showing -- see doc comment above), then
        -- populated -- or left as an unused placeholder -- once
        -- computeCommonAncestor actually returns. sectionLabelForIndex is
        -- only given once candidates from a second service are already on
        -- screen (see its own doc comment), so that alone says whether up
        -- to 1 or 2 source groups are possible here.
        local commonAncestorSourceCount = sectionLabelForIndex and 2 or 1
        -- Indexed [source][slot] -- kept alongside the flat option lookup
        -- below (indexed by absolute row position) purely so the click
        -- handler can address "group 2, row 3" without recomputing offsets.
        local commonAncestorOptionsBySource = nil
        if computeCommonAncestor then
            local commonAncestorHeaders = {}
            local commonAncestorRadios = {} -- flat, in row order: source 1's slots, then source 2's
            -- The iNat link button's URL for each slot -- populated
            -- alongside the radio's title below. The button itself is
            -- pre-created (same "can't inject rows later" constraint) with
            -- a fixed action that reads this table at click time, rather
            -- than trying to rebind .action on an existing view after
            -- construction (unlike .title/.enabled, reassigning a view's
            -- action callback post-creation isn't an established-working
            -- pattern in this codebase, so this sidesteps needing it).
            local commonAncestorLinkUrls = {}
            local commonAncestorLinkButtons = {} -- flat, same indexing as commonAncestorRadios

            for source = 1, commonAncestorSourceCount do
                local header = f:static_text { title = "" }
                table.insert(commonAncestorHeaders, header)
                table.insert(scrollArgs, header)

                for slot = 1, MAX_COMMON_ANCESTOR_OPTIONS do
                    local rowIndex = #commonAncestorRadios + 1
                    -- Fixed width up front -- like the static_text bug in
                    -- DialogTest.lua, a control doesn't grow to fit .title
                    -- changes made after creation, so sizing to the short
                    -- placeholder here would clip the real (longer) label
                    -- once computed.
                    local radio = f:radio_button {
                        title = "(not yet computed)",
                        value = LrView.bind("selectedIndex"),
                        checked_value = #candidates + rowIndex,
                        enabled = false,
                        width_in_chars = RADIO_WIDTH_IN_CHARS,
                    }
                    table.insert(commonAncestorRadios, radio)

                    local linkButton = f:push_button {
                        title = "iNat",
                        enabled = false,
                        action = function()
                            local url = commonAncestorLinkUrls[rowIndex]
                            if url then
                                LrHttp.openUrlInBrowser(url)
                            end
                        end,
                    }
                    table.insert(commonAncestorLinkButtons, linkButton)
                    -- Same shared fixed-width radio as the regular
                    -- candidate rows above -- lands at the same x position.
                    table.insert(scrollArgs, f:row { radio, linkButton })
                end
            end

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
                    for _, radio in ipairs(commonAncestorRadios) do
                        radio.title = "Looking up..."
                    end

                    LrTasks.startAsyncTask(function()
                        local ok, groups = LrTasks.pcall(computeCommonAncestor)
                        local foundAny = false
                        if ok and groups then
                            commonAncestorOptionsBySource = groups
                            for source = 1, commonAncestorSourceCount do
                                local group = groups[source]
                                commonAncestorHeaders[source].title = group and (group.label .. ":") or ""
                                for slot = 1, MAX_COMMON_ANCESTOR_OPTIONS do
                                    local rowIndex = (source - 1) * MAX_COMMON_ANCESTOR_OPTIONS + slot
                                    local radio = commonAncestorRadios[rowIndex]
                                    local linkButton = commonAncestorLinkButtons[rowIndex]
                                    local option = group and group.options and group.options[slot]
                                    if option then
                                        foundAny = true
                                        radio.title = formatEntry(option.candidate)
                                            .. string.format("  [rolls up %d candidates]", option.memberCount)
                                        radio.enabled = true
                                        -- commonAncestorOptions guarantees a
                                        -- real resolved taxon id on every
                                        -- option it returns.
                                        commonAncestorLinkUrls[rowIndex] = "https://www.inaturalist.org/taxa/" .. tostring(option.candidate.id)
                                        linkButton.enabled = true
                                    else
                                        radio.title = "(no additional option)"
                                    end
                                end
                            end
                        end
                        if foundAny then
                            props.selectedIndex = #candidates + 1
                        else
                            for _, radio in ipairs(commonAncestorRadios) do
                                radio.title = "No common ancestor found"
                            end
                        end
                    end)
                end,
            }
            commonAncestorFooterButton = commonAncestorButton
        end

        -- Hint text and footer buttons stay fixed/always visible, outside
        -- the scrollable list -- otherwise "Also try X" or "Find Common
        -- Ancestor" could scroll out of reach on a long combined list.
        local args = {
            f:static_text { title = hint or "Which one is it?" },
            f:scrolled_view {
                width = CANDIDATE_LIST_WIDTH,
                height = CANDIDATE_LIST_HEIGHT,
                vertical_scroller = true,
                f:column(scrollArgs),
            },
        }
        if otherServiceFooterButton then
            table.insert(args, otherServiceFooterButton)
        end
        if commonAncestorFooterButton then
            table.insert(args, commonAncestorFooterButton)
        end

        local contents = f:row {
            f:catalog_photo { photo = photos[1], width = 400, height = 400, frame_width = 1 },
            f:column(args),
        }

        local result = LrDialogs.presentModalDialog {
            title = title,
            contents = contents,
            actionVerb = "Tag Photos",
            otherVerb = "None of These (Enter Manually)",
        }

        if result == "ok" then
            -- Absolute position among the pre-created common-ancestor rows
            -- (1-based, spanning all source groups back to back) -> which
            -- group and which slot within it, mirroring how the rows were
            -- laid out and indexed above.
            local flatSlot = props.selectedIndex - #candidates
            local option = nil
            if commonAncestorOptionsBySource and flatSlot >= 1 then
                local source = math.ceil(flatSlot / MAX_COMMON_ANCESTOR_OPTIONS)
                local slot = flatSlot - (source - 1) * MAX_COMMON_ANCESTOR_OPTIONS
                local group = commonAncestorOptionsBySource[source]
                option = group and group.options and group.options[slot]
            end
            if option then
                selected = option.candidate
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
