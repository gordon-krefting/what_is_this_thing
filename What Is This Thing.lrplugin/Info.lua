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
    },

    VERSION = { major = 0, minor = 1, revision = 0, build = 0 },
}
