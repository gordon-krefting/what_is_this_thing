-- Hard-coded home location, shared by GpsPrompt.lua (the "Use Home" fallback
-- for photos with no GPS) and INaturalist.lua (the reference point for the
-- Establishment Means radius check). Previously user-configurable via a
-- "Save as home location" checkbox in the "No GPS Data" dialog, stored in
-- LrPrefs -- fixed to a single constant instead (2026-07-22) and no longer
-- editable from that dialog. Kept in its own file rather than duplicated as
-- a literal in both places, since a typo in one of two copies of a
-- 17-significant-digit coordinate would be easy to miss.
return {
    lat = 41.30309775170536,
    lng = -74.23935760947066,
}
