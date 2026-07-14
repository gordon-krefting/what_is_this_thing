local LrExportSession = import 'LrExportSession'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local ExportTemp = {}

-- Exports the given photos to JPEGs in a fresh temp subfolder, so RAW (or
-- any non-JPEG) files can be sent to an identification API that only
-- understands standard image formats.
-- Returns (paths, tempDir); caller must call ExportTemp.cleanup(tempDir)
-- once done with the exported files.
function ExportTemp.exportToTempJpegs(photos)
    local tempDir = LrPathUtils.child(
        LrPathUtils.getStandardFilePath("temp"),
        "WhatIsThisThing-" .. tostring(math.random(1000000000))
    )
    LrFileUtils.createAllDirectories(tempDir)

    local exportSession = LrExportSession {
        photosToExport = photos,
        exportSettings = {
            LR_format = "JPEG",
            LR_jpeg_quality = 0.9,
            LR_export_destinationType = "specificFolder",
            LR_export_destinationPathPrefix = tempDir,
            LR_export_useSubfolder = false,
            LR_collisionHandling = "uniqueName",
            LR_reimportExportedPhoto = false,
        },
    }

    local paths = {}
    for _, rendition in exportSession:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if not success then
            error("JPEG export failed: " .. tostring(pathOrMessage))
        end
        table.insert(paths, pathOrMessage)
    end

    return paths, tempDir
end

function ExportTemp.cleanup(tempDir)
    if not tempDir then
        return
    end
    for filePath in LrFileUtils.files(tempDir) do
        LrFileUtils.delete(filePath)
    end
    LrFileUtils.delete(tempDir)
end

return ExportTemp
