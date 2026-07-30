local LrPathUtils = import 'LrPathUtils'

-- Pulls the user's own iNaturalist observations, matches them to local
-- photos, and applies the current (agreed-with) species ID plus a link
-- back to the observation page. INatSyncRunner.run() itself now asks
-- (via a small pre-flight dialog) whether this should be a full history
-- pull or an incremental one -- this used to be a separate "Full Sync
-- from iNaturalist" menu command, folded into this single entry point as
-- part of the 2026-07-29 consolidation (also absorbing what was
-- "Recover Missing Photos from iNaturalist" as an inline, per-observation
-- step -- see DEVELOPMENT_NOTES.md). See INatSyncRunner.lua for the
-- actual orchestration -- this file is just a thin entry point.
local INatSyncRunner = dofile(LrPathUtils.child(_PLUGIN.path, "INatSyncRunner.lua"))
INatSyncRunner.run({})
