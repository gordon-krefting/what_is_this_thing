local LrPathUtils = import 'LrPathUtils'
local LrFileUtils = import 'LrFileUtils'
local LrTasks = import 'LrTasks'

-- Single consolidated log for the whole plugin (2026-08-09 reorg --
-- replaces two separate hand-rolled logs, inat-sync-log.txt and
-- inat-sync-claim-trace.log, that lived under ~/Photos/local/WhatIsThisThing/
-- and were growing unboundedly forever, with nothing ever pruning them).
--
-- Deliberately NOT under ~/Photos/ at all -- manage_photo_backups.rb's
-- LOCAL_SOURCE sweep backs up everything under ~/Photos/local/ wholesale,
-- and a diagnostic log isn't worth protecting (unlike taxon-data.lua,
-- which stays right where it was). ~/Library/Logs/ is the standard macOS
-- location for this kind of app-owned diagnostic log.
--
-- Deliberately NOT routed through Lightroom's own LrLogger facility --
-- research turned up no confirmation it bounds size or rotates at all,
-- and its own log file location has moved between SDK versions (SDK 14.0
-- changed the Mac path). This project needs a location and a size
-- guarantee it controls directly, not one it has to hope Adobe provides.
local MAX_LOG_SIZE_BYTES = 2 * 1024 * 1024

local PluginLog = {}

local function logDir()
    local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath("home"), "Library")
    dir = LrPathUtils.child(dir, "Logs")
    return LrPathUtils.child(dir, "WhatIsThisThing")
end

local function logPath()
    return LrPathUtils.child(logDir(), "whatisthisthing.log")
end

local function rotatedPath()
    return LrPathUtils.child(logDir(), "whatisthisthing.log.1")
end

function PluginLog.path()
    return logPath()
end

-- Rotates current -> .log.1 (overwriting any previous .log.1) once the
-- log has grown past MAX_LOG_SIZE_BYTES, then lets the caller start a
-- fresh log -- checked before every write, so the log can never grow
-- past roughly this size no matter how long the plugin's been in use.
-- Uses plain os.rename/os.remove, not an LrFileUtils move/copy call --
-- matching the bare os.remove already relied on elsewhere in this plugin
-- (INatSyncRunner.lua's thumbnail cleanup) rather than introducing an
-- unverified SDK function name.
local function rotateIfNeeded(path)
    if not LrFileUtils.exists(path) then
        return
    end
    local content = LrFileUtils.readFile(path)
    if content and #content >= MAX_LOG_SIZE_BYTES then
        local rotated = rotatedPath()
        if LrFileUtils.exists(rotated) then
            os.remove(rotated)
        end
        os.rename(path, rotated)
    end
end

-- Appends `text` (a single line, or a multi-line block -- e.g. one whole
-- sync run's worth of entries in one call) to the consolidated log,
-- rotating first if needed. The caller supplies any timestamp/formatting
-- it wants inside `text` -- this is just a bounded, single-destination
-- appender, not a formatter.
--
-- Wraps its own body in LrTasks.pcall and never raises on failure --
-- plain pcall can't yield across the C-call boundary that local file I/O
-- sometimes crosses in this environment (confirmed live as the root
-- cause of an earlier silently-vanishing log, see DEVELOPMENT_NOTES.md),
-- so every call site gets that fix for free instead of having to
-- remember it individually.
function PluginLog.append(text)
    LrTasks.pcall(function()
        local dir = logDir()
        LrFileUtils.createAllDirectories(dir)
        local path = logPath()
        rotateIfNeeded(path)
        local f = assert(io.open(path, "a"))
        f:write(text .. "\n")
        f:close()
    end)
end

return PluginLog
