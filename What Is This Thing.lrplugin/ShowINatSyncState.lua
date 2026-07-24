local LrPrefs = import 'LrPrefs'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'

-- One-off diagnostic: shows the raw stored sync state, to root-cause why
-- every "Sync from iNaturalist" run has pulled the same full 701
-- observations instead of narrowing via `updated_since` on later runs.
local prefs = LrPrefs.prefsForPlugin()
local lastSync = prefs.lastINatSyncAt
local retryIds = prefs.iNatPendingRetryIds or {}

local message
if lastSync then
    local ok, asString = pcall(LrDate.timeToW3CDate, lastSync)
    message = "lastINatSyncAt (raw number): " .. tostring(lastSync)
        .. "\nlastINatSyncAt (as date): " .. (ok and asString or "(failed to convert: " .. tostring(asString) .. ")")
else
    message = "lastINatSyncAt is nil -- no cursor has ever been stored."
end
message = message .. "\n\nPending retry list: " .. #retryIds .. " observation(s)."
message = message .. "\n\niNat username stored: " .. tostring(prefs.iNatUsername)

LrDialogs.message("iNat Sync State", message, "info")
