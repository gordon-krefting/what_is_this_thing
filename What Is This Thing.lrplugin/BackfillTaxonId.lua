local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'

local INaturalist = dofile(LrPathUtils.child(_PLUGIN.path, "INaturalist.lua"))

-- catalog:findPhotosWithProperty requires the plug-in's toolkit identifier
-- as a plain string (unlike get/setPropertyForPlugin, which also accept
-- the _PLUGIN object) -- must match Info.lua's LrToolkitIdentifier exactly.
local TOOLKIT_ID = "org.krefting.whatisthisthing"

-- Manual, catalog-wide backfill -- taxonId (added 2026-08-04, see
-- MetadataDefinition.lua) is only ever written going forward by
-- KeywordWriter.applyIdentification, so every photo identified before that
-- existed has scientificName but no taxonId. One-off, not needed for
-- day-to-day use once run -- every identification from here on already
-- gets taxonId for free.
--
-- Resolves by scientific name via the same INaturalist.getMajorAncestryForCandidate
-- path Pl@ntNet-sourced identifications already rely on for exactly this
-- ("candidate carries no id of its own") -- one exact-name lookup per
-- DISTINCT species missing taxonId, not per photo, then writes the
-- resolved id to every photo of that species at once. A species iNat's
-- exact-match name search can't resolve (renamed/typo'd/no longer valid)
-- is skipped and listed in the summary, not guessed at.
LrTasks.startAsyncTask(function()
    local catalog = LrApplication.activeCatalog()

    local identifiedPhotos = catalog:findPhotosWithProperty(TOOLKIT_ID, "scientificName")

    local bySpecies = {}
    local speciesOrder = {}
    for _, photo in ipairs(identifiedPhotos) do
        if not photo:getPropertyForPlugin(_PLUGIN, "taxonId") then
            local name = photo:getPropertyForPlugin(_PLUGIN, "scientificName")
            if name then
                local entry = bySpecies[name]
                if not entry then
                    entry = { rank = photo:getPropertyForPlugin(_PLUGIN, "taxonRank"), photos = {} }
                    bySpecies[name] = entry
                    table.insert(speciesOrder, name)
                end
                table.insert(entry.photos, photo)
            end
        end
    end

    if #speciesOrder == 0 then
        LrDialogs.message("Backfill Taxon ID", "Every locally-identified photo already has a taxon id.", "info")
        return
    end

    local progressScope = LrProgressScope({ title = "Backfill Taxon ID" })
    progressScope:setCancelable(true)

    local resolvedIds = {}
    local unresolvedNames = {}
    for i, name in ipairs(speciesOrder) do
        if progressScope:isCanceled() then
            break
        end
        progressScope:setCaption("Resolving " .. name .. "...")
        progressScope:setPortionComplete(i - 1, #speciesOrder)

        -- getMajorAncestryForCandidate makes TWO sequential requests per
        -- species (a name search, then a detail fetch by id) with no retry
        -- on either -- confirmed live 2026-08-04: a real backfill run left
        -- ~5% of species unresolved, including one (Danaus plexippus)
        -- independently confirmed to resolve cleanly via a direct,
        -- one-off API call -- pointing at transient failures under this
        -- command's specific back-to-back-request pattern, not a real
        -- name-match problem. One retry, after a pause distinct from the
        -- steady between-species pacing below, before actually giving up
        -- on a species.
        local candidate = { scientificName = name, rank = bySpecies[name].rank }
        local resolveOk, resolvedCandidate = LrTasks.pcall(INaturalist.getMajorAncestryForCandidate, candidate)
        if not (resolveOk and resolvedCandidate and resolvedCandidate.id) then
            LrTasks.sleep(2.0)
            resolveOk, resolvedCandidate = LrTasks.pcall(INaturalist.getMajorAncestryForCandidate, candidate)
        end
        if resolveOk and resolvedCandidate and resolvedCandidate.id then
            resolvedIds[name] = tostring(resolvedCandidate.id)
        else
            table.insert(unresolvedNames, name)
        end

        -- Same pacing already used for paginated iNat requests elsewhere
        -- in this plugin (INaturalist.lua) -- this can be dozens of
        -- sequential one-off lookups, unlike a single paginated pull.
        if i < #speciesOrder then
            LrTasks.sleep(1.0)
        end
    end

    local photoCount, speciesCount = 0, 0
    catalog:withWriteAccessDo("Backfill taxon id", function()
        for name, taxonId in pairs(resolvedIds) do
            speciesCount = speciesCount + 1
            for _, photo in ipairs(bySpecies[name].photos) do
                photo:setPropertyForPlugin(_PLUGIN, "taxonId", taxonId)
                photoCount = photoCount + 1
            end
        end
    end)

    progressScope:done()

    local message = string.format(
        "%d photo%s across %d species backfilled with a taxon id.",
        photoCount, photoCount == 1 and "" or "s", speciesCount
    )
    if #unresolvedNames > 0 then
        message = message .. string.format(
            "\n\n%d species couldn't be resolved (no exact iNaturalist name match -- renamed or misspelled?):\n%s",
            #unresolvedNames, table.concat(unresolvedNames, "\n")
        )
    end
    if progressScope:isCanceled() then
        message = message .. "\n\n(Stopped early -- run again to pick up the rest.)"
    end
    LrDialogs.message("Backfill Taxon ID", message, "info")
end)
