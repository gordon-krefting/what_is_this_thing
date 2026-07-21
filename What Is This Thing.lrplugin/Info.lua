return {
    LrSdkVersion = 6.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'org.krefting.whatisthisthing',
    LrPluginName = "What is this Thing?",

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
    },

    VERSION = { major = 0, minor = 1, revision = 0, build = 0 },
}
