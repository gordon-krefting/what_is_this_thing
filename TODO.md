# Project TODO

The single canonical todo list for this project. When asked to save
something as a todo, it goes here. When asked "what's on the todo list,"
this file is the answer -- not memory, not conversation history.

Completed items are deleted, not checked off -- `git log`/`DEVELOPMENT_NOTES.md`
already have the history of what shipped and when.

- Bound unbounded log growth (`inat-sync-log.txt`,
  `inat-sync-claim-trace.log`, `inat-recovery-log.txt`)
- Add a way to refresh iNat taxonomy for local-only observations (never
  uploaded to iNat)
- Design an iPhone -> Lightroom workflow for all photos (not just iNat
  observations)
- Show local + iNat observation counts for the selected species (deferred
  to the ID-process redo)
- Design a report with info about local observations (spec TBD)
- Graceful degradation when the external archive drive isn't mounted
- Trim the one-off diagnostics (e.g. `logClaim`/`inat-sync-claim-trace.log`,
  no longer needed since the species-first sync redesign)
