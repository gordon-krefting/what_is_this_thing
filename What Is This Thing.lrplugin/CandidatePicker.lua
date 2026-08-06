local LrHttp = import 'LrHttp'
local LrView = import 'LrView'
local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local CandidatePicker = {}

-- How many candidate rows each service tab (iNaturalist, Pl@ntNet)
-- reserves -- a dialog can't have new rows injected into it after it's
-- already showing, so this many placeholder rows are always pre-created
-- per tab and only some of them may end up populated; an occasional
-- richer result set beyond this cap is silently truncated, not shown.
local MAX_CANDIDATES_PER_TAB = 10
-- How many "Find Common Ancestor" rollup options each service tab
-- reserves, same "pre-create, populate or leave hidden" reasoning.
local MAX_ANCESTOR_OPTIONS_PER_TAB = 3

-- Global flat slot layout, matching props.selectedIndex's own numbering
-- (a single radio-group value spans every tab, so whichever radio is
-- checked -- in ANY tab -- is unambiguous and drives the live thumbnail
-- preview the same way regardless of which tab happens to be visible):
--   1..10    iNaturalist candidates
--   11..13   iNaturalist "Find Common Ancestor" rollups
--   14..23   Pl@ntNet candidates
--   24..26   Pl@ntNet "Find Common Ancestor" rollups
--   27       manual-entry result
local INAT_CANDIDATE_BASE = 0
local INAT_ANCESTOR_BASE = INAT_CANDIDATE_BASE + MAX_CANDIDATES_PER_TAB
local PLANTNET_CANDIDATE_BASE = INAT_ANCESTOR_BASE + MAX_ANCESTOR_OPTIONS_PER_TAB
local PLANTNET_ANCESTOR_BASE = PLANTNET_CANDIDATE_BASE + MAX_CANDIDATES_PER_TAB
local MANUAL_INDEX = PLANTNET_ANCESTOR_BASE + MAX_ANCESTOR_OPTIONS_PER_TAB + 1

