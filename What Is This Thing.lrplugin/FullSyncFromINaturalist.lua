local LrPathUtils = import 'LrPathUtils'

-- Same as "Sync from iNaturalist", but always pulls the ENTIRE observation
-- history, ignoring the stored `updated_since` cursor -- for whenever the
-- matching/apply logic itself changes and old results need reconsidering
-- (came up often enough during development that a separate one-off
-- cursor-reset tool plus a normal sync was more friction than it was
-- worth). Still updates the cursor at the end of a successful run, so
-- your NEXT regular "Sync from iNaturalist" goes back to being a fast
-- incremental check -- this is "pull everything this one time," not "stay
-- in full-pull mode forever." See INatSyncRunner.lua for the shared
-- orchestration.
local INatSyncRunner = dofile(LrPathUtils.child(_PLUGIN.path, "INatSyncRunner.lua"))
INatSyncRunner.run({ forceFullPull = true })
