return {
    LrSdkVersion = 6.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'org.krefting.whatisthisthing',
    LrPluginName = "What is this Thing?",

    LrMetadataProvider = "MetadataDefinition.lua",

    LrExportMenuItems = {
        {
            title = "iNaturalist Identification",
            file = "WhatIsThisAnimal.lua",
        },
        {
            title = "Pl@ntNet Identification",
            file = "WhatIsThisPlant.lua",
        },
        {
            title = "Export for iNaturalist",
            file = "ExportForINaturalist.lua",
        },
        {
            title = "Update Location from GPX",
            file = "UpdateLocationFromGpx.lua",
        },
        {
            title = "Set Cultivar",
            file = "SetCultivar.lua",
        },
        {
            title = "Edit Taxon Info",
            file = "EditTaxonInfo.lua",
        },
        {
            title = "Split Observation",
            file = "SplitObservation.lua",
        },
        {
            title = "Merge Observation",
            file = "MergeObservation.lua",
        },
        {
            title = "Set iNat Observation",
            file = "SetINatObservation.lua",
        },
        {
            title = "Sync from iNaturalist",
            file = "SyncFromINaturalist.lua",
        },
        {
            title = "Full Sync from iNaturalist",
            file = "FullSyncFromINaturalist.lua",
        },
        {
            title = "Show iNat Sync State (one-off)",
            file = "ShowINatSyncState.lua",
        },
        {
            title = "Show Observation Filenames (one-off)",
            file = "ShowObservationFilenames.lua",
        },
        {
            title = "Rebuild Mismatch List (one-off)",
            file = "RebuildMismatchList.lua",
        },
    },

    VERSION = { major = 0, minor = 1, revision = 0, build = 0 },
}