-- Fixed viewport for each tab's scrollable candidate list -- bounds the
-- dialog's height regardless of how many candidates/rollup options there
-- are. Wide enough to comfortably fit RADIO_WIDTH_IN_CHARS plus a
-- trailing link button without triggering the horizontal scrollbar in
-- the common case -- Mac auto-hides it when the content fits (per
-- scrolled_view's own SDK docs), so an occasional wider row just gets one
-- instead of being clipped.
--
-- Confirmed live (2026-08-06): at 750, a radio fixed to RADIO_WIDTH_IN_
-- CHARS plus its trailing button came out a few pixels wider than the
-- viewport -- content itself was fine (fully readable, nothing clipped),
-- just short on room, so this only widens the viewport rather than
-- touching the radio width again.
local CANDIDATE_LIST_WIDTH = 900
local CANDIDATE_LIST_HEIGHT = 500

-- Every radio in the list -- regular candidates and common-ancestor
-- rollups alike -- gets this same fixed width, so a row's link button
-- always lands at the same x position regardless of how long that row's
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
-- matches its 400x400 size, per the user's own request.
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

-- Builds a single pre-allocated "iNat" link button whose actual
-- destination is read fresh at click time via getLink() -- needed
-- because a button's .action can't be rebound after construction (not an
-- established-working pattern in this codebase), so the link itself has
-- to be indirected through a closure instead of baked in when the row is
-- first built, before any real candidate is behind it. getLink() should
-- return { url = ... } or { resolveUrl = ... } (a no-arg function
-- resolving lazily on click, for a destination not known until it's
-- actually needed -- e.g. a Pl@ntNet-sourced candidate's iNat taxon page
-- requires a name-search round trip) or nil if there's nothing to link
-- to yet.
local function buildLinkButton(f, getLink)
    local button
    button = f:push_button {
        title = "iNat",
        visible = false,
        action = function()
            local link = getLink()
            if not link then
                return
            end
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

-- Builds one "service" tab's content: MAX_CANDIDATES_PER_TAB pre-
-- allocated candidate rows (hidden until populated) + a "Find Common
-- Ancestor" button (hidden until there's at least one candidate to
-- compute from) + MAX_ANCESTOR_OPTIONS_PER_TAB pre-allocated rollup rows
-- (hidden until computed) -- shared by the iNaturalist and Pl@ntNet tabs,
-- which are structurally identical, just populated at different times
-- (iNaturalist immediately, since it's already known by the time this
-- dialog opens; Pl@ntNet lazily, on first view of its own tab).
--
-- `computeCommonAncestorFor` is called as
-- `computeCommonAncestorFor(candidates, MAX_ANCESTOR_OPTIONS_PER_TAB)`
-- (matching INaturalist.commonAncestorOptions' own signature) -- always
-- against just THIS tab's own candidates, never mixed with the other
-- tab's, since the two services' scores aren't comparable (see
-- commonAncestorOptions' own doc comment).
--
-- Returns:
--   panelArgs -- the list of views to place in this tab's f:column.
--   populate(candidates, countForCandidate) -- fills the candidate rows
--     (up to MAX_CANDIDATES_PER_TAB; extras are silently not shown) and
--     reveals the Find Common Ancestor button if there's at least one.
--     Safe to call with an empty list (leaves everything hidden).
--   resolveIndex(globalIndex) -- returns the candidate at that global
--     slot if it falls within this panel's own candidate/ancestor
--     ranges, else nil.
local function buildServicePanel(f, props, candidateBase, ancestorBase, linksForCandidate, computeCommonAncestorFor)
    local panelArgs = { bind_to_object = props, spacing = f:control_spacing() }

    local currentCandidates = {}
    local currentAncestorOptions = {}

    local candidateRadios = {}
    local candidateLinkButtons = {}
    local candidateLinks = {} -- slot -> link table, set by populate()
    for slot = 1, MAX_CANDIDATES_PER_TAB do
        local radio = f:radio_button {
            title = "",
            value = LrView.bind("selectedIndex"),
            checked_value = candidateBase + slot,
            width_in_chars = RADIO_WIDTH_IN_CHARS,
            visible = false,
        }
        table.insert(candidateRadios, radio)
        local linkButton = buildLinkButton(f, function() return candidateLinks[slot] end)
        table.insert(candidateLinkButtons, linkButton)
        table.insert(panelArgs, f:row { radio, linkButton })
    end

    local ancestorRadios = {}
    local ancestorLinkButtons = {}
    local ancestorLinks = {} -- slot -> link table, set once computed
    for slot = 1, MAX_ANCESTOR_OPTIONS_PER_TAB do
        local radio = f:radio_button {
            title = "",
            value = LrView.bind("selectedIndex"),
            checked_value = ancestorBase + slot,
            width_in_chars = RADIO_WIDTH_IN_CHARS,
            visible = false,
        }
        table.insert(ancestorRadios, radio)
        local linkButton = buildLinkButton(f, function() return ancestorLinks[slot] end)
        table.insert(ancestorLinkButtons, linkButton)
        table.insert(panelArgs, f:row { radio, linkButton })
    end

    local ancestorButton
    ancestorButton = f:push_button {
        title = "Find Common Ancestor",
        visible = false,
        -- Button actions run on Lightroom's main task, not inside
        -- whatever async task launched this dialog. computeCommonAncestorFor
        -- makes network calls (which need to yield), so it must run
        -- inside its own LrTasks-started task or it can hang indefinitely
        -- instead of failing cleanly.
        action = function()
            local originalTitle = ancestorButton.title
            ancestorButton.enabled = false
            ancestorButton.title = "Looking up..."

            LrTasks.startAsyncTask(function()
                local ok, options = LrTasks.pcall(computeCommonAncestorFor, currentCandidates, MAX_ANCESTOR_OPTIONS_PER_TAB)
                local foundAny = false
                local firstPopulatedIndex = nil
                if ok and options then
                    currentAncestorOptions = options
                    for slot = 1, MAX_ANCESTOR_OPTIONS_PER_TAB do
                        local option = options[slot]
                        if option then
                            foundAny = true
                            firstPopulatedIndex = firstPopulatedIndex or (ancestorBase + slot)
                            ancestorRadios[slot].title = formatEntry(option.candidate)
                                .. string.format("  [rolls up %d candidates]", option.memberCount)
                            ancestorRadios[slot].visible = true
                            -- commonAncestorOptions guarantees a real
                            -- resolved taxon id on every option it
                            -- returns.
                            ancestorLinks[slot] = { url = "https://www.inaturalist.org/taxa/" .. tostring(option.candidate.id) }
                            ancestorLinkButtons[slot].visible = true
                        end
                    end
                end
                if foundAny then
                    ancestorButton.title = originalTitle
                    ancestorButton.enabled = true
                    props.selectedIndex = firstPopulatedIndex
                else
                    ancestorButton.title = "No common ancestor found"
                end
            end)
        end,
    }
    table.insert(panelArgs, ancestorButton)

    local function populate(candidates, countForCandidate)
        currentCandidates = candidates
        for slot = 1, MAX_CANDIDATES_PER_TAB do
            local candidate = candidates[slot]
            if candidate then
                local count = countForCandidate and countForCandidate(candidate)
                candidateRadios[slot].title = formatEntry(candidate, count)
                candidateRadios[slot].visible = true
                local links = linksForCandidate(candidate)
                local link = links and links[1]
                candidateLinks[slot] = link
                candidateLinkButtons[slot].visible = (link ~= nil)
            end
        end
        ancestorButton.visible = (#candidates > 0)
    end

    local function resolveIndex(globalIndex)
        if globalIndex > candidateBase and globalIndex <= candidateBase + MAX_CANDIDATES_PER_TAB then
            return currentCandidates[globalIndex - candidateBase]
        end
        if globalIndex > ancestorBase and globalIndex <= ancestorBase + MAX_ANCESTOR_OPTIONS_PER_TAB then
            local slot = globalIndex - ancestorBase
            local option = currentAncestorOptions[slot]
            return option and option.candidate
        end
        return nil
    end

    return panelArgs, populate, resolveIndex
end

-- Shows a modal dialog for picking a species identification, organized
-- into three tabs -- iNaturalist, Pl@ntNet, and Manual Entry -- so each
-- service's candidates, common-ancestor rollups, and (for Pl@ntNet) its
-- own lazy fetch stay self-contained instead of being mixed into one
-- flat list. Takes a single table of named options (not positional
-- arguments -- this grew past the point where remembering positional
-- order was reasonable):
--
-- `title` -- the dialog's title.
--
-- `photoPaths` -- local file paths to the photos being identified (non-
-- empty -- the real caller already refuses to reach this point with none
-- selected), shown as a large 400x400 reference image alongside the
-- candidate list. Deliberately file paths (via f:picture), not LrPhoto
-- objects (via f:catalog_photo) -- confirmed live 2026-08-07 that
-- catalog_photo's .photo doesn't actually re-render when mutated post-
-- creation, unlike f:picture's .value. Expected to be a SEPARATE,
-- smaller (e.g. ~800px) export than whatever the caller uses for its own
-- identification API upload -- decoding a full upload-sized (2048px)
-- JPEG on every paging click was noticeably laggy, live-confirmed
-- 2026-08-07 (see ExportTemp.exportToTempDisplayJpegs). When more than
-- one photo is passed, prev/next arrows and an "X of Y" counter let the
-- user page through all of them.
--
-- `hint` -- optional, replaces the default header text -- useful for
-- explaining why a particular entry was preselected.
--
-- `existingTagText` -- optional, shown as an extra line ("Currently
-- tagged: ...") above the candidate list -- the photo's current local
-- species tag (see KeywordWriter.findSpeciesName), so the user has that
-- context before picking a new one. Purely a string the caller already
-- resolved; this module makes no metadata calls of its own.
--
-- `inatCandidates` -- the iNaturalist tab's candidates (non-empty -- the
-- real caller already goes straight to manual entry instead of opening
-- this dialog at all when there are zero automatic results), already
-- known by the time this dialog opens, so its tab is populated
-- immediately rather than lazily. Only the first MAX_CANDIDATES_PER_TAB
-- are shown; a richer result set is silently truncated.
--
-- `inatDefaultIndex` -- optional (default 1), 1-based index into
-- inatCandidates to preselect.
--
-- `countForINatCandidate`, if given, is called as
-- `countForINatCandidate(candidate)` for each iNaturalist row and should
-- return the number of photos already tagged with that candidate's
-- identification (or nil/0 to show nothing extra) -- appended to the
-- row's label, e.g. "[12 photos already tagged]".
--
-- `linksForCandidate`, called as `linksForCandidate(candidate)` for
-- every candidate/rollup row (either tab), should return a list with one
-- { label, url } or { label, resolveUrl } entry; `url` opens
-- immediately, `resolveUrl` (a no-arg function returning a url or nil)
-- resolves lazily ON CLICK instead, inside its own LrTasks-started task
-- -- for a link whose real destination isn't known until it's actually
-- needed (e.g. resolving a Pl@ntNet-sourced candidate's iNat taxon page
-- requires a name-search round trip; doing that for every row when the
-- dialog opens would be a network call per row before the user has asked
-- for any of them).
--
-- `computeCommonAncestorFor` -- called as
-- `computeCommonAncestorFor(candidates, maxOptions)` (matching
-- INaturalist.commonAncestorOptions' own signature) when either tab's
-- own "Find Common Ancestor" button is clicked, always against just that
-- tab's own candidates -- see commonAncestorOptions' own doc comment for
-- why the two services' candidates must never be mixed into one call.
--
-- `fetchPlantNetCandidates` -- called with no arguments the first time
-- the Pl@ntNet tab is viewed (not automatically, and not more than
-- once), inside its own LrTasks-started task. Should return candidates,
-- countForCandidate (a function like countForINatCandidate above, or
-- nil) on success, or raise an error (e.g. via Lua's own `error()`) on
-- failure -- a progress label in that tab shows "Looking up species...",
-- then either hides once results are shown, or reports "no matches
-- found" / the failure, whichever applies.
--
-- `resolveManualEntry` -- called as `resolveManualEntry(name)` on demand
-- (the inline "type a scientific name" field + button in the Manual
-- Entry tab) and should return a candidate (or nil if no exact match),
-- same shape as INaturalist.resolveByName. A successful resolution fills
-- one pre-allocated, hidden-until-used row and selects it -- which then
-- drives the same live thumbnail preview as any other row, letting the
-- user compare a hand-typed ID's iNat photo against the local one before
-- committing, without leaving this dialog.
--
-- `downloadThumbnailsForCandidate` -- called as
-- `downloadThumbnailsForCandidate(candidate)` every time the selected
-- row changes (including the initial default selection, across any
-- tab), and should return a list of local file paths to downloaded
-- images (empty if none are available) -- shown as a live
-- INAT_THUMBNAIL_SIZE-square preview under the local reference photo, so
-- whichever radio is CHECKED -- regardless of which tab is currently
-- being viewed -- always drives this preview, since props.selectedIndex
-- is one value shared across every tab. When a candidate has more than
-- one photo, prev/next arrows and an "X of Y" counter appear. Called on
-- demand per row, not prefetched for every candidate up front, so
-- switching between rows already seen this dialog is instant (results
-- are cached by candidate) while a row seen for the first time takes one
-- network round trip. Runs in its own LrTasks-started task. Every path
-- this returns is deleted once the dialog closes (own temp-file, per-
-- call downloads, not the caller's to clean up).
--
-- Returns selected: the candidate that was picked and confirmed, or nil
-- if the dialog was canceled.
function CandidatePicker.choose(options)
    local title = options.title
    local photoPaths = options.photoPaths
    local hint = options.hint
    local existingTagText = options.existingTagText
    local inatCandidates = options.inatCandidates
    local inatDefaultIndex = options.inatDefaultIndex or 1
    local countForINatCandidate = options.countForINatCandidate
    local linksForCandidate = options.linksForCandidate
    local computeCommonAncestorFor = options.computeCommonAncestorFor
    local fetchPlantNetCandidates = options.fetchPlantNetCandidates
    local resolveManualEntry = options.resolveManualEntry
    local downloadThumbnailsForCandidate = options.downloadThumbnailsForCandidate

    local selected = nil

    LrFunctionContext.callWithContext("CandidatePicker", function(context)
        local props = LrBinding.makePropertyTable(context)
        props.selectedIndex = INAT_CANDIDATE_BASE + inatDefaultIndex
        props.activeTab = "inat"
        props.manualEntryName = ""

        local f = LrView.osFactory()

        local inatPanelArgs, inatPopulate, inatResolveIndex = buildServicePanel(
            f, props, INAT_CANDIDATE_BASE, INAT_ANCESTOR_BASE, linksForCandidate, computeCommonAncestorFor
        )
        inatPopulate(inatCandidates, countForINatCandidate)

        local plantNetPanelArgs, plantNetPopulate, plantNetResolveIndex = buildServicePanel(
            f, props, PLANTNET_CANDIDATE_BASE, PLANTNET_ANCESTOR_BASE, linksForCandidate, computeCommonAncestorFor
        )
        -- Inserted at the front of the tab's own content (after its
        -- bind_to_object/spacing named keys, which don't occupy
        -- positional slots, so this lands as the first visible row) --
        -- shows load progress/errors/"no matches" above the (initially
        -- all-hidden) candidate rows.
        local plantNetProgressText = f:static_text { title = "Not yet loaded", visible = true }
        table.insert(plantNetPanelArgs, 1, plantNetProgressText)

        local plantNetFetchStarted = false
        props:addObserver("activeTab", function(_, _, newValue)
            if newValue ~= "plantnet" or plantNetFetchStarted then
                return
            end
            plantNetFetchStarted = true
            plantNetProgressText.title = "Looking up species..."
            plantNetProgressText.visible = true

            LrTasks.startAsyncTask(function()
                local ok, a, b = LrTasks.pcall(fetchPlantNetCandidates)
                if ok then
                    local candidates, countForCandidate = a, b
                    plantNetPopulate(candidates or {}, countForCandidate)
                    if candidates and #candidates > 0 then
                        plantNetProgressText.visible = false
                    else
                        plantNetProgressText.title = "No Pl@ntNet matches found"
                        plantNetProgressText.visible = true
                    end
                else
                    plantNetProgressText.title = "Pl@ntNet lookup failed: " .. tostring(a)
                    plantNetProgressText.visible = true
                end
            end)
        end)

        -- Manual Entry tab: text field + Look Up button + error message
        -- spot + one pre-allocated, hidden-until-resolved radio+link row.
        local manualEntryRadio = f:radio_button {
            title = "",
            value = LrView.bind("selectedIndex"),
            checked_value = MANUAL_INDEX,
            width_in_chars = RADIO_WIDTH_IN_CHARS,
            visible = false,
        }
        local manualEntryCandidate = nil
        local manualEntryLinkButton = buildLinkButton(f, function()
            return manualEntryCandidate and { url = "https://www.inaturalist.org/taxa/" .. tostring(manualEntryCandidate.id) }
        end)
        -- Fixed width up front -- a control doesn't grow to fit a .title
        -- change made after creation, so sizing to the empty starting
        -- title here would leave the real error message invisibly
        -- clipped once set.
        local manualEntryErrorText = f:static_text { title = "", visible = false, width_in_chars = RADIO_WIDTH_IN_CHARS }
        -- immediate = true -- without it, an edit_field only commits its
        -- bound value when it loses focus, and on Mac that only happens
        -- on Tab, NOT on clicking a different control with the mouse
        -- (per LrView's own docs) -- clicking "Look Up" directly would
        -- otherwise read back the stale (empty) value every time.
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
                        props.selectedIndex = MANUAL_INDEX
                    else
                        manualEntryErrorText.title = "No exact iNaturalist match for \"" .. name .. "\""
                        manualEntryErrorText.visible = true
                    end
                end)
            end,
        }
        local manualPanelArgs = {
            bind_to_object = props,
            spacing = f:control_spacing(),
            f:static_text { title = "Type a scientific name:" },
            f:row { manualEntryField, manualEntryButton },
            manualEntryErrorText,
            f:row { manualEntryRadio, manualEntryLinkButton },
        }

        -- Resolves a 1-based row index (matching props.selectedIndex's
        -- own numbering) to the candidate it represents -- whichever of
        -- the three tabs' own ranges it falls into, or the manual-entry
        -- result. Factored out here so the live thumbnail preview can
        -- reuse the exact same mapping instead of re-deriving it.
        local function candidateForIndex(index)
            if index == MANUAL_INDEX then
                return manualEntryCandidate
            end
            return inatResolveIndex(index) or plantNetResolveIndex(index)
        end

        -- Every downloaded thumbnail's temp path -- declared here so the
        -- cleanup after presentModalDialog can always iterate it
        -- unconditionally.
        local downloadedThumbnailPaths = {}
        local inatThumbnail = f:picture {
            width = INAT_THUMBNAIL_SIZE,
            height = INAT_THUMBNAIL_SIZE,
            frame_width = 1,
            visible = false,
        }
        -- Paging controls for when the selected candidate has more than
        -- one iNat photo (default_photo + taxon_photos -- confirmed live
        -- 2026-08-07 that a taxon can have several).
        local inatPhotoCounterText = f:static_text { title = "", visible = false }
        -- currentINatPaths/currentINatIndex track the CURRENTLY SELECTED
        -- CANDIDATE's own photo list -- unlike the local reference
        -- photo's fixed photoPaths (same for the whole dialog), this set
        -- changes every time the selected row changes, so it's mutable
        -- state here rather than a fixed list captured at dialog-build
        -- time.
        local currentINatPaths = {}
        local currentINatIndex = 1
        -- Forward-declared (not `local ... = f:push_button{...}` below)
        -- so updateINatPhotoNav, defined next, captures these as
        -- upvalues -- a local declared AFTER a function that references
        -- it resolves to a global (nil) instead, not this variable.
        local inatPrevButton, inatNextButton

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
        -- this dialog just reuses the list instead of re-downloading. An
        -- empty list is itself a valid, truthy cached result ("this
        -- candidate has no iNat photos"), so absence from the cache
        -- table alone means "not yet attempted".
        local thumbnailCache = {}
        -- Guards against a slow download finishing after the user has
        -- already moved on to a different row -- only the request that
        -- was still current when it completes is allowed to update the
        -- view.
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
                -- Only apply if nothing more recent has been requested
                -- since this download started.
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
        -- addObserver only fires on future CHANGES, not the current value
        -- at registration time, so kick off a load for the initial
        -- selection too.
        showThumbnailsFor(props.selectedIndex)

        -- Local reference photo + its own paging (unrelated to which
        -- tab/candidate is selected -- this is just "which of the
        -- selected photos am I looking at").
        local localPhotoView = f:picture { value = photoPaths[1], width = 400, height = 400, frame_width = 1 }
        local leftColumnArgs = { localPhotoView }

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

        table.insert(leftColumnArgs, inatThumbnail)
        table.insert(leftColumnArgs, f:row { inatPrevButton, inatPhotoCounterText, inatNextButton })

        -- bind_to_object needed on this outer column too, not just on
        -- each tab panel's own -- the tab_view's own `value` binding
        -- lives here, a sibling of the tab panels, not a descendant of
        -- any one of them.
        local rightColumnArgs = {
            bind_to_object = props,
            f:static_text { title = hint or "Which one is it?" },
        }
        if existingTagText then
            table.insert(rightColumnArgs, f:static_text { title = "Currently tagged: " .. existingTagText })
        end
        table.insert(rightColumnArgs, f:tab_view {
            value = LrView.bind("activeTab"),
            width = CANDIDATE_LIST_WIDTH,
            f:tab_view_item {
                identifier = "inat",
                title = "iNaturalist",
                f:scrolled_view {
                    width = CANDIDATE_LIST_WIDTH,
                    height = CANDIDATE_LIST_HEIGHT,
                    vertical_scroller = true,
                    f:column(inatPanelArgs),
                },
            },
            f:tab_view_item {
                identifier = "plantnet",
                title = "Pl@ntNet",
                f:scrolled_view {
                    width = CANDIDATE_LIST_WIDTH,
                    height = CANDIDATE_LIST_HEIGHT,
                    vertical_scroller = true,
                    f:column(plantNetPanelArgs),
                },
            },
            f:tab_view_item {
                identifier = "manual",
                title = "Manual Entry",
                f:scrolled_view {
                    width = CANDIDATE_LIST_WIDTH,
                    height = CANDIDATE_LIST_HEIGHT,
                    vertical_scroller = true,
                    f:column(manualPanelArgs),
                },
            },
        })

        local contents = f:row {
            f:column(leftColumnArgs),
            f:column(rightColumnArgs),
        }

        local result = LrDialogs.presentModalDialog {
            title = title,
            contents = contents,
            actionVerb = "Tag Photos",
        }

        -- Best-effort cleanup for every thumbnail downloaded during this
        -- dialog's lifetime -- same as INatSyncRunner.lua's
        -- cleanupINatThumbnail, wrapped in pcall since a failure to
        -- delete a scratch temp file isn't worth surfacing to the user.
        for _, path in ipairs(downloadedThumbnailPaths) do
            pcall(os.remove, path)
        end

        if result == "ok" then
            selected = candidateForIndex(props.selectedIndex)
        end
    end)

    return selected
end

return CandidatePicker
