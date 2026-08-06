local LrExportSession = import 'LrExportSession'
local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'

local ExportTemp = {}

-- Shared by exportToTempJpegs and exportToTempDisplayJpegs below -- same
-- fresh-temp-subfolder + LrExportSession + waitForRender mechanics, just
-- a different size cap for each's own purpose.
-- Returns (paths, tempDir, sourcePhotos); caller must call
-- ExportTemp.cleanup(tempDir) once done with the exported files.
-- sourcePhotos[i] is the original LrPhoto that paths[i] was rendered from
-- (via rendition.photo) -- callers that only need the file paths can
-- ignore this third return value.
local function exportToTempJpegsAtSize(photos, maxSize)
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
            LR_size_doConstrain = true,
            LR_size_maxWidth = maxSize,
            LR_size_maxHeight = maxSize,
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

-- Exports the given photos to JPEGs in a fresh temp subfolder, so RAW (or
-- any non-JPEG) files can be sent to an identification API that only
-- understands standard image formats.
--
-- Caps the longest edge at 2048 instead of sending full-resolution
-- originals: identification APIs don't need more than this for accuracy,
-- and iNaturalist's backend has been observed to fail ("Error scoring
-- image", 500) on at least one full-size photo that its own web uploader
-- (which resizes client-side before upload) handled fine.
function ExportTemp.exportToTempJpegs(photos)
    return exportToTempJpegsAtSize(photos, 2048)
end

-- Same as exportToTempJpegs, but capped at 800 -- for CandidatePicker.lua's
-- on-screen reference photo (a fixed 400x400 box) instead of the API
-- upload. 800, not 400: Lightroom's view sizes are in points, and a
-- Retina display renders a 400x400-point box at roughly 800x800 physical
-- pixels -- exporting at exactly 400 would look visibly soft on any
-- Retina screen once upscaled to fill it. Kept as a SEPARATE export
-- (rather than just reusing exportToTempJpegs' own 2048px files for
-- display too) because decoding a full 2048px JPEG on every paging click
-- was noticeably laggy live -- confirmed 2026-08-07.
function ExportTemp.exportToTempDisplayJpegs(photos)
    return exportToTempJpegsAtSize(photos, 800)
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
