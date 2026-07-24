local LrPathUtils = import 'LrPathUtils'

local INatSyncRunner = dofile(LrPathUtils.child(_PLUGIN.path, "INatSyncRunner.lua"))

-- One-off migration tool: the bounded pending-mismatch list
-- (iNatPendingMismatchIds) only ever rechecks observation ids already ON
-- it, so mismatches logged BEFORE that list existed (or before a
-- comparison-logic fix, like the filename-count-gate one) never get
-- re-evaluated -- they just sit there stale forever, since a normal sync
-- has no reason to look at an already-linked, unchanged group again.
--
-- Confirmed live: after the filename-count-gate fix shipped, the mismatch
-- report looked completely unchanged and the entries no longer looked
-- like real mismatches -- checking Lightroom's own preferences plist
-- directly showed iNatPendingMismatchIds didn't even exist yet, and the
-- report file's own timestamp hadn't moved.
--
-- Runs a full, forced recheck of the user's ENTIRE observation history
-- exactly once (via INatSyncRunner's forceRecheckAll option), correctly
-- repopulating the bounded pending list under whatever the CURRENT
-- matching/comparison logic is. Same temporary-tool pattern as
-- BackfillMetadata.lua/RefreshTaxonomy.lua before it -- remove this file
-- and its Info.lua entry once it's been run and the pending list is
-- trustworthy again; don't leave it in the permanent menu, since routine
-- syncs should never pay this full-history cost.
INatSyncRunner.run({ forceFullPull = true, forceRecheckAll = true })
