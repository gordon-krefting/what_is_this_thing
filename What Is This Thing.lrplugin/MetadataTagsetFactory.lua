-- Defines a "What is this Thing?" entry in the Metadata panel's view
-- dropdown (alongside Lightroom's built-in Default/EXIF/IPTC/etc. and any
-- personal custom presets), showing this plugin's own custom fields
-- grouped into sections -- ships with the plugin, so it's available to
-- anyone who installs it, unlike a personal per-machine custom preset.
--
-- Registered via LrMetadataTagsetFactory in Info.lua, a sibling
-- declaration to LrMetadataProvider (MetadataDefinition.lua) -- confirmed
-- via a real working example (Lightroom-CR2-White-Balance's
-- MetadataTagsetFactory.lua) that this file returns a SINGLE tagset table
-- (id/title/items), not an array; multiple tagsets would need multiple
-- files listed in Info.lua instead.
--
-- Custom field ids in `items` must be fully qualified with this plugin's
-- own LrToolkitIdentifier ("org.krefting.whatisthisthing.<fieldId>") --
-- confirmed via the same real-world example, which uses this exact
-- "<toolkit id>.<field id>" form for its own custom fields. Hardcoded as
-- literal strings (matching that example) rather than built from
-- _PLUGIN.id, since a tagset-factory file's execution context isn't
-- necessarily the same as a command file's.
--
-- `{ 'com.adobe.label', label = "..." }` entries are a pseudo-field
-- Lightroom recognizes as a section header within the tagset, not a real
-- metadata field -- also confirmed via the same working example.
--
-- Built-in field ids (the "Photo" section below) confirmed against the
-- SDK's own predefined-field list, not guessed:
--   - `dateCreated`, not `dateTimeOriginal` -- the latter is read-only,
--     EXIF-derived, and confirmed live to show blank on recovered photos
--     (see DEVELOPMENT_NOTES.md); dateCreated is the one this plugin
--     actually writes and is guaranteed populated either way.
--   - No true "file path" field exists in the SDK's list -- `folder`
--     (the containing folder's name only, not a full path) is the
--     closest available.
--   - IPTC has one Caption/Description field, exposed as `caption` --
--     there's no field distinct from that for "description".
--
-- NOT yet confirmed live -- first real thing to check after this change:
-- does "What is this Thing?" actually appear in the Metadata panel's
-- dropdown, with these fields grouped and labeled as expected.
return {
    title = "What is this Thing?",
    id = "WhatIsThisThingTagset",
    items = {
        { "com.adobe.label", label = "Photo" },
        "com.adobe.filename",
        "com.adobe.folder",
        "com.adobe.dateCreated",
        "com.adobe.GPS",
        "com.adobe.imageCroppedDimensions",
        "com.adobe.imageFileDimensions",
        "com.adobe.title",
        "com.adobe.caption",
        "com.adobe.rating",
        "com.adobe.copyright",

        { "com.adobe.label", label = "Identification" },
        "org.krefting.whatisthisthing.scientificName",
        "org.krefting.whatisthisthing.commonName",
        "org.krefting.whatisthisthing.taxonRank",
        "org.krefting.whatisthisthing.taxonId",
        "org.krefting.whatisthisthing.idConfidence",
        "org.krefting.whatisthisthing.cultivar",

        { "com.adobe.label", label = "Species Info" },
        "org.krefting.whatisthisthing.conservationStatus",
        "org.krefting.whatisthisthing.establishmentMeans",
        "org.krefting.whatisthisthing.growthHabit",
        "org.krefting.whatisthisthing.wikipediaUrl",
        "org.krefting.whatisthisthing.notes",

        { "com.adobe.label", label = "iNaturalist Link" },
        "org.krefting.whatisthisthing.iNatObservationId",
        "org.krefting.whatisthisthing.iNatObservationUrl",
        "org.krefting.whatisthisthing.iNatQualityGrade",
        "org.krefting.whatisthisthing.iNatSuggestedId",

        { "com.adobe.label", label = "Grouping & Flags" },
        "org.krefting.whatisthisthing.observationId",
        "org.krefting.whatisthisthing.approximateLocation",
        "org.krefting.whatisthisthing.iNatRecoveredPlaceholder",
    },
}
