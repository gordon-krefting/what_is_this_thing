local LrPathUtils = import 'LrPathUtils'

-- Pulls the user's own iNaturalist observations, matches them to local
-- photos, and applies the current (agreed-with) species ID plus a link
-- back to the observation page. Full pull the first time it's ever run;
-- only changed observations (via `updated_since`) on every run after, plus
-- anything still on the retry list from a previous run that failed to
-- apply. See INatSyncRunner.lua for the actual orchestration -- this file
-- is just a thin entry point, shared with FullSyncFromINaturalist.lua's
-- "always pull everything" variant.
local INatSyncRunner = dofile(LrPathUtils.child(_PLUGIN.path, "INatSyncRunner.lua"))
INatSyncRunner.run({})
