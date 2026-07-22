-- Declares custom metadata fields for identifications, so species/rank/
-- confidence become real, structured data -- searchable via Smart
-- Collections and the Library Filter bar -- instead of only living in
-- free-text Title/Caption/keywords.
--
-- Written to via photo:setPropertyForPlugin(_PLUGIN, id, value), read via
-- photo:getPropertyForPlugin(_PLUGIN, id). Values are stored only in
-- Lightroom's own catalog database (confirmed via the SDK guide -- a
-- plug-in cannot link a custom field to XMP or save it into the file
-- itself); acceptable per-project decision, see project memory.
--
-- NAMING NOTE: `observationId` here is a purely local, auto-generated
-- UUID shared by photos identified together in one batch -- NOT the same
-- thing as a future `iNatObservationId` field (a still-separate TODO) that
-- would hold the real observation ID from iNaturalist's own servers. Keep
-- these two clearly distinct if/when the iNat-sync field gets added.
return {
    metadataFieldsForPhotos = {
        {
            id = "scientificName",
            title = "Scientific Name",
            dataType = "string",
            searchable = true,
            browsable = true,
        },
        {
            id = "commonName",
            title = "Common Name",
            dataType = "string",
            searchable = true,
            browsable = true,
        },
        {
            id = "taxonRank",
            title = "Taxon Rank",
            dataType = "enum",
            searchable = true,
            browsable = true,
            values = {
                { value = nil, title = "(unknown)" },
                { value = "species", title = "Species" },
                { value = "subspecies", title = "Subspecies" },
                { value = "variety", title = "Variety" },
                { value = "genus", title = "Genus" },
                { value = "subfamily", title = "Subfamily" },
                { value = "family", title = "Family" },
                { value = "superfamily", title = "Superfamily" },
                { value = "tribe", title = "Tribe" },
                { value = "infraorder", title = "Infraorder" },
                { value = "suborder", title = "Suborder" },
                { value = "order", title = "Order" },
                { value = "subclass", title = "Subclass" },
                { value = "class", title = "Class" },
                { value = "subphylum", title = "Subphylum" },
                { value = "phylum", title = "Phylum" },
                { value = "kingdom", title = "Kingdom" },
                { value = "hybrid", title = "Hybrid" },
                -- Common_ancestor/lowest-common-ancestor results aren't
                -- filtered through MAJOR_RANKS the way the normal ancestry
                -- chain is, so they can legitimately land on any real iNat
                -- rank, including intermediate ones -- this list is every
                -- rank confirmed against real API responses this session
                -- (e.g. Harmonia axyridis's full ancestor chain). Found the
                -- hard way that a value outside the declared list shows as
                -- blank in the Metadata panel's enum popup even with
                -- allowPluginToSetOtherValues set -- that flag apparently
                -- only prevents a write-time error, it doesn't give the
                -- popup a way to display an undeclared value. Kept as a
                -- safety net for anything even more exotic (e.g. "complex").
                allowPluginToSetOtherValues = true,
            },
        },
        {
            id = "idConfidence",
            title = "ID Confidence",
            dataType = "string",
            searchable = true,
        },
        {
            id = "cultivar",
            title = "Cultivar",
            dataType = "string",
            searchable = true,
            browsable = true,
        },
        {
            id = "observationId",
            title = "Observation ID",
            dataType = "string",
            searchable = true,
            -- Auto-assigned by applyIdentification; never hand-typed --
            -- a mistyped UUID would silently break the grouping it exists
            -- for. Visible in the Metadata panel but not user-editable
            -- there; still settable programmatically via
            -- setPropertyForPlugin().
            readOnly = true,
        },

        -- Taxon-level fields (2026-07-22): facts about the *species*, not
        -- the individual photo or observation -- cached in TaxonStore.lua
        -- (a local file, not the catalog) as the source of truth, then
        -- denormalized here so they're visible/searchable in Lightroom's
        -- own panels. All five are readOnly for the same reason: with
        -- potentially dozens of photos sharing one taxon, a hand-edit on
        -- just one photo would silently drift out of sync with the rest --
        -- changes must go through TaxonStore (which fans out to every
        -- matching photo), not the Metadata panel directly.
        --
        -- All plain `string`, not `enum`, even where the underlying value
        -- set is small (e.g. IUCN conservation categories, native/
        -- introduced) -- learned the hard way with Taxon Rank that an enum
        -- value outside the declared list renders blank in the Metadata
        -- panel even when the write itself succeeds. String has no such
        -- gap and needs no value list to maintain.
        {
            id = "conservationStatus",
            title = "Conservation Status",
            dataType = "string",
            searchable = true,
            browsable = true,
            readOnly = true,
        },
        {
            id = "establishmentMeans",
            title = "Establishment Means",
            dataType = "string",
            searchable = true,
            browsable = true,
            readOnly = true,
        },
        {
            id = "growthHabit",
            title = "Growth Habit",
            dataType = "string",
            searchable = true,
            browsable = true,
            -- Manual only -- no reliable API source (GBIF/USDA both
            -- dead ends, see project memory). Set via EditTaxonInfo.lua.
            readOnly = true,
        },
        {
            id = "wikipediaUrl",
            title = "Wikipedia",
            dataType = "url",
            searchable = true,
            readOnly = true,
        },
        {
            id = "notes",
            title = "Species Notes",
            dataType = "string",
            searchable = true,
            -- Manual only, set via EditTaxonInfo.lua.
            readOnly = true,
        },
    },
    schemaVersion = 1,
}
