local LrExportSession = import 'LrExportSession'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local ExportTemp = {}

-- Exports the given photos to JPEGs in a fresh temp subfolder, so RAW (or
-- any non-JPEG) files can be sent to an identification API that only
-- understands standard image formats.
-- Returns (paths, tempDir, sourcePhotos); caller must call
-- ExportTemp.cleanup(tempDir) once done with the exported files.
-- sourcePhotos[i] is the original LrPhoto that paths[i] was rendered from
-- (via rendition.photo) -- callers that only need the file paths can
-- ignore this third return value.
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
            -- Cap the longest edge instead of sending full-resolution
            -- originals: identification APIs don't need more than this for
            -- accuracy, and iNaturalist's backend has been observed to fail
            -- ("Error scoring image", 500) on at least one full-size photo
            -- that its own web uploader (which resizes client-side before
            -- upload) handled fine.
            LR_size_doConstrain = true,
            LR_size_maxWidth = 2048,
            LR_size_maxHeight = 2048,
        },
    }

    local paths = {}
    local sourcePhotos = {}
    for _, rendition in exportSession:renditions() do
        local success, pathOrMessage = rendition:waitForRender()
        if not success then
            error("JPEG export failed: " .. tostring(pathOrMessage))
        end
        table.insert(paths, pathOrMessage)
        table.insert(sourcePhotos, rendition.photo)
    end

    return paths, tempDir, sourcePhotos
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
