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

-- The live iNat preview thumbnail shown under the local reference photo
-- matches its 400x400 size, per the user's own request -- see
-- downloadThumbnailsForCandidate's doc comment below.
local INAT_THUMBNAIL_SIZE = 400

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
-- called as `linksForCandidate(candidate)` for each row and should return
-- a list of { label, url } and/or { label, resolveUrl } entries; `url`
-- opens immediately, `resolveUrl` (a no-arg function returning a url or
-- nil) resolves lazily ON CLICK instead, inside its own LrTasks-started
-- task -- for a link whose real destination isn't known until it's
-- actually needed (e.g. resolving a Pl@ntNet-sourced candidate's iNat
-- taxon page requires a name-search round trip; doing that for every row
-- when the dialog opens would be a network call per row before the user
-- has asked for any of them). Each entry becomes its own button next to
-- that row, opening the resolved URL in the system browser.
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
-- combined into one. These rows stay hidden (not just disabled) until
-- actually populated -- see #8 in the doc comment history, changed
-- 2026-08-07 from a visible "(not yet computed)" placeholder since a
-- rarely-used two-source dialog could otherwise show up to 6 grayed-out
-- rows nobody asked for.
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
-- `photoPaths`, local file paths to the photos being identified (non-
-- empty -- the real caller already refuses to reach this point with none
-- selected), shows photoPaths[1] as a large 400x400 reference image
-- alongside the candidate list -- these ID commands work on a small
-- batch of angles of the same organism. Added 2026-08-05, since this
-- dialog previously had no image at all, unlike the merge/sync collision
-- pickers. Deliberately file paths (via f:picture), not LrPhoto objects
-- (via f:catalog_photo) -- confirmed live 2026-08-07 that catalog_photo's
-- .photo doesn't actually re-render when mutated post-creation, unlike
-- f:picture's .value (already proven by the iNat thumbnail preview
-- below), which is why paging (below) needs a real file per photo.
-- Expected to be a SEPARATE, smaller (e.g. ~800px) export than whatever
-- the caller uses for its own identification API upload -- decoding a
-- full upload-sized (2048px) JPEG on every paging click was noticeably
-- laggy, live-confirmed 2026-08-07 (see ExportTemp.exportToTempDisplayJpegs).
-- When more than one photo is passed, prev/next arrows and an "X of Y"
-- counter let the user page through all of them (added 2026-08-07 -- one
-- angle isn't always enough to judge a tricky ID against the candidate
-- list).
--
-- `downloadThumbnailsForCandidate`, if given, is called as
-- `downloadThumbnailsForCandidate(candidate)` every time the selected row
-- changes (including the initial default selection) and should return a
-- list of local file paths to downloaded images (empty if none are
-- available) -- shown as a live INAT_THUMBNAIL_SIZE-square preview under
-- the local reference photo, e.g. an iNat taxon's own photos, for a
-- visual side-by-side comparison against the local photo. When a
-- candidate has more than one photo, prev/next arrows and an "X of Y"
-- counter appear (added 2026-08-07, same reasoning as the local
-- reference photo's own paging above) -- confirmed live against the real
-- API that a taxon can have several photos (default_photo plus
-- taxon_photos), not just one. Called on demand per row, not prefetched
-- for every candidate up front, so switching between rows already seen
-- this dialog is instant (results are cached by candidate) while a row
-- seen for the first time takes one network round trip. Runs in its own
-- LrTasks-started task, same reasoning as computeCommonAncestor above --
-- it's expected to make network calls. Every path this returns is
-- deleted once the dialog closes (own temp-file, per-call downloads, not
-- the caller's to clean up).
--
-- `existingTagText`, if given, is shown as an extra line ("Currently
-- tagged: ...") above the candidate list -- the photo's current local
-- species tag (see KeywordWriter.findSpeciesName), so the user has that
-- context before picking a new one. Purely a string the caller already
-- resolved; this module makes no metadata calls of its own.
--
-- `resolveManualEntry`, if given, adds an inline "type a scientific name"
-- text field + button (replacing the old separate "None of These"
-- dialog) -- called as `resolveManualEntry(name)` on demand and should
-- return a candidate (or nil if no exact match), same shape as
-- INaturalist.resolveByName. A successful resolution fills one more
-- pre-allocated, hidden-until-used row (same approach as the common-
-- ancestor rows) and selects it -- which then drives the SAME live
-- thumbnail preview as any other row, letting the user compare a
-- hand-typed ID's iNat photo against the local one before committing,
-- without leaving this dialog. Runs in its own LrTasks-started task, same
-- reasoning as computeCommonAncestor above.
--
-- Returns selected: the candidate that was picked and confirmed, or nil
-- if the dialog was canceled.
--   - wantOtherService: true if the other-service button was clicked
--     (the caller should fetch that service's results and reopen)
function CandidatePicker.choose(
    title, candidates, defaultIndex, hint, linksForCandidate, countForCandidate, computeCommonAncestor,
    otherServiceButtonLabel, sectionLabelForIndex, photoPaths, downloadThumbnailsForCandidate,
    existingTagText, resolveManualEntry
)
    local selected = nil
    local wantOtherService = false

    LrFunctionContext.callWithContext("CandidatePicker", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.selectedIndex = defaultIndex or 1
        props.manualEntryName = ""

        local f = LrView.osFactory()

        -- Everything selectable (candidates + common-ancestor rollup rows
        -- + the manual-entry result row) lives in this scrollable column,
        -- bound to props so radios in it can use LrView.bind -- kept
        -- separate from `args` below (the hint text and footer buttons,
        -- which stay fixed/always visible regardless of list length) so
        -- the scroll viewport wraps only the list itself.
        local scrollArgs = {
            bind_to_object = props,
            spacing = f:control_spacing(),
        }
        -- Set further down (if applicable) but declared here so the fixed
        -- footer built after the scroll view can reference them
        -- regardless of which blocks below actually run.
        local otherServiceFooterButton = nil
        local commonAncestorFooterButton = nil
        local manualEntryFooterArgs = nil

        -- Wraps a link's { label, url } / { label, resolveUrl } into a
        -- push_button. Lazy (resolveUrl) links resolve on click, inside
        -- their own LrTasks-started task -- see resolveUrl's own doc
        -- comment above.
        local function buildLinkButton(link)
            local button
            button = f:push_button {
                title = link.label,
                action = function()
                    if link.url then
                        LrHttp.openUrlInBrowser(link.url)
                    elseif link.resolveUrl then
                        local originalTitle = button.title
                        button.enabled = false
                        button.title = "..."
                        LrTasks.startAsyncTask(function()
                            local ok, url = LrTasks.pcall(link.resolveUrl)
                            button.title = originalTitle
                            button.enabled = true
                            if ok and url then
                                LrHttp.openUrlInBrowser(url)
                            end
                        end)
                    end
                end,
            }
            return button
        end

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
                    table.insert(rowArgs, buildLinkButton(link))
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
        -- Each row's title/url is set by directly mutating these view
        -- objects (not via bind_to_object/LrView.bind reactivity, which
        -- doesn't reliably refresh a control's title after the dialog is
        -- already showing -- confirmed the hard way in DialogTest.lua;
        -- Adobe's own CustomDialogWithObserver.lua sample does the same
        -- direct-mutation thing). All rows -- one header + MAX_COMMON_
        -- ANCESTOR_OPTIONS radios per source group -- are pre-created up
        -- front (a dialog can't have new rows injected after it's already
        -- showing -- see doc comment above), then populated -- or left
        -- hidden -- once computeCommonAncestor actually returns. Hiding
        -- (rather than a visible disabled placeholder) confirmed live
        -- 2026-08-07 to work the same way as the thumbnail preview's
        -- visible toggling. sectionLabelForIndex is only given once
        -- candidates from a second service are already on screen (see its
        -- own doc comment), so that alone says whether up to 1 or 2
        -- source groups are possible here.
        local commonAncestorSourceCount = sectionLabelForIndex and 2 or 1
        local commonAncestorRowCount = computeCommonAncestor and (commonAncestorSourceCount * MAX_COMMON_ANCESTOR_OPTIONS) or 0
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
            -- construction (unlike .title/.visible, reassigning a view's
            -- action callback post-creation isn't an established-working
            -- pattern in this codebase, so this sidesteps needing it).
            local commonAncestorLinkUrls = {}
            local commonAncestorLinkButtons = {} -- flat, same indexing as commonAncestorRadios

            for source = 1, commonAncestorSourceCount do
                -- Fixed width up front -- same reasoning as
                -- manualEntryErrorText below: a control doesn't grow to
                -- fit a .title change made after creation.
                local header = f:static_text { title = "", visible = false, width_in_chars = RADIO_WIDTH_IN_CHARS }
                table.insert(commonAncestorHeaders, header)
                table.insert(scrollArgs, header)

                for slot = 1, MAX_COMMON_ANCESTOR_OPTIONS do
                    local rowIndex = #commonAncestorRadios + 1
                    -- visible = false set on each LEAF control directly,
                    -- not on the row wrapping them -- confirmed live
                    -- 2026-08-07 that a row container's own visible flag
                    -- doesn't reliably hide its children (unlike a leaf
                    -- control's own visible, which the thumbnail preview
                    -- already proved works), so hiding has to happen at
                    -- the control that's actually rendering.
                    local radio = f:radio_button {
                        title = "",
                        value = LrView.bind("selectedIndex"),
                        checked_value = #candidates + rowIndex,
                        width_in_chars = RADIO_WIDTH_IN_CHARS,
                        visible = false,
                    }
                    table.insert(commonAncestorRadios, radio)

                    local linkButton = f:push_button {
                        title = "iNat",
                        visible = false,
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
                    local originalTitle = commonAncestorButton.title
                    commonAncestorButton.enabled = false
                    commonAncestorButton.title = "Looking up..."

                    LrTasks.startAsyncTask(function()
                        local ok, groups = LrTasks.pcall(computeCommonAncestor)
                        local foundAny = false
                        local firstPopulatedIndex = nil
                        if ok and groups then
                            commonAncestorOptionsBySource = groups
                            for source = 1, commonAncestorSourceCount do
                                local group = groups[source]
                                local anyForSource = false
                                for slot = 1, MAX_COMMON_ANCESTOR_OPTIONS do
                                    local rowIndex = (source - 1) * MAX_COMMON_ANCESTOR_OPTIONS + slot
                                    local radio = commonAncestorRadios[rowIndex]
                                    local linkButton = commonAncestorLinkButtons[rowIndex]
                                    local option = group and group.options and group.options[slot]
                                    if option then
                                        anyForSource = true
                                        foundAny = true
                                        firstPopulatedIndex = firstPopulatedIndex or (#candidates + rowIndex)
                                        radio.title = formatEntry(option.candidate)
                                            .. string.format("  [rolls up %d candidates]", option.memberCount)
                                        -- commonAncestorOptions guarantees a
                                        -- real resolved taxon id on every
                                        -- option it returns.
                                        commonAncestorLinkUrls[rowIndex] = "https://www.inaturalist.org/taxa/" .. tostring(option.candidate.id)
                                        radio.visible = true
                                        linkButton.visible = true
                                    end
                                end
                                commonAncestorHeaders[source].visible = anyForSource
                                if anyForSource then
                                    commonAncestorHeaders[source].title = group.label .. ":"
                                end
                            end
                        end
                        if foundAny then
                            commonAncestorButton.title = originalTitle
                            props.selectedIndex = firstPopulatedIndex
                        else
                            commonAncestorButton.title = "No common ancestor found"
                        end
                    end)
                end,
            }
            commonAncestorFooterButton = commonAncestorButton
        end

        -- One more pre-allocated, hidden-until-used row for a successful
        -- inline manual-entry resolution -- see resolveManualEntry's own
        -- doc comment above. Comes right after every common-ancestor slot
        -- (reserved or not), same "reserve up front, populate on demand"
        -- constraint as everything else in this dialog.
        local manualEntryRowIndex = #candidates + commonAncestorRowCount + 1
        local manualEntryRadio = nil
        local manualEntryLinkButton = nil
        local manualEntryCandidate = nil
        if resolveManualEntry then
            -- visible = false on each leaf control directly -- see the
            -- common-ancestor rows' own comment above for why a row
            -- container's visible flag alone doesn't reliably hide it.
            manualEntryRadio = f:radio_button {
                title = "",
                value = LrView.bind("selectedIndex"),
                checked_value = manualEntryRowIndex,
                width_in_chars = RADIO_WIDTH_IN_CHARS,
                visible = false,
            }
            manualEntryLinkButton = f:push_button {
                title = "iNat",
                visible = false,
                action = function()
                    if manualEntryCandidate and manualEntryCandidate.id then
                        LrHttp.openUrlInBrowser("https://www.inaturalist.org/taxa/" .. tostring(manualEntryCandidate.id))
                    end
                end,
            }
            table.insert(scrollArgs, f:row { manualEntryRadio, manualEntryLinkButton })
        end

        -- Resolves a 1-based row index (matching props.selectedIndex's own
        -- numbering) to the candidate it represents -- a plain entry from
        -- `candidates`, a common-ancestor rollup option once one has been
        -- computed, or the manual-entry result once resolved (see the
        -- resolution logic already worked out in the final "ok" branch
        -- below, factored out here so the live thumbnail preview can
        -- reuse the exact same mapping instead of re-deriving it).
        local function candidateForIndex(index)
            if resolveManualEntry and index == manualEntryRowIndex then
                return manualEntryCandidate
            end
            local flatSlot = index - #candidates
            if commonAncestorOptionsBySource and flatSlot >= 1 then
                local source = math.ceil(flatSlot / MAX_COMMON_ANCESTOR_OPTIONS)
                local slot = flatSlot - (source - 1) * MAX_COMMON_ANCESTOR_OPTIONS
                local group = commonAncestorOptionsBySource[source]
                local option = group and group.options and group.options[slot]
                if option then
                    return option.candidate
                end
            end
            return candidates[index]
        end

        if resolveManualEntry then
            -- Fixed width up front -- same "doesn't grow to fit a later
            -- .title change" control behavior as the common-ancestor
            -- radios above (see RADIO_WIDTH_IN_CHARS's own comment) --
            -- sizing to the empty starting title here would leave the
            -- real error message invisibly clipped once set.
            local manualEntryErrorText = f:static_text { title = "", visible = false, width_in_chars = RADIO_WIDTH_IN_CHARS }
            -- immediate = true -- without it, an edit_field only commits
            -- its bound value when it loses focus, and on Mac that only
            -- happens on Tab, NOT on clicking a different control with
            -- the mouse (per LrView's own docs) -- clicking "Look Up"
            -- directly would otherwise read back the stale (empty)
            -- value every time.
            local manualEntryField = f:edit_field {
                value = LrView.bind("manualEntryName"),
                width_in_chars = 30,
                immediate = true,
            }
            local manualEntryButton
            manualEntryButton = f:push_button {
                title = "Look Up",
                action = function()
                    local name = props.manualEntryName
                    if not name or name == "" then
                        return
                    end
                    manualEntryButton.enabled = false
                    manualEntryErrorText.visible = false

                    LrTasks.startAsyncTask(function()
                        local ok, candidate = LrTasks.pcall(resolveManualEntry, name)
                        manualEntryButton.enabled = true
                        if ok and candidate then
                            manualEntryCandidate = candidate
                            manualEntryRadio.title = formatEntry(candidate)
                            manualEntryRadio.visible = true
                            manualEntryLinkButton.visible = true
                            props.selectedIndex = manualEntryRowIndex
                        else
                            manualEntryErrorText.title = "No exact iNaturalist match for \"" .. name .. "\""
                            manualEntryErrorText.visible = true
                        end
                    end)
                end,
            }
            manualEntryFooterArgs = {
                f:static_text { title = "None of these? Type a scientific name:" },
                f:row { manualEntryField, manualEntryButton },
                manualEntryErrorText,
            }
        end

        -- Every downloaded thumbnail's temp path, regardless of whether
        -- downloadThumbnailsForCandidate was even given -- declared here
        -- (not inside the `if` below) so the cleanup after
        -- presentModalDialog can always iterate it unconditionally.
        local downloadedThumbnailPaths = {}
        local inatThumbnail = nil
        local inatPhotoCounterText = nil
        local inatPrevButton, inatNextButton
        if downloadThumbnailsForCandidate then
            inatThumbnail = f:picture {
                width = INAT_THUMBNAIL_SIZE,
                height = INAT_THUMBNAIL_SIZE,
                frame_width = 1,
                visible = false,
            }
            -- Paging controls for when the selected candidate has more
            -- than one iNat photo (default_photo + taxon_photos --
            -- confirmed live 2026-08-07 that a taxon can have several).
            -- Same visible-on-each-leaf-control approach as everything
            -- else in this dialog.
            inatPhotoCounterText = f:static_text { title = "", visible = false }

            -- currentINatPaths/currentINatIndex track the CURRENTLY
            -- SELECTED CANDIDATE's own photo list -- unlike the local
            -- reference photo's fixed photoPaths (same for the whole
            -- dialog), this set changes every time the selected row
            -- changes, so it's mutable state here rather than a fixed
            -- list captured at dialog-build time.
            local currentINatPaths = {}
            local currentINatIndex = 1

            local function updateINatPhotoNav()
                local total = #currentINatPaths
                if total == 0 then
                    inatThumbnail.visible = false
                    inatPhotoCounterText.visible = false
                    inatPrevButton.visible = false
                    inatNextButton.visible = false
                    return
                end
                inatThumbnail.value = currentINatPaths[currentINatIndex]
                inatThumbnail.visible = true
                inatPhotoCounterText.title = tostring(currentINatIndex) .. " of " .. total
                inatPhotoCounterText.visible = total > 1
                inatPrevButton.visible = total > 1
                inatNextButton.visible = total > 1
                inatPrevButton.enabled = currentINatIndex > 1
                inatNextButton.enabled = currentINatIndex < total
            end

            inatPrevButton = f:push_button {
                title = "◀",
                visible = false,
                action = function()
                    if currentINatIndex > 1 then
                        currentINatIndex = currentINatIndex - 1
                        updateINatPhotoNav()
                    end
                end,
            }
            inatNextButton = f:push_button {
                title = "▶",
                visible = false,
                action = function()
                    if currentINatIndex < #currentINatPaths then
                        currentINatIndex = currentINatIndex + 1
                        updateINatPhotoNav()
                    end
                end,
            }

            -- Cache of already-downloaded photo-path LISTS, keyed by
            -- candidate table identity -- re-selecting a row already seen
            -- this dialog just reuses the list instead of re-downloading.
            -- An empty list is itself a valid, truthy cached result ("this
            -- candidate has no iNat photos"), unlike the single-photo
            -- version this replaced, so no separate not-yet-attempted
            -- sentinel is needed -- absence from the cache table IS "not
            -- yet attempted".
            local thumbnailCache = {}
            -- Guards against a slow download finishing after the user has
            -- already moved on to a different row -- only the request
            -- that was still current when it completes is allowed to
            -- update the view.
            local thumbnailRequestToken = 0

            local function showThumbnailsFor(index)
                local candidate = candidateForIndex(index)
                if not candidate then
                    currentINatPaths = {}
                    currentINatIndex = 1
                    updateINatPhotoNav()
                    return
                end

                local cached = thumbnailCache[candidate]
                if cached then
                    currentINatPaths = cached
                    currentINatIndex = 1
                    updateINatPhotoNav()
                    return
                end

                thumbnailRequestToken = thumbnailRequestToken + 1
                local myToken = thumbnailRequestToken
                currentINatPaths = {}
                currentINatIndex = 1
                updateINatPhotoNav()

                LrTasks.startAsyncTask(function()
                    local ok, paths = LrTasks.pcall(downloadThumbnailsForCandidate, candidate)
                    local resolvedPaths = (ok and paths) or {}
                    thumbnailCache[candidate] = resolvedPaths
                    for _, p in ipairs(resolvedPaths) do
                        table.insert(downloadedThumbnailPaths, p)
                    end
                    -- Only apply if nothing more recent has been
                    -- requested since this download started.
                    if myToken == thumbnailRequestToken then
                        currentINatPaths = resolvedPaths
                        currentINatIndex = 1
                        updateINatPhotoNav()
                    end
                end)
            end

            props:addObserver("selectedIndex", function(_, _, newValue)
                showThumbnailsFor(newValue)
            end)

            -- addObserver only fires on future CHANGES, not the current
            -- value at registration time, so kick off a load for the
            -- initial selection too.
            showThumbnailsFor(props.selectedIndex)
        end

        -- Hint text and footer buttons stay fixed/always visible, outside
        -- the scrollable list -- otherwise "Also try X" or "Find Common
        -- Ancestor" could scroll out of reach on a long combined list.
        -- bind_to_object needed here too, not just on scrollArgs -- the
        -- manual-entry field's LrView.bind("manualEntryName") lives in
        -- this footer, a sibling of the scrolled_view, not a descendant
        -- of it, so it has no bound ancestor to resolve against without
        -- this. Confirmed live 2026-08-07 via debug logging: the button
        -- fired correctly, but props.manualEntryName always read back
        -- empty -- an unbound LrView.bind just silently never commits.
        local args = {
            bind_to_object = props,
            f:static_text { title = hint or "Which one is it?" },
        }
        if existingTagText then
            table.insert(args, f:static_text { title = "Currently tagged: " .. existingTagText })
        end
        table.insert(args, f:scrolled_view {
            width = CANDIDATE_LIST_WIDTH,
            height = CANDIDATE_LIST_HEIGHT,
            vertical_scroller = true,
            f:column(scrollArgs),
        })
        if otherServiceFooterButton then
            table.insert(args, otherServiceFooterButton)
        end
        if commonAncestorFooterButton then
            table.insert(args, commonAncestorFooterButton)
        end
        if manualEntryFooterArgs then
            for _, view in ipairs(manualEntryFooterArgs) do
                table.insert(args, view)
            end
        end

        -- The local reference photo and its live iNat thumbnail (if any)
        -- stack vertically, side by side with the candidate list -- same
        -- INAT_THUMBNAIL_SIZE square as the local photo, per the user's
        -- own request, for a direct visual comparison. f:picture, not
        -- f:catalog_photo -- see photoPaths' own doc comment above for
        -- why.
        local localPhotoView = f:picture { value = photoPaths[1], width = 400, height = 400, frame_width = 1 }
        local leftColumnArgs = { localPhotoView }

        -- Paging arrows + "X of Y" counter, only when there's more than
        -- one photo to look through -- these ID commands work on a
        -- handful of angles of the same organism, so switching the
        -- reference photo can matter (e.g. one angle shows the diagnostic
        -- feature better than another). Same direct-mutation approach as
        -- everything else in this dialog (.value/.title/.enabled set
        -- directly on the already-built views, not via LrView.bind
        -- reactivity -- see the doc comment on the common-ancestor button
        -- above for why).
        if #photoPaths > 1 then
            local currentPhotoIndex = 1
            local photoCounterText = f:static_text { title = "1 of " .. #photoPaths }
            local prevPhotoButton, nextPhotoButton
            local function updatePhotoNav()
                localPhotoView.value = photoPaths[currentPhotoIndex]
                photoCounterText.title = tostring(currentPhotoIndex) .. " of " .. #photoPaths
                prevPhotoButton.enabled = currentPhotoIndex > 1
                nextPhotoButton.enabled = currentPhotoIndex < #photoPaths
            end
            prevPhotoButton = f:push_button {
                title = "◀",
                enabled = false,
                action = function()
                    if currentPhotoIndex > 1 then
                        currentPhotoIndex = currentPhotoIndex - 1
                        updatePhotoNav()
                    end
                end,
            }
            nextPhotoButton = f:push_button {
                title = "▶",
                action = function()
                    if currentPhotoIndex < #photoPaths then
                        currentPhotoIndex = currentPhotoIndex + 1
                        updatePhotoNav()
                    end
                end,
            }
            table.insert(leftColumnArgs, f:row { prevPhotoButton, photoCounterText, nextPhotoButton })
        end

        if inatThumbnail then
            table.insert(leftColumnArgs, inatThumbnail)
            table.insert(leftColumnArgs, f:row { inatPrevButton, inatPhotoCounterText, inatNextButton })
        end

        local contents = f:row {
            f:column(leftColumnArgs),
            f:column(args),
        }

        local result = LrDialogs.presentModalDialog {
            title = title,
            contents = contents,
            actionVerb = "Tag Photos",
        }

        -- Best-effort cleanup for every thumbnail downloaded during this
        -- dialog's lifetime -- same as INatSyncRunner.lua's
        -- cleanupINatThumbnail, wrapped in pcall since a failure to delete
        -- a scratch temp file isn't worth surfacing to the user.
        for _, path in ipairs(downloadedThumbnailPaths) do
            pcall(os.remove, path)
        end

        if result == "ok" then
            selected = candidateForIndex(props.selectedIndex)
        elseif result == "tryOtherService" then
            wantOtherService = true
        end
    end)

    return selected, wantOtherService
end

return CandidatePicker
