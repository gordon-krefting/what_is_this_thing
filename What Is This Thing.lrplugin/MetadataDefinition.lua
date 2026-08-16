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
-- thing as `iNatObservationId` below, which holds the real observation ID
-- from iNaturalist's own servers (set by the "Sync from iNaturalist"
-- feature). Keep these two clearly distinct.
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
                { value = "form", title = "Form" },
                { value = "infrahybrid", title = "Infrahybrid" },
                { value = "hybrid", title = "Hybrid" },
                { value = "complex", title = "Complex" },
                { value = "subsection", title = "Subsection" },
                { value = "section", title = "Section" },
                { value = "subgenus", title = "Subgenus" },
                { value = "genus", title = "Genus" },
                { value = "genushybrid", title = "Genus Hybrid" },
                { value = "subtribe", title = "Subtribe" },
                { value = "tribe", title = "Tribe" },
                { value = "supertribe", title = "Supertribe" },
                { value = "subfamily", title = "Subfamily" },
                { value = "family", title = "Family" },
                { value = "epifamily", title = "Epifamily" },
                { value = "superfamily", title = "Superfamily" },
                { value = "zoosubsection", title = "Zoosubsection" },
                { value = "zoosection", title = "Zoosection" },
                { value = "parvorder", title = "Parvorder" },
                { value = "infraorder", title = "Infraorder" },
                { value = "suborder", title = "Suborder" },
                { value = "order", title = "Order" },
                { value = "superorder", title = "Superorder" },
                { value = "subterclass", title = "Subterclass" },
                { value = "infraclass", title = "Infraclass" },
                { value = "subclass", title = "Subclass" },
                { value = "class", title = "Class" },
                { value = "superclass", title = "Superclass" },
                { value = "subphylum", title = "Subphylum" },
                { value = "phylum", title = "Phylum" },
                { value = "kingdom", title = "Kingdom" },
                -- Common_ancestor/lowest-common-ancestor results aren't
                -- filtered through MAJOR_RANKS the way the normal ancestry
                -- chain is, so they can legitimately land on any real iNat
                -- rank, including intermediate ones. This is now the FULL
                -- set iNaturalist itself supports -- pulled directly from
                -- Taxon::RANK_LEVELS in their own source
                -- (github.com/inaturalist/inaturalist, app/models/taxon.rb),
                -- not just whatever had been confirmed against real API
                -- responses so far (2026-08-02, prompted by a real photo
                -- identified as a subtribe, which wasn't in the old,
                -- narrower list). Deliberately excludes "stateofmatter"
                -- (rank_level 100, the root of the whole tree, e.g. "Life")
                -- -- iNaturalist's own VISIBLE_RANKS constant excludes it
                -- too, and no real photo identification would ever
                -- legitimately land there. Found the hard way that a value
                -- outside the declared list shows as blank in the Metadata
                -- panel's enum popup even with allowPluginToSetOtherValues
                -- set -- that flag apparently only prevents a write-time
                -- error, it doesn't give the popup a way to display an
                -- undeclared value. Kept as a safety net regardless, in
                -- case iNaturalist adds another rank in the future.
                allowPluginToSetOtherValues = true,
            },
        },
        {
            id = "taxonId",
            title = "iNat Taxon ID",
            dataType = "string",
            searchable = true,
            -- The iNat TAXON id (the species/genus/etc. itself, e.g.
            -- inaturalist.org/taxa/58514) -- deliberately distinct from
            -- iNatObservationId below (a specific OBSERVATION record).
            -- Written by KeywordWriter.applyIdentification alongside
            -- scientificName/commonName/taxonRank whenever a candidate
            -- carries one (every identification path already resolves
            -- this via INaturalist.getMajorAncestryForCandidate before
            -- reaching applyIdentification, so it's always available in
            -- practice) -- added 2026-08-04 so a report can link out to
            -- "all my observations of this taxon" without a by-name
            -- lookup.
        },
        {
            id = "taxonUrl",
            title = "iNat Taxon Page",
            dataType = "url",
            searchable = true,
            readOnly = true,
            -- Clickable link to the taxon's own iNat page (not a specific
            -- observation -- doesn't need one to exist). Same clickable-
            -- link pattern as iNatObservationUrl/wikipediaUrl below.
            -- Written by KeywordWriter.applyIdentification alongside
            -- taxonId, purely computed from it
            -- ("https://www.inaturalist.org/taxa/" .. taxonId) -- no
            -- separate API call needed. Added 2026-08-09; photos
            -- identified before this existed were backfilled via a
            -- one-off script, since removed (same throwaway-migration-
            -- tool pattern as BackfillTaxonId.lua).
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
            id = "observationNickname",
            title = "Observation Nickname",
            dataType = "string",
            searchable = true,
            browsable = true,
            -- New 2026-08-16, per the user -- distinct from the
            -- specimen-level `nickname` below despite the similar name
            -- and both being free descriptive text. This one is
            -- OBSERVATION-scoped (same mechanism as `cultivar` above --
            -- a plain photo property, fanned out to the observation via
            -- ObservationGroup.expand, no SpecimenStore involved) and
            -- exists to disambiguate an INCOMPLETE identification (e.g.
            -- "goldenrod with red flecks on the leaves" for a genus-only
            -- ID) from other equally-undetermined sightings -- it applies
            -- even to a one-off observation you'll never revisit.
            -- Specimen nickname is the opposite axis: identity of one
            -- PHYSICAL individual tracked across multiple SEPARATE
            -- observations over time, independent of whether its ID is
            -- precise. Cleared alongside the rest of an identification
            -- (see KeywordWriter.lua's IDENTIFICATION_FIELDS) since it
            -- describes that specific ID, not the specimen.
        },
        {
            id = "observationNotes",
            title = "Observation Notes",
            dataType = "string",
            searchable = true,
            -- New 2026-08-16 -- free-form notes about THIS observation
            -- specifically (e.g. "leaves showing early fall color"),
            -- distinct from both observationNickname above (a short
            -- disambiguating LABEL, not general notes -- also shown in
            -- specimen-picker contexts where a long note would look out
            -- of place) and the taxon-level `notes` below (shared across
            -- every photo of the species/cultivar, wrong fit for
            -- something that can genuinely differ photo to photo). Same
            -- mechanism as cultivar/observationNickname -- a plain photo
            -- property, fanned out to the observation via
            -- ObservationGroup.expand. Cleared alongside the rest of an
            -- identification (see KeywordWriter.lua's IDENTIFICATION_FIELDS).
        },

        -- Specimen-level fields (2026-08-11): facts about one enduring
        -- PHYSICAL individual plant, not one identify session -- cached in
        -- SpecimenStore.lua (a local file, like TaxonStore.lua), fanned out
        -- to every photo sharing a specimenId. Optional/opt-in -- most
        -- observations (any non-garden sighting) never get one. All six
        -- readOnly for the same reason as the taxon-level fields below:
        -- editable only through ManageFloraObservation.lua, which fans out
        -- to every photo of that specimen's own observation, not the
        -- Metadata panel directly.
        {
            id = "specimenId",
            title = "Specimen ID",
            dataType = "string",
            searchable = true,
            -- Auto-assigned by ManageFloraObservation.lua; never hand-typed -- same
            -- reasoning as observationId above (a mistyped UUID would
            -- silently break the grouping it exists for).
            readOnly = true,
        },
        {
            id = "gardenLocation",
            title = "Specimen Location",
            dataType = "enum",
            searchable = true,
            browsable = true,
            -- Single-valued, unlike the taxon-level gardenLocations
            -- checklist below -- a specimen is one physical, stationary
            -- plant, so it only ever has one location. Titled "Specimen
            -- Location" (not just "Location") to avoid sitting confusingly
            -- close to approximateLocation above and gardenLocations below.
            -- Values verbatim from PlantBook's own `location` enum.
            values = {
                { value = nil, title = "(unknown)" },
                { value = "backyard", title = "Back Yard" },
                { value = "frontyard", title = "Front Yard" },
                { value = "meadow", title = "Meadow" },
                { value = "meadowgarden", title = "Meadow Garden" },
                { value = "pondarea", title = "Pond Area" },
                { value = "slopegarden", title = "Slope Garden" },
                { value = "other", title = "The Woods" },
            },
            allowPluginToSetOtherValues = true,
            readOnly = true,
        },
        {
            id = "locationNotes",
            title = "Specimen Location Notes",
            dataType = "string",
            searchable = true,
            -- New 2026-08-16, per the user -- a free-text note about
            -- specifically where THIS specimen is (e.g. "near the big
            -- oak, north side"), distinct from the taxon-level
            -- gardenLocations checklist's own per-location descriptions
            -- (those describe where the SPECIES as a whole has been
            -- seen, one description per checked location; this describes
            -- one specimen's own single location in more detail).
            readOnly = true,
        },
        {
            id = "plantingMethod",
            title = "Introduction Method",
            dataType = "enum",
            searchable = true,
            browsable = true,
            -- Field id stays `plantingMethod` (only the display title
            -- changed, 2026-08-15, per the user) -- values verbatim from
            -- PlantBook's own `introduced` enum, aside from "preexistent"'s
            -- title (was "Preexistent", now "Natural"; the stored value
            -- string itself is unchanged). Note this title choice does
            -- reintroduce some overlap with establishmentMeans below
            -- (native/introduced, iNat's ecological sense) -- flagged to
            -- the user, who confirmed it's fine given the two fields sit
            -- in different panel sections (Specimen vs. Species Info).
            values = {
                { value = nil, title = "(unknown)" },
                { value = "preexistent", title = "Natural" },
                { value = "seed", title = "Seeding" },
                { value = "bulb", title = "Bulbs" },
                { value = "plant", title = "Planting" },
            },
            allowPluginToSetOtherValues = true,
            readOnly = true,
        },
        {
            id = "plantingYear",
            title = "Introduction Year",
            dataType = "string",
            searchable = true,
            browsable = true,
            -- Field id stays `plantingYear` (only the display title
            -- changed, 2026-08-16, per the user, matching the same
            -- title-only-rename precedent as plantingMethod/"Introduction
            -- Method" above) -- see TODO.md for the parked broader
            -- cleanup renaming both underlying field ids to match.
            readOnly = true,
        },
        {
            id = "nickname",
            title = "Specimen Nickname",
            dataType = "string",
            searchable = true,
            browsable = true,
            -- Purely descriptive, e.g. "The tall, shaggy goldenrod" -- not
            -- a stand-in for a real identification. Exists for cases like
            -- several visually-similar species only identifiable to genus
            -- (e.g. several yard Solidago), where Specimen is what keeps
            -- them from collapsing into one undifferentiated entry, but
            -- they still need a human label to tell apart in a list.
            readOnly = true,
        },

        {
            id = "approximateLocation",
            title = "Approximate Location",
            dataType = "enum",
            searchable = true,
            browsable = true,
            -- Set automatically whenever GpsPrompt.lua fills in missing GPS
            -- via hand-typed coordinates (per the user, usually a memory/
            -- Google Maps guess, not precise) -- NOT set for the "Use Home"
            -- fallback, which is accurate to within ~100 yards and treated
            -- as close enough not to need flagging. User-editable afterward
            -- in the Metadata panel (e.g. to clear it once they've confirmed
            -- an exact location some other way). The `nil` entry must be
            -- declared explicitly, or the panel's dropdown has nothing to
            -- switch back to once "Yes" is set -- confirmed live: with only
            -- "yes" declared, there was no way to un-flag a photo from the
            -- panel at all. Inverse of the Taxon Rank lesson (there, an
            -- undeclared *non-nil* value rendered blank); here it's the
            -- reverse -- nil itself needs to be a selectable choice.
            values = {
                { value = nil, title = "No" },
                { value = "yes", title = "Yes" },
            },
        },
        {
            id = "iNatRecoveredPlaceholder",
            title = "iNat Recovered Placeholder",
            dataType = "enum",
            searchable = true,
            browsable = true,
            -- Set by "Recover Missing Photos from iNaturalist" on every
            -- photo it downloads/imports (never on a pre-existing sibling
            -- in an absorbed group) -- iNat caps every stored photo at
            -- 2048px on the long edge regardless of source, so these are
            -- accepted lower-quality placeholders, not real backups. This
            -- is the queue for a future manual pass replacing them with
            -- higher-quality originals from Apple Photos once that
            -- workflow exists -- filter a Smart Collection on this being
            -- "Yes" to find them all. Same nil/"yes" enum shape as
            -- approximateLocation above, for the same reason (nil must be
            -- an explicit, selectable choice so a photo can be manually
            -- un-flagged once replaced).
            values = {
                { value = nil, title = "No" },
                { value = "yes", title = "Yes" },
            },
        },
        {
            id = "pendingMetadataSave",
            title = "Pending Metadata Save",
            dataType = "enum",
            searchable = true,
            browsable = true,
            -- Set by PendingMetadataSave.markIfNeeded whenever a plugin
            -- command writes metadata to a photo while its file isn't
            -- currently reachable on disk (e.g. an unmounted archive
            -- drive) -- Lightroom's catalog write still succeeds, but it
            -- never gets flushed to the actual file/XMP sidecar until
            -- something explicitly saves it, and there's no reliable
            -- native way to find these later (Lightroom's own "Metadata
            -- Status" Smart Collection criterion is a confirmed Lightroom
            -- Classic bug; "Edit Date" doesn't work either, since Save
            -- Metadata to Files itself bumps it). Every flagged photo is
            -- ALSO kept in sync with membership in a "Pending Metadata
            -- Save" collection (see PendingMetadataSave.lua) -- that
            -- collection, not this field directly, is the actual
            -- workflow: open it, select what's there, Metadata > Save
            -- Metadata to Files, then remove them from the collection (or
            -- delete it) once satisfied. This field exists alongside it
            -- for Metadata-panel visibility/searchability. Same nil/"yes"
            -- enum shape as approximateLocation/iNatRecoveredPlaceholder
            -- above, for the same reason.
            values = {
                { value = nil, title = "No" },
                { value = "yes", title = "Yes" },
            },
            readOnly = true,
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
        {
            id = "iNatObservationId",
            title = "iNat Observation ID",
            dataType = "string",
            searchable = true,
            -- The REAL iNaturalist observation id (from the "Sync from
            -- iNaturalist" feature), deliberately distinct from the
            -- purely-local `observationId` above -- that one is a
            -- plugin-generated UUID that never leaves the catalog; this one
            -- identifies a real record on iNat's own servers. Auto-set by
            -- the sync, never hand-typed.
            readOnly = true,
        },
        {
            id = "iNatObservationUrl",
            title = "iNat Observation",
            dataType = "url",
            searchable = true,
            -- Same clickable-link pattern as the existing wikipediaUrl
            -- field. Written alongside iNatObservationId.
            readOnly = true,
        },
        {
            id = "iNatQualityGrade",
            title = "iNat Quality Grade",
            dataType = "enum",
            searchable = true,
            browsable = true,
            -- Written/refreshed on every sync (not just first link), since
            -- it can improve (or regress) over time as identifications and
            -- votes accrue on iNat's side. `allowPluginToSetOtherValues`
            -- as a safety net for any future iNat grade this list doesn't
            -- yet know about -- see the Taxon Rank field above for why an
            -- undeclared enum value would otherwise render blank.
            values = {
                { value = nil, title = "(not synced)" },
                { value = "casual", title = "Casual" },
                { value = "needs_id", title = "Needs ID" },
                { value = "research", title = "Research Grade" },
            },
            allowPluginToSetOtherValues = true,
            readOnly = true,
        },
        {
            id = "iNatSuggestedId",
            title = "iNat Suggested ID (Unreviewed)",
            dataType = "string",
            searchable = true,
            browsable = true,
            -- Set when someone other than the account owner has proposed a
            -- DIFFERENT taxon more recently than the owner's own last
            -- identification on that observation (or the owner never
            -- identified it at all) -- i.e. a suggestion sitting there
            -- unanswered. Blank (not just untouched) once answered, so a
            -- Smart Collection filtering on "is not empty" always reflects
            -- the current state as of the last sync, not a stale flag.
            readOnly = true,
        },

        -- Taxon-level fields (2026-07-22, extended 2026-08-11): facts about
        -- the *species* (or, for growthHabit/nativity/gardenLocations/
        -- notes, a specific *cultivar* of it -- see TaxonStore.lua's
        -- cultivar-aware get/set), not the individual photo or observation
        -- -- cached in TaxonStore.lua (a local file, not the catalog) as
        -- the source of truth, then denormalized here so they're
        -- visible/searchable in Lightroom's own panels. All are readOnly
        -- for the same reason: with potentially dozens of photos sharing
        -- one taxon, a hand-edit on just one photo would silently drift
        -- out of sync with the rest -- changes must go through TaxonStore
        -- (which fans out to every matching photo), not the Metadata panel
        -- directly.
        --
        -- Mostly plain `string`, not `enum`, even where the underlying
        -- value set is small (e.g. IUCN conservation categories, iNat's
        -- own establishment-means terms) -- learned the hard way with
        -- Taxon Rank that an enum value outside the declared list renders
        -- blank in the Metadata panel even when the write itself succeeds.
        -- String has no such gap and needs no value list to maintain.
        -- growthHabit/nativity are the deliberate exceptions -- their
        -- value sets are small, stable, and shared with PlantBook's own
        -- enums, so the enum's structure/filterability is worth the
        -- `allowPluginToSetOtherValues` safety net that gap requires.
        -- gardenLocations is a further exception: not an enum despite a
        -- fixed value set, because its real shape is a multi-select
        -- checklist, not a single value at all (see its own comment).
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
            dataType = "enum",
            version = 2,
            searchable = true,
            browsable = true,
            -- Manual only -- no reliable API source (GBIF/USDA both
            -- dead ends, see project memory). Set via ManageFloraObservation.lua.
            -- Converted from a free string to this enum 2026-08-11 --
            -- values reused verbatim from PlantBook's own `plantType`
            -- enum, so the eventual website-generation phase can reuse
            -- book_formatter/values.py's PLANTING_TYPES-style dict almost
            -- as-is. allowPluginToSetOtherValues as a safety net (see
            -- Taxon Rank's own comment above for why).
            --
            -- `version = 2` required here (confirmed live 2026-08-15,
            -- Lightroom refused to upgrade the catalog without it): unlike
            -- adding a brand-new field (no prior registration to conflict
            -- with), changing an EXISTING field's dataType needs an
            -- explicit per-field version bump, or Lightroom has no way to
            -- know this is an intentional change to how already-stored
            -- data should be reinterpreted, not a plugin bug.
            values = {
                { value = nil, title = "(unknown)" },
                { value = "tree", title = "Tree" },
                { value = "shrub", title = "Shrub" },
                { value = "forb", title = "Forb" },
                { value = "fern", title = "Fern" },
                { value = "fungus", title = "Fungus" },
                { value = "grass", title = "Grass, Sedge or Rush" },
                { value = "vine", title = "Vine" },
                { value = "otherplant", title = "Other" },
            },
            allowPluginToSetOtherValues = true,
            readOnly = true,
        },
        {
            id = "nativity",
            title = "Nativity",
            dataType = "enum",
            searchable = true,
            browsable = true,
            -- New 2026-08-11, from PlantBook's own `nativity` enum
            -- (values verbatim) -- deliberately kept separate from
            -- establishmentMeans above (auto-pulled from iNat) rather than
            -- merged, per the user. Manual only, set via ManageFloraObservation.lua.
            values = {
                { value = nil, title = "(unknown)" },
                { value = "native", title = "Native" },
                { value = "nonnative", title = "Non-native" },
                { value = "invasive", title = "Invasive" },
            },
            allowPluginToSetOtherValues = true,
            readOnly = true,
        },
        {
            id = "gardenLocations",
            title = "Garden Locations",
            dataType = "string",
            searchable = true,
            browsable = true,
            -- New 2026-08-11 -- a multi-select checklist of garden
            -- locations this SPECIES is known to grow in (distinct from
            -- the specimen-level, single-valued `gardenLocation` above --
            -- a Lightroom metadata field id must be unique per plugin, and
            -- a specimen-linked photo needs both as separate rows). Real
            -- storage in TaxonStore.lua is a map ({ [locationValue] =
            -- descriptionOrFalse }), edited via checkboxes in
            -- ManageFloraObservation.lua -- this field is a plain readOnly string,
            -- a computed joined rendering (e.g. "Meadow (near the big
            -- oak); Pond Area") for panel display/search, since Lightroom's
            -- metadata dataTypes have no native multi-select/map shape.
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
            -- Manual only, set via ManageFloraObservation.lua.
            readOnly = true,
        },
    },
    schemaVersion = 1,
}
